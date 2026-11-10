//
//  ProxyService+Selection.swift
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

/// What ``ProxyService/apply(_:to:stopBottle:isRunning:)`` did.
public enum ProxyChange: Equatable, Sendable {
    /// The bottle already had this setting.
    case unchanged
    /// The setting was changed.
    case applied
    /// The bottle's programs could not be stopped, so nothing was changed.
    case stillRunning
}

public extension ProxyService {
    /// The profile a bottle's network currently goes through, or `nil` for off.
    static func selection(of bottle: Bottle) -> UUID? {
        bottle.settings.proxyEnabled ? bottle.settings.proxyProfileID : nil
    }

    /// Switches a bottle's proxy to `profileID` (`nil` turns it off).
    ///
    /// The bottle's programs are stopped first: in Wine the server makes the
    /// TCP connections, and a server started under the old setting would keep
    /// it for everything started later.
    ///
    /// If the server is still there after the stop, the change is refused:
    /// going on would leave a proxied bottle connecting directly, or the reverse.
    @discardableResult
    func apply(
        _ profileID: UUID?, to bottle: Bottle,
        stopBottle: @MainActor (Bottle) -> Void = { Wine.killBottleAndWait(bottle: $0) },
        isRunning: @MainActor (Bottle) -> Bool = { ProxyService.serverIsRunning(for: $0) }
    ) -> ProxyChange {
        guard Self.selection(of: bottle) != profileID else { return .unchanged }
        stopBottle(bottle)
        guard !isRunning(bottle) else { return .stillRunning }
        stop(bottleURL: bottle.url)
        forgetPlaceholders(bottleURL: bottle.url)
        if let profileID {
            bottle.settings.proxyProfileID = profileID
            bottle.settings.proxyEnabled = true
        } else {
            bottle.settings.proxyEnabled = false
        }
        // Start the helper now: Terminal sessions and shortcuts use the app's.
        if profileID != nil { _ = port(for: bottle) }
        return .applied
    }

    /// Whether the bottle's Wine server is alive, asked the way Wine does
    /// (`ano-server -k0` succeeds only if there is one). Waits up to a second
    /// for a server that is on its way out.
    static func serverIsRunning(for bottle: Bottle) -> Bool {
        for attempt in 0 ..< 10 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
            let probe = Process()
            probe.executableURL = AnoWineRuntime.serverURL
            probe.arguments = ["-k0"]
            probe.environment = ["WINEPREFIX": bottle.url.path(percentEncoded: false)]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            do {
                try probe.run()
            } catch {
                return false
            }
            probe.waitUntilExit()
            if probe.terminationStatus != 0 { return false }
        }
        return true
    }
}
