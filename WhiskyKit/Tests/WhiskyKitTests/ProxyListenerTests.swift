//
//  ProxyListenerTests.swift
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
@testable import WhiskyKit
import XCTest

final class ProxyListenerTests: XCTestCase {
    private func makeListener(upstreamPort: UInt16) throws -> (ProxyListener, UInt16) {
        let listener = ProxyListener(
            upstream: .socks5(host: "127.0.0.1", port: upstreamPort, username: nil, password: nil)
        )
        let port = try listener.start(preferredPort: nil)
        return (listener, port)
    }

    private func request(_ port: UInt16, _ frame: ProxyFrame, replyLength: Int) -> [UInt8]? {
        let sock = ProxyTestServer.connect(port: port)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        ProxyTestServer.write(sock, frame.encoded())
        return ProxyTestServer.read(sock, replyLength)
    }

    private func localPort(of sock: Int32) -> UInt16 {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &size) }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func testResolveThenConnectSendsHostnameUpstream() throws {
        let upstream = try ProxyTestServer.socks5()
        let (listener, port) = try makeListener(upstreamPort: upstream.port)
        defer { listener.stop() }

        let reply = try XCTUnwrap(request(port, .resolve("anotest.example.com"), replyLength: 4))
        let fake = reply.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        XCTAssertTrue(FakeDNS().contains(fake))

        let sock = ProxyTestServer.connect(port: port)
        defer { close(sock) }
        ProxyTestServer.write(sock, ProxyFrame.connect(.ipv4(fake, port: 7_000)).encoded() + Array("PING\n".utf8))
        XCTAssertEqual(ProxyTestServer.read(sock, 5), Array("PING\n".utf8))
        XCTAssertEqual(
            upstream.requests.last,
            [5, 1, 0, 3, 19] + Array("anotest.example.com".utf8) + [0x1B, 0x58]
        )
    }

    func testConnectToPlainIPv4UsesIPv4() throws {
        let upstream = try ProxyTestServer.socks5()
        let (listener, port) = try makeListener(upstreamPort: upstream.port)
        defer { listener.stop() }

        let sock = ProxyTestServer.connect(port: port)
        defer { close(sock) }
        ProxyTestServer.write(sock, ProxyFrame.connect(.ipv4(0xC000_0201, port: 7_000)).encoded() + [1])
        XCTAssertEqual(ProxyTestServer.read(sock, 1), [1])
        XCTAssertEqual(upstream.requests.last, [5, 1, 0, 1, 192, 0, 2, 1, 0x1B, 0x58])
    }

    func testUnknownFakeAddressIsClosedWithoutUpstream() throws {
        let upstream = try ProxyTestServer.socks5()
        let (listener, port) = try makeListener(upstreamPort: upstream.port)
        defer { listener.stop() }

        let sock = ProxyTestServer.connect(port: port)
        defer { close(sock) }
        ProxyTestServer.write(sock, ProxyFrame.connect(.ipv4(0xC612_C801, port: 80)).encoded())

        XCTAssertEqual(ProxyTestServer.readToEnd(sock), [])
        XCTAssertTrue(upstream.requests.isEmpty)
        XCTAssertNotNil(listener.status.lastError)
    }

    func testPeerReturnsOriginalDestination() throws {
        let upstream = try ProxyTestServer.socks5()
        let (listener, port) = try makeListener(upstreamPort: upstream.port)
        defer { listener.stop() }

        let sock = ProxyTestServer.connect(port: port)
        defer { close(sock) }
        ProxyTestServer.write(sock, ProxyFrame.connect(.ipv4(0xC000_0201, port: 7_000)).encoded() + [9])
        XCTAssertEqual(ProxyTestServer.read(sock, 1), [9])

        let reply = request(port, .peer(localPort: localPort(of: sock)), replyLength: 7)
        XCTAssertEqual(reply, [1, 192, 0, 2, 1, 0x1B, 0x58])
        XCTAssertEqual(listener.status.activeConnections, 1)
        XCTAssertEqual(request(port, .peer(localPort: 1), replyLength: 1), [0])
    }

    /// Wine's IPv6 sockets are IPv6-only, so the helper must answer on `::1` too.
    func testAnswersOnIPv6Loopback() throws {
        let upstream = try ProxyTestServer.socks5()
        let (listener, port) = try makeListener(upstreamPort: upstream.port)
        defer { listener.stop() }

        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(sock) }
        var one: Int32 = 1
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        ProxyTestServer.write(sock, ProxyFrame.resolve("ipv6.example").encoded())
        let reply = try XCTUnwrap(ProxyTestServer.read(sock, 4))
        XCTAssertTrue(FakeDNS().contains(reply.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
    }

    func testPreferredPortIsReused() throws {
        let first = ProxyListener(upstream: .socks5(host: "127.0.0.1", port: 1, username: nil, password: nil))
        let port = try first.start(preferredPort: nil)
        first.stop()

        let second = ProxyListener(upstream: .socks5(host: "127.0.0.1", port: 1, username: nil, password: nil))
        defer { second.stop() }
        let reused = try second.start(preferredPort: port)
        XCTAssertEqual(reused, port)
    }

    func testBusyPreferredPortFallsBack() throws {
        let first = ProxyListener(upstream: .socks5(host: "127.0.0.1", port: 1, username: nil, password: nil))
        defer { first.stop() }
        let port = try first.start(preferredPort: nil)

        let second = ProxyListener(upstream: .socks5(host: "127.0.0.1", port: 1, username: nil, password: nil))
        defer { second.stop() }
        let other = try second.start(preferredPort: port)
        XCTAssertNotEqual(other, port)
        XCTAssertNotEqual(other, 0)
    }

    /// A bound socket that never listens: connecting to its port is refused, and
    /// holding it keeps the port from being handed to anyone else meanwhile.
    private func refusingPort() throws -> (Int32, UInt16) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(sock)
            throw POSIXError(.EADDRINUSE)
        }
        return (sock, localPort(of: sock))
    }

    func testUpstreamDownClosesClient() throws {
        let (holder, upstreamPort) = try refusingPort()
        defer { close(holder) }
        let (listener, port) = try makeListener(upstreamPort: upstreamPort)
        defer { listener.stop() }

        let sock = ProxyTestServer.connect(port: port)
        XCTAssertGreaterThanOrEqual(sock, 0)
        defer { close(sock) }
        ProxyTestServer.write(sock, ProxyFrame.connect(.ipv4(0xC000_0201, port: 7_000)).encoded())

        XCTAssertEqual(ProxyTestServer.readToEnd(sock, timeout: 20_000), [])
        XCTAssertTrue(listener.status.lastError?.contains("unreachable") ?? false, "\(listener.status)")
    }
}
