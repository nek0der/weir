// Gate.swift
// Weir — a response the test holds until it says what the answer is.

import Foundation

/// Holds every caller of `wait()` until the test calls `open(with:)`, then
/// hands each of them, and every later caller, that value.
///
/// A test that has to act while a read, a send, or a listing is in flight
/// needs the call to stop where it is rather than after a wall-clock delay,
/// which is either too long or, on a busy machine, too short. The state sits
/// behind a lock rather than in an actor so that a stub on any actor, and a
/// synchronous `pollUntil` condition, can read it without a hop. Opening
/// before anyone waits is allowed: the value is kept, so the order of the
/// test's two steps cannot hang it.
final class Gate<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case closed
        case open(Value)
    }

    private let lock = NSLock()
    private var state = State.closed
    private var waiting: [CheckedContinuation<Value, Never>] = []
    private var requestCount = 0
    private var observerCount = 0

    /// How many callers have reached `wait()`, held or not.
    var requests: Int {
        lock.withLock { requestCount }
    }

    /// How many tasks passed the initial cancellation check and are observing calls.
    var observingCount: Int {
        lock.withLock { observerCount }
    }

    /// Returns the value the test opens with, at once if it already has.
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = lock.withLock {
                requestCount += 1
                if case let .open(value) = state {
                    return value
                }
                waiting.append(continuation)
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    struct RequestTimeout: Error, Equatable {
        let expected: Int
        let actual: Int
    }

    /// Waits for callers to reach the gate, failing when the deadline passes
    /// or this task is canceled. Callers still own releasing held responses,
    /// including when this prerequisite fails.
    func waitUntilRequested(_ count: Int = 1, timeout: Duration = .seconds(2)) async throws {
        let deadline = SuspendingClock.now + timeout
        try Task.checkCancellation()
        lock.withLock { observerCount += 1 }
        defer { lock.withLock { observerCount -= 1 } }
        while true {
            let actual = requests
            guard actual < count else { return }
            guard SuspendingClock.now < deadline else {
                throw RequestTimeout(expected: count, actual: actual)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Lets every held caller go with `value`, and every later one too.
    func open(with value: Value) {
        let held: [CheckedContinuation<Value, Never>] = lock.withLock {
            state = .open(value)
            defer { waiting = [] }
            return waiting
        }
        held.forEach { $0.resume(returning: value) }
    }

}

extension Gate where Value == Void {
    func open() {
        open(with: ())
    }

    /// Writes `start` and `end` around the wait, so a test can read in which
    /// order calls reached the gate and left it.
    func pass(_ name: String, loggingTo log: Recorded<[String]>) async {
        log.update { $0.append("start \(name)") }
        await wait()
        log.update { $0.append("end \(name)") }
    }
}
