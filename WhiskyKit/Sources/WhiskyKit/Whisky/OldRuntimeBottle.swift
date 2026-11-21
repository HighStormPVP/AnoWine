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
    /// Whether the bottle at `bottleURL` was made by an earlier Ano.
    ///
    /// Reads only, and is checked before the bottle's settings are decoded.
    ///
    /// - Parameter bottleURL: The bottle's folder.
    /// - Returns: `true` for a bottle made by an earlier Ano.
    public static func isOld(at bottleURL: URL) -> Bool {
        false
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
