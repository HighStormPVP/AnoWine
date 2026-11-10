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

        let fd = try upstream.open(to: .domain("steam.example", port: 443))
        defer { close(fd) }

        XCTAssertEqual(server.requests.first, [5, 1, 0])
        XCTAssertEqual(server.requests.last, [5, 1, 0, 3, 13] + Array("steam.example".utf8) + [0x01, 0xBB])
        ProxyTestServer.write(fd, Array("PING\n".utf8))
        XCTAssertEqual(ProxyTestServer.read(fd, 5), Array("PING\n".utf8))
    }

    func testSocks5IPv4AndIPv6Requests() throws {
        let server = try ProxyTestServer.socks5()
        let upstream = ProxyUpstream.socks5(host: "127.0.0.1", port: server.port, username: nil, password: nil)

        close(try upstream.open(to: .ipv4(0xC000_0201, port: 7_000)))
        let v6 = [UInt8](repeating: 0, count: 15) + [1]
        close(try upstream.open(to: .ipv6(v6, port: 80)))

        let requests = server.requests.filter { $0.count > 3 }
        XCTAssertEqual(requests.first, [5, 1, 0, 1, 192, 0, 2, 1, 0x1B, 0x58])
        XCTAssertEqual(requests.last, [5, 1, 0, 4] + v6 + [0, 80])
    }

    func testSocks5Credentials() throws {
        let server = try ProxyTestServer { fd, server in
            guard let greeting = ProxyTestServer.read(fd, 2),
                  let methods = ProxyTestServer.read(fd, Int(greeting[1]))
            else { return }
            server.record(greeting + methods)
            ProxyTestServer.write(fd, [5, 2])
            guard let version = ProxyTestServer.read(fd, 2),
                  let user = ProxyTestServer.read(fd, Int(version[1])),
                  let passLength = ProxyTestServer.read(fd, 1),
                  let pass = ProxyTestServer.read(fd, Int(passLength[0]))
            else { return }
            server.record(version + user + passLength + pass)
            ProxyTestServer.write(fd, [1, 0])
            guard ProxyTestServer.readSocksRequest(fd) != nil else { return }
            ProxyTestServer.write(fd, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        }
        let upstream = ProxyUpstream.socks5(
            host: "127.0.0.1", port: server.port, username: "alice", password: "secret"
        )

        close(try upstream.open(to: .domain("a.example", port: 80)))

        XCTAssertEqual(server.requests[0], [5, 2, 0, 2])
        XCTAssertEqual(server.requests[1], [1, 5] + Array("alice".utf8) + [6] + Array("secret".utf8))
    }

    func testSocks5AuthRejected() throws {
        let server = try ProxyTestServer { fd, _ in
            guard let greeting = ProxyTestServer.read(fd, 2),
                  ProxyTestServer.read(fd, Int(greeting[1])) != nil
            else { return }
            ProxyTestServer.write(fd, [5, 2])
            _ = ProxyTestServer.read(fd, 2 + 5 + 1 + 6)
            ProxyTestServer.write(fd, [1, 1])
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
        let server = try ProxyTestServer { fd, server in
            var bytes: [UInt8] = []
            while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard let byte = ProxyTestServer.read(fd, 1) else { return }
                bytes += byte
            }
            server.record(bytes)
            ProxyTestServer.write(fd, Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
            ProxyTestServer.echo(fd)
        }
        let upstream = ProxyUpstream.httpConnect(
            host: "127.0.0.1", port: server.port, username: "alice", password: "secret"
        )

        let fd = try upstream.open(to: .domain("steam.example", port: 443))
        defer { close(fd) }

        let request = String(decoding: try XCTUnwrap(server.requests.first), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("CONNECT steam.example:443 HTTP/1.1\r\n"), request)
        XCTAssertTrue(request.contains("Proxy-Authorization: Basic YWxpY2U6c2VjcmV0\r\n"), request)
        ProxyTestServer.write(fd, Array("PING\n".utf8))
        XCTAssertEqual(ProxyTestServer.read(fd, 5), Array("PING\n".utf8))
    }

    func testHttpConnectRefused() throws {
        let server = try ProxyTestServer { fd, _ in
            var bytes: [UInt8] = []
            while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard let byte = ProxyTestServer.read(fd, 1) else { return }
                bytes += byte
            }
            ProxyTestServer.write(fd, Array("HTTP/1.1 403 Forbidden\r\n\r\n".utf8))
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
