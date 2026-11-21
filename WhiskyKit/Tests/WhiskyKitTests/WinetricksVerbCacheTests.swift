//
//  WinetricksVerbCacheTests.swift
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
import Testing
@testable import WhiskyKit

/// Plan 3c-4a: ano-tricks keeps its log in a bottle as `ano-tricks.log`; the
/// installed verbs, and when the cache of them is stale, are read from it.
@Suite("ano-tricks' log and the verb cache")
struct WinetricksVerbCacheTests {
    private static func makeBottleFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "verb-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "drive_c"), withIntermediateDirectories: true)
        return url
    }

    @Test("The log is ano-tricks.log")
    func logName() {
        #expect(WinetricksVerbCache.logFileName == "ano-tricks.log")
    }

    @Test("Installed verbs come from ano-tricks.log, not winetricks.log")
    func verbsComeFromTheAnoTricksLog() throws {
        let bottle = try Self.makeBottleFolder()
        defer { try? FileManager.default.removeItem(at: bottle) }

        try Data("vcrun2019\n".utf8).write(to: bottle.appending(path: "winetricks.log"))
        #expect(WinetricksVerbCache.verbsFromLog(in: bottle).isEmpty)
        #expect(WinetricksVerbCache.winetricksLogInfo(for: bottle).size == nil)

        try Data("vcrun2022\nd3dx9\nExecuting load_xact\n".utf8).write(to: bottle.appending(path: "ano-tricks.log"))
        #expect(WinetricksVerbCache.verbsFromLog(in: bottle) == ["vcrun2022", "d3dx9", "xact"])
        #expect(WinetricksVerbCache.winetricksLogInfo(for: bottle).size != nil)
    }

    @Test("A log in drive_c counts when the prefix root has none")
    func driveCLogCounts() throws {
        let bottle = try Self.makeBottleFolder()
        defer { try? FileManager.default.removeItem(at: bottle) }

        try Data("xinput\n".utf8).write(to: bottle.appending(path: "drive_c").appending(path: "ano-tricks.log"))
        #expect(WinetricksVerbCache.verbsFromLog(in: bottle) == ["xinput"])
        #expect(WinetricksVerbCache.winetricksLogInfo(for: bottle).modDate != nil)
    }

    @Test("The cache is saved as AnoTricksCache.plist")
    func cacheFileName() throws {
        let bottle = try Self.makeBottleFolder()
        defer { try? FileManager.default.removeItem(at: bottle) }

        try WinetricksVerbCache.save(WinetricksVerbCache(installedVerbs: ["xact"]), to: bottle)
        let saved = bottle.appending(path: "AnoTricksCache.plist").path(percentEncoded: false)
        let old = bottle.appending(path: "WinetricksCache.plist").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: saved))
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(WinetricksVerbCache.load(from: bottle)?.installedVerbs == ["xact"])
    }
}
