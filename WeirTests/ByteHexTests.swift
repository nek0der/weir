// ByteHexTests.swift
// Weir — the one hexadecimal spelling digests are named by.

import CryptoKit
import Foundation
import Testing
@testable import Weir

struct ByteHexTests {
    @Test func hexString_isLowercase_andTwoDigitsPerByte() {
        #expect([UInt8]([0x00, 0x0A, 0xFF, 0x7F]).hexString == "000aff7f")
        #expect([UInt8]().hexString.isEmpty)
    }

    /// A digest and a prefix of one spell alike, as the refs and range IDs
    /// that keep only the first bytes rely on.
    @Test func hexString_ofADigest_isItsWellKnownSpelling() {
        let digest = SHA256.hash(data: Data("abc".utf8))
        #expect(digest.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(digest.prefix(4).hexString == "ba7816bf")
    }
}
