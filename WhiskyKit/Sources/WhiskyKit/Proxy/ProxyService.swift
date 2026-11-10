//
//  ProxyService.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

private let proxyLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "Proxy")

/// Runs one helper (``ProxyListener``) per proxied bottle, inside the Ano app.
/// Programs lose their network when it stops; they never fall back to a direct
/// connection.
///
/// Only the app hosts helpers. The command-line tool exits long before the
/// programs it starts, so there the service only reports the port the app's
/// helper last used: with the app closed, a proxied bottle has no network.
@MainActor
public final class ProxyService: ObservableObject {
    public static let shared = ProxyService(
        profileStore: .shared, hosting: Bundle.main.bundleURL.pathExtension == "app"
    )

    private struct Running {
        let profileID: UUID
        let listener: ProxyListener
    }

    private let profileStore: ProxyProfileStore
    private let hosting: Bool
    private var running: [URL: Running] = [:]
    private var tables: [URL: FakeDNS] = [:]

    /// - Parameter hosting: Whether this process runs helpers (the app) or only
    ///   points at the app's (the command-line tool).
    public init(profileStore: ProxyProfileStore, hosting: Bool = true) {
        self.profileStore = profileStore
        self.hosting = hosting
    }

    /// The bottle's placeholder table. It outlives helper restarts, so a
    /// placeholder a running program holds keeps meaning the same name.
    func placeholders(for bottle: Bottle) -> FakeDNS {
        if let table = tables[bottle.url] { return table }
        let table = FakeDNS()
        tables[bottle.url] = table
        return table
    }

    /// Forgets the bottle's placeholders, for when its programs have been stopped.
    func forgetPlaceholders(bottleURL: URL) {
        tables[bottleURL] = nil
    }

    /// The helper port for a proxied bottle, starting the helper if needed.
    ///
    /// Prefers the bottle's last port and records the one it got.
    /// - Returns: `nil` if the bottle's profile is missing or the helper cannot listen.
    public func port(for bottle: Bottle) -> UInt16? {
        guard let profileID = bottle.settings.proxyProfileID else { return nil }
        guard hosting else { return bottle.settings.proxyLastPort }
        if let existing = running[bottle.url], existing.profileID == profileID {
            return existing.listener.status.port
        }
        stop(bottleURL: bottle.url)
        guard let upstream = profileStore.upstream(for: profileID) else {
            proxyLogger.error("Proxy profile for bottle '\(bottle.settings.name, privacy: .public)' is missing")
            return nil
        }
        let listener = ProxyListener(upstream: upstream, dns: placeholders(for: bottle))
        do {
            let port = try listener.start(preferredPort: bottle.settings.proxyLastPort)
            running[bottle.url] = Running(profileID: profileID, listener: listener)
            if bottle.settings.proxyLastPort != port {
                bottle.settings.proxyLastPort = port
            }
            proxyLogger.info("Proxy helper for '\(bottle.settings.name, privacy: .public)' on port \(port)")
            objectWillChange.send()
            return port
        } catch {
            proxyLogger.error("Proxy helper could not listen: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func status(for bottle: Bottle) -> ProxyStatus? {
        running[bottle.url]?.listener.status
    }

    public func stop(bottleURL: URL) {
        guard let entry = running.removeValue(forKey: bottleURL) else { return }
        entry.listener.stop()
        objectWillChange.send()
    }

    /// Restarts the helper so it uses the profile's current settings.
    public func restart(for bottle: Bottle) {
        stop(bottleURL: bottle.url)
        _ = port(for: bottle)
    }
}
