//
//  ProxyEnvironment.swift
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

/// How a proxied bottle's programs get the network interceptor
/// (`libano_net.dylib`): only Wine itself loads it. Native macOS tools abort when
/// handed an x86_64 library, so `DYLD_INSERT_LIBRARIES` is set on nothing but
/// the process that runs `ano-loader` or `ano-server`, and shells reach Wine
/// through a wrapper that sets it for that one program.
public enum ProxyEnvironment {
    /// The helper's port, or `0` when it could not start (everything then fails closed).
    public static let portKey = "ANO_PROXY_PORT"
    /// Absolute path of `libano_net.dylib`.
    public static let libraryKey = "ANO_NET_LIB"
    /// The runtime's `Libraries/Wine` folder: programs under it keep the interceptor.
    public static let wineDirKey = "ANO_WINE_DIR"
    /// The runtime's `ano-loader`, which the wrapper starts.
    public static let realLoaderKey = "ANO_REAL_LOADER"
    static let dyldKey = "DYLD_INSERT_LIBRARIES"

    /// The variables a proxied bottle's launches carry.
    public static func variables(
        port: UInt16?, library: URL = libraryURL,
        wineFolder: URL = WhiskyWineInstaller.libraryFolder.appending(path: "Wine"),
        realLoader: URL = AnoWineRuntime.loaderURL
    ) -> [String: String] {
        [
            portKey: String(port ?? 0),
            libraryKey: library.path(percentEncoded: false),
            wineDirKey: wineFolder.path(percentEncoded: false),
            realLoaderKey: realLoader.path(percentEncoded: false)
        ]
    }

    /// The environment to start `executable` with: `DYLD_INSERT_LIBRARIES` is
    /// added only for the runtime's loader or server in a proxied environment,
    /// and removed for anything else.
    public static func launchEnvironment(_ environment: [String: String], executable: URL) -> [String: String] {
        var result = environment
        result[dyldKey] = nil
        let target = executable.standardizedFileURL.path(percentEncoded: false)
        let wine = [AnoWineRuntime.loaderURL, AnoWineRuntime.serverURL]
            .map { $0.standardizedFileURL.path(percentEncoded: false) }
        if let library = environment[libraryKey], !library.isEmpty, wine.contains(target) {
            result[dyldKey] = library
        }
        return result
    }

    /// Where `libano_net.dylib` is: `ANO_NET_LIB_PATH` if set, else the app's
    /// resources (also found from the CLI bundled inside the app).
    public static var libraryURL: URL {
        if let override = ProcessInfo.processInfo.environment["ANO_NET_LIB_PATH"], !override.isEmpty {
            return URL(filePath: override)
        }
        if let bundled = Bundle.main.url(forResource: "libano_net", withExtension: "dylib") {
            return bundled
        }
        return Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "libano_net.dylib")
    }

    /// The folder holding the `ano-loader` wrapper.
    public static var wrapperFolder: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Proxy").appending(path: "bin")
    }

    static let wrapperScript = """
    #!/bin/sh
    # Ano: start Wine with the proxy interceptor. Only Wine gets it.
    DYLD_INSERT_LIBRARIES="$ANO_NET_LIB" exec "$ANO_REAL_LOADER" "$@"

    """

    /// Writes the wrapper (`ano-loader`, mode 755) and returns its URL.
    @discardableResult
    public static func installWrapper(in folder: URL = wrapperFolder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wrapper = folder.appending(path: AnoWineRuntime.loaderName)
        if (try? String(contentsOf: wrapper, encoding: .utf8)) != wrapperScript {
            try wrapperScript.write(to: wrapper, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    /// For tools that start Wine by name from a shell (Winetricks): the
    /// variables to add and the folder to put first on `PATH`, so `ano-loader`
    /// resolves to the wrapper. Empty for a bottle with the proxy off.
    @MainActor
    public static func shellAdditions(
        for bottle: Bottle, proxyPort: @MainActor (Bottle) -> UInt16? = { ProxyService.shared.port(for: $0) }
    ) -> (variables: [String: String], pathPrefix: String?) {
        guard bottle.settings.proxyEnabled else { return ([:], nil) }
        _ = try? installWrapper()
        var additions = variables(port: proxyPort(bottle))
        // Winetricks reads the Wine binary to learn its architecture; the wrapper
        // is a script, so point it at the real loader (it still runs `ano-loader`
        // from PATH, which is the wrapper).
        additions["WINE_BIN"] = AnoWineRuntime.loaderURL.path(percentEncoded: false)
        return (additions, wrapperFolder.path(percentEncoded: false))
    }

    /// `environment` with ``shellAdditions(for:proxyPort:)`` applied.
    public static func applying(
        _ additions: (variables: [String: String], pathPrefix: String?), to environment: [String: String]
    ) -> [String: String] {
        var result = environment.merging(additions.variables) { _, proxy in proxy }
        if let prefix = additions.pathPrefix {
            result["PATH"] = [prefix, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        }
        result[dyldKey] = nil
        return result
    }
}
