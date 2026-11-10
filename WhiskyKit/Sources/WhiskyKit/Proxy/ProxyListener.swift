//
//  ProxyListener.swift
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

/// What a running helper is doing, for the bottle's Network section.
public struct ProxyStatus: Equatable, Sendable {
    public var port: UInt16
    public var activeConnections: Int
    public var totalConnections: Int
    public var lastError: String?
}

/// The helper a proxied bottle's interposer talks to: answers DNS with
/// ``FakeDNS`` placeholders and turns each `C` request into a tunnel through the
/// owner's proxy client. Listens on loopback only. One thread per socket accepts, and
/// each connection runs on threads of its own.
public final class ProxyListener: @unchecked Sendable {
    private let upstream: ProxyUpstream
    private let dns: FakeDNS
    private let lock = NSLock()
    private var acceptor: ProxyAcceptor?
    private var peers: [UInt16: ProxyAddress] = [:]
    private var current = ProxyStatus(port: 0, activeConnections: 0, totalConnections: 0, lastError: nil)

    /// Called with the request type (`C`, `R` or `P`) of every accepted request.
    public var onRequest: (@Sendable (Character) -> Void)?

    public init(upstream: ProxyUpstream, dns: FakeDNS = FakeDNS()) {
        self.upstream = upstream
        self.dns = dns
    }

    /// Does not wait: the last reference can go away on one of the helper's own threads.
    deinit { acceptor?.stop(wait: false) }

    public var status: ProxyStatus {
        lock.withLock { current }
    }

    /// Starts listening on `127.0.0.1` and `::1` (Wine's IPv6 sockets are
    /// IPv6-only, like Windows', so they need the second) and returns the port.
    /// Tries `preferredPort` first, so programs still running from an earlier
    /// start keep working.
    public func start(preferredPort: UInt16?) throws -> UInt16 {
        let (fds, port) = try Self.listen(preferredPort: preferredPort)
        let acceptor = ProxyAcceptor(sockets: fds) { [weak self] client in
            guard let self else {
                close(client)
                return
            }
            ProxySocket.prepare(client)
            Thread.detachNewThread { self.serve(client) }
        }
        lock.withLock {
            self.acceptor = acceptor
            current.port = port
        }
        return port
    }

    /// Stops listening; the port is free again when this returns. Connections
    /// already open run on until they end.
    public func stop() {
        let acceptor = lock.withLock {
            let acceptor = self.acceptor
            self.acceptor = nil
            return acceptor
        }
        acceptor?.stop()
    }

    static func listen(preferredPort: UInt16?) throws -> ([Int32], UInt16) {
        if let preferredPort, preferredPort != 0, let bound = try? bindBoth(port: preferredPort) {
            return bound
        }
        for _ in 0 ..< 8 {
            if let bound = try? bindBoth(port: 0) { return bound }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// Binds the IPv4 loopback (on `port`, or any port when 0), then the IPv6
    /// loopback on the same port.
    private static func bindBoth(port: UInt16) throws -> ([Int32], UInt16) {
        let (ipv4Socket, bound) = try bindLoopback(family: AF_INET, port: port)
        do {
            let (ipv6Socket, _) = try bindLoopback(family: AF_INET6, port: bound)
            return ([ipv4Socket, ipv6Socket], bound)
        } catch {
            close(ipv4Socket)
            throw error
        }
    }

    private static func bindLoopback(family: Int32, port: UInt16) throws -> (Int32, UInt16) {
        let sock = socket(family, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EMFILE) }
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var storage = sockaddr_storage()
        let length: socklen_t
        if family == AF_INET6 {
            setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_family = sa_family_t(AF_INET6)
                    $0.pointee.sin6_len = UInt8(length)
                    $0.pointee.sin6_addr = in6addr_loopback
                    $0.pointee.sin6_port = port.bigEndian
                }
            }
        } else {
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_family = sa_family_t(AF_INET)
                    $0.pointee.sin_len = UInt8(length)
                    $0.pointee.sin_addr.s_addr = inet_addr("127.0.0.1")
                    $0.pointee.sin_port = port.bigEndian
                }
            }
        }
        let bound = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, length) }
        }
        guard bound == 0, Darwin.listen(sock, 128) == 0 else {
            close(sock)
            throw POSIXError(.EADDRINUSE)
        }
        return (sock, localPort(of: sock))
    }

    private static func localPort(of sock: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &size) }
        }
        return port(of: storage)
    }

    /// The port in an IPv4 or IPv6 socket address; both keep it at the same offset.
    private static func port(of storage: sockaddr_storage) -> UInt16 {
        withUnsafePointer(to: storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
    }

    // MARK: - Requests

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let frame = try? readFrame(client) else { return }
        switch frame {
        case let .resolve(name):
            onRequest?("R")
            let address = dns.address(for: name) ?? 0
            try? ProxySocket.writeAll(client, ProxyFrame.bigEndian(address))
        case let .peer(localPort):
            onRequest?("P")
            let destination = lock.withLock { peers[localPort] }
            try? ProxySocket.writeAll(client, ProxyFrame.encodeAddress(destination))
        case let .connect(requested):
            onRequest?("C")
            tunnel(client, requested: requested)
        }
    }

    private func readFrame(_ sock: Int32) throws -> ProxyFrame {
        var bytes = try ProxySocket.readExactly(sock, ProxyFrame.magic.count + 1)
        while true {
            do {
                return try ProxyFrame.decode(bytes).0
            } catch ProxyFrameError.incomplete {
                bytes += try ProxySocket.readExactly(sock, 1)
            }
        }
    }

    private func tunnel(_ client: Int32, requested: ProxyAddress) {
        var destination = requested
        if case let .ipv4(value, port) = requested, dns.contains(value) {
            guard let name = dns.name(for: value) else {
                fail("no hostname for placeholder \(ProxySocket.text(ipv4: value))")
                return
            }
            destination = .domain(name, port: port)
        }

        let clientPort = Self.remotePort(of: client)
        lock.withLock {
            peers[clientPort] = requested
            current.activeConnections += 1
            current.totalConnections += 1
        }
        defer {
            lock.withLock {
                peers[clientPort] = nil
                current.activeConnections -= 1
            }
        }

        let remote: Int32
        do {
            remote = try upstream.open(to: destination)
        } catch {
            fail("\(ProxyUpstream.authority(for: destination)): \(error)")
            return
        }
        defer { close(remote) }

        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            Self.copy(from: client, to: remote)
            done.signal()
        }
        Self.copy(from: remote, to: client)
        done.wait()
    }

    private func fail(_ message: String) {
        lock.withLock { current.lastError = message }
    }

    /// Copies until `source` ends, then ends the write side of `destination`.
    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let got = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if got < 0, errno == EINTR { continue }
            guard got > 0, (try? ProxySocket.writeAll(destination, Array(buffer[0 ..< got]))) != nil else { break }
        }
        shutdown(destination, SHUT_WR)
    }

    private static func remotePort(of sock: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getpeername(sock, $0, &size) }
        }
        return port(of: storage)
    }
}
