//
//  AnoWineIdentityTests.swift
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

final class AnoWineIdentityTests: XCTestCase {
    /// Without an identifier (e.g. the bundled CLI), falling back to Whisky's
    /// would point the CLI, Open Terminal and desktop shortcuts at the user's
    /// Whisky bottles.
    func testFallbackBundleIdentifierIsAnoWine() {
        XCTAssertEqual(Bundle.resolveWhiskyBundleIdentifier(nil), "io.github.highstormpvp.Ano")
    }

    /// If the CLI does carry an identifier, it is its own target's. It still
    /// has to use the app's folders, or it never sees the app's bottles.
    func testCLIIdentifierResolvesToTheApp() {
        XCTAssertEqual(
            Bundle.resolveWhiskyBundleIdentifier("io.github.highstormpvp.AnoCmd"),
            "io.github.highstormpvp.Ano"
        )
    }

    func testRealBundleIdentifierWins() {
        XCTAssertEqual(Bundle.resolveWhiskyBundleIdentifier("io.example.Other"), "io.example.Other")
    }

    /// Whisky installs its CLI as /usr/local/bin/whisky; AnoWine must not
    /// overwrite it, and must not shadow the `anowine` Wine loader either.
    func testCLILinkDoesNotCollide() {
        XCTAssertEqual(AnoWineCLI.linkPath, "/usr/local/bin/ano")
    }
}
