//
//  ProxyUpstream+ExitIP.swift
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

public extension ProxyUpstream {
    /// The address the internet sees for traffic through this proxy, read from
    /// Cloudflare's trace page over the same tunnel a bottle's connections use.
    /// Blocking; call it off the main thread.
    func exitIP(
        host: String = "one.one.one.one", port: UInt16 = 80, timeout: TimeInterval = 15
    ) throws -> String {
        let sock = try open(to: .domain(host, port: port), timeout: timeout)
        defer { close(sock) }
        var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        let request = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        try ProxySocket.writeAll(sock, Array(request.utf8))

        var response: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while response.count < 65_536 {
            let got = buffer.withUnsafeMutableBytes { read(sock, $0.baseAddress, $0.count) }
            guard got > 0 else { break }
            response += buffer[0 ..< got]
        }
        let text = String(bytes: response, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) else {
            throw ProxyError.protocolError("no ip= line in the trace response")
        }
        return line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
