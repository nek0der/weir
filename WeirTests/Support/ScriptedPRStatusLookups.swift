// ScriptedPRStatusLookups.swift
// Weir — a pull request fetcher whose every lookup waits until the test answers it.

import Foundation
@testable import Weir

/// A `PRStatusLookups` whose lookups wait until the test answers them, so a
/// test decides the order the answers land in, and reads which rows each
/// lookup asked about.
actor ScriptedPRStatusLookups: PRStatusLookups {
    private struct Waiting {
        let id: UUID
        let rows: [PRStatusRow]
        let continuation: CheckedContinuation<PRStatusBatch, Never>
    }

    private var waiting: [Waiting] = []
    private var isFinished = false
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
        let id = UUID()
        let batch = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isFinished || Task.isCancelled {
                    continuation.resume(returning: PRStatusBatch())
                } else {
                    waiting.append(Waiting(id: id, rows: rows, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelLookup(id) }
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

    /// Ends pending and future lookups with an empty batch.
    func finish() {
        isFinished = true
        let pending = waiting
        waiting.removeAll()
        for request in pending {
            request.continuation.resume(returning: PRStatusBatch())
        }
    }

    private func cancelLookup(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: PRStatusBatch())
    }
}

/// Releases the waiters a test started, including follow-ups that register
/// after the test exits.
@MainActor
func withPRStatusCleanup(
    clock: ManualPRStatusClock,
    lookups: ScriptedPRStatusLookups,
    perform: () async throws -> Void
) async throws {
    defer { clock.finish() }
    do {
        try await perform()
    } catch {
        await lookups.finish()
        throw error
    }
    await lookups.finish()
}
