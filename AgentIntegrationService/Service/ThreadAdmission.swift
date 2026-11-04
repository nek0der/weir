// ThreadAdmission.swift
// Weir — a count of the service's requester threads, up to a limit.

import Foundation

/// Counts the requester threads running, up to a limit.
///
/// In a file of its own so the app target compiles it too, as it does
/// `RustApprovalHost.swift`, and its tests can reach it.
final class ThreadAdmission: @unchecked Sendable {
    // `@unchecked Sendable`: `running` is read and written only under `lock`.
    private let lock = NSLock()
    private let limit: Int
    private var running = 0

    init(limit: Int) {
        self.limit = limit
    }

    func admit() -> Bool {
        lock.withLock {
            guard running < limit else { return false }
            running += 1
            return true
        }
    }

    func release() {
        lock.withLock { running -= 1 }
    }
}
