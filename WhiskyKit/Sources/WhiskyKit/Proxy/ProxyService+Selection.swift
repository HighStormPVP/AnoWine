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
    /// - Returns: `false` if nothing changed.
    @discardableResult
    func apply(
        _ profileID: UUID?, to bottle: Bottle,
        stopBottle: @MainActor (Bottle) -> Void = { Wine.killBottleAndWait(bottle: $0) }
    ) -> Bool {
        guard Self.selection(of: bottle) != profileID else { return false }
        stopBottle(bottle)
        stop(bottleURL: bottle.url)
        if let profileID {
            bottle.settings.proxyProfileID = profileID
            bottle.settings.proxyEnabled = true
        } else {
            bottle.settings.proxyEnabled = false
        }
        return true
    }
}
