//
//  OldRuntimeBottle.swift
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

/// Bottles made by an Ano before runtime 5.0.0, the engine whose names no longer say Wine.
///
/// Such a bottle's registry and settings carry the old names, so this Ano can't run
/// it, and decoding its `Metadata.plist` would quietly give it default settings.
/// Ano lists it, refuses it and never writes to it; the owner recreates it
/// (design decision 3).
public enum OldRuntimeBottle {
    /// How the registry files of an engine before 5.0.0 begin (5.0.0 writes `ANO REGISTRY`).
    private static let oldRegistryHeader = Data("WINE REGISTRY".utf8) // old name: a 3.x or 4.x engine's registry

    /// The word every settings key an earlier Ano wrote for the runtime carries (`wineConfig`).
    private static let oldKeyWord = "wine" // old name: recognises an earlier Ano's Metadata.plist

    /// Whether the bottle at `bottleURL` was made by an earlier Ano: its
    /// `system.reg` begins `WINE REGISTRY`, or its `Metadata.plist` has a
    /// top-level key containing `wine`, in any case.
    ///
    /// Reads only, and is checked before the bottle's settings are decoded.
    ///
    /// - Parameter bottleURL: The bottle's folder.
    /// - Returns: `true` for a bottle made by an earlier Ano.
    public static func isOld(at bottleURL: URL) -> Bool {
        registryIsOld(bottleURL.appending(path: "system.reg"))
            || metadataIsOld(bottleURL.appending(path: "Metadata").appendingPathExtension("plist"))
    }

    private static func registryIsOld(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: oldRegistryHeader.count)) == oldRegistryHeader
    }

    private static func metadataIsOld(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let keys = (plist as? [String: Any])?.keys
        else { return false }
        return keys.contains { $0.lowercased().contains(oldKeyWord) }
    }
}

/// Why a command refused a bottle made by an earlier Ano.
public struct OldRuntimeBottleError: LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        String(
            localized: "bottle.oldRuntime.message",
            defaultValue: """
            This bottle was made by an earlier version of Ano and can't be used with this one. \
            Create a new bottle and reinstall its programs.
            """
        )
    }
}

extension BottleSettings {
    /// What an earlier Ano's bottle is held with: defaults, named after its
    /// folder, since its own settings are never decoded.
    ///
    /// - Parameter bottleURL: The bottle's folder.
    init(oldBottleAt bottleURL: URL) {
        self.init()
        name = bottleURL.lastPathComponent
    }
}

public extension Bottle {
    /// Throws when this bottle was made by an earlier Ano, which nothing may run or change.
    ///
    /// - Throws: ``OldRuntimeBottleError`` for such a bottle.
    func refuseIfFromOldRuntime() throws {
        if isFromOldRuntime {
            throw OldRuntimeBottleError()
        }
    }
}
