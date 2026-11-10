//
//  main.swift
//  ano-proxy
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

// The proxy helper as a command-line tool, for CI: the app runs the same
// engine in-process. Usage:
//   ano-proxy (--socks5|--http) HOST:PORT [--user U] [--password-env VAR] [--port N]
//   ano-proxy --write-wrapper DIR   (writes DIR/ano-loader and prints its path)

import Darwin
import Foundation
import WhiskyKit

func usage() -> Never {
    let text = "usage: ano-proxy (--socks5|--http) HOST:PORT [--user U] [--password-env VAR] [--port N]\n"
        + "       ano-proxy --write-wrapper DIR\n"
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

var kind: String?
var target: String?
var user: String?
var password: String?
var port: UInt16?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--socks5", "--http":
        kind = argument
        target = arguments.next()
    case "--user":
        user = arguments.next()
    case "--password-env":
        password = arguments.next().flatMap { ProcessInfo.processInfo.environment[$0] }
    case "--port":
        port = arguments.next().flatMap { UInt16($0) }
    case "--write-wrapper":
        guard let folder = arguments.next() else { usage() }
        do {
            let wrapper = try ProxyEnvironment.installWrapper(in: URL(filePath: folder))
            print(wrapper.path(percentEncoded: false))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ano-proxy: cannot write wrapper: \(error)\n".utf8))
            exit(1)
        }
    default:
        usage()
    }
}

guard let kind, let target, let colon = target.lastIndex(of: ":"),
      let upstreamPort = UInt16(target[target.index(after: colon)...])
else { usage() }
let host = String(target[..<colon])
let upstream: ProxyUpstream = kind == "--socks5"
    ? .socks5(host: host, port: upstreamPort, username: user, password: password)
    : .httpConnect(host: host, port: upstreamPort, username: user, password: password)

let listener = ProxyListener(upstream: upstream)
listener.onRequest = { type in
    FileHandle.standardError.write(Data("accepted \(type)\n".utf8))
}

do {
    let listening = try listener.start(preferredPort: port)
    print("listening \(listening)")
    fflush(stdout)
} catch {
    FileHandle.standardError.write(Data("ano-proxy: cannot listen: \(error)\n".utf8))
    exit(1)
}

while true {
    pause()
}
