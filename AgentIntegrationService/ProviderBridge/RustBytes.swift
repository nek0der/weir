// RustBytes.swift
// Weir — takes ownership of the bytes a Rust bridge call hands out, copies them, and frees them.
//
// Compiled into the app, the Hook Helper, and the service: every target that
// links the Rust bridge.

import Foundation
import WeirRustBridge

/// The one place a Swift caller takes bytes the Rust bridge handed out.
///
/// A call that answers with bytes allocates them on the Rust side and hands
/// the pointer and length over; from then on they are ours until we pass the
/// same pair to `weir_approval_bytes_free_v1`, whatever status came with
/// them. We copy them into `Data` and free them before the copy is returned,
/// so no Swift value ever points into Rust's allocation: `Data(bytesNoCopy:)`
/// would tie the free to a deallocator that runs wherever the last copy of
/// the value dies.
enum RustBytes {
    /// What one call returned: its status, and a copy of the bytes it handed
    /// out, `nil` when it handed out none.
    struct Output {
        let status: Int32
        let body: Data?
    }

    /// What releases a pair. Only a test passes another, to count the frees
    /// and still release what it counted.
    typealias Free = (UnsafeMutablePointer<UInt8>?, Int) -> Void

    /// Runs one call that hands bytes out through an `out`/`out_len` pair.
    ///
    /// The free is deferred from before the call, so it runs whatever the
    /// status, and also when `body` throws after the call wrote the pair.
    /// The slots start null and zero; a pair still null afterwards was never
    /// handed out and is not passed to the free. The pointers `body`
    /// receives are valid only while it runs.
    static func call(
        free: Free = { weir_approval_bytes_free_v1($0, $1) },
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
            UnsafeMutablePointer<Int>
        ) throws -> Int32
    ) rethrows -> Output {
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        defer {
            if let out {
                free(out, outCount)
            }
        }
        let status = try withUnsafeMutablePointer(to: &out) { outPointer in
            try withUnsafeMutablePointer(to: &outCount) { outCountPointer in
                try body(outPointer, outCountPointer)
            }
        }
        return Output(status: status, body: out.map { Data(bytes: $0, count: outCount) })
    }

    /// Takes ownership of one pair a call returned some other way (the
    /// approval exchange's `weir_approval_bytes_v1`): hands `body` the bytes,
    /// `nil` when the pointer is null, then frees them, whatever `body` does.
    /// A null pointer was never handed out and is not passed to the free.
    static func consume<T>(
        _ data: UnsafeMutablePointer<UInt8>?,
        count: Int,
        free: Free = { weir_approval_bytes_free_v1($0, $1) },
        _ body: (UnsafeBufferPointer<UInt8>?) throws -> T
    ) rethrows -> T {
        defer {
            if let data {
                free(data, count)
            }
        }
        return try body(data.map { UnsafeBufferPointer(start: $0, count: count) })
    }

    /// Lends `data` to one call; Rust copies whatever it keeps, so the
    /// pointer need not outlive `body`. An empty value is lent as a null
    /// pointer with length 0, which every entry point either reads as empty
    /// input or reports (projection's required inputs) and never
    /// dereferences.
    static func withBytes<T>(
        _ data: Data,
        _ body: (UnsafePointer<UInt8>?, Int) throws -> T
    ) rethrows -> T {
        guard !data.isEmpty else { return try body(nil, 0) }
        return try data.withUnsafeBytes { buffer in
            try body(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
    }
}
