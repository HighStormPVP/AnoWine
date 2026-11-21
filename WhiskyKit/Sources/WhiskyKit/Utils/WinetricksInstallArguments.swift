//
//  WinetricksInstallArguments.swift
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

/// How the app runs the bundled ano-tricks script (in the app's Resources,
/// beside cabextract): the command line for installing one verb with nobody
/// watching (from a game configuration, a troubleshooting fix or the
/// dependency panel) or listing the installed ones, the environment those
/// runs get, and the script Terminal sources for a command the user picks.
public enum WinetricksInstallArguments {
    /// The script's file name in the app's Resources.
    public static let scriptName = "ano-tricks"

    /// The bundled script in the Resources folder `resourcesURL`.
    public static func scriptURL(in resourcesURL: URL) -> URL {
        resourcesURL.appending(path: scriptName)
    }

    /// The arguments to run `/usr/bin/env` with to install `verb`.
    ///
    /// Every verb gets `-q` (W_OPT_UNATTENDED). Without it an installer shows
    /// its wizard and waits for a click nothing prompts for, so the process
    /// never exits and the ano-tricks.log entry is never written. It is not
    /// only installers: `w_try_regsvr32` adds `/S` only when unattended, so
    /// `xact` put up one "Successfully registered DLL" panel per audio DLL,
    /// each waiting on a click.
    ///
    /// The vcrun verbs also get `--force`: Microsoft rotates the vc_redist
    /// binaries in place, so the checksums pinned in the bundled ano-tricks go
    /// stale between releases and the install aborts with exit 1 on the SHA256
    /// mismatch (winetricks#2195).
    ///
    /// - Parameters:
    ///   - verb: The ano-tricks verb to install.
    ///   - winetricksPath: The path of the bundled ano-tricks script.
    /// - Returns: `bash`, the script, its options and the verb.
    public static func arguments(verb: String, winetricksPath: String) -> [String] {
        var arguments = ["bash", winetricksPath]
        if verb.hasPrefix("vcrun") {
            arguments.append("--force")
        }
        arguments.append("-q")
        arguments.append(verb)
        return arguments
    }

    /// ``arguments(verb:winetricksPath:)`` for the script in the Resources
    /// folder `resourcesURL`.
    public static func arguments(verb: String, resourcesURL: URL) -> [String] {
        arguments(verb: verb, winetricksPath: scriptURL(in: resourcesURL).path(percentEncoded: false))
    }

    /// The arguments to run `/usr/bin/env` with to list the verbs installed in
    /// a bottle (`list-installed`, which prints the bottle's log).
    public static func listInstalledArguments(resourcesURL: URL) -> [String] {
        ["bash", scriptURL(in: resourcesURL).path(percentEncoded: false), "list-installed"]
    }

    /// The whole environment of a run with nobody watching in the bottle at
    /// `bottleURL`: the engine's prefix, loader and server, a `PATH` with the
    /// runtime's `bin` and the Resources folder (for cabextract), and `HOME`.
    ///
    /// - Parameters:
    ///   - proxy: ``ProxyEnvironment/shellAdditions(for:proxyPort:)`` for the
    ///     bottle: for a proxied one, the wrapper first on `PATH` and the real
    ///     loader named for the script, which cannot read a wrapper's
    ///     architecture; empty otherwise.
    ///   - home: The user's home folder.
    public static func environment(
        bottleURL: URL,
        resourcesURL: URL,
        proxy: (variables: [String: String], pathPrefix: String?),
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        ProxyEnvironment.applying(proxy, to: [
            "ANOPREFIX": bottleURL.path(percentEncoded: false),
            "ANO": AnoWineRuntime.loaderName,
            "ANOSERVER": AnoWineRuntime.serverURL.path(percentEncoded: false),
            "PATH": [
                WhiskyWineInstaller.binFolder.path(percentEncoded: false),
                resourcesURL.path(percentEncoded: false),
                "/usr/bin",
                "/bin"
            ].joined(separator: ":"),
            "HOME": home
        ])
    }

    /// The script Terminal sources to run `command` in the bottle at
    /// `bottleURL`, with the same engine variables as ``environment(bottleURL:resourcesURL:proxy:home:)``
    /// and `PATH` put in front of the user's own.
    ///
    /// Every value is single-quoted, so nothing in a path is read as shell
    /// syntax: a bottle imported from a directory named with `$(...)` or
    /// backticks used to execute in the user's terminal.
    public static func terminalScript(
        command: String,
        bottleURL: URL,
        resourcesURL: URL,
        proxy: (variables: [String: String], pathPrefix: String?)
    ) -> String {
        let pathValue = ([proxy.pathPrefix].compactMap { $0 } + [
            WhiskyWineInstaller.binFolder.path(percentEncoded: false), resourcesURL.path(percentEncoded: false)
        ]).joined(separator: ":")
        let proxyExports = proxy.variables.sorted { $0.key < $1.key }
            .map { "export " + ShellQuoting.assignment($0.key, $0.value) }
        return ([
            "#!/bin/bash",
            "export PATH=\(ShellQuoting.quoted(pathValue)):\"$PATH\"",
            "export ANO=\(AnoWineRuntime.loaderName)",
            "export " + ShellQuoting.assignment("ANOSERVER", AnoWineRuntime.serverURL.path(percentEncoded: false)),
            "export " + ShellQuoting.assignment("ANOPREFIX", bottleURL.path(percentEncoded: false))
        ] + proxyExports + [
            ShellQuoting.commandLine(["bash", scriptURL(in: resourcesURL).path(percentEncoded: false), command]),
            ""
        ]).joined(separator: "\n")
    }

    /// The file name, in the temporary folder, of one ``terminalScript(command:bottleURL:resourcesURL:proxy:)``.
    public static func terminalScriptName(uuid: UUID = UUID()) -> String {
        "ano-tricks-\(uuid.uuidString).sh"
    }
}
