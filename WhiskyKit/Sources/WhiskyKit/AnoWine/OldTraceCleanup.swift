//
//  OldTraceCleanup.swift
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

/// Removes, once, what Ano 6-8 left outside the bottles under Wine's names
/// (spec decision 8): winetricks' download cache and temporary folders, stale
/// Wine server folders, the Metal shader caches named after the old loaders,
/// the app's old terminal and registry files, and the proxy's old wrapper.
///
/// - A server folder whose `lock` another process holds belongs to a running
///   server, Ano's or another Wine app's, and stays.
/// - A symlink is removed as a link; no link is followed.
/// - A removal that fails is logged under `AnoMigration` and skipped; the run
///   still counts as done, so it never repeats on every launch.
/// - Bottles, the runtime's `Libraries` (the runtime install replaces it whole)
///   and anything outside the given places are never touched, and nothing
///   needs admin rights.
///
/// The inventory behind the list is in the Plan 3c-4c ledger (`old-traces.md`).
public enum OldTraceCleanup {
    /// Raised when the list grows, so the cleanup runs once more.
    public static let currentVersion = 1
    /// The defaults key holding the version that last ran.
    public static let doneDefaultsKey = "oldTracesCleanupVersion"

    /// Where the traces are; injected, so tests run in temporary folders.
    public struct Places: Sendable {
        /// The user's home folder.
        public let home: URL
        /// The user's temporary folder (`$TMPDIR`).
        public let temporaryFolder: URL
        /// The user cache folder, `confstr(_CS_DARWIN_USER_CACHE_DIR)`.
        public let userCacheFolder: URL
        /// The app's Application Support folder.
        public let applicationFolder: URL
        /// The folder that holds the per-user server folder (`/private/tmp`).
        public let serverRoot: URL
        /// The user's id, part of the server folder's name.
        public let uid: uid_t

        /// This Mac's places for the current user.
        public static var live: Places {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Places(
                home: home,
                temporaryFolder: FileManager.default.temporaryDirectory,
                userCacheFolder: darwinUserCacheFolder ?? home.appending(path: "Library").appending(path: "Caches"),
                applicationFolder: WhiskyWineInstaller.applicationFolder,
                serverRoot: URL(filePath: "/private/tmp", directoryHint: .isDirectory),
                uid: getuid()
            )
        }

        /// The per-user server folder of the engine in runtimes 3.x and 4.x.
        var serverFolder: URL {
            serverRoot.appending(path: ".wine-\(uid)") // old name: the server folder of runtimes 3.x and 4.x
        }

