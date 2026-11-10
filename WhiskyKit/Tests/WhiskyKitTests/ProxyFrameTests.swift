//
//  ProxyFrameTests.swift
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

@testable import WhiskyKit
import XCTest

final class ProxyFrameTests: XCTestCase {
    private let magic = Array("ANO1".utf8)

    func testConnectIPv4Encoding() {
        let frame = ProxyFrame.connect(.ipv4(0xC000_0201, port: 7_000))
        XCTAssertEqual(frame.encoded(), magic + [0x43, 1, 192, 0, 2, 1, 0x1B, 0x58])
    }

    func testConnectIPv6Encoding() {
        let address: [UInt8] = [0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 11) + [1]
        let frame = ProxyFrame.connect(.ipv6(address, port: 443))
        XCTAssertEqual(frame.encoded(), magic + [0x43, 4] + address + [0x01, 0xBB])
    }

    func testResolveEncodingNormalisesName() {
        let frame = ProxyFrame.resolve("Steam.com.")
        XCTAssertEqual(frame.encoded(), magic + [0x52, 9] + Array("steam.com".utf8))
    }

    func testPeerEncoding() {
        XCTAssertEqual(ProxyFrame.peer(localPort: 513).encoded(), magic + [0x50, 0x02, 0x01])
    }

    func testFramesRoundTrip() throws {
        let frames: [ProxyFrame] = [
            .connect(.ipv4(0xC000_0201, port: 7_000)),
            .connect(.ipv6(Array(repeating: 0, count: 15) + [1], port: 80)),
            .resolve("anotest.example.com"),
            .peer(localPort: 51_234)
        ]
        for frame in frames {
            let bytes = frame.encoded()
            let (decoded, consumed) = try ProxyFrame.decode(bytes + [0xFF])
            XCTAssertEqual(decoded, frame)
            XCTAssertEqual(consumed, bytes.count)
        }
    }

    func testPrefixIsIncomplete() {
        let bytes = ProxyFrame.connect(.ipv4(0xC000_0201, port: 7_000)).encoded()
        for length in 0 ..< bytes.count {
            XCTAssertThrowsError(try ProxyFrame.decode(Array(bytes.prefix(length)))) { error in
                XCTAssertEqual(error as? ProxyFrameError, .incomplete)
            }
        }
    }

    func testBadMagicIsInvalid() {
        XCTAssertThrowsError(try ProxyFrame.decode(Array("ANO2".utf8) + [0x50, 0, 1])) { error in
            XCTAssertEqual(error as? ProxyFrameError, .invalid)
        }
    }

    func testUnknownTypeAndBadLengthsAreInvalid() {
        XCTAssertThrowsError(try ProxyFrame.decode(magic + [0x58])) { error in
            XCTAssertEqual(error as? ProxyFrameError, .invalid)
        }
        XCTAssertThrowsError(try ProxyFrame.decode(magic + [0x52, 0])) { error in
            XCTAssertEqual(error as? ProxyFrameError, .invalid)
        }
        XCTAssertThrowsError(try ProxyFrame.decode(magic + [0x43, 2, 0, 0])) { error in
            XCTAssertEqual(error as? ProxyFrameError, .invalid)
        }
    }

    func testFakeDNSIsStableAndNormalised() {
        let dns = FakeDNS()
        let first = dns.address(for: "A.Example.")
        XCTAssertEqual(first, 0xC612_0001)
        XCTAssertEqual(dns.address(for: "a.example"), first)
        let second = dns.address(for: "b.example")
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(dns.name(for: 0xC612_0001), "a.example")
        XCTAssertNil(dns.name(for: 0xC612_00FF))
    }

    func testFakeDNSRejectsBadNames() {
        let dns = FakeDNS()
        XCTAssertNil(dns.address(for: ""))
        XCTAssertNil(dns.address(for: "."))
        XCTAssertNil(dns.address(for: String(repeating: "a", count: 254)))
        XCTAssertNil(dns.address(for: "stéam.com"))
    }

    func testFakeDNSRange() {
        let dns = FakeDNS()
        XCTAssertTrue(dns.contains(0xC612_0000))
        XCTAssertTrue(dns.contains(0xC613_0000))
        XCTAssertTrue(dns.contains(0xC613_FFFF))
        XCTAssertFalse(dns.contains(0xC614_0000))
        XCTAssertFalse(dns.contains(0xC611_FFFF))
    }

    func testFakeDNSExhaustionReturnsNil() {
        let dns = FakeDNS(range: 0xC612_0001 ... 0xC612_0002)
        XCTAssertNotNil(dns.address(for: "one.example"))
        XCTAssertNotNil(dns.address(for: "two.example"))
        XCTAssertNil(dns.address(for: "three.example"))
        XCTAssertEqual(dns.address(for: "one.example"), 0xC612_0001)
    }
}
