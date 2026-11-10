//
//  FakeDNS.swift
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

/// Hands out placeholder IPv4 addresses for hostnames, so a proxied bottle never
/// resolves names itself: a later connection to the placeholder is sent to the
/// proxy by hostname, and the proxy resolves it on the far side.
///
/// Addresses come from `198.18.0.0/15`, which is reserved for benchmarking and
/// never routed on the internet. Each instance starts at a random place in the
/// range: a program that still holds a placeholder from an earlier helper then
/// gets a closed connection, not some other name's site.
public final class FakeDNS: @unchecked Sendable {
    /// `198.18.0.0/15`.
    static let reservedRange: ClosedRange<UInt32> = 0xC612_0000 ... 0xC613_FFFF

    private let lock = NSLock()
    private let range: ClosedRange<UInt32>
    private var next: UInt32
    private var exhausted = false
    private var addresses: [String: UInt32] = [:]
    private var names: [UInt32: String] = [:]

    /// - Parameter start: The first placeholder to hand out; random when `nil`.
    public init(range: ClosedRange<UInt32> = 0xC612_0001 ... 0xC613_FFFE, start: UInt32? = nil) {
        self.range = range
        self.next = start.map { min(max($0, range.lowerBound), range.upperBound) } ?? UInt32.random(in: range)
    }

    /// The placeholder for `name`, the same one every time; `nil` if the name is
    /// empty, longer than 253 bytes, not ASCII, or the range is used up.
    public func address(for name: String) -> UInt32? {
        let name = ProxyFrame.normalise(name)
        guard !name.isEmpty, name.utf8.count <= 253, name.allSatisfy(\.isASCII) else { return nil }
        return lock.withLock {
            if let known = addresses[name] { return known }
            guard !exhausted else { return nil }
            let address = next
            addresses[name] = address
            names[address] = name
            next = address == range.upperBound ? range.lowerBound : address + 1
            exhausted = names[next] != nil
            return address
        }
    }

    /// The hostname a placeholder stands for.
    public func name(for address: UInt32) -> String? {
        lock.withLock { names[address] }
    }

    /// Whether `address` is in the placeholder range, mapped or not.
    public func contains(_ address: UInt32) -> Bool {
        Self.reservedRange.contains(address)
    }
}
