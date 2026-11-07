// RustBytesTests.swift
// Weir — the one way bytes the Rust bridge hands out are taken, copied, and freed.

import Foundation
import Synchronization
import Testing
import WeirRustBridge
@testable import Weir

/// One pair a free was handed: the address and the length.
private struct FreedPair: Equatable {
    let address: UInt?
    let count: Int
}

@Suite("RustBytes")
struct RustBytesTests {
    /// Each pair `RustBytes` frees, released for real after it is counted,
    /// so a test sees that what a call handed out is freed once, and only it.
    private final class FreeLog: Sendable {
        private let pairs = Mutex<[FreedPair]>([])

        var freed: [FreedPair] {
            pairs.withLock { $0 }
        }

        func free(_ data: UnsafeMutablePointer<UInt8>?, _ count: Int) {
            pairs.withLock { $0.append(FreedPair(address: data.map { UInt(bitPattern: $0) }, count: count)) }
            weir_approval_bytes_free_v1(data, count)
        }
    }

    /// A call that hands bytes out (`weir_projection_providers_v1`), with the
    /// pair it wrote noted down.
    private static func handOut(
        _ out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        _ outCount: UnsafeMutablePointer<Int>,
        into handed: inout FreedPair?
    ) -> Int32 {
        let status = weir_projection_providers_v1(out, outCount)
        handed = FreedPair(address: out.pointee.map { UInt(bitPattern: $0) }, count: outCount.pointee)
        return status
    }

    @Test("a call that hands bytes out returns a copy of them, and frees them once")
    func call_copiesAndFreesWhatTheCallHandedOut() throws {
        let log = FreeLog()
        var handed: FreedPair?
        var original: Data?
        let output = RustBytes.call(free: log.free) { out, outCount in
            let status = Self.handOut(out, outCount, into: &handed)
            original = out.pointee.map { Data(bytes: $0, count: outCount.pointee) }
            return status
        }
        #expect(output.status == Int32(WEIR_PROJECTION_OK.rawValue))
        let body = try #require(output.body)
        #expect(body == original)
        #expect(try AgentProviderDescriptor.registry(from: body)["codex"] != nil)
        #expect(handed?.address != nil)
        #expect(log.freed == [handed])
    }

    /// The bytes are ours whatever the status, so a refusal that handed
    /// some out still returns them, and they are freed with the rest.
    @Test("a call that refuses after handing bytes out returns them and frees them once")
    func call_refusedWithBytes_returnsAndFreesThem() {
        let log = FreeLog()
        var handed: FreedPair?
        let output = RustBytes.call(free: log.free) { out, outCount in
            _ = Self.handOut(out, outCount, into: &handed)
            return 7
        }
        #expect(output.status == 7)
        #expect(output.body?.isEmpty == false)
        #expect(log.freed == [handed])
    }

    /// The pair is freed from a `defer`, so an error after the call wrote it
    /// still leaves nothing owned.
    @Test("an error thrown after the call wrote its bytes still frees them once")
    func call_thatThrowsAfterTheCall_freesWhatItHandedOut() {
        struct AfterTheCall: Error {}
        let log = FreeLog()
        var handed: FreedPair?
        #expect(throws: AfterTheCall.self) {
            try RustBytes.call(free: log.free) { out, outCount in
                _ = Self.handOut(out, outCount, into: &handed)
                throw AfterTheCall()
            }
        }
        #expect(handed?.address != nil)
        #expect(log.freed == [handed])
    }

    /// No pointer is no body, not an empty one: the callers tell "said OK
    /// with nothing" from "said OK with an empty answer" by it.
    @Test("a call that hands nothing out has no body, whatever its status")
    func call_withoutBytes_hasNoBody() {
        let log = FreeLog()
        let refused = RustBytes.call(free: log.free) { _, _ in 7 }
        #expect(refused.status == 7)
        #expect(refused.body == nil)
        let empty = RustBytes.call(free: log.free) { _, _ in Int32(WEIR_PROVIDER_OK.rawValue) }
        #expect(empty.body == nil)
        // A pair never handed out is not passed to the free.
        #expect(log.freed.isEmpty)
    }

    /// The approval exchange returns its pair in a struct, so it takes the
    /// bytes through `consume`, which frees them once whatever it returns.
    @Test("a pair taken another way is lent, then freed once, also when the reader throws")
    func consume_lendsThenFreesOnce() throws {
        struct TooLarge: Error {}
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        #expect(weir_projection_providers_v1(&out, &outCount) == Int32(WEIR_PROJECTION_OK.rawValue))
        let log = FreeLog()
        let copy = RustBytes.consume(out, count: outCount, free: log.free) { buffer in
            #expect(log.freed.isEmpty)
            return buffer.map { Data($0) }
        }
        #expect(copy?.count == outCount)
        #expect(log.freed == [FreedPair(address: out.map { UInt(bitPattern: $0) }, count: outCount)])

        #expect(weir_projection_providers_v1(&out, &outCount) == Int32(WEIR_PROJECTION_OK.rawValue))
        let refusing = FreeLog()
        #expect(throws: TooLarge.self) {
            try RustBytes.consume(out, count: outCount, free: refusing.free) { _ in throw TooLarge() }
        }
        #expect(refusing.freed == [FreedPair(address: out.map { UInt(bitPattern: $0) }, count: outCount)])
        let isNil = RustBytes.consume(nil, count: 0, free: { _, _ in }, { $0 == nil })
        #expect(isNil)
    }

    /// An empty value is lent as a null pointer with length 0, which every
    /// entry point either reads as empty input or reports, and never
    /// dereferences.
    @Test("an empty value is lent as a null pointer with length 0")
    func withBytes_empty_isNull() {
        let empty = RustBytes.withBytes(Data()) { pointer, count in pointer == nil && count == 0 }
        #expect(empty)
        let bytes = RustBytes.withBytes(Data("abc".utf8)) { pointer, count in
            pointer.map { Array(UnsafeBufferPointer(start: $0, count: count)) }
        }
        #expect(bytes == Array("abc".utf8))
    }
}
