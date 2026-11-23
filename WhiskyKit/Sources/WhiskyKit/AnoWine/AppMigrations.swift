//
//  AppMigrations.swift
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
import os

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "AnoMigration")

/// Carries what Ano 6-8 stored under Wine's names across the rename (spec
/// decision 8), before anything reads it:
///
/// - defaults keys: a renamed key takes the user's value, unless the new key
///   already holds a choice; every other key that says Wine, and the keys of
///   removed features, go;
/// - the GPTK store: its bridges' folder, Apple's name in Ano 8, takes the
///   engine's (`lib/ano`), a store that counted as verified still does, and
///   Wine DLLs backed up from a runtime before the rename are dropped.
///
/// Each step does nothing once done, so ``runAtLaunch()`` runs on every
/// launch, synchronously, from `AppDelegate.applicationWillFinishLaunching`:
/// before the runtime update check reads its key and before the GPTK steps
/// at launch read the store.
public enum AppMigrations {
    /// Keys that keep the user's value under a new name.
    public static let renamedDefaultsKeys: [(old: String, new: String)] = [
        ("checkWhiskyWineUpdates", "checkAnoRuntimeUpdates"), // old name: Ano 6-8's update-check opt-out
        ("wineSectionExpanded", "anoSectionExpanded") // old name: the bottle settings' section state
    ]

    /// Keys of features that are gone.
    public static let obsoleteDefaultsKeys = ["hasOfferedLegacyMigration"]

    /// The first runtime major version with the engine's names; Wine DLLs
    /// backed up from an earlier one belong to an engine that is gone.
    static let firstRenamedRuntimeMajor = 5

    /// Runs both migrations on this Mac's settings and GPTK store.
    public static func runAtLaunch() {
        if let domain = Bundle.main.bundleIdentifier {
            migrateDefaults(.standard, domain: domain)
        }
        migrateGPTKStore(at: GPTKImporter.storeFolder)
    }

    // MARK: - Defaults

    /// Renames and drops the keys stored in `domain`, which must be the domain
    /// `defaults` writes to (the bundle identifier for `.standard`, the suite
    /// name for a suite). Only keys stored there are looked at.
    /// - Returns: The keys it wrote or removed, sorted.
    @discardableResult
    public static func migrateDefaults(_ defaults: UserDefaults, domain: String) -> [String] {
        var stored = defaults.persistentDomain(forName: domain) ?? [:]
        var changed: Set<String> = []
        for (old, new) in renamedDefaultsKeys {
            guard let value = stored[old] else { continue }
            if stored[new] == nil {
                defaults.set(value, forKey: new)
                stored[new] = value
                changed.insert(new)
            }
            defaults.removeObject(forKey: old)
            stored[old] = nil
            changed.insert(old)
        }
        for key in stored.keys where obsoleteDefaultsKeys.contains(key) || saysOldName(key) {
            defaults.removeObject(forKey: key)
            changed.insert(key)
        }
        let keys = changed.sorted()
        if !keys.isEmpty {
            logger.info("Settings carried over or dropped: \(keys.joined(separator: ", "), privacy: .public)")
        }
        return keys
    }

    /// Whether a defaults key says Wine, in any case.
    static func saysOldName(_ key: String) -> Bool {
        key.range(of: "wine", options: .caseInsensitive) != nil // old name: Ano 6-8's and Whisky's keys
    }

    // MARK: - The GPTK store

    /// Gives an Ano 8 store the engine's folder name and drops Wine DLLs
    /// backed up from a runtime before the rename. A store whose stamp said
    /// "verified" for its contents before is stamped again afterwards: the
    /// rename changes the paths the stamp's fingerprint covers, not what the
    /// checks looked at. A store without that stamp stays without it, so the
    /// check runs before its next deploy, as it would have.
    /// - Returns: Whether it changed anything.
    @discardableResult
    public static func migrateGPTKStore(at store: URL) -> Bool {
        GPTKImporter.mutationLock.lock()
        defer { GPTKImporter.mutationLock.unlock() }
        let lib = store.appending(path: "lib")
        let oldFolder = lib.appending(path: "wine") // old name: Ano 8's store folder, Apple's name
        let renaming = entryExists(oldFolder)
        let droppingOriginals = originalsPredateTheRename(inStore: store)
        guard renaming || droppingOriginals else { return false }

        let wasVerified = isStampedVerified(store)
        var changed = false
        if renaming {
            changed = renameModuleFolder(oldFolder, inStoreLib: lib)
        }
        if droppingOriginals {
            changed = remove(store.appending(path: "originals")) || changed
        }
        if changed, wasVerified {
            GPTKImporter.stampStoreVerified(inStore: store)
        }
        return changed
    }

    /// Renames the store's bridges' folder by the import's rule
    /// (``GPTKImporter/adoptModuleFolder(inPayload:)``): a `lib/ano` that
    /// holds the bridges wins, and the old folder then goes.
    /// - Returns: Whether the old folder is gone.
    private static func renameModuleFolder(_ oldFolder: URL, inStoreLib lib: URL) -> Bool {
        do {
            try GPTKImporter.adoptModuleFolder(inPayload: lib)
            let own = GPTKImporter.storeModuleFolder(inStoreLib: lib).lastPathComponent
            if entryExists(oldFolder), GPTKImporter.moduleFolder(inPayload: lib)?.lastPathComponent == own {
                try FileManager.default.removeItem(at: oldFolder)
            }
        } catch {
            logger.error("The GPTK store kept its old folder: \(error.localizedDescription, privacy: .public)")
        }
        let renamed = !entryExists(oldFolder)
        if renamed {
            logger.info("The GPTK store's bridges' folder took the engine's name")
        }
        return renamed
    }

    /// Whether `originals/` holds Wine DLLs backed up from a runtime before
    /// the rename; restoring them would put that engine's DLLs into this one.
    static func originalsPredateTheRename(inStore store: URL) -> Bool {
        guard let version = GPTKImporter.originalsRecord(inStore: store)?.runtimeVersion,
              let major = version.split(separator: ".").first.flatMap({ Int($0) })
        else { return false }
        return major < firstRenamedRuntimeMajor
    }

    /// Whether the store's stamp says it passed the checks as it is now.
    private static func isStampedVerified(_ store: URL) -> Bool {
        guard let stamp = GPTKImporter.storeStamp(inStore: store), stamp.failure == nil else { return false }
        return stamp.fingerprint == GPTKImporter.storeFingerprint(inStore: store)
    }

    /// Removes `item`; a failure is logged and skipped.
    private static func remove(_ item: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: item)
            return true
        } catch {
            let path = item.path(percentEncoded: false)
            logger.error("Skipped \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether anything, a link included, is at `url`; a link is not followed.
    private static func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }
}
