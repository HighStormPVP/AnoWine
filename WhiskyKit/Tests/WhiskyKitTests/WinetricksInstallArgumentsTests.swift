//
//  WinetricksInstallArgumentsTests.swift
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

@Suite("Winetricks install arguments")
struct WinetricksInstallArgumentsTests {
    private let script = "/Resources/ano-tricks"
    private let resources = URL(filePath: "/Resources")
    private let bottle = URL(filePath: "/Bottles/Game")

    @Test("Every verb runs unattended", arguments: ["xact", "dotnet48", "d3dcompiler_47", "corefonts"])
    func everyVerbIsUnattended(_ verb: String) {
        #expect(WinetricksInstallArguments.arguments(verb: verb, winetricksPath: script)
            == ["bash", script, "-q", verb])
    }

    @Test("The vcrun verbs are also forced past stale checksums")
    func vcrunIsForced() {
        #expect(WinetricksInstallArguments.arguments(verb: "vcrun2022", winetricksPath: script)
            == ["bash", script, "--force", "-q", "vcrun2022"])
    }

    // MARK: - Plan 3c-4a: ano-tricks and the engine's names

    @Test("Installs and the installed-verbs list run the bundled ano-tricks")
    func runsAnoTricks() {
        #expect(WinetricksInstallArguments.scriptName == "ano-tricks")
        #expect(WinetricksInstallArguments.arguments(verb: "vcrun2022", resourcesURL: resources)
            == ["bash", "/Resources/ano-tricks", "--force", "-q", "vcrun2022"])
        #expect(WinetricksInstallArguments.arguments(verb: "xact", resourcesURL: resources)
            == ["bash", "/Resources/ano-tricks", "-q", "xact"])
        #expect(WinetricksInstallArguments.listInstalledArguments(resourcesURL: resources)
            == ["bash", "/Resources/ano-tricks", "list-installed"])
    }

    @Test("An install's environment uses the engine's names and none with WINE")
    func environmentUsesTheEnginesNames() {
        let environment = WinetricksInstallArguments.environment(
            bottleURL: bottle, resourcesURL: resources, proxy: ([:], nil), home: "/Users/me"
        )
        #expect(environment == [
            "ANOPREFIX": "/Bottles/Game",
            "ANO": "ano-loader",
            "ANOSERVER": AnoWineRuntime.serverURL.path(percentEncoded: false),
            "PATH": WhiskyWineInstaller.binFolder.path(percentEncoded: false) + ":/Resources:/usr/bin:/bin",
            "HOME": "/Users/me"
        ])
        #expect(environment.keys.filter { $0.contains("WINE") }.isEmpty, "\(environment.keys.sorted())")
    }

    @Test("The Terminal script exports the engine's names and runs ano-tricks")
    func terminalScriptUsesTheEnginesNames() {
        let text = WinetricksInstallArguments.terminalScript(
            command: "vcrun2022", bottleURL: bottle, resourcesURL: resources, proxy: ([:], nil)
        )
        let lines = text.split(separator: "\n").map(String.init)
        let server = AnoWineRuntime.serverURL.path(percentEncoded: false)
        #expect(lines.contains("export ANO=ano-loader"), "\(text)")
        #expect(lines.contains("export ANOSERVER='\(server)'"), "\(text)")
        #expect(lines.contains("export ANOPREFIX='/Bottles/Game'"), "\(text)")
        #expect(lines.last == "'bash' '/Resources/ano-tricks' 'vcrun2022'", "\(text)")
        #expect(!text.contains("WINE"), "\(text)")
    }

    @Test("The Terminal script carries a proxied bottle's variables and wrapper")
    func terminalScriptCarriesTheProxy() {
        let text = WinetricksInstallArguments.terminalScript(
            command: "list-installed", bottleURL: bottle, resourcesURL: resources,
            proxy: (variables: ["ANO_BIN": "/Ano/bin/ano-loader"], pathPrefix: "/Wrapper")
        )
        #expect(text.contains("\nexport ANO_BIN='/Ano/bin/ano-loader'\n"), "\(text)")
        #expect(text.contains("\nexport PATH='/Wrapper:"), "\(text)")
    }

    @Test("The Terminal script's temp file is named for ano-tricks")
    func terminalScriptName() {
        let uuid = UUID()
        #expect(WinetricksInstallArguments.terminalScriptName(uuid: uuid) == "ano-tricks-\(uuid.uuidString).sh")
    }
}
