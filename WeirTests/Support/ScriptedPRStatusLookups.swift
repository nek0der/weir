// ScriptedPRStatusLookups.swift
// Weir — a pull request fetcher whose every lookup waits until the test answers it.

import Foundation
@testable import Weir

/// A `PRStatusLookups` whose lookups wait until the test answers them, so a
/// test decides the order the answers land in, and reads which rows each
/// lookup asked about.
actor ScriptedPRStatusLookups: PRStatusLookups {
    private struct Waiting {
        let rows: [PRStatusRow]
        let continuation: CheckedContinuation<PRStatusBatch, Never>
    }

    private var waiting: [Waiting] = []
    /// The rows of every lookup made, in order.
    private(set) var asked: [[ContainerID]] = []
    private(set) var invalidationCount = 0
    private var runningCount = 0
    /// The most lookups that were running at once.
    private(set) var peakRunningCount = 0

    var lookupCount: Int {
        asked.count
    }

    var waitingCount: Int {
        waiting.count
    }

    func lookup(_ rows: [PRStatusRow]) async -> PRStatusBatch {
        asked.append(rows.map(\.container))
        runningCount += 1
        peakRunningCount = max(peakRunningCount, runningCount)
        // A test that fails while a lookup waits cancels it on the way out;
        // answering then keeps the test from waiting out its time limit.
        let batch = await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append(Waiting(rows: rows, continuation: $0)) }
        } onCancel: {
            Task { await self.answerAll() }
        }
        runningCount -= 1
        return batch
    }

    func invalidate() {
        invalidationCount += 1
    }

    /// Answer the oldest lookup still waiting with `lookup` for every row it
    /// asked about, and `isQuotaLow` for its host.
    func answer(_ lookup: PRStatusFetcher.Lookup, isQuotaLow: Bool? = false) {
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        let lookups = Dictionary(next.rows.map { ($0.container, lookup) }, uniquingKeysWith: { first, _ in first })
        next.continuation.resume(returning: PRStatusBatch(lookups: lookups, isQuotaLow: isQuotaLow))
    }

    /// Answer the oldest lookup still waiting row by row; a row `lookups`
    /// does not name gets no answer.
    func answer(_ lookups: [ContainerID: PRStatusFetcher.Lookup]) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().continuation.resume(returning: PRStatusBatch(lookups: lookups, isQuotaLow: false))
    }

    private func answerAll() {
        while !waiting.isEmpty {
            answer(PRStatusFetcher.Lookup(isAnswered: false))
        }
    }
}
