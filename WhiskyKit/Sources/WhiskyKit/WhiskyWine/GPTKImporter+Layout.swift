//
//  GPTKImporter+Layout.swift
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

/// Where the payload's parts sit: in Apple's image, in the store and in the
/// engine's tree.
///
/// Apple's image keeps the D3D bridges in a folder named after Wine's module
/// folder, beside `external`. The engine's is ``AnoWineRuntime/moduleFolderName``,
/// and so is the store's: the import renames that one folder and copies
/// everything else as it is. The app never names Apple's folder; it finds it by
/// what it holds.
extension GPTKImporter {
    /// The folder in a payload's `lib` that holds the bridges
    /// (`x86_64-windows`, `x86_64-unix`), or `nil` when there is none.
    ///
    /// The store calls it ``AnoWineRuntime/moduleFolderName``, and that name
    /// wins. In Apple's image it is the first folder beside `external`, by
    /// name, that holds an `x86_64-windows` folder.
    static func moduleFolder(inPayload libRoot: URL) -> URL? {
        let fileManager = FileManager.default
        func holdsBridges(_ folder: URL) -> Bool {
            var isDirectory: ObjCBool = false
            let windows = folder.appending(path: "x86_64-windows").path(percentEncoded: false)
            return fileManager.fileExists(atPath: windows, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let own = libRoot.appending(path: AnoWineRuntime.moduleFolderName)
        if holdsBridges(own) {
            return own
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: libRoot.path(percentEncoded: false))) ?? []
        return names.sorted()
            .filter { $0 != "external" }
            .map { libRoot.appending(path: $0) }
            .first(where: holdsBridges)
    }

    /// Whether `libRoot` holds the shared dylib and, in `modules`, the dxgi
    /// forwarder.
    static func holdsPayload(_ libRoot: URL, modules: URL) -> Bool {
        let fileManager = FileManager.default
        let dylib = libRoot.appending(path: "external").appending(path: "libd3dshared.dylib")
        let dxgi = modules.appending(path: "x86_64-windows").appending(path: "dxgi.dll")
        return fileManager.fileExists(atPath: dylib.path(percentEncoded: false)) &&
            fileManager.fileExists(atPath: dxgi.path(percentEncoded: false))
    }

    /// The store's module folder: `lib/ano`, the bridges' folder of the
    /// imported payload under the engine's name.
    static func storeModuleFolder(inStoreLib storeLib: URL) -> URL {
        storeLib.appending(path: AnoWineRuntime.moduleFolderName)
    }

    /// The store's Windows DLL folder: `lib/ano/x86_64-windows`.
    static func storeWindowsFolder(inStoreLib storeLib: URL) -> URL {
        storeModuleFolder(inStoreLib: storeLib).appending(path: "x86_64-windows")
    }

    /// Gives a copied payload's bridges' folder the store's name. Everything
    /// after the import reads the store by the engine's names.
    static func adoptModuleFolder(inPayload libRoot: URL) throws {
        let own = storeModuleFolder(inStoreLib: libRoot)
        guard let found = moduleFolder(inPayload: libRoot), found.lastPathComponent != own.lastPathComponent else {
            return
        }
        try FileManager.default.moveItem(at: found, to: own)
    }
}
