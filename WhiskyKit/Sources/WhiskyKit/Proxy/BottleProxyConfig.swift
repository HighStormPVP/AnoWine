//
//  BottleProxyConfig.swift
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

/// Whether a bottle's network goes through one of the app's proxy profiles.
///
/// Off by default, so bottles made before the proxy existed open unchanged.
public struct BottleProxyConfig: Codable, Equatable {
    /// The bottle's TCP connections and DNS lookups go through the proxy.
    var enabled: Bool = false
    /// The ``ProxyProfile`` the bottle uses.
    var profileID: UUID?
    /// The helper port the bottle last used. Reusing it keeps programs that are
    /// still running connected after Ano restarts.
    var lastPort: UInt16?

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        self.profileID = try? container.decodeIfPresent(UUID.self, forKey: .profileID)
        self.lastPort = try? container.decodeIfPresent(UInt16.self, forKey: .lastPort)
    }
}
