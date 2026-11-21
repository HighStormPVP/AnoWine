//
//  EngineFeedTests.swift
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
import SemanticVersion
import Testing
@testable import WhiskyKit

@Suite("Engine update feeds")
struct EngineFeedTests {
    /// Ano 6 and 7 read `WhiskyWineVersion.plist` (runtime 3.1.6) and Ano 8
    /// reads `WhiskyWineVersion-v4.plist` (4.9.0). This app needs the renamed
    /// engine, so it reads a feed of its own, or a bump meant for one app line
    /// would reach the others too.
    @Test("The app reads the renamed engine's feed, not the ones older apps read")
    func readsItsOwnFeed() {
        let pages = "https://raw.githubusercontent.com/HighStormPVP/AnoWine/main/dist/pages"
        #expect(DistributionConfig.versionPlistURL == "\(pages)/AnoRuntimeVersion.plist")
        #expect(DistributionConfig.versionPlistURL != "\(pages)/WhiskyWineVersion.plist")
        #expect(DistributionConfig.versionPlistURL != "\(pages)/WhiskyWineVersion-v4.plist")
    }

    /// The published feeds decode as the app reads them: the old one still on
    /// 3.1.6, the new one on the GPTK-capable runtime 4.9.0 with a digest.
    @Test("The published feeds name the engines each app line should get")
    func publishedFeedsDecode() throws {
        let pages = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "dist/pages")
        let decoder = PropertyListDecoder()
        let legacy = try decoder.decode(
            WhiskyWineVersion.self, from: Data(contentsOf: pages.appending(path: "WhiskyWineVersion.plist"))
        )
        let current = try decoder.decode(
            WhiskyWineVersion.self, from: Data(contentsOf: pages.appending(path: "WhiskyWineVersion-v4.plist"))
        )
        #expect(legacy.version == SemanticVersion(3, 1, 6))
        #expect(current.version == SemanticVersion(4, 9, 0))
        #expect(current.gptkCapable == true)
        #expect(current.sha256?.count == 64)
    }
}
