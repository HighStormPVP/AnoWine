//
//  ProxyUpstream.swift
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

import Darwin
import Foundation

/// The owner's proxy client, as the helper talks to it.
public enum ProxyUpstream: Equatable, Sendable {
    case socks5(host: String, port: UInt16, username: String?, password: String?)
    case httpConnect(host: String, port: UInt16, username: String?, password: String?)

    /// Opens a tunnel to `destination` through the proxy client.
    ///
    /// - Returns: A connected, blocking descriptor positioned after the handshake.
    /// - Throws: ``ProxyError``.
    public func open(to destination: ProxyAddress, timeout: TimeInterval = 15) throws -> Int32 {
        switch self {
        case let .socks5(host, port, username, password):
            let sock = try ProxySocket.connect(host: host, port: port, timeout: timeout)
            do {
                try Self.socks5Handshake(sock, destination: destination, username: username, password: password)
                return sock
            } catch {
                close(sock)
                throw error
            }
        case let .httpConnect(host, port, username, password):
            let sock = try ProxySocket.connect(host: host, port: port, timeout: timeout)
            do {
                try Self.httpHandshake(sock, destination: destination, username: username, password: password)
                return sock
            } catch {
                close(sock)
                throw error
            }
        }
    }

    // MARK: - SOCKS5 (RFC 1928, RFC 1929)

    static func socks5Handshake(
        _ sock: Int32, destination: ProxyAddress, username: String?, password: String?
    ) throws {
        try socks5Authenticate(sock, username: username, password: password)
        try ProxySocket.writeAll(sock, socks5Request(for: destination))
        try socks5ReadReply(sock)
    }

    /// The method exchange, and RFC 1929 username/password when one is set.
    static func socks5Authenticate(_ sock: Int32, username: String?, password: String?) throws {
        let credentials = username.map { !$0.isEmpty } ?? false
        try ProxySocket.writeAll(sock, credentials ? [5, 2, 0, 2] : [5, 1, 0])
        let choice = try ProxySocket.readExactly(sock, 2)
        guard choice[0] == 5 else { throw ProxyError.protocolError("not a SOCKS5 proxy") }
        switch choice[1] {
        case 0:
            return
        case 2 where credentials:
            let user = Array((username ?? "").utf8.prefix(255))
            let pass = Array((password ?? "").utf8.prefix(255))
            try ProxySocket.writeAll(sock, [1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)
            let status = try ProxySocket.readExactly(sock, 2)
            guard status[1] == 0 else { throw ProxyError.authFailed }
        default:
            throw ProxyError.authFailed
        }
    }

    static func socks5Request(for destination: ProxyAddress) -> [UInt8] {
        let request: [UInt8] = [5, 1, 0]
        switch destination {
        case let .ipv4(value, port):
            return request + [1] + ProxyFrame.bigEndian(value) + ProxyFrame.bigEndian(port)
        case let .ipv6(bytes, port):
            return request + [4] + bytes + ProxyFrame.bigEndian(port)
        case let .domain(name, port):
            let name = Array(name.utf8.prefix(255))
            return request + [3, UInt8(name.count)] + name + ProxyFrame.bigEndian(port)
        }
    }

    static func socks5ReadReply(_ sock: Int32) throws {
        let reply = try ProxySocket.readExactly(sock, 4)
        guard reply[0] == 5 else { throw ProxyError.protocolError("bad SOCKS5 reply") }
        guard reply[1] == 0 else { throw ProxyError.refused("SOCKS5 reply \(reply[1])") }
        switch reply[3] {
        case 1: _ = try ProxySocket.readExactly(sock, 4 + 2)
        case 4: _ = try ProxySocket.readExactly(sock, 16 + 2)
        case 3:
            let length = try ProxySocket.readExactly(sock, 1)[0]
            _ = try ProxySocket.readExactly(sock, Int(length) + 2)
        default: throw ProxyError.protocolError("bad SOCKS5 bound address")
        }
    }

    // MARK: - HTTP CONNECT

    static func authority(for destination: ProxyAddress) -> String {
        switch destination {
        case let .ipv4(value, port): "\(ProxySocket.text(ipv4: value)):\(port)"
        case let .ipv6(bytes, port): "[\(ProxySocket.text(ipv6: bytes))]:\(port)"
        case let .domain(name, port): "\(name):\(port)"
        }
    }

    static func httpHandshake(
        _ sock: Int32, destination: ProxyAddress, username: String?, password: String?
    ) throws {
        let authority = authority(for: destination)
        var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if let username, !username.isEmpty {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        try ProxySocket.writeAll(sock, Array(request.utf8))

        let headers = try ProxySocket.readHeaders(sock)
        let statusLine = headers.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw ProxyError.protocolError("bad HTTP response")
        }
        if code == 407 { throw ProxyError.authFailed }
        guard (200 ..< 300).contains(code) else { throw ProxyError.refused(statusLine) }
    }
}
