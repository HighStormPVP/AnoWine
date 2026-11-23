//
//  AppMigrationsTests.swift
//  WhiskyKitTests
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

@testable import WhiskyKit
import XCTest

/// The first launch of the renamed app carries the user's settings and the
/// imported Game Porting Toolkit across the rename (Plan 3c-4c Task 2).
final class AppMigrationsTests: XCTestCase {
    private var root = URL(filePath: "/nonexistent")
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeGPTKTempDir()
        suiteName = "AppMigrationsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - Settings

    func testTheUpdateCheckOptOutIsCarriedOver() {
        defaults.set(false, forKey: "checkWhiskyWineUpdates")

        let changed = AppMigrations.migrateDefaults(defaults, domain: suiteName)

        XCTAssertEqual(changed, ["checkAnoRuntimeUpdates", "checkWhiskyWineUpdates"])
        XCTAssertFalse(defaults.bool(forKey: "checkAnoRuntimeUpdates"))
        XCTAssertEqual(defaults.object(forKey: "checkAnoRuntimeUpdates") as? Bool, false, "stored, not absent")
        XCTAssertNil(defaults.object(forKey: "checkWhiskyWineUpdates"))
        XCTAssertEqual(WhiskyWineInstaller.automaticUpdateCheckDefaultsKey, "checkAnoRuntimeUpdates")
        XCTAssertFalse(WhiskyWineInstaller.automaticUpdateChecksEnabled(in: defaults), "the check stays off")
    }

