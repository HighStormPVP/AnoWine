//
//  ProxyServiceTests.swift
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
@testable import WhiskyKit
import XCTest

@MainActor
final class ProxyServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appending(path: "proxy-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeService() -> ProxyService {
        ProxyService(profileStore: ProxyProfileStore(
            fileURL: tempDir.appending(path: "profiles.json"), secrets: InMemoryProxySecretStore()
        ))
    }

    func testChangingProxySettingStopsBottle() {
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        let service = makeService()
        var stopped = 0
        let profile = UUID()

        XCTAssertTrue(service.apply(profile, to: bottle) { _ in stopped += 1 })
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(bottle.settings.proxyEnabled)
        XCTAssertEqual(bottle.settings.proxyProfileID, profile)

        XCTAssertFalse(service.apply(profile, to: bottle) { _ in stopped += 1 })
        XCTAssertEqual(stopped, 1, "re-selecting the same profile changes nothing")

        XCTAssertTrue(service.apply(nil, to: bottle) { _ in stopped += 1 })
        XCTAssertEqual(stopped, 2)
        XCTAssertFalse(bottle.settings.proxyEnabled)
        XCTAssertNil(ProxyService.selection(of: bottle))
    }

    func testHelperStartsForProfileAndStopsWithSelectionChange() throws {
        let file = tempDir.appending(path: "profiles.json")
        let store = ProxyProfileStore(fileURL: file, secrets: InMemoryProxySecretStore())
        let profile = ProxyProfile.newDefault()
        try store.save(profile, password: nil)
        let service = ProxyService(profileStore: store)
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        service.apply(profile.id, to: bottle) { _ in }

        let port = try XCTUnwrap(service.port(for: bottle))
        XCTAssertEqual(service.status(for: bottle)?.port, port)
        XCTAssertEqual(bottle.settings.proxyLastPort, port)

        service.apply(nil, to: bottle) { _ in }
        XCTAssertNil(service.status(for: bottle))
    }

    nonisolated func testExitIPReadsTraceThroughTheProxy() throws {
        let server = try ProxyTestServer { sock, server in
            guard let greeting = ProxyTestServer.read(sock, 2),
                  ProxyTestServer.read(sock, Int(greeting[1])) != nil
            else { return }
            ProxyTestServer.write(sock, [5, 0])
            guard let request = ProxyTestServer.readSocksRequest(sock) else { return }
            server.record(request)
            ProxyTestServer.write(sock, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            var bytes: [UInt8] = []
            while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard let byte = ProxyTestServer.read(sock, 1) else { return }
                bytes += byte
            }
            ProxyTestServer.write(sock, Array("HTTP/1.1 200 OK\r\n\r\nfl=1\nip=203.0.113.9\nts=1\n".utf8))
        }
        let upstream = ProxyUpstream.socks5(host: "127.0.0.1", port: server.port, username: nil, password: nil)

        let address = try upstream.exitIP()
        XCTAssertEqual(address, "203.0.113.9")
        XCTAssertEqual(server.requests.last, [5, 1, 0, 3, 15] + Array("one.one.one.one".utf8) + [0, 80])
    }

    func testMissingProfileGivesNoPort() {
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        let service = makeService()
        service.apply(UUID(), to: bottle) { _ in }
        XCTAssertNil(service.port(for: bottle))
    }
}
