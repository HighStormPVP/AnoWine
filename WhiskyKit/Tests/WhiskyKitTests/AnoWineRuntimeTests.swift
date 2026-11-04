//
//  AnoWineRuntimeTests.swift
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

@testable import WhiskyKit
import XCTest

final class AnoWineRuntimeTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(AnoWineRuntime.loaderName, "ano-loader")
        XCTAssertEqual(AnoWineRuntime.serverName, "ano-server")
    }

    func testURLsLiveInTheRuntimeBinFolder() {
        XCTAssertEqual(AnoWineRuntime.loaderURL, WhiskyWineInstaller.binFolder.appending(path: "ano-loader"))
        XCTAssertEqual(AnoWineRuntime.serverURL, WhiskyWineInstaller.binFolder.appending(path: "ano-server"))
    }

    func testWineBinaryUsesLoaderName() {
        XCTAssertEqual(Wine.wineBinary.lastPathComponent, "ano-loader")
    }

    @MainActor
    func testEnvironmentSetsWineserver() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        let env = Wine.constructWineEnvironment(for: bottle)

        let server = try XCTUnwrap(env["WINESERVER"])
        XCTAssertTrue(server.hasSuffix("/Libraries/Wine/bin/ano-server"), server)
    }

    /// A runtime downloaded before the rename (or a partial install) only has
    /// `wine64`. It must count as "not installed" so setup re-downloads it,
    /// rather than failing at the first launch.
    func testRuntimeWithOnlyOriginalNamesIsNotPresent() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let binDir = tempDir.appending(path: "Wine").appending(path: "bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["version": ["major": 3, "minor": 1, "patch": 2]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: tempDir.appending(path: "WhiskyWineVersion").appendingPathExtension("plist"))
        try Data("#!/bin/sh\n".utf8).write(to: binDir.appending(path: "wine64"))
        // Runtime v3.1.2 named the loader `anowine`; it must be replaced, not reused.
        try Data("#!/bin/sh\n".utf8).write(to: binDir.appending(path: "anowine"))

        XCTAssertFalse(WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: tempDir))

        try Data("#!/bin/sh\n".utf8).write(to: binDir.appending(path: "ano-loader"))
        XCTAssertTrue(WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: tempDir))
    }
}
