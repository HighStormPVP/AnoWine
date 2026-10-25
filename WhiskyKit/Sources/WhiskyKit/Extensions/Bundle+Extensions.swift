//
//  Bundle+Extensions.swift
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

public extension Bundle {
    static var whiskyBundleIdentifier: String {
        resolveWhiskyBundleIdentifier(Bundle.main.bundleIdentifier)
    }

    /// The bundled CLI (WhiskyCmd) must use the app's folders, or it never
    /// sees the app's bottles: map both a missing identifier and the CLI
    /// target's own identifier to the app's.
    static func resolveWhiskyBundleIdentifier(_ identifier: String?) -> String {
        let app = "io.github.highstormpvp.AnoWine"
        guard let identifier, identifier != app + "Cmd" else { return app }
        return identifier
    }
}
