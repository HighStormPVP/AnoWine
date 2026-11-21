//
//  EngineNamesTests.swift
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

/// Engine 5.x reads only its own names: `ANOPREFIX`, `ANOSERVER`, `ANODEBUG`,
/// `ANODLLOVERRIDES`, `ANOMSYNC`, `ANO_LARGE_ADDRESS_AWARE`, `ANO_D3D_CONFIG`; the
/// registry under `Software\Ano`; the program `ano-cfg`; and it prints its version
/// as `ano-11.19`. D3DMetal's two variables are set as `ANOD3DMETAL` and `ANOESYNC`
/// (the engine hands them on under the names D3DMetal reads). A `WINE` name the
/// app still set would be silently ignored.
@Suite("The engine's names")
struct EngineNamesTests {
    static let syncModes: [EnhancedSync] = [.none, .esync, .msync]
    /// No launcher, then every launcher preset.
    static let launchers: [LauncherType?] = [nil] + LauncherType.allCases.map(Optional.some)

    static func wineNames(in environment: [String: String]) -> [String] {
        environment.keys.filter { $0.uppercased().contains("WINE") }.sorted()
    }

    static func expectSync(_ sync: EnhancedSync, in env: [String: String], _ context: String) {
        switch sync {
        case .esync:
            #expect(env["ANOESYNC"] == "1", "\(context)")
            #expect(env["ANOMSYNC"] == nil, "\(context)")
        case .msync:
            #expect(env["ANOMSYNC"] == "1", "\(context)")
            #expect(env["ANOESYNC"] == "1", "\(context)")
        case .none:
            #expect(env["ANOESYNC"] == (MacOSVersion.current >= .sequoia15_4 ? "1" : nil), "\(context)")
            #expect(env["ANOMSYNC"] == nil, "\(context)")
        }
    }

    // MARK: - Environment

