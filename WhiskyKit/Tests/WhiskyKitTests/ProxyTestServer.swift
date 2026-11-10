//
//  ProxyTestServer.swift
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

/// A one-thread-per-connection TCP server on `127.0.0.1` for proxy tests. Each
/// accepted connection is handed to `handler` on its own thread and closed after.
final class ProxyTestServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var recorded: [[UInt8]] = []
    private var stopped = false

    init(handler: @escaping @Sendable (Int32, ProxyTestServer) -> Void) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &size) }
        }
        self.listener = sock
        self.port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else { return }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread {
                    handler(client, self)
                    close(client)
                }
            }
        }
    }

    deinit { stop() }

    /// Stops listening. Safe to call more than once: the descriptor is closed only
    /// once, so a later socket that reuses its number is never closed by mistake.
    func stop() {
        let open = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard open else { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    /// Bytes a handler chose to remember, in order.
    var requests: [[UInt8]] {
        lock.withLock { recorded }
    }

    func record(_ bytes: [UInt8]) {
        lock.withLock { recorded.append(bytes) }
    }

    // MARK: - Helpers for handlers

    static func read(_ sock: Int32, _ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let got = bytes[offset...].withUnsafeMutableBytes { Darwin.read(sock, $0.baseAddress, $0.count) }
            guard got > 0 else { return nil }
            offset += got
        }
        return bytes
    }

    static func write(_ sock: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.write(sock, $0.baseAddress, $0.count) }
    }

    /// Copies everything received back to the sender until the peer closes.
    static func echo(_ sock: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(sock, $0.baseAddress, $0.count) }
            guard got > 0 else { return }
            write(sock, Array(buffer[0 ..< got]))
        }
    }

    /// Reads one SOCKS5 CONNECT request (after the method exchange) and returns
    /// it from the version byte up to and including the port.
    static func readSocksRequest(_ sock: Int32) -> [UInt8]? {
        guard let head = read(sock, 4) else { return nil }
        let rest: [UInt8]?
        switch head[3] {
        case 1: rest = read(sock, 4 + 2)
        case 4: rest = read(sock, 16 + 2)
        case 3:
            guard let length = read(sock, 1) else { return nil }
            rest = read(sock, Int(length[0]) + 2).map { length + $0 }
        default: return nil
        }
        return rest.map { head + $0 }
    }

    /// A SOCKS5 server without authentication that records each request and then
    /// echoes, or refuses with `reply` when it is not 0.
    static func socks5(reply: UInt8 = 0) throws -> ProxyTestServer {
        try ProxyTestServer { sock, server in
            guard let greeting = read(sock, 2), let methods = read(sock, Int(greeting[1])) else { return }
            server.record(greeting + methods)
            write(sock, [5, 0])
            guard let request = readSocksRequest(sock) else { return }
            server.record(request)
            write(sock, [5, reply, 0, 1, 127, 0, 0, 1, 0, 0])
            if reply == 0 { echo(sock) }
        }
    }

    /// A connected client socket to `127.0.0.1:port`.
    static func connect(port: UInt16) -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return result == 0 ? sock : -1
    }

    /// Reads until the peer closes or `limit` bytes; used to see "closed with nothing".
    static func readToEnd(_ sock: Int32, limit: Int = 65_536, timeout: Int32 = 5_000) -> [UInt8] {
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while collected.count < limit {
            var poller = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, timeout) == 1 else { break }
            let got = buffer.withUnsafeMutableBytes { Darwin.read(sock, $0.baseAddress, $0.count) }
            guard got > 0 else { break }
            collected += buffer[0 ..< got]
        }
        return collected
    }
}
