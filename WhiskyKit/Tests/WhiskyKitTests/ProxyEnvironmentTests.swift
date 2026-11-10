//
//  ProxyEnvironmentTests.swift
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

final class ProxyEnvironmentTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appending(path: "proxy-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    private func makeBottle(proxied: Bool) -> Bottle {
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        if proxied {
            bottle.settings.proxyEnabled = true
            bottle.settings.proxyProfileID = UUID()
        }
        return bottle
    }

    @MainActor
    func testProxyOffBottleHasNoProxyOrDyldKeys() {
        let env = Wine.constructWineEnvironment(for: makeBottle(proxied: false), proxyPort: { _ in 4_242 })
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("ANO_") || $0.hasPrefix("DYLD_") }.isEmpty, "\(env.keys)")
    }

    @MainActor
    func testProxiedBottleGetsVariablesWithoutDyld() {
        let env = Wine.constructWineEnvironment(for: makeBottle(proxied: true), proxyPort: { _ in 4_242 })
        XCTAssertEqual(env[ProxyEnvironment.portKey], "4242")
        XCTAssertEqual(env[ProxyEnvironment.realLoaderKey], AnoWineRuntime.loaderURL.path(percentEncoded: false))
        XCTAssertNotNil(env[ProxyEnvironment.libraryKey])
        XCTAssertNotNil(env[ProxyEnvironment.wineDirKey])
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
    }

    @MainActor
    func testProxiedBottleWithoutHelperFailsClosed() {
        let env = Wine.constructWineEnvironment(for: makeBottle(proxied: true), proxyPort: { _ in nil })
        XCTAssertEqual(env[ProxyEnvironment.portKey], "0")
    }

    func testDyldOnlyForLoaderAndServer() {
        let proxied = ProxyEnvironment.variables(port: 4_242, library: URL(filePath: "/tmp/libano_net.dylib"))

        for executable in [AnoWineRuntime.loaderURL, AnoWineRuntime.serverURL] {
            let env = ProxyEnvironment.launchEnvironment(proxied, executable: executable)
            XCTAssertEqual(env["DYLD_INSERT_LIBRARIES"], "/tmp/libano_net.dylib", executable.path)
        }
        for executable in [URL(filePath: "/usr/bin/env"), URL(filePath: "/bin/sh")] {
            var incoming = proxied
            incoming["DYLD_INSERT_LIBRARIES"] = "/tmp/libano_net.dylib"
            XCTAssertNil(ProxyEnvironment.launchEnvironment(incoming, executable: executable)["DYLD_INSERT_LIBRARIES"])
        }
        let unproxied = ProxyEnvironment.launchEnvironment(["WINEPREFIX": "/x"], executable: AnoWineRuntime.loaderURL)
        XCTAssertNil(unproxied["DYLD_INSERT_LIBRARIES"])
    }

    func testTerminalForProxiedBottleShadowsLoaderAndNeverExportsDyld() {
        let bin = URL(filePath: "/tmp/ano-bin")
        var environment = ProxyEnvironment.variables(port: 4_242)
        environment["DYLD_INSERT_LIBRARIES"] = "/tmp/libano_net.dylib"

        let command = Wine.generateTerminalEnvironmentCommand(binFolder: bin, environment: environment)

        let pathLine = command.split(separator: "\n").first { $0.hasPrefix("export PATH=") } ?? ""
        let wrapper = pathLine.range(of: ProxyEnvironment.wrapperFolder.path(percentEncoded: false))
        let runtime = pathLine.range(of: "/tmp/ano-bin")
        XCTAssertNotNil(wrapper, String(pathLine))
        XCTAssertNotNil(runtime, String(pathLine))
        if let wrapper, let runtime { XCTAssertLessThan(wrapper.lowerBound, runtime.lowerBound) }
        XCTAssertFalse(command.contains("DYLD_"), command)
    }

    func testTerminalForUnproxiedBottleIsUnchanged() {
        let command = Wine.generateTerminalEnvironmentCommand(
            binFolder: URL(filePath: "/tmp/ano-bin"), environment: [:]
        )
        XCTAssertFalse(command.contains(ProxyEnvironment.wrapperFolder.path(percentEncoded: false)))
    }

    @MainActor
    func testRunCommandForProxiedBottleUsesWrapper() {
        let program = tempDir.appending(path: "game.exe")
        let command = Wine.generateRunCommand(
            at: program, bottle: makeBottle(proxied: true), args: "", environment: [:]
        )
        let wrapper = ProxyEnvironment.wrapperFolder.appending(path: AnoWineRuntime.loaderName)
        XCTAssertTrue(command.contains(wrapper.esc), command)
        XCTAssertFalse(command.contains(Wine.wineBinary.esc), command)
        XCTAssertFalse(command.contains("DYLD_"), command)
    }

    func testWrapperScriptIsExact() throws {
        let wrapper = try ProxyEnvironment.installWrapper(in: tempDir)

        XCTAssertEqual(wrapper.lastPathComponent, "ano-loader")
        let script = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertEqual(script, """
        #!/bin/sh
        # Ano: start Wine with the proxy interceptor. Only Wine gets it.
        DYLD_INSERT_LIBRARIES="$ANO_NET_LIB" exec "$ANO_REAL_LOADER" "$@"

        """)
        let mode = try FileManager.default.attributesOfItem(atPath: wrapper.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testApplyingAdditionsPrefixesPathAndDropsDyld() {
        let additions = (variables: [ProxyEnvironment.portKey: "4242"], pathPrefix: Optional("/w"))
        let env = ProxyEnvironment.applying(
            additions, to: ["PATH": "/bin:/usr/bin", "WINE": "ano-loader", "DYLD_INSERT_LIBRARIES": "/x"]
        )
        XCTAssertEqual(env["PATH"], "/w:/bin:/usr/bin")
        XCTAssertEqual(env["WINE"], "ano-loader")
        XCTAssertEqual(env[ProxyEnvironment.portKey], "4242")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(ProxyEnvironment.applying(([:], nil), to: ["PATH": "/bin"]), ["PATH": "/bin"])
    }

    @MainActor
    func testShellAdditionsOnlyForProxiedBottles() {
        XCTAssertTrue(ProxyEnvironment.shellAdditions(for: makeBottle(proxied: false)).variables.isEmpty)
        XCTAssertNil(ProxyEnvironment.shellAdditions(for: makeBottle(proxied: false)).pathPrefix)

        let additions = ProxyEnvironment.shellAdditions(for: makeBottle(proxied: true), proxyPort: { _ in 4_242 })
        XCTAssertEqual(additions.variables[ProxyEnvironment.portKey], "4242")
        XCTAssertEqual(additions.pathPrefix, ProxyEnvironment.wrapperFolder.path(percentEncoded: false))
    }
}
