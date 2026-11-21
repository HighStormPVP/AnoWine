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

/// Names of the programs, folders and files in Ano's runtime.
///
/// Ano's runtime is upstream's engine with its names renamed (runtime 5.0.0):
/// the loader (`wine64`, a symlink to `wine` upstream) is `ano-loader`,
/// `wineserver` is `ano-server`, and the layout is `Libraries/Ano` with
/// `bin`, `lib/ano` and `share/ano`, beside `Libraries/AnoRuntimeVersion.plist`.
/// The engine finds the renamed server through the server variable every launch
/// environment sets. See `spikes/REPORT.md`.
public enum AnoWineRuntime {
    /// The Wine loader every program is launched through.
    public static let loaderName = "ano-loader"
    /// The Wine server.
    public static let serverName = "ano-server"
    /// The Windows program that creates, updates and shuts down a bottle
    /// (upstream's `wineboot.exe`), run as `ano-loader ano-boot`.
    public static let bootProgramName = "ano-boot"
    /// The Windows program that hosts drivers (upstream's `winedevice.exe`).
    public static let deviceHostImageName = "ano-device.exe"
    /// The Unix program every Windows process runs as (upstream's
    /// `lib/wine/x86_64-unix/wine`). From runtime 3.1.6 `ps` shows its path
    /// first, then the Windows program.
    public static let coreName = "ano-core"

    /// The runtime's folder in `Libraries` (upstream's `Wine`), holding `bin`,
    /// `lib` and `share`.
    public static let runtimeFolderName = "Ano"
    /// The folder in the runtime's `lib` and `share` that holds its modules and
    /// data (upstream's `wine`): `lib/ano/x86_64-windows`, `share/ano/mono`.
    public static let moduleFolderName = "ano"
    /// The runtime's version record in `Libraries`, without its `.plist`
    /// extension (upstream's `WhiskyWineVersion`, with the same keys).
    public static let versionPlistName = "AnoRuntimeVersion"
    /// The marks a builtin DLL carries in the 16 bytes at offset 0x40, where a
    /// native PE has its DOS stub. The engine writes the first on its own DLLs
    /// and still loads the second as builtin, because Apple's D3DMetal DLLs
    /// carry it.
    public static let builtinMarks = [
        "Ano builtin DLL",
        "Wine builtin DLL" // old name: the mark Apple's D3DMetal DLLs carry
    ]

    /// ``builtinMarks`` as the loader compares them: the 16 bytes at offset
    /// 0x40, the mark padded with NULs ("Ano builtin DLL" and its terminator).
    static let builtinMarkWindows: [Data] = builtinMarks.map { mark in
        var window = Data(mark.utf8)
        window.append(Data(count: max(0, builtinMarkLength - window.count)))
        return window
    }

    /// How many bytes at offset 0x40 a builtin mark takes.
    static let builtinMarkLength = 16

    /// The runtime under a `Libraries` folder: `Libraries/Ano`.
    static func runtimeFolder(inLibraryFolder folder: URL) -> URL {
        folder.appending(path: runtimeFolderName)
    }

    /// The runtime's `lib`: `Libraries/Ano/lib`, holding the module folder,
    /// `external` (Apple's D3DMetal, once imported) and `gptk-video`.
    static func libFolder(inLibraryFolder folder: URL) -> URL {
        runtimeFolder(inLibraryFolder: folder).appending(path: "lib")
    }

    /// One of the runtime's module folders: `Libraries/Ano/lib/ano/<arch>`,
    /// for example `x86_64-windows` or `x86_64-unix`.
    static func moduleFolder(_ arch: String, inLibraryFolder folder: URL) -> URL {
        libFolder(inLibraryFolder: folder).appending(path: moduleFolderName).appending(path: arch)
    }

    /// The runtime's version record: `Libraries/AnoRuntimeVersion.plist`.
    static func versionPlist(inLibraryFolder folder: URL) -> URL {
        folder.appending(path: versionPlistName).appendingPathExtension("plist")
    }

    /// The loader inside the installed runtime.
    public static var loaderURL: URL {
        WhiskyWineInstaller.binFolder.appending(path: loaderName)
    }

    /// The server inside the installed runtime.
    public static var serverURL: URL {
        WhiskyWineInstaller.binFolder.appending(path: serverName)
    }
}