        /// The user cache folder, or `nil` when the system does not say.
        private static var darwinUserCacheFolder: URL? {
            let length = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
            guard length > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: length)
            guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, length) > 0 else { return nil }
            let path = buffer.withUnsafeBufferPointer { pointer in
                pointer.baseAddress.map { String(cString: $0) }
            }
            return path.map { URL(filePath: $0, directoryHint: .isDirectory) }
        }
    }

    /// When a temporary item whose name matches goes.
    enum TemporaryRule: Sendable {
        /// A folder, always.
        case folder
        /// A file, always: the app no longer writes this name.
        case file
        /// A file whose text says Wine: the app still writes this name, with Ano's names.
        case fileWithOldText
    }

    /// A name the app or winetricks gave items in the temporary folder.
    struct TemporaryName: Sendable {
        let prefix: String
        let suffix: String
        let rule: TemporaryRule
    }

    /// Ano 6-8's temporary items: winetricks' `mktemp -d` folders, the
    /// terminal scripts (winetricks, Run in Terminal, the shell environment)
    /// and the `.reg` files a crash left before their import removed them.
    static let temporaryNames = [
        TemporaryName(prefix: "winetricks.", suffix: "", rule: .folder), // old name: winetricks' mktemp folders
        TemporaryName(prefix: "whisky-winetricks-", suffix: ".sh", rule: .file), // old name: Ano 6-8's script
        TemporaryName(prefix: "whisky-run-", suffix: ".sh", rule: .fileWithOldText),
        TemporaryName(prefix: "whisky-env-", suffix: ".sh", rule: .fileWithOldText),
        TemporaryName(prefix: "whisky-registry-", suffix: ".reg", rule: .fileWithOldText),
        TemporaryName(prefix: "whisky-dll-overrides-", suffix: ".reg", rule: .fileWithOldText)
    ]

    /// The bundle identifiers of Ano 6-8's loaders, which name their Metal
    /// shader caches in the user cache folder.
    static let loaderCacheNames = [
        "org.winehq.wine", // old name: runtime 3.x's loader (Ano 6 and 7)
        "com.codeweavers.CrossOver.wineloader" // old name: runtime 4.9.0's loader (Ano 8)
    ]

    // MARK: - Running

    /// Runs ``clean(_:isServerLive:)`` unless this version already ran, then
    /// records that it ran, whatever was skipped.
    /// - Returns: What it removed, or `nil` when it had already run.
    @discardableResult
    public static func runIfNeeded(defaults: UserDefaults = .standard, places: Places = .live) -> [URL]? {
        guard defaults.integer(forKey: doneDefaultsKey) < currentVersion else { return nil }
        let removed = clean(places)
        defaults.set(currentVersion, forKey: doneDefaultsKey)
        logger.info("Old traces removed: \(removed.count)")
        return removed
    }

    /// Removes every target; a failure is logged and skipped.
    /// - Returns: What it removed.
    @discardableResult
    public static func clean(
        _ places: Places, isServerLive: (URL) -> Bool = OldTraceCleanup.serverLockIsHeld
    ) -> [URL] {
        var removed: [URL] = []
        for target in targets(in: places, isServerLive: isServerLive) {
            do {
                if target == places.serverFolder {
                    try removeEmptyFolder(target)
                } else {
                    try FileManager.default.removeItem(at: target)
                }
                removed.append(target)
            } catch {
                let path = target.path(percentEncoded: false)
                logger.error("Skipped \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    /// What ``clean(_:isServerLive:)`` removes now. The stale server folders
    /// come first, so little time passes between their lock test and their
    /// removal; then the server folder that holds them when nothing else is in
    /// it, the caches, the temporary items and the proxy's old wrapper.
    public static func targets(in places: Places, isServerLive: (URL) -> Bool) -> [URL] {
        serverTraces(in: places, isServerLive: isServerLive)
            + cacheTraces(in: places).filter { entry(at: $0) != nil }
            + temporaryTraces(in: places.temporaryFolder)
            + oldWrapper(in: places)
    }

    /// Whether another process holds the write lock a running server keeps on
    /// `<serverFolder>/lock` (`fcntl(F_SETLK)`), asked with `F_GETLK` over the
    /// whole file. A missing or unopenable `lock` counts as not held.
    public static func serverLockIsHeld(_ serverFolder: URL) -> Bool {
        let path = serverFolder.appending(path: "lock").path(percentEncoded: false)
        let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &lock) == 0 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }

    // MARK: - The list

    /// The stale `server-*` folders in the per-user server folder and, when
    /// they are all it holds, that folder too; it is removed only while empty,
    /// so a server folder made in the meantime keeps it. A per-user folder that
    /// is a symlink or someone else's is left alone.
    private static func serverTraces(in places: Places, isServerLive: (URL) -> Bool) -> [URL] {
        let root = places.serverFolder
        guard let info = entry(at: root), info.type == mode_t(S_IFDIR), info.owner == places.uid,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        else { return [] }
        let stale = names.sorted().map { root.appending(path: $0) }.filter { folder in
            folder.lastPathComponent.hasPrefix("server-") && entry(at: folder)?.type == mode_t(S_IFDIR)
                && !isServerLive(folder)
        }
        return stale.count == names.count ? stale + [root] : stale
    }

    /// winetricks' download cache and the Metal shader caches named after the
    /// old loaders, whether or not they are there.
    private static func cacheTraces(in places: Places) -> [URL] {
        let cacheFolders = [places.userCacheFolder, places.home.appending(path: "Library").appending(path: "Caches")]
        let tricksCache = places.home.appending(path: ".cache").appending(path: "winetricks") // old name: its cache
        return [tricksCache] + loaderCacheNames.flatMap { name in cacheFolders.map { $0.appending(path: name) } }
    }

    /// The items in the temporary folder that match ``temporaryNames``.
    private static func temporaryTraces(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.sorted().map { folder.appending(path: $0) }.filter { item in
            temporaryNames.contains { name in
                item.lastPathComponent.hasPrefix(name.prefix) && item.lastPathComponent.hasSuffix(name.suffix)
                    && matches(item, name.rule)
            }
        }
    }

    /// Ano 6-8's proxy wrapper, which says Wine; the proxy writes today's
    /// wrapper again when a proxied bottle needs it.
    private static func oldWrapper(in places: Places) -> [URL] {
        let wrapper = ProxyEnvironment.wrapperFolder(inApplicationFolder: places.applicationFolder)
            .appending(path: AnoWineRuntime.loaderName)
        return textSaysOldName(wrapper) ? [wrapper] : []
    }

    // MARK: - Files

    private static func matches(_ item: URL, _ rule: TemporaryRule) -> Bool {
        switch rule {
        case .folder: entry(at: item)?.type == mode_t(S_IFDIR)
        case .file: entry(at: item)?.type == mode_t(S_IFREG)
        case .fileWithOldText: textSaysOldName(item)
        }
    }

    /// Whether the regular file at `url` says Wine, in any case. The app's
    /// `.reg` files are UTF-16 with a byte order mark; its scripts are UTF-8.
    /// A symlink is not read.
    static func textSaysOldName(_ url: URL) -> Bool {
        guard entry(at: url)?.type == mode_t(S_IFREG),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return false }
        let byteOrderMarks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF]]
        let encoding: String.Encoding = byteOrderMarks.contains(Array(data.prefix(2))) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding) else { return false }
        return text.range(of: "wine", options: .caseInsensitive) != nil // old name: what Ano 6-8's files say
    }

    /// The type (`S_IFDIR`, `S_IFREG`, `S_IFLNK`, ...) and owner of what is at
    /// `url`: a symlink's own, never its target's; `nil` when nothing is there.
    static func entry(at url: URL) -> (type: mode_t, owner: uid_t)? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return (mode_t(info.st_mode) & mode_t(S_IFMT), info.st_uid)
    }

    /// Removes `folder` only while it is empty (`rmdir`).
    private static func removeEmptyFolder(_ folder: URL) throws {
        guard rmdir(folder.path(percentEncoded: false)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
