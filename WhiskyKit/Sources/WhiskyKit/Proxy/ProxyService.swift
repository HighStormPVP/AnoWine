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

/// Runs one helper (``ProxyListener``) per proxied bottle, inside the process
/// that launches the bottle's programs. Programs lose their network when it
/// stops; they never fall back to a direct connection.
@MainActor
public final class ProxyService: ObservableObject {
    public static let shared = ProxyService(profileStore: .shared)

    private struct Running {
        let profileID: UUID
        let listener: ProxyListener
    }

    private let profileStore: ProxyProfileStore
    private var running: [URL: Running] = [:]

    public init(profileStore: ProxyProfileStore) {
        self.profileStore = profileStore
    }

    /// The helper port for a proxied bottle, starting the helper if needed.
    ///
    /// Prefers the bottle's last port and records the one it got.
    /// - Returns: `nil` if the bottle's profile is missing or the helper cannot listen.
    public func port(for bottle: Bottle) -> UInt16? {
        guard let profileID = bottle.settings.proxyProfileID else { return nil }
        if let existing = running[bottle.url], existing.profileID == profileID {
            return existing.listener.status.port
        }
        stop(bottleURL: bottle.url)
        guard let upstream = profileStore.upstream(for: profileID) else {
            proxyLogger.error("Proxy profile for bottle '\(bottle.settings.name, privacy: .public)' is missing")
            return nil
        }
        let listener = ProxyListener(upstream: upstream)
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
