//
//  BottleFileKeysTests.swift
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

/// The keys a bottle's files are written with follow the rename (`wine` → `ano`),
/// so a bottle this Ano makes never looks like one an earlier Ano made.
@Suite("Bottle file keys")
@MainActor
final class BottleFileKeysTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bottle_file_keys_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Every dictionary key, at any depth, of a decoded property list.
    private static func keys(in plist: Any) -> [String] {
        if let dictionary = plist as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap { keys(in: $0) }
        }
        if let array = plist as? [Any] {
            return array.flatMap { keys(in: $0) }
        }
        return []
    }

    private static func keys(ofPlist data: Data) throws -> [String] {
        try keys(in: PropertyListSerialization.propertyList(from: data, format: nil))
    }

    private static func keys(of value: some Encodable) throws -> [String] {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try keys(ofPlist: encoder.encode(value))
    }

    private static func wineKeys(_ keys: [String]) -> [String] {
        keys.filter { $0.lowercased().contains("wine") }.sorted()
    }

    @Test("A new bottle's Metadata.plist has no key containing wine, and reads back")
    func newBottleMetadata() throws {
        let url = root.appending(path: "New")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: url)
        // Optional keys are written only once set.
        bottle.settings.rockstarWineD3D = false
        bottle.settings.windowsVersion = .win7
        bottle.settings.avxEnabled = true

        let keys = try Self.keys(ofPlist: Data(contentsOf: url.appending(path: "Metadata.plist")))
        #expect(Self.wineKeys(keys) == [])
        #expect(keys.contains("anoConfig"))
        #expect(keys.contains("anoVersion"))
        #expect(keys.contains("rockstarAnoD3D"))

        let reloaded = Bottle(bottleUrl: url)
        #expect(!reloaded.isFromOldRuntime)
        #expect(reloaded.settings.windowsVersion == .win7)
        #expect(reloaded.settings.avxEnabled)
        #expect(!reloaded.settings.rockstarWineD3D)
    }

    @Test("Program settings keep their ANODEBUG preset under activeAnoDebugPreset")
    func programSettings() throws {
        var settings = ProgramSettings()
        settings.activeWineDebugPreset = .dllLoad

        let keys = try Self.keys(of: settings)
        #expect(Self.wineKeys(keys) == [])
        #expect(keys.contains("activeAnoDebugPreset"))

        let url = root.appending(path: "Program.plist")
        try settings.encode(to: url)
        #expect(try ProgramSettings.decode(from: url).activeWineDebugPreset == .dllLoad)
    }

    @Test("A run log entry records the ANODEBUG preset and output under the Ano keys")
    func runLog() throws {
        var entry = RunLogEntry(programName: "Game.exe", logFileName: "run.log")
        entry.activeWineDebugPreset = "crash"
        entry.hasWineDebugOutput = true

        let keys = try Self.keys(of: entry)
        #expect(Self.wineKeys(keys) == [])
        #expect(keys.contains("activeAnoDebugPreset"))
        #expect(keys.contains("hasAnoDebugOutput"))

        let decoded = try PropertyListDecoder().decode(RunLogEntry.self, from: PropertyListEncoder().encode(entry))
        #expect(decoded.activeWineDebugPreset == "crash")
        #expect(decoded.hasWineDebugOutput)
    }

    @Test("A diagnosis history entry records its ANODEBUG preset under anoDebugPreset")
    func diagnosisHistory() throws {
        let entry = DiagnosisHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), logFileRef: "run.log",
            primaryCategory: .coreCrashFatal, confidenceTier: .high, topSignatures: [], remediationCardIds: [],
            wineDebugPreset: .crash, bottleIdentifier: "Bottle", programPath: "/Game.exe"
        )

        let keys = try Self.keys(of: entry)
        #expect(Self.wineKeys(keys) == [])
        #expect(keys.contains("anoDebugPreset"))

        let decoded = try PropertyListDecoder()
            .decode(DiagnosisHistoryEntry.self, from: PropertyListEncoder().encode(entry))
        #expect(decoded.wineDebugPreset == .crash)
    }

    @Test("A troubleshooting snapshot records the server state under isAnoServerRunning")
    func preflight() throws {
        let preflight = PreflightData(
            bottleURL: root, bottleName: "Bottle", isWineserverRunning: true, processCount: 3,
            graphicsBackend: "dxvk"
        )

        let keys = try Self.keys(of: preflight)
        #expect(Self.wineKeys(keys) == [])
        #expect(keys.contains("isAnoServerRunning"))

        let decoded = try PropertyListDecoder()
            .decode(PreflightData.self, from: PropertyListEncoder().encode(preflight))
        #expect(decoded.isWineserverRunning)
        #expect(decoded.processCount == 3)
    }
}
