//
//  ProxyUpstreamTests.swift
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

final class ProxyUpstreamTests: XCTestCase {
    func testSocks5DomainRequestThenEcho() throws {
        let server = try ProxyTestServer.socks5()
        let upstream = ProxyUpstream.socks5(host: "127.0.0.1", port: server.port, username: nil, password: nil)

        let sock = try upstream.open(to: .domain("steam.example", port: 443))
        defer { close(sock) }

        XCTAssertEqual(server.requests.first, [5, 1, 0])
        XCTAssertEqual(server.requests.last, [5, 1, 0, 3, 13] + Array("steam.example".utf8) + [0x01, 0xBB])
        ProxyTestServer.write(sock, Array("PING\n".utf8))
        XCTAssertEqual(ProxyTestServer.read(sock, 5), Array("PING\n".utf8))
    }

    func testSocks5IPv4AndIPv6Requests() throws {
        let server = try ProxyTestServer.socks5()
        let upstream = ProxyUpstream.socks5(host: "127.0.0.1", port: server.port, username: nil, password: nil)

        try close(upstream.open(to: .ipv4(0xC000_0201, port: 7_000)))
        let ipv6Bytes = [UInt8](repeating: 0, count: 15) + [1]
        try close(upstream.open(to: .ipv6(ipv6Bytes, port: 80)))

        let requests = server.requests.filter { $0.count > 3 }
        XCTAssertEqual(requests.first, [5, 1, 0, 1, 192, 0, 2, 1, 0x1B, 0x58])
        XCTAssertEqual(requests.last, [5, 1, 0, 4] + ipv6Bytes + [0, 80])
    }

    func testSocks5Credentials() throws {
        let server = try ProxyTestServer { sock, server in
            guard let greeting = ProxyTestServer.read(sock, 2),
                  let methods = ProxyTestServer.read(sock, Int(greeting[1]))
            else { return }
            server.record(greeting + methods)
            ProxyTestServer.write(sock, [5, 2])
            guard let version = ProxyTestServer.read(sock, 2),
                  let user = ProxyTestServer.read(sock, Int(version[1])),
                  let passLength = ProxyTestServer.read(sock, 1),
                  let pass = ProxyTestServer.read(sock, Int(passLength[0]))
            else { return }
            server.record(version + user + passLength + pass)
            ProxyTestServer.write(sock, [1, 0])
            guard ProxyTestServer.readSocksRequest(sock) != nil else { return }
            ProxyTestServer.write(sock, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        }
        let upstream = ProxyUpstream.socks5(
            host: "127.0.0.1", port: server.port, username: "alice", password: "secret"
        )

        try close(upstream.open(to: .domain("a.example", port: 80)))

        XCTAssertEqual(server.requests[0], [5, 2, 0, 2])
        XCTAssertEqual(server.requests[1], [1, 5] + Array("alice".utf8) + [6] + Array("secret".utf8))
    }

    func testSocks5AuthRejected() throws {
        let server = try ProxyTestServer { sock, _ in
            guard let greeting = ProxyTestServer.read(sock, 2),
                  ProxyTestServer.read(sock, Int(greeting[1])) != nil
            else { return }
            ProxyTestServer.write(sock, [5, 2])
            _ = ProxyTestServer.read(sock, 2 + 5 + 1 + 6)
            ProxyTestServer.write(sock, [1, 1])
        }
        let upstream = ProxyUpstream.socks5(
            host: "127.0.0.1", port: server.port, username: "alice", password: "secret"
        )
        XCTAssertThrowsError(try upstream.open(to: .domain("a.example", port: 80))) {
            XCTAssertEqual($0 as? ProxyError, .authFailed)
        }
    }

    func testSocks5Refusal() throws {
        let server = try ProxyTestServer.socks5(reply: 5)
        let upstream = ProxyUpstream.socks5(host: "127.0.0.1", port: server.port, username: nil, password: nil)
        XCTAssertThrowsError(try upstream.open(to: .domain("a.example", port: 80))) {
            XCTAssertEqual($0 as? ProxyError, .refused("SOCKS5 reply 5"))
        }
    }

    func testHttpConnectWithBasicAuth() throws {
        let server = try ProxyTestServer { sock, server in
            var bytes: [UInt8] = []
            while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard let byte = ProxyTestServer.read(sock, 1) else { return }
                bytes += byte
            }
            server.record(bytes)
            ProxyTestServer.write(sock, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
            ProxyTestServer.echo(sock)
        }
        let upstream = ProxyUpstream.httpConnect(
            host: "127.0.0.1", port: server.port, username: "alice", password: "secret"
        )

        let sock = try upstream.open(to: .domain("steam.example", port: 443))
        defer { close(sock) }

        let request = try XCTUnwrap(String(bytes: XCTUnwrap(server.requests.first), encoding: .utf8))
        XCTAssertTrue(request.hasPrefix("CONNECT steam.example:443 HTTP/1.1\r\n"), request)
        XCTAssertTrue(request.contains("Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n"), request)
        ProxyTestServer.write(sock, Array("PING\n".utf8))
        XCTAssertEqual(ProxyTestServer.read(sock, 5), Array("PING\n".utf8))
    }

    func testHttpConnectRefused() throws {
        let server = try ProxyTestServer { sock, _ in
            var bytes: [UInt8] = []
            while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard let byte = ProxyTestServer.read(sock, 1) else { return }
                bytes += byte
            }
            ProxyTestServer.write(sock, Array("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
        }
        let upstream = ProxyUpstream.httpConnect(host: "127.0.0.1", port: server.port, username: nil, password: nil)
        XCTAssertThrowsError(try upstream.open(to: .ipv4(0xC000_0201, port: 7_000))) {
            XCTAssertEqual($0 as? ProxyError, .refused("HTTP/1.1 403 Forbidden"))
        }
    }

    func testNothingListeningIsUnreachable() throws {
        let server = try ProxyTestServer { _, _ in }
        let port = server.port
        server.stop()
        let upstream = ProxyUpstream.socks5(host: "127.0.0.1", port: port, username: nil, password: nil)
        XCTAssertThrowsError(try upstream.open(to: .domain("a.example", port: 80), timeout: 2)) {
            XCTAssertEqual($0 as? ProxyError, .unreachable)
        }
    }
}
