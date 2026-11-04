// ByteHex.swift
// Weir — bytes written as lowercase hexadecimal, two digits each.

import Foundation

extension Sequence<UInt8> {
    /// The bytes as lowercase hexadecimal, two digits each and nothing
    /// between them: how a SHA-256 digest is named in a file, a ref, a key,
    /// and Codex's trust hash. We keep one spelling because a value one
    /// target writes and another compares must match byte for byte.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
