//
//  OldTraceCleanupTests+LockHolder.swift
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

import Foundation
import XCTest

/// Another process that holds a server folder's `lock`, as a running server does.
extension OldTraceCleanupTests {
    /// Starts another process that holds a write lock on `lock` with
    /// `fcntl(F_SETLK)`, as a running server holds its `lock` file, and
    /// returns once it holds it.
    func startLockHolder(on lock: URL) throws -> Process {
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

    struct LockHolderFailed: Error, CustomStringConvertible {
        let tool: String
        let reason: String
        var description: String { "\(tool) could not take the lock: \(reason)" }
    }
}