    @Test("Every backend, sync mode and launcher preset sets the ANO names and no WINE one")
    @MainActor func bottleEnvironmentsUseTheEngineNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        for backend in GraphicsBackend.allCases {
            for sync in Self.syncModes {
                for launcher in Self.launchers {
                    bottle.settings.graphicsBackend = backend
                    bottle.settings.enhancedSync = sync
                    bottle.settings.launcherCompatibilityMode = launcher != nil
                    bottle.settings.detectedLauncher = launcher
                    let context = "\(backend.rawValue), \(sync), \(launcher?.rawValue ?? "no launcher")"

                    let env = Wine.constructWineEnvironment(
                        for: bottle, recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: false
                    )
                    #expect(Self.wineNames(in: env).isEmpty, "\(context): \(Self.wineNames(in: env))")
                    #expect(env["ANOPREFIX"] == tempDir.path, "\(context)")
                    #expect(env["ANOSERVER"] == AnoWineRuntime.serverURL.path(percentEncoded: false), "\(context)")
                    #expect(env["ANODEBUG"] == "fixme-all", "\(context)")
                    Self.expectSync(sync, in: env, context)
                    if launcher == .rockstar {
                        #expect(env["ANO_LARGE_ADDRESS_AWARE"] == "1", "\(context)")
                    }
                    if launcher == nil {
                        #expect(env["ANOD3DMETAL"] == (backend == .wined3d ? "0" : nil), "\(context)")
                        if backend == .dxvk || backend == .dxmt {
                            #expect(env["ANODLLOVERRIDES"]?.contains("d3d11=n,b") == true, "\(context)")
                        }
                    }

                    var settingsEnv: [String: String] = [:]
                    bottle.settings.environmentVariables(wineEnv: &settingsEnv)
                    #expect(Self.wineNames(in: settingsEnv).isEmpty, "\(context): \(Self.wineNames(in: settingsEnv))")
                    Self.expectSync(sync, in: settingsEnv, context)
                }
            }
        }
    }

    @Test("A program's backend and sync overrides set the ANO names and no WINE one")
    @MainActor func programOverridesUseTheEngineNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        bottle.settings.graphicsBackend = .dxvk

        for backend in GraphicsBackend.allCases {
            for sync in Self.syncModes {
                var overrides = ProgramOverrides()
                overrides.graphicsBackend = backend
                overrides.enhancedSync = sync
                let context = "program on \(backend.rawValue), \(sync)"

                let env = Wine.constructWineEnvironment(
                    for: bottle, programOverrides: overrides, recommendedBackend: .d3dMetal,
                    builtinD3D12IsD3DMetal: false
                )
                #expect(Self.wineNames(in: env).isEmpty, "\(context): \(Self.wineNames(in: env))")
                #expect(env["ANOD3DMETAL"] == (backend == .wined3d ? "0" : nil), "\(context)")
                Self.expectSync(sync, in: env, context)
            }
        }
    }

    @Test("Platform fixes and launcher presets name no WINE variable")
    func presetsUseTheEngineNames() {
        #expect(!MacOSCompatibilityFixes.allFixes.contains { $0.key.contains("WINE") })
        for launcher in LauncherType.allCases {
            let names = Array(launcher.environmentOverrides().keys) + launcher.fixDetails().map(\.key)
            #expect(!names.contains { $0.contains("WINE") }, "\(launcher.rawValue): \(names.sorted())")
        }
        let rockstar = LauncherType.rockstar
        #expect(rockstar.environmentOverrides()["ANO_LARGE_ADDRESS_AWARE"] == "1")
        #expect(rockstar.fixDetails().contains { $0.key == "ANO_LARGE_ADDRESS_AWARE" })
    }

    @Test("The game database names no WINE variable, and its wined3d variants still decode")
    func gameDatabaseUsesTheEngineNames() {
        var wined3dVariants = 0
        for entry in GameDBLoader.loadDefaults() {
            for variant in entry.variants {
                let names = (variant.environmentVariables ?? [:]).keys
                #expect(!names.contains { $0.contains("WINE") }, "\(entry.id)/\(variant.id): \(names.sorted())")
                if variant.settings.graphicsBackend == .wined3d {
                    wined3dVariants += 1
                }
            }
        }
        // Three variants pick the OpenGL backend; with a stale raw value they
        // would decode to no backend at all.
        #expect(wined3dVariants == 3)
        #expect(GraphicsBackend.wined3d.rawValue == "anod3d")
        #expect(GraphicsBackend(rawValue: "anod3d") == .wined3d)
    }

    // MARK: - Registry

    @Test("Every registry key the app reads or writes under Software is the engine's")
    func registryKeysUseSoftwareAno() {
        let keys = [
            Wine.RegistryKey.macDriver.rawValue,
            Wine.RegistryKey.explorer.rawValue,
            Wine.RegistryKey.explorerDesktops.rawValue,
            Wine.VirtualDesktopRegistryKey.explorer.rawValue,
            Wine.VirtualDesktopRegistryKey.desktops.rawValue,
            Wine.AudioRegistryKey.drivers.rawValue,
            Wine.AudioRegistryKey.directSound.rawValue,
            WineAudioEndpoint.driverKey,
            CJKFontReplacements.registryKey,
            Wine.DLLOverrideScope.bottle.registryKey,
            Wine.DLLOverrideScope.program("game.exe").registryKey,
            Wine.DLLOverrideScope.direct3D("game.exe").registryKey
        ]
        for key in keys {
            #expect(key.contains(#"\Software\Ano\"#), "\(key)")
            #expect(!key.lowercased().contains("wine"), "\(key)")
        }
        #expect(Wine.RegistryKey.macDriver.rawValue == #"HKCU\Software\Ano\Mac Driver"#)
        #expect(Wine.AudioRegistryKey.drivers.rawValue == #"HKCU\Software\Ano\Drivers"#)
        #expect(WineAudioEndpoint.driverKey == #"HKCU\Software\Ano\Drivers\anocoreaudio.drv"#)
    }

    @Test("The .reg documents the app imports say Software\\Ano, never Software\\Wine")
    func registryDocumentsUseSoftwareAno() {
        let overrides = Wine.registryDocument(for: [
            (key: Wine.DLLOverrideScope.bottle.registryKey, overrides: ["d3d11": "n,b"]),
            (key: Wine.DLLOverrideScope.program("game.exe").registryKey, overrides: ["dxgi": "n,b"])
        ])
        let fonts = CJKFontReplacements.registryDocument(for: CJKFontReplacements.replacements)
        for document in [overrides, fonts] {
            #expect(document.contains(#"\Software\Ano\"#), "\(document)")
            #expect(!document.lowercased().contains(#"software\wine"#), "\(document)")
        }
        #expect(overrides.contains(#"[HKCU\Software\Ano\AppDefaults\game.exe\DllOverrides]"#))
    }

    @Test("The AppDefaults scan reads the engine's section headers")
    func appDefaultsScanReadsSoftwareAno() {
        let userReg = #"""
        [Software\\Ano\\AppDefaults\\EADesktop.exe\\DllOverrides] 1731628800
        "d3d11"="n,b"
        """#
        #expect(Wine.appDefaultsDLLOverrideExecutables(in: userReg) == ["EADesktop.exe"])
    }

    // MARK: - Programs and output

    @Test("Bottle creation sets the Windows version with ano-cfg")
    func bottleCreationRunsAnoCfg() {
        #expect(Wine.changeWinVersionArguments(.win10) == ["ano-cfg", "-v", "win10"])
        #expect(Wine.changeWinVersionArguments(.winXP) == ["ano-cfg", "-v", "winxp64"])
    }

    @Test("ano-loader --version prints ano-11.19, which is version 11.19")
    func versionOutputParses() {
        #expect(Wine.versionNumber(fromVersionOutput: "ano-11.19\n") == "11.19")
        #expect(Wine.versionNumber(fromVersionOutput: "ano-11.19 (CrossOver FOSS 25.1.1)\n") == "11.19")
    }
}
