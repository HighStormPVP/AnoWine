//
//  ProxyProfile.swift
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

/// The protocol a proxy profile speaks to the proxy client.
public enum ProxyKind: String, Codable, CaseIterable, Sendable {
    /// SOCKS5 (RFC 1928), with optional username and password (RFC 1929).
    case socks5
    /// HTTP `CONNECT`, with optional Basic authentication.
    case httpConnect
}

/// A proxy client the owner already runs, such as Xray or Hiddify, that bottles
/// can send their traffic through. The password lives in the Keychain, never here.
public struct ProxyProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: UInt16
    public var username: String

    public init(
        id: UUID = UUID(), name: String, kind: ProxyKind, host: String, port: UInt16, username: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }

    /// A SOCKS5 profile for a client on this Mac, matching Hiddify's local port.
    public static func newDefault() -> ProxyProfile {
        ProxyProfile(name: "Hiddify", kind: .socks5, host: "127.0.0.1", port: 1_080)
    }
}
