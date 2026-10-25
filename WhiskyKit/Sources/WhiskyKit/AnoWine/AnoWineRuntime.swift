//
//  AnoWineRuntime.swift
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

/// Names of the Wine programs in AnoWine's runtime.
///
/// AnoWine's runtime is upstream's with two programs renamed: the loader
/// (`wine64`, a symlink to `wine` upstream) is `anowine`, and `wineserver` is
/// `anowine-server`. Wine finds the renamed server through `WINESERVER`, which
/// every launch environment sets. See `spikes/REPORT.md`.
public enum AnoWineRuntime {
    /// The Wine loader every program is launched through.
    public static let loaderName = "anowine"
    /// The Wine server.
    public static let serverName = "anowine-server"

    /// The loader inside the installed runtime.
    public static var loaderURL: URL {
        WhiskyWineInstaller.binFolder.appending(path: loaderName)
    }

    /// The server inside the installed runtime.
    public static var serverURL: URL {
        WhiskyWineInstaller.binFolder.appending(path: serverName)
    }
}
