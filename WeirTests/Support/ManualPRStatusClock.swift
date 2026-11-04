// ManualPRStatusClock.swift
// Weir — a clock the pull request suites step by hand, so a gathering, a floor, or a rate limit's wait passes without sleeping.

import Foundation
@testable import Weir

/// A `PRStatusClock` whose time moves only when the test calls `advance`.
/// A sleeper wakes when the time reaches its deadline, and a canceled one
/// throws at once. The state sits behind a lock so the rate limiter, an
/// actor, can read the time without a hop.
final class ManualPRStatusClock: PRStatusClock, @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    deinit {
        // A sleeper left at the end of a suite is told it was canceled, so
        // its task ends rather than leaking its continuation.
        for sleeper in sleepers {
            sleeper.continuation.resume(throwing: CancellationError())
        }
    }

    func now() -> Date {
        lock.withLock { current }
    }

    /// How many tasks are asleep on this clock.
    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    /// The deadlines of the tasks asleep, earliest first.
    var deadlines: [Date] {
        lock.withLock { sleepers.map(\.deadline).sorted() }
    }

    func sleep(for interval: TimeInterval) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    let deadline = current.addingTimeInterval(interval)
                    guard deadline > current else { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on by `interval` and wakes every sleeper whose deadline
    /// it reached.
    func advance(by interval: TimeInterval) {
        let woken: [Sleeper] = lock.withLock {
            current = current.addingTimeInterval(interval)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in woken {
            sleeper.continuation.resume()
        }
    }
}
