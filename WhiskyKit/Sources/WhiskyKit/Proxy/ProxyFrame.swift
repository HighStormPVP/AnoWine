//
//  ProxyFrame.swift
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

/// Where a proxied connection goes.
public enum ProxyAddress: Equatable, Sendable {
    /// An IPv4 address (big-endian value, e.g. `0xC0000201` is 192.0.2.1).
    case ipv4(UInt32, port: UInt16)
    /// An IPv6 address, 16 bytes.
    case ipv6([UInt8], port: UInt16)
    /// A hostname the proxy resolves.
    case domain(String, port: UInt16)

    public var port: UInt16 {
        switch self {
        case let .ipv4(_, port), let .ipv6(_, port), let .domain(_, port): port
        }
    }
}

public enum ProxyFrameError: Error, Equatable {
    /// More bytes are needed to decode the frame.
    case incomplete
    /// The bytes are not a valid frame.
    case invalid
}

/// A request from the interposer (`AnoNet/ano_net.c`) to the helper. The byte
/// layout is the wire protocol in Plan 2a; both sides must match exactly.
public enum ProxyFrame: Equatable, Sendable {
    /// Become a data stream to this destination.
    case connect(ProxyAddress)
    /// Give back a fake IPv4 address for this hostname.
    case resolve(String)
    /// Give back the destination of the connection whose client-side port is this.
    case peer(localPort: UInt16)

    static let magic: [UInt8] = Array("ANO1".utf8)
    static let typeConnect: UInt8 = 0x43
    static let typeResolve: UInt8 = 0x52
    static let typePeer: UInt8 = 0x50
    static let atypIPv4: UInt8 = 1
    static let atypIPv6: UInt8 = 4

    /// Lower-cases a hostname and drops one trailing dot.
    static func normalise(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    public func encoded() -> [UInt8] {
        var bytes = Self.magic
        switch self {
        case let .connect(address):
            bytes.append(Self.typeConnect)
            bytes += Self.encodeAddress(address)
        case let .resolve(name):
            let name = Array(Self.normalise(name).utf8)
            bytes.append(Self.typeResolve)
            bytes.append(UInt8(truncatingIfNeeded: name.count))
            bytes += name
        case let .peer(localPort):
            bytes.append(Self.typePeer)
            bytes += Self.bigEndian(localPort)
        }
        return bytes
    }

    /// The `atyp` + address + port layout, shared with the `P` reply.
    /// `.domain` has no wire form and encodes as `atyp` 0 (unknown).
    static func encodeAddress(_ address: ProxyAddress?) -> [UInt8] {
        switch address {
        case let .ipv4(value, port):
            [atypIPv4] + bigEndian(value) + bigEndian(port)
        case let .ipv6(bytes, port):
            [atypIPv6] + bytes + bigEndian(port)
        case .domain, nil:
            [0]
        }
    }

    public static func decode(_ bytes: [UInt8]) throws -> (ProxyFrame, consumed: Int) {
        let prefix = min(bytes.count, magic.count)
        guard Array(bytes.prefix(prefix)) == Array(magic.prefix(prefix)) else { throw ProxyFrameError.invalid }
        guard bytes.count > magic.count else { throw ProxyFrameError.incomplete }
        let body = Array(bytes.dropFirst(magic.count + 1))
        switch bytes[magic.count] {
        case typeConnect:
            let (address, used) = try decodeAddress(body)
            return (.connect(address), magic.count + 1 + used)
        case typeResolve:
            let (name, used) = try decodeName(body)
            return (.resolve(name), magic.count + 1 + used)
        case typePeer:
            guard body.count >= 2 else { throw ProxyFrameError.incomplete }
            return (.peer(localPort: UInt16(body[0]) << 8 | UInt16(body[1])), magic.count + 3)
        default:
            throw ProxyFrameError.invalid
        }
    }

    /// A length byte (1–255) followed by an ASCII hostname.
    static func decodeName(_ bytes: [UInt8]) throws -> (String, used: Int) {
        guard let length = bytes.first else { throw ProxyFrameError.incomplete }
        guard length > 0 else { throw ProxyFrameError.invalid }
        guard bytes.count >= 1 + Int(length) else { throw ProxyFrameError.incomplete }
        guard let name = String(bytes: bytes[1 ... Int(length)], encoding: .ascii) else {
            throw ProxyFrameError.invalid
        }
        return (name, 1 + Int(length))
    }

    static func decodeAddress(_ bytes: [UInt8]) throws -> (ProxyAddress, used: Int) {
        guard let atyp = bytes.first else { throw ProxyFrameError.incomplete }
        let length: Int
        switch atyp {
        case atypIPv4: length = 4
        case atypIPv6: length = 16
        default: throw ProxyFrameError.invalid
        }
        guard bytes.count >= 1 + length + 2 else { throw ProxyFrameError.incomplete }
        let address = Array(bytes[1 ... length])
        let port = UInt16(bytes[1 + length]) << 8 | UInt16(bytes[2 + length])
        if atyp == atypIPv4 {
            let value = address.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return (.ipv4(value, port: port), 1 + length + 2)
        }
        return (.ipv6(address, port: port), 1 + length + 2)
    }

    static func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
