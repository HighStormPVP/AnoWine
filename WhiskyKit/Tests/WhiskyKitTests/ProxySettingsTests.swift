//
//  ProxySettingsTests.swift
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

final class InMemoryProxySecretStore: ProxySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: String] = [:]

    func password(for id: UUID) -> String? {
        lock.withLock { secrets[id] }
    }

    func setPassword(_ password: String?, for id: UUID) throws {
        lock.withLock { secrets[id] = password }
    }
}

final class ProxySettingsTests: XCTestCase {
    func testBottleSettingsWithoutProxyKeysDecodeProxyOff() throws {
        let data = try PropertyListEncoder().encode(BottleSettings())
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNotNil(plist["proxyConfig"])
        plist.removeValue(forKey: "proxyConfig")
        let stripped = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let settings = try PropertyListDecoder().decode(BottleSettings.self, from: stripped)

        XCTAssertFalse(settings.proxyEnabled)
        XCTAssertNil(settings.proxyProfileID)
        XCTAssertNil(settings.proxyLastPort)
    }

    func testProxySettingsRoundTrip() throws {
        var settings = BottleSettings()
        settings.proxyEnabled = true
        settings.proxyProfileID = UUID()
        settings.proxyLastPort = 51_234

        let data = try PropertyListEncoder().encode(settings)
        let decoded = try PropertyListDecoder().decode(BottleSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
        XCTAssertTrue(decoded.proxyEnabled)
        XCTAssertEqual(decoded.proxyLastPort, 51_234)
    }

    @MainActor
    func testProfileStorePersistsWithoutPassword() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let secrets = InMemoryProxySecretStore()
        let store = ProxyProfileStore(fileURL: file, secrets: secrets)
        var profile = ProxyProfile.newDefault()
        profile.username = "alice"

        try store.save(profile, password: "s3cret")

        let reloaded = ProxyProfileStore(fileURL: file, secrets: secrets)
        XCTAssertEqual(reloaded.profiles, [profile])
        XCTAssertEqual(reloaded.profile(id: profile.id), profile)
        let bytes = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(bytes.contains("s3cret"))
        XCTAssertEqual(secrets.password(for: profile.id), "s3cret")
    }

    @MainActor
    func testDeletingProfileDeletesSecret() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let secrets = InMemoryProxySecretStore()
        let store = ProxyProfileStore(fileURL: file, secrets: secrets)
        let profile = ProxyProfile.newDefault()
        try store.save(profile, password: "s3cret")

        try store.delete(id: profile.id)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(secrets.password(for: profile.id))
        XCTAssertTrue(ProxyProfileStore(fileURL: file, secrets: secrets).profiles.isEmpty)
    }

    func testDefaultProfileIsLocalSocks() {
        let profile = ProxyProfile.newDefault()
        XCTAssertEqual(profile.kind, .socks5)
        XCTAssertEqual(profile.host, "127.0.0.1")
        XCTAssertEqual(profile.port, 1080)
        XCTAssertEqual(profile.name, "Hiddify")
        XCTAssertEqual(profile.username, "")
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "proxy-\(UUID().uuidString).json")
    }
}