    func testANewChoiceIsNotOverwritten() {
        defaults.set(false, forKey: "checkWhiskyWineUpdates")
        defaults.set(true, forKey: "checkAnoRuntimeUpdates")

        let changed = AppMigrations.migrateDefaults(defaults, domain: suiteName)

        XCTAssertEqual(changed, ["checkWhiskyWineUpdates"])
        XCTAssertEqual(defaults.object(forKey: "checkAnoRuntimeUpdates") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "checkWhiskyWineUpdates"))
    }

    func testNoOldKeyLeavesTheDefault() {
        XCTAssertEqual(AppMigrations.migrateDefaults(defaults, domain: suiteName), [])
        XCTAssertNil(defaults.object(forKey: "checkAnoRuntimeUpdates"))
        XCTAssertTrue(WhiskyWineInstaller.automaticUpdateChecksEnabled(in: defaults))
    }

    func testTheSectionStateIsCarriedOver() {
        defaults.set(false, forKey: "wineSectionExpanded")

        AppMigrations.migrateDefaults(defaults, domain: suiteName)

        XCTAssertEqual(defaults.object(forKey: "anoSectionExpanded") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "wineSectionExpanded"))
    }

    func testEveryOtherWineKeyIsDropped() {
        defaults.set(1, forKey: "wineDebugThing")
        defaults.set("x", forKey: "WINEsomething")
        defaults.set(true, forKey: "hasOfferedLegacyMigration")
        defaults.set("name", forKey: "librarySort")

        let changed = AppMigrations.migrateDefaults(defaults, domain: suiteName)

        XCTAssertEqual(changed, ["WINEsomething", "hasOfferedLegacyMigration", "wineDebugThing"])
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?.keys.sorted(), ["librarySort"])
        XCTAssertEqual(defaults.string(forKey: "librarySort"), "name")
    }

    // MARK: - The GPTK store

    func testAnAno8StoreIsRenamedAndStaysVerified() throws {
        let store = try makeAno8Store(verified: true)
        let lib = store.appending(path: "lib")
        XCTAssertNil(GPTKImporter.storedRecord(inStore: store), "Ano 8's layout does not count as a store")

        XCTAssertTrue(AppMigrations.migrateGPTKStore(at: store))

        XCTAssertTrue(exists(lib.appending(path: "ano").appending(path: "x86_64-windows").appending(path: "dxgi.dll")))
        XCTAssertFalse(exists(lib.appending(path: "wine")))
        XCTAssertNotNil(GPTKImporter.storedRecord(inStore: store))
        // From the stamp: a fresh check with this signer would fail.
        XCTAssertEqual(GPTKImporter.storeVerdict(inStore: store, isAppleSigned: { _, _ in false }), .verified)
        XCTAssertTrue(exists(GPTKImporter.storeWindowsFolder(inStoreLib: lib).appending(path: "dxgi.dll")))

        let runtime = root.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)
        XCTAssertTrue(GPTKImporter.isStorePayloadDeployed(inLibraryFolder: runtime, usingStore: store))
    }

    func testAnUnverifiedStoreStaysUnverified() throws {
        let store = try makeAno8Store(verified: false)

        XCTAssertTrue(AppMigrations.migrateGPTKStore(at: store))

        XCTAssertTrue(exists(storeWindowsDir(store).appending(path: "dxgi.dll")))
        XCTAssertNil(GPTKImporter.storeStamp(inStore: store))
    }

    func testOriginalsFromAnEarlierRuntimeAreDropped() throws {
        let earlier = try makeStore(named: "earlier", originalsFrom: "4.9.0")
        let current = try makeStore(named: "current", originalsFrom: "5.0.0")

        XCTAssertTrue(AppMigrations.migrateGPTKStore(at: earlier))
        XCTAssertFalse(AppMigrations.migrateGPTKStore(at: current))

        XCTAssertFalse(exists(earlier.appending(path: "originals")))
        XCTAssertTrue(exists(current.appending(path: "originals").appending(path: "dxgi.dll")))
    }

    func testBothFoldersKeepTheAnoOne() throws {
        let store = try makeImportedStore(in: root)
        let lib = store.appending(path: "lib")
        let ano = lib.appending(path: "ano")
        let before = try snapshot(of: ano)
        let old = lib.appending(path: "wine")
        try makePayload(at: root.appending(path: "old"))
        try FileManager.default.moveItem(at: root.appending(path: "old").appending(path: "wine"), to: old)
        try Data("Ano 8's copy".utf8).write(to: old.appending(path: "x86_64-windows").appending(path: "dxgi.dll"))

        XCTAssertTrue(AppMigrations.migrateGPTKStore(at: store))

        XCTAssertFalse(exists(old))
        XCTAssertEqual(try snapshot(of: ano), before)
    }

    // MARK: - Helpers

    /// A store the way Ano 8 left it: what `GPTKImporter` makes, but with the
    /// bridges' folder under Apple's name, and stamped verified when asked.
    private func makeAno8Store(verified: Bool) throws -> URL {
        let store = root.appending(path: "D3DMetal")
        try makePayload(at: store.appending(path: "lib"), moduleFolder: "wine")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(GPTKStoreRecord(gptkVersion: "4.0b2", importedAt: Date()))
            .write(to: GPTKImporter.recordURL(inStore: store))
        if verified {
            GPTKImporter.stampStoreVerified(inStore: store)
            XCTAssertNotNil(GPTKImporter.storeStamp(inStore: store))
        }
        return store
    }

    /// An imported store whose `originals/` holds a backup taken from `runtimeVersion`.
    private func makeStore(named name: String, originalsFrom runtimeVersion: String) throws -> URL {
        let store = try makeImportedStore(in: root.appending(path: name))
        let originals = store.appending(path: "originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try fakePE(builtin: true, mark: anoBuiltinMark).write(to: originals.appending(path: "dxgi.dll"))
        try PropertyListEncoder().encode(GPTKOriginalsRecord(runtimeVersion: runtimeVersion))
            .write(to: GPTKImporter.originalsRecordURL(inStore: store))
        return store
    }

    /// Every entry under `folder` with its bytes (empty for a folder).
    private func snapshot(of folder: URL) throws -> [String: Data] {
        let entries = try FileManager.default.subpathsOfDirectory(atPath: folder.path(percentEncoded: false))
        return Dictionary(uniqueKeysWithValues: entries.map { entry in
            (entry, (try? Data(contentsOf: folder.appending(path: entry))) ?? Data())
        })
    }

    /// Whether anything, a dangling link included, is at `url`.
    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }
}
