// OffPoolWorkTests.swift
// Weir — blocking work runs on a dispatch queue, never on the cooperative pool.

import Foundation
import Testing
@testable import Weir

struct OffPoolWorkTests {
    private struct Failure: Error, Equatable {}

    @Test func run_returnsTheValue() async {
        let value = await OffPoolWork.run { 6 * 7 }
        #expect(value == 42)
    }

    @Test func run_rethrowsTheError() async {
        await #expect(throws: Failure()) {
            try await OffPoolWork.run { () throws(Failure) -> Int in throw Failure() }
        }
    }

    @MainActor
    @Test func run_fromTheMainActor_isNotOnTheMainThread() async {
        let isMainThread = await OffPoolWork.run { Thread.isMainThread }
        #expect(!isMainThread)
    }

    /// The cooperative pool has one thread per core and adds none for a
    /// thread that blocks, so work that blocks until more of it than there
    /// are cores has started never all starts there. A dispatch queue
    /// replaces a blocked worker, so here every one starts.
    @Test(.timeLimit(.minutes(1)))
    func run_blockingWorkWiderThanThePool_allStarts() async {
        let width = min(2 * ProcessInfo.processInfo.activeProcessorCount, 48)
        let started = DispatchGroup()
        for _ in 0..<width {
            started.enter()
        }
        let allStarted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<width {
                group.addTask {
                    await OffPoolWork.run {
                        started.leave()
                        return started.wait(timeout: .now() + 10) == .success
                    }
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results.allSatisfy(\.self)
        }
        #expect(allStarted)
    }
}
