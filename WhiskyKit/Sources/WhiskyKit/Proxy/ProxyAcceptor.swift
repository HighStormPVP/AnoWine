//
//  ProxyAcceptor.swift
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

import Darwin
import Foundation

/// Accepts connections on listening sockets, one thread per socket, and owns
/// those sockets: only the thread that waits on a socket ever closes it.
///
/// Closing a socket from another thread while one is blocked in `accept` lets
/// that thread go on to accept from whatever socket reuses the number next.
/// Here ``stop()`` wakes the threads through a pipe and waits until each has
/// closed its own socket, so the port is free again when it returns.
final class ProxyAcceptor: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var wakeWriter: Int32 = -1
    private var wakeReader: Int32 = -1

    /// Takes ownership of `sockets` and calls `onAccept` for each connection,
    /// on the accepting thread.
    init(sockets: [Int32], onAccept: @escaping @Sendable (Int32) -> Void) {
        var ends: [Int32] = [-1, -1]
        _ = pipe(&ends)
        wakeReader = ends[0]
        wakeWriter = ends[1]
        let reader = ends[0]
        for sock in sockets {
            finished.enter()
            Thread.detachNewThread { [finished] in
                Self.run(sock, wake: reader, onAccept: onAccept)
                close(sock)
                finished.leave()
            }
        }
    }

    deinit { stop(wait: false) }

    /// Stops accepting and closes the sockets. Safe to call more than once.
    /// - Parameter wait: Return only once the sockets are closed. Pass `false`
    ///   when the caller may be one of the accepting threads.
    func stop(wait: Bool = true) {
        let writer = lock.withLock {
            let writer = wakeWriter
            wakeWriter = -1
            return writer
        }
        guard writer >= 0 else { return }
        close(writer)
        let reader = wakeReader
        if wait {
            finished.wait()
            close(reader)
        } else {
            finished.notify(queue: .global()) { close(reader) }
        }
    }

    /// Accepts until the wake pipe closes or the socket fails.
    private static func run(_ sock: Int32, wake: Int32, onAccept: (Int32) -> Void) {
        while true {
            var polled = [
                pollfd(fd: sock, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&polled, 2, -1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, polled[1].revents == 0, polled[0].revents & Int16(POLLIN) != 0 else { return }
            let client = accept(sock, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                return
            }
            onAccept(client)
        }
    }
}
