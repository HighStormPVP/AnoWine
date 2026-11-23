//
//  OldTraceCleanupTests.swift
//  WhiskyKitTests
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

@testable import WhiskyKit
import XCTest

/// The first launch of the renamed app removes what Ano 6-8 left outside the
/// bottles, once, and never a live server's folder (Plan 3c-4c Task 1).
final class OldTraceCleanupTests: XCTestCase {
    private var root = URL(filePath: "/nonexistent")
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    /// Ano 6-8's proxy wrapper, word for word.
    private static let oldWrapper = """
    #!/bin/sh
    # Ano: start Wine with the proxy interceptor. Only Wine gets it.
    DYLD_INSERT_LIBRARIES="$ANO_NET_LIB" exec "$ANO_REAL_LOADER" "$@"

    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appending(path: "old-traces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "OldTraceCleanupTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - The list

    func testTheListedTracesAreRemoved() throws {
        let places = try makePlaces()
        let traces = try makeEveryTrace(in: places)
        let kept = try makeFilesBesideThem(in: places)

        let removed = OldTraceCleanup.clean(places) { _ in false }

        for trace in traces {
            XCTAssertFalse(exists(trace), "still there: \(trace.path(percentEncoded: false))")
        }
        XCTAssertFalse(exists(serverFolder(places)), "the emptied server root goes too")
        for path in kept {
            XCTAssertTrue(exists(path), "removed: \(path.path(percentEncoded: false))")
        }
        XCTAssertEqual(
            removed.map(\.lastPathComponent).sorted(),
            (traces + [serverFolder(places)]).map(\.lastPathComponent).sorted()
        )
    }

    // MARK: - Servers

    func testALiveServerFolderStays() throws {
        let places = try makePlaces()
        let live = serverFolder(places).appending(path: "server-1-2")
        let stale = serverFolder(places).appending(path: "server-3-4")
        try file(live.appending(path: "lock"), "")
        try file(stale.appending(path: "lock"), "")
        let isLive: (URL) -> Bool = { $0.lastPathComponent == "server-1-2" }

        let targets = OldTraceCleanup.targets(in: places, isServerLive: isLive)
        XCTAssertEqual(targets.map(\.lastPathComponent), ["server-3-4"])
        let removed = OldTraceCleanup.clean(places, isServerLive: isLive)

        XCTAssertTrue(exists(live.appending(path: "lock")))
        XCTAssertFalse(exists(stale))
        XCTAssertTrue(exists(serverFolder(places)), "not empty, so it stays")
        XCTAssertEqual(removed.map(\.lastPathComponent), ["server-3-4"])
    }

    func testServerLockIsHeldSeesAnotherProcessesLock() throws {
        let places = try makePlaces()
        let server = serverFolder(places).appending(path: "server-5-6")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        XCTAssertFalse(OldTraceCleanup.serverLockIsHeld(server), "no lock file")
        let lock = try file(server.appending(path: "lock"), "")
        XCTAssertFalse(OldTraceCleanup.serverLockIsHeld(server), "nobody holds it")

        let holder = try startLockHolder(on: lock)
        defer { if holder.isRunning { holder.terminate() } }
        XCTAssertTrue(OldTraceCleanup.serverLockIsHeld(server), "another process holds it")

        holder.terminate()
        holder.waitUntilExit()
        XCTAssertFalse(OldTraceCleanup.serverLockIsHeld(server), "its holder is gone")
    }

    // MARK: - Safety

    func testASymlinkIsRemovedNotFollowed() throws {
        let places = try makePlaces()
        let target = root.appending(path: "external").appending(path: "winetricks")
        let targetFile = try file(target.appending(path: "vc_redist.x86.exe"))
        let link = places.home.appending(path: ".cache").appending(path: "winetricks")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let removed = OldTraceCleanup.clean(places) { _ in false }

        XCTAssertFalse(exists(link), "the link goes")
        XCTAssertTrue(exists(targetFile), "its target stays")
        XCTAssertEqual(removed.map(\.lastPathComponent), ["winetricks"])
    }

    func testAFailedRemovalIsSkippedAndTheRunIsMarkedDone() throws {
        let places = try makePlaces()
        let cache = places.home.appending(path: ".cache")
        try file(cache.appending(path: "winetricks").appending(path: "vc_redist.x86.exe"))
        let tricksTemp = places.temporaryFolder.appending(path: "winetricks.AbCd1234")
        try FileManager.default.createDirectory(at: tricksTemp, withIntermediateDirectories: true)
        let cachePath = cache.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cachePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cachePath) }

        let removed = try XCTUnwrap(OldTraceCleanup.runIfNeeded(defaults: defaults, places: places))

        XCTAssertEqual(removed.map(\.lastPathComponent), ["winetricks.AbCd1234"])
        XCTAssertFalse(exists(tricksTemp))
        XCTAssertTrue(exists(cache.appending(path: "winetricks")), "its folder is read-only")
        XCTAssertEqual(defaults.integer(forKey: "oldTracesCleanupVersion"), 1)
    }

    func testItRunsOnce() throws {
        XCTAssertEqual(OldTraceCleanup.doneDefaultsKey, "oldTracesCleanupVersion")
        XCTAssertEqual(OldTraceCleanup.currentVersion, 1)
        let places = try makePlaces()
        try FileManager.default.createDirectory(
            at: places.temporaryFolder.appending(path: "winetricks.first"), withIntermediateDirectories: true
        )
        XCTAssertEqual(OldTraceCleanup.runIfNeeded(defaults: defaults, places: places)?.count, 1)

        let later = places.temporaryFolder.appending(path: "winetricks.later")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        XCTAssertNil(OldTraceCleanup.runIfNeeded(defaults: defaults, places: places))
        XCTAssertTrue(exists(later))
    }

    func testTheWrapperIsRemovedOnlyWhenItSaysWine() throws {
        let today = try makePlaces("today")
        let todayWrapper = try file(wrapperURL(today), ProxyEnvironment.wrapperScript)
        OldTraceCleanup.clean(today) { _ in false }
        XCTAssertTrue(exists(todayWrapper), "today's wrapper stays")

        let old = try makePlaces("old")
        let oldWrapper = try file(wrapperURL(old), "#!/bin/sh\nexec \"$ANO_WINE_DIR/bin/ano-loader\" \"$@\"\n")
        OldTraceCleanup.clean(old) { _ in false }
        XCTAssertFalse(exists(oldWrapper), "an old wrapper goes")
    }

    // MARK: - Helpers

    /// Creates one of every trace on the list and returns them; a stale
    /// server folder is among them.
    private func makeEveryTrace(in places: OldTraceCleanup.Places) throws -> [URL] {
        let temp = places.temporaryFolder
        let tricksCache = places.home.appending(path: ".cache").appending(path: "winetricks")
        try file(tricksCache.appending(path: "vcrun2019").appending(path: "vc_redist.x86.exe"))
        let server = serverFolder(places).appending(path: "server-1000010-359992")
        try file(server.appending(path: "lock"), "")
        let caches = ["org.winehq.wine", "com.codeweavers.CrossOver.wineloader"].flatMap { name in
            [places.userCacheFolder.appending(path: name), places.home.appending(path: "Library/Caches/\(name)")]
        }
        for cache in caches {
            try file(cache.appending(path: "com.apple.metalfe").appending(path: "functions.data"))
        }
        let tricksTemp = temp.appending(path: "winetricks.AbCd1234")
        try file(tricksTemp.appending(path: "release.json"))
        let files = try [
            file(temp.appending(path: "whisky-winetricks-\(UUID().uuidString).sh"), "export WINEPREFIX=/b\n"),
            file(temp.appending(path: "whisky-run-\(UUID().uuidString).sh"), "export WINEPREFIX=/b\n"),
            file(temp.appending(path: "whisky-env-\(UUID().uuidString).sh"), "/T/whisky-winetricks-1.sh\n"),
            registryFile(temp.appending(path: "whisky-registry-1.reg"), "[HKEY_CURRENT_USER\\Software\\Wine]"),
            registryFile(temp.appending(path: "whisky-dll-overrides-1.reg"), "[HKCU\\Software\\Wine\\DllOverrides]"),
            file(wrapperURL(places), Self.oldWrapper)
        ]
        return [tricksCache, server, tricksTemp] + caches + files
    }

    /// Files beside the traces that stay, among them today's files under
    /// the same names, which say Ano.
    private func makeFilesBesideThem(in places: OldTraceCleanup.Places) throws -> [URL] {
        let temp = places.temporaryFolder
        return try [
            file(places.home.appending(path: ".cache").appending(path: "other").appending(path: "file")),
            file(temp.appending(path: "keep.txt")),
            file(places.applicationFolder.appending(path: "Proxy/bin/other")),
            file(temp.appending(path: "whisky-run-\(UUID().uuidString).sh"), "export ANOPREFIX=/b\n"),
            file(temp.appending(path: "whisky-env-\(UUID().uuidString).sh"), "eval \"$(ano shellenv b)\"\n"),
            registryFile(temp.appending(path: "whisky-registry-2.reg"), "[HKEY_CURRENT_USER\\Software\\Ano]"),
            file(places.userCacheFolder.appending(path: "io.github.highstormpvp.Ano.core").appending(path: "x"))
        ]
    }

    /// A fake set of places under the test's folder, each folder created.
    private func makePlaces(_ name: String = "places") throws -> OldTraceCleanup.Places {
        let base = root.appending(path: name)
        let places = OldTraceCleanup.Places(
            home: base.appending(path: "home"),
            temporaryFolder: base.appending(path: "T"),
            userCacheFolder: base.appending(path: "C"),
            applicationFolder: base.appending(path: "Application Support"),
            serverRoot: base.appending(path: "tmp"),
            uid: getuid()
        )
        for folder in [places.home, places.temporaryFolder, places.userCacheFolder, places.applicationFolder,
                       places.serverRoot] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return places
    }

    private func serverFolder(_ places: OldTraceCleanup.Places) -> URL {
        places.serverRoot.appending(path: ".wine-\(places.uid)")
    }

    private func wrapperURL(_ places: OldTraceCleanup.Places) -> URL {
        places.applicationFolder.appending(path: "Proxy").appending(path: "bin").appending(path: "ano-loader")
    }

    /// Writes `text` to `url`, creating its folders.
    @discardableResult
    private func file(_ url: URL, _ text: String = "x") throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Writes a `.reg` file as the app does: UTF-16LE with a byte order mark.
    private func registryFile(_ url: URL, _ text: String) throws -> URL {
        try ("\u{FEFF}Windows Registry Editor Version 5.00\r\n\r\n" + text + "\r\n")
            .write(to: url, atomically: true, encoding: .utf16LittleEndian)
        return url
    }

    /// Whether anything is at `url`, a dangling symlink included.
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    /// Starts another process that holds a write lock on `lock` with
    /// `fcntl(F_SETLK)`, as a running server holds its `lock` file, and
    /// returns once it holds it.
    private func startLockHolder(on lock: URL) throws -> Process {
        let path = lock.path(percentEncoded: false)
        // Darwin's struct flock: l_start, l_len (off_t), l_pid (pid_t), l_type, l_whence (short).
        let perl = """
        open(my $f, ">>", $ARGV[0]) or die "open: $!"; my $l = pack("qqlss", 0, 0, 0, F_WRLCK, 0); \
        fcntl($f, F_SETLK, $l) or die "lock: $!"; $| = 1; print "locked\\n"; sleep 120;
        """
        // lockf is fcntl(F_SETLK) over the whole file.
        let python = """
        import fcntl, sys, time
        f = open(sys.argv[1], "a")
        fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print("locked", flush=True)
        time.sleep(120)
        """
        let holders: [(tool: String, arguments: [String])] = [
            ("/usr/bin/perl", ["-MFcntl", "-e", perl, path]),
            ("/usr/bin/python3", ["-c", python, path])
        ]
        guard let holder = holders.first(where: { FileManager.default.isExecutableFile(atPath: $0.tool) }) else {
            throw XCTSkip("Neither /usr/bin/perl nor /usr/bin/python3 is here to hold a lock from another process")
        }
        let process = Process()
        process.executableURL = URL(filePath: holder.tool)
        process.arguments = holder.arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // One line once it holds the lock; end of file if it could not.
        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        guard line == "locked\n" else {
            process.waitUntilExit()
            let reason = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LockHolderFailed(tool: holder.tool, reason: reason)
        }
        return process
    }

    private struct LockHolderFailed: Error, CustomStringConvertible {
        let tool: String
        let reason: String
        var description: String { "\(tool) could not take the lock: \(reason)" }
    }
}
