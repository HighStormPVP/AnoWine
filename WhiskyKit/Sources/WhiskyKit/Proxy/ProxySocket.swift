//
//  ProxySocket.swift
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

/// Why talking to the proxy client failed.
public enum ProxyError: Error, Equatable, CustomStringConvertible {
    /// The proxy client could not be reached.
    case unreachable
    /// The proxy client refused the destination.
    case refused(String)
    /// The proxy client rejected the username or password.
    case authFailed
    /// The proxy client answered something unexpected.
    case protocolError(String)

    public var description: String {
        switch self {
        case .unreachable: "proxy unreachable"
        case let .refused(reason): "proxy refused: \(reason)"
        case .authFailed: "proxy rejected the username or password"
        case let .protocolError(reason): "proxy protocol error: \(reason)"
        }
    }
}

/// Small blocking POSIX socket helpers for the proxy helper.
enum ProxySocket {
    /// Connects to `host:port` (resolved here: it is the local proxy client,
    /// not a bottle's destination) and returns a blocking descriptor.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw ProxyError.unreachable
        }
        defer { freeaddrinfo(list) }
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry {
            let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if sock >= 0 {
                if connect(sock, address: info.pointee.ai_addr, length: info.pointee.ai_addrlen, timeout: timeout) {
                    prepare(sock)
                    return sock
                }
                close(sock)
            }
            entry = info.pointee.ai_next
        }
        throw ProxyError.unreachable
    }

    private static func connect(
        _ sock: Int32, address: UnsafePointer<sockaddr>, length: socklen_t, timeout: TimeInterval
    ) -> Bool {
        let flags = fcntl(sock, F_GETFL)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(sock, F_SETFL, flags) }
        if Darwin.connect(sock, address, length) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1_000)) == 1 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &size)
        return error == 0
    }

    /// No `SIGPIPE` on writes to a closed peer; the write fails instead.
    static func prepare(_ sock: Int32) {
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ sock: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(sock, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw ProxyError.protocolError("write failed (\(errno))")
            }
            offset += written
        }
    }

    /// Reads exactly `count` bytes; throws if the peer closes first.
    static func readExactly(_ sock: Int32, _ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes[offset...].withUnsafeMutableBytes { read(sock, $0.baseAddress, $0.count) }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw ProxyError.protocolError("connection closed") }
            offset += got
        }
        return bytes
    }

    /// Reads an HTTP header block up to and including the blank line, one byte at
    /// a time so nothing after it is consumed.
    static func readHeaders(_ sock: Int32, limit: Int = 8_192) throws -> String {
        var bytes: [UInt8] = []
        while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard bytes.count < limit else { throw ProxyError.protocolError("response headers too long") }
            bytes += try readExactly(sock, 1)
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Text form of an IP address in network byte order.
    static func text(ipv4 value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    static func text(ipv6 bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }
}
