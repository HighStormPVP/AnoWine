//
//  BundledDataNamesTests.swift
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

/// The JSON WhiskyKit bundles (the game database, remediations, troubleshooting
/// flows, crash patterns) names its keys and ids after Ano, and every renamed key
/// still reaches its Swift property, whose name stays (code-only, decision 6).
/// A key renamed in the JSON but not in its decoding leaves an optional field
/// nil without an error, so the counts here are pinned from the data as it was
/// before the rename: a dropped field changes a count.
@Suite("Bundled data uses Ano's names")
struct BundledDataNamesTests {
    /// WhiskyKit's sources, found from this file's location.
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WhiskyKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WhiskyKit
        .appending(path: "Sources")
        .appending(path: "WhiskyKit")

    /// A JSON resource of WhiskyKit, read from the repository as written.
    static func resource(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: sources.appending(path: path)))
    }

    /// Every string value anywhere in `json`, with the key it is the value of.
    static func texts(in json: Any, key: String? = nil) -> [(key: String?, text: String)] {
        if let object = json as? [String: Any] {
            return object.flatMap { texts(in: $0.value, key: $0.key) }
        }
        if let array = json as? [Any] {
            return array.flatMap { texts(in: $0, key: key) }
        }
        if let text = json as? String {
            return [(key, text)]
        }
        return []
    }

    /// How many objects anywhere in `json` have the key `key`.
    static func count(key: String, in json: Any) -> Int {
        if let object = json as? [String: Any] {
            let here = object[key] == nil ? 0 : 1
            return here + object.values.reduce(0) { $0 + count(key: key, in: $1) }
        }
        if let array = json as? [Any] {
            return array.reduce(0) { $0 + count(key: key, in: $1) }
        }
        return 0
    }

    // MARK: - Game database

    @Test("GameDB keeps its 87 entries, and each renamed key reaches its field")
    func gameDatabaseKeys() throws {
        let json = try Self.resource("GameDatabase/Resources/GameDB.json")
        #expect(Self.count(key: "minAnoVersion", in: json) == 85)
        #expect(Self.count(key: "anoTricksVerbs", in: json) == 90)
        #expect(Self.count(key: "anoVersion", in: json) == 89)
        for old in ["minWineVersion", "winetricksVerbs", "wineVersion"] {
            #expect(Self.count(key: old, in: json) == 0, "\(old)")
        }

        let entries = GameDBLoader.loadDefaults()
        let variants = entries.flatMap(\.variants)
        #expect(entries.count == 87)
        #expect(variants.count == 90)
        #expect(entries.compactMap { $0.constraints?.minWineVersion }.count == 85)
        #expect(variants.compactMap(\.winetricksVerbs).count == 90)
        #expect(variants.compactMap { $0.testedWith?.wineVersion }.filter { !$0.isEmpty }.count == 89)
    }

    @Test("An entry written with the new keys decodes them")
    func entryDecodesTheNewKeys() throws {
        let json = """
        {
          "id": "game",
          "title": "Game",
          "rating": "works",
          "constraints": { "minAnoVersion": "11.0" },
          "variants": [
            {
              "id": "recommended",
              "label": "Recommended",
              "settings": {},
              "anoTricksVerbs": ["vcrun2022"],
              "testedWith": {
                "lastTestedAt": "2026-11-22T00:00:00Z",
                "macOSVersion": "15.4.0",
                "anoVersion": "11.19"
              }
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(GameDBEntry.self, from: Data(json.utf8))
        #expect(entry.constraints?.minWineVersion == "11.0")
        #expect(entry.variants.first?.winetricksVerbs == ["vcrun2022"])
        #expect(entry.variants.first?.testedWith?.wineVersion == "11.19")
    }

    @Test("Variant ids name anod3d, not wined3d")
    func variantIds() {
        let entries = GameDBLoader.loadDefaults()
        let ids = Dictionary(entries.map { ($0.id, $0.variants.map(\.id)) }, uniquingKeysWith: { first, _ in first })
        #expect(ids["the-witcher-2"]?.contains("recommended-anod3d") == true)
        #expect(ids["zuma-deluxe"] == ["anod3d-winxp"])
        let wine = entries.flatMap { entry in entry.variants.map { "\(entry.id)/\($0.id)" } }
            .filter { $0.lowercased().contains("wine") }
        #expect(wine.isEmpty, "\(wine)")
    }

    // MARK: - Remediations and crash patterns

    @Test("Remediations name the verb anoTricksVerb, and the three installs keep their verbs")
    func remediationKeys() throws {
        let json = try Self.resource("Diagnostics/Resources/remediations.json")
        #expect(Self.count(key: "anoTricksVerb", in: json) == 9)
        #expect(Self.count(key: "winetricksVerb", in: json) == 0)

        let (_, remediations) = PatternLoader.loadDefaults()
        #expect(remediations["install-vcredist"]?.winetricksVerb == "vcrun2019")
        #expect(remediations["install-dotnet"]?.winetricksVerb == "dotnet48")
        #expect(remediations["install-dx-redist"]?.winetricksVerb == "d3dx9")
        let installs = remediations.values.filter { $0.actionType == .installVerb }
        #expect(installs.count == 3)
        #expect(installs.allSatisfy { $0.winetricksVerb != nil })

        let written = """
        {
          "id": "install-xact",
          "title": "Install XACT",
          "description": "Installs xact.",
          "category": "dependenciesLoading",
          "actionType": "installVerb",
          "risk": "low",
          "anoTricksVerb": "xact",
          "whatWillChange": "Installs xact",
          "undoPath": "Recreate the bottle",
          "appliesNextLaunch": true
        }
        """
        let action = try JSONDecoder().decode(RemediationAction.self, from: Data(written.utf8))
        #expect(action.winetricksVerb == "xact")
    }

    @Test("Crash pattern ids say ano, not wine")
    func patternIds() {
        let (patterns, _) = PatternLoader.loadDefaults()
        let ids = patterns.map(\.id)
        #expect(ids.contains("ano-nonzero-exit"))
        #expect(!ids.contains { $0.lowercased().contains("wine") }, "\(ids)")
    }

    // MARK: - Troubleshooting

    @Test("Flows route through the renamed nodes, check and fix")
    func flowIds() {
        let flows = Array(FlowLoader.loadAllFlows().values) + Array(FlowLoader.loadFragments().values)
        let nodes = flows.flatMap(\.nodes.values)
        func node(_ id: String) -> FlowStepNode? {
            nodes.first { $0.id == id }
        }

        #expect(node("check_ano_tricks")?.checkId == "anoTricks.verb_check")
        #expect(node("check_ano_dns")?.checkId == "registry.value_check")
        #expect(node("fix_ano_dns")?.fixId == "set-registry-value")
        #expect(nodes.filter { $0.checkId == "anoTricks.verb_check" }.count == 2)
        #expect(nodes.filter { $0.fixId == "install-ano-tricks-verb" }.count == 2)
        #expect(CheckRegistry().check(for: "anoTricks.verb_check") != nil)

        let ids = nodes.flatMap { [$0.id, $0.checkId, $0.fixId].compactMap { $0 } + ($0.on ?? [:]).values }
        let wine = ids.filter { $0.lowercased().contains("wine") }
        #expect(wine.isEmpty, "\(wine)")
    }

    @Test("The fix applicator previews and applies install-ano-tricks-verb")
    @MainActor func installFix() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let bottle = Bottle(bottleUrl: url, inFlight: false, isAvailable: true)

        #expect(FixApplicator.knownFixIds.contains("install-ano-tricks-verb"))
        #expect(!FixApplicator.knownFixIds.contains { $0.lowercased().contains("wine") })
        let preview = FixApplicator.preview(
            fixId: "install-ano-tricks-verb", params: ["verb": "vcrun2019"], bottle: bottle, program: nil
        )
        #expect(preview?.newValue == "vcrun2019")
        #expect(preview?.isReversible == false)
        let attempt = FixApplicator.apply(
            fixId: "install-ano-tricks-verb", params: ["verb": "vcrun2019"], bottle: bottle, program: nil
        )
        #expect(attempt.result == .pending)
        #expect(attempt.afterValue == "vcrun2019")
    }

    // MARK: - Wording

    /// A vendor's Proton support is a Linux-only opt-in, not what would make a
    /// game run in Ano on macOS, so no workaround and no "until" line waits for it.
    @Test("No GameDB workaround or until line waits for Proton support")
    func protonIsNotTheWayOut() throws {
        let texts = try Self.texts(in: Self.resource("GameDatabase/Resources/GameDB.json"))
        let lines = texts.filter { $0.key == "workaround" || $0.text.localizedCaseInsensitiveContains("until") }
        #expect(lines.contains { $0.key == "workaround" })
        let proton = lines.filter { $0.text.localizedCaseInsensitiveContains("Proton") }
        #expect(proton.isEmpty, "\(proton.map { "\($0.key ?? ""): \($0.text)" })")
    }

    /// The bundled data's text names Ano. Kept by ruling: the `author` of
    /// upstream's entries, the links to upstream's issues (`referenceURL`) and
    /// `frankea/Whisky#N` references.
    @Test("No bundled text says Whisky except its attribution")
    func noWhiskyText() throws {
        let files = (FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "json" }
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.isSuperset(of: ["GameDB.json", "remediations.json", "launcher-issues.json"]), "\(names)")

        var whisky: [String] = []
        for file in files {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            for (key, text) in Self.texts(in: json) where key != "author" && key != "referenceURL" {
                let unreferenced = text.replacingOccurrences(
                    of: #"frankea/Whisky#\d+"#, with: "", options: .regularExpression
                )
                if unreferenced.contains("Whisky") {
                    whisky.append("\(file.lastPathComponent): \(text)")
                }
            }
        }
        #expect(whisky.isEmpty, "\(whisky)")
    }

    // MARK: - Version tags

    /// GameDB versions are engine versions (11.0, 11.19), not Ano's own (app
    /// 3.10.2, runtime 5.0.0): "Ano 9.0+" would read as an Ano too old to use.
    @Test("The GameDB version tags name the engine")
    func versionTags() throws {
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: StringCatalog.url))
        let root = try #require(catalog as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let row = (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
            return (row?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        for language in ["en", "en-GB"] {
            #expect(value("gamedb.tag.minAno %@", language) == "Engine %@+", "\(language)")
            #expect(value("gameConfig.staleness.ano %@", language) == "Tested with engine %@.", "\(language)")
        }

        let result = StalenessChecker.check(
            testedWith: TestedWith(lastTestedAt: Date(), macOSVersion: "15.3.0", wineVersion: "9.0"),
            currentMacOSVersion: "15.3.0",
            currentWineVersion: "10.0"
        )
        #expect(result.warningMessage?.contains("Tested with engine 9.0.") == true, "\(result.warningMessage ?? "")")
    }
}
