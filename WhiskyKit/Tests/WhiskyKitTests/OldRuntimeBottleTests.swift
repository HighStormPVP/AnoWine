//
//  OldRuntimeBottleTests.swift
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

import Foundation
import Testing
@testable import WhiskyKit

/// Records whether a launch got as far as the prefix: its registry imports and
/// the prefix bootstrap, which need the engine.
@MainActor
private final class LaunchRecorder {
    private(set) var calls: [String] = []

    var writer: Wine.DLLOverrideWriter {
        { _, _ in self.calls.append("DLL overrides") }
    }

    var importer: Wine.RegistryImporter {
        { _, _ in self.calls.append("registry import") }
    }

    var bootstrapper: Wine.PrefixBootstrapper {
        { _ in self.calls.append("prefix bootstrap") }
    }
}

/// A bottle made by an Ano before runtime 5.0.0 is listed and refused, and
/// nothing writes to it (design decision 3): not loading, not a refresh, not a
/// settings change and not a refused run.
@Suite("Bottles made by an earlier Ano")
@MainActor
final class OldRuntimeBottleTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "old_runtime_bottle_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeOldBottle(_ name: String = "OldBottle") throws -> URL {
        let url = root.appending(path: name)
        try OldRuntimeBottleFixture.make(at: url)
        return url
    }

    private func expectUnchanged(_ url: URL, since before: BottleFilesSnapshot) throws {
        let changed = try BottleFilesSnapshot(url).changes(since: before)
        #expect(changed.isEmpty, "written to the old bottle: \(changed)")
    }

    // MARK: - Detection

    @Test("A system.reg headed WINE REGISTRY or a Metadata.plist key containing wine marks an old bottle")
    func detection() throws {
        let both = root.appending(path: "Both")
        try OldRuntimeBottleFixture.make(at: both)
        let registryOnly = root.appending(path: "RegistryOnly")
        try OldRuntimeBottleFixture.make(at: registryOnly, configKey: "anoConfig")
        let plistOnly = root.appending(path: "PlistOnly")
        try OldRuntimeBottleFixture.make(at: plistOnly, registryHeader: "ANO REGISTRY Version 2")
        let capitalised = root.appending(path: "Capitalised")
        try OldRuntimeBottleFixture.make(at: capitalised, registryHeader: nil, configKey: "WineConfig")
        let registryWithoutPlist = root.appending(path: "RegistryWithoutPlist")
        try OldRuntimeBottleFixture.make(at: registryWithoutPlist, configKey: nil)

        #expect(OldRuntimeBottle.isOld(at: both))
        #expect(OldRuntimeBottle.isOld(at: registryOnly))
        #expect(OldRuntimeBottle.isOld(at: plistOnly))
        #expect(OldRuntimeBottle.isOld(at: capitalised))
        #expect(OldRuntimeBottle.isOld(at: registryWithoutPlist))
    }

    @Test("A bottle this Ano made, or one not set up yet, is not old")
    func currentBottlesAreNotOld() throws {
        let current = root.appending(path: "Current")
        try OldRuntimeBottleFixture.make(at: current, registryHeader: "ANO REGISTRY Version 2", configKey: "anoConfig")
        let notBootedYet = root.appending(path: "NotBootedYet")
        try OldRuntimeBottleFixture.make(at: notBootedYet, registryHeader: nil, configKey: "anoConfig")
        let empty = root.appending(path: "Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(!OldRuntimeBottle.isOld(at: current))
        #expect(!OldRuntimeBottle.isOld(at: notBootedYet))
        #expect(!OldRuntimeBottle.isOld(at: empty))
        #expect(!Bottle(bottleUrl: current, isAvailable: true).isFromOldRuntime)
        #expect(!Bottle(bottleUrl: empty).isFromOldRuntime)
    }

    @Test("An old bottle is flagged and listed by its folder name, its settings not read")
    func flaggedWithoutDecoding() throws {
        let url = try makeOldBottle()
        let bottle = Bottle(bottleUrl: url, isAvailable: true)

        #expect(bottle.isFromOldRuntime)
        #expect(bottle.settings.name == url.lastPathComponent, "the plist's name would mean it was decoded")
        #expect(bottle.settings.windowsVersion == .win10, "the plist says Windows 7")
        #expect(bottle.settings.pins.isEmpty, "the plist pins Game.exe")
        #expect(!bottle.isAvailable, "an old bottle can't be opened")
    }

    // MARK: - Nothing writes to it

    @Test("Loading and refreshing the bottle list write nothing to an old bottle")
    func loadAndRefresh() throws {
        let url = try makeOldBottle()
        let before = try BottleFilesSnapshot(url)
        var registry = BottleData(entriesFile: root.appending(path: "BottleVM.plist"))
        let registered = registry.registerBottlePath(url)
        #expect(registered)

        for _ in 0 ..< 2 {
            let bottles = registry.loadBottles()
            #expect(bottles.count == 1)
            for bottle in bottles {
                #expect(bottle.isFromOldRuntime)
                // What the app's refresh runs on each bottle.
                LauncherBackendMigration.migrateIfNeeded(bottle, d3dMetalInstalled: true)
                LauncherLocaleMigration.migrateIfNeeded(bottle)
            }
        }

        try expectUnchanged(url, since: before)
    }

    @Test("A settings change, a program's settings and a pin write nothing to an old bottle")
    func settingsChanges() throws {
        let url = try makeOldBottle()
        let before = try BottleFilesSnapshot(url)
        let bottle = Bottle(bottleUrl: url, isAvailable: true)

        bottle.settings.name = "Renamed"
        bottle.settings.windowsVersion = .win11
        bottle.saveBottleSettings()
        let program = Program(url: url.appending(path: OldRuntimeBottleFixture.programPath), bottle: bottle)
        #expect(program.settings.activeWineDebugPreset == nil, "the program's old settings were decoded")
        program.settings.arguments = "-new"
        program.pinned = true
        program.pinned = false

        try expectUnchanged(url, since: before)
    }

    @Test("The orphan scan leaves an old bottle alone")
    func orphanScan() throws {
        let url = try makeOldBottle()
        let before = try BottleFilesSnapshot(url)
        let registry = BottleData(entriesFile: root.appending(path: "BottleVM.plist"))

        #expect(registry.orphanedBottles(in: root).isEmpty, "an old bottle is no bottle to re-import")
        try expectUnchanged(url, since: before)
    }

    // MARK: - Refused

    @Test("Running a program in an old bottle is refused before anything reaches it")
    func runRefused() async throws {
        let url = try makeOldBottle()
        let before = try BottleFilesSnapshot(url)
        let bottle = Bottle(bottleUrl: url, isAvailable: true)
        // Without the refusal these would start the engine on the bottle.
        try #require(bottle.isFromOldRuntime)
        let program = Program(url: url.appending(path: OldRuntimeBottleFixture.programPath), bottle: bottle)
        let recorder = LaunchRecorder()

        await #expect(throws: OldRuntimeBottleError.self) {
            _ = try await program.prepareLaunch(
                args: [], overrideWriter: recorder.writer, importer: recorder.importer,
                bootstrapper: recorder.bootstrapper
            )
        }
        await #expect(throws: OldRuntimeBottleError.self) {
            try await Wine.runProgram(at: program.url, bottle: bottle)
        }
        await #expect(throws: OldRuntimeBottleError.self) {
            try await program.launch(args: [])
        }
        await #expect(throws: OldRuntimeBottleError.self) {
            try await Wine.runWine(["--version"], bottle: bottle)
        }
        let result = await program.launchWithUserMode(useTerminal: false)
        #expect(result.errorDescription == OldRuntimeBottleError().localizedDescription)

        #expect(recorder.calls.isEmpty)
        try expectUnchanged(url, since: before)
    }

    @Test("Commands that act on an old bottle refuse it with a message that names the fix")
    func commandsRefuse() throws {
        let url = try makeOldBottle()
        let before = try BottleFilesSnapshot(url)
        let bottle = Bottle(bottleUrl: url, isAvailable: true)

        #expect(throws: OldRuntimeBottleError.self) {
            try bottle.refuseIfFromOldRuntime()
        }
        #expect(throws: ExistingBottleError.madeByEarlierAno) {
            try BottleData.existingBottleSettings(at: url)
        }
        let message = OldRuntimeBottleError().localizedDescription
        #expect(message.contains("earlier version of Ano"))
        #expect(message.contains("Create a new bottle and reinstall its programs"))
        #expect(!message.lowercased().contains("wine"))

        try expectUnchanged(url, since: before)
    }

    @Test("A bottle this Ano made is not refused")
    func currentBottleNotRefused() throws {
        let url = root.appending(path: "Current")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: url)

        #expect(throws: Never.self) {
            try bottle.refuseIfFromOldRuntime()
        }
        #expect(throws: Never.self) {
            try BottleData.existingBottleSettings(at: url)
        }
    }
}
