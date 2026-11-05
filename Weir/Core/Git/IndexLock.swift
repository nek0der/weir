// IndexLock.swift
// Weir — Git's lock on a worktree's index, taken and let go as Git does, for the carry to write the index in place.

import Foundation

/// Git's lock on an index, taken as Git takes it: `<index>.lock` made with
/// `O_EXCL`, so only one process holds it, then renamed over the index to
/// put a new one in place at once. Any Git that wants to write the index
/// meanwhile finds the lock and stops or waits.
///
/// Not `Sendable`: one task takes it, uses it, and lets it go.
final class IndexLock {
    let index: URL
    private let lock: URL
    /// The open lock file, closed by `commit` or `release`; -1 once closed.
    private var descriptor: Int32

    private init(index: URL, lock: URL, descriptor: Int32) {
        self.index = index
        self.lock = lock
        self.descriptor = descriptor
    }

    /// A lock never let go, as when the task holding it is torn down, is
    /// let go here, or every Git in the worktree would stop on it.
    deinit {
        release()
    }

    /// How long to wait for another Git to let the lock go: `git status`
    /// holds it a moment to refresh the index.
    static let patience: Duration = .seconds(2)

    /// `nil` when another holds the lock past `patience`, or `index` is no
    /// index: a lock beside a file that is not there guards nothing.
    static func acquire(for index: URL) async -> IndexLock? {
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let deadline = ContinuousClock.now + patience
        repeat {
            let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if descriptor >= 0 {
                return IndexLock(index: index, lock: lock, descriptor: descriptor)
            }
            guard errno == EEXIST else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return nil
    }

    /// The index at `next` written into the lock and renamed over the
    /// index, as Git puts a new index in place. `false` leaves the old
    /// index as it was.
    func commit(contentsOf next: URL) -> Bool {
        guard descriptor >= 0, let data = try? Data(contentsOf: next) else { return false }
        let isWritten = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return fsync(descriptor) == 0
        }
        close(descriptor)
        descriptor = -1
        guard isWritten, rename(lock.path, index.path) == 0 else {
            unlink(lock.path)
            return false
        }
        return true
    }

    /// Lets the lock go without changing the index, unless `commit` put a
    /// new one in place already.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        unlink(lock.path)
    }
}
