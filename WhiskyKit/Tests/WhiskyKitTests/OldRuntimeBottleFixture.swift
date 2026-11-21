//
//  OldRuntimeBottleFixture.swift
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
@testable import WhiskyKit

/// A bottle as an Ano before runtime 5.0.0 left it: registries headed
/// `WINE REGISTRY Version 2`, a `Metadata.plist` with `wineConfig`, a pinned
/// program and that program's settings under their legacy file name.
enum OldRuntimeBottleFixture {
    /// The pinned program, relative to the bottle.
    static let programPath = "drive_c/Program Files/Game/Game.exe"

    /// Writes a bottle at `url`.
    ///
    /// - Parameters:
    ///   - url: The bottle's folder, created here.
    ///   - registryHeader: The first line of `system.reg` and `user.reg`; `nil` writes neither.
    ///   - configKey: The key of the runtime settings group in `Metadata.plist`; `nil` writes no plist.
    ///     Nested keys follow it: the old ones beside a key containing `wine`, the new ones otherwise.
    static func make(
        at url: URL, registryHeader: String? = "WINE REGISTRY Version 2", configKey: String? = "wineConfig"
    ) throws {
        let fileManager = FileManager.default
        let program = url.appending(path: programPath)
        try fileManager.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ an old game".utf8).write(to: program)

        if let registryHeader {
            try Data("\(registryHeader)\n;; All keys relative to \\\\Machine\n\n#arch=win64\n".utf8)
                .write(to: url.appending(path: "system.reg"))
            try Data("\(registryHeader)\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n#arch=win64\n".utf8)
                .write(to: url.appending(path: "user.reg"))
        }

        if let configKey {
            let old = configKey.lowercased().contains("wine")
            let pin = try plist(PinnedProgram(name: "Game", url: program))
            var info: [String: Any] = ["name": "Old Steam", "pins": [pin]]
            info["blocklist"] = [String]()
            info["unpinnedPrograms"] = [String]()
            var config: [String: Any] = ["windowsVersion": "win7", "avxEnabled": true]
            config[old ? "wineVersion" : "anoVersion"] = version(7, 7, 0)
            config["enhancedSync"] = ["esync": [String: String]()]
            var launcher: [String: Any] = ["backendMigration": 0, "localeMigration": 0]
            launcher[old ? "rockstarWineD3D" : "rockstarAnoD3D"] = false
            var metadata: [String: Any] = ["fileVersion": version(1, 0, 0), "info": info]
            metadata[configKey] = config
            metadata["launcherConfig"] = launcher
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: url.appending(path: "Metadata.plist"))
        }

        // Named the way settings were before they were keyed by the program's path.
        let settingsFolder = url.appending(path: "Program Settings")
        try fileManager.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
        let programSettings: [String: Any] = [
            "activeWineDebugPreset": "verbose",
            "arguments": "-old",
            "environment": [String: String](),
            "locale": "auto"
        ]
        try PropertyListSerialization.data(fromPropertyList: programSettings, format: .xml, options: 0)
            .write(to: settingsFolder.appending(path: "Game.exe.plist"))
    }

    private static func version(_ major: Int, _ minor: Int, _ patch: Int) -> [String: Any] {
        ["major": major, "minor": minor, "patch": patch, "preRelease": "", "build": ""]
    }

    private static func plist(_ value: some Encodable) throws -> Any {
        try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(value), format: nil)
    }
}

/// Every file and folder under a bottle, with its bytes and modification time,
/// so a test can tell that nothing was written, created or removed.
struct BottleFilesSnapshot: Equatable {
    private struct Entry: Equatable {
        let isDirectory: Bool
        let bytes: Data?
        let modified: Date?
    }

    private let entries: [String: Entry]

    init(_ root: URL) throws {
        let fileManager = FileManager.default
        let rootPath = root.path(percentEncoded: false)
        var entries: [String: Entry] = [:]
        for relative in try [""] + fileManager.subpathsOfDirectory(atPath: rootPath) {
            let path = relative.isEmpty ? rootPath : (rootPath as NSString).appendingPathComponent(relative)
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
            entries[relative] = try Entry(
                isDirectory: isDirectory,
                bytes: isDirectory ? nil : Data(contentsOf: URL(filePath: path)),
                modified: attributes[.modificationDate] as? Date
            )
        }
        self.entries = entries
    }

    /// The paths, relative to the bottle (`""` is the bottle's own folder), that
    /// differ from `earlier`: written, touched, created or removed.
    func changes(since earlier: BottleFilesSnapshot) -> [String] {
        Set(entries.keys).union(earlier.entries.keys)
            .filter { entries[$0] != earlier.entries[$0] }
            .sorted()
    }
}
