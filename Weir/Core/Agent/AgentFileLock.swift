// AgentFileLock.swift
// Weir — the persistent-inode advisory lock shared by Swift and hook receivers.

import Foundation

enum RecordMutationOutcome: Equatable {
    case applied
    case notFound
    case preconditionChanged
    case busy
}

enum AgentFileLock {
    /// Thrown when the bridge could not say what the lock sidecar is called.
    /// A guessed name would be a lock no writer takes, so holding it would
    /// keep nobody out while we replace or delete their file.
    struct LayoutUnavailable: Error {}

    /// How many times a sidecar a sweep removed under us is opened again
    /// before the call reads as busy.
    private static let reopenLimit = 4

    /// Runs `body` while holding the lock every writer of `url` takes: the
    /// sidecar named by the layout's lock suffix.
    static func withLock(for url: URL, _ body: () throws -> RecordMutationOutcome) throws -> RecordMutationOutcome {
        guard let suffix = AgentProviderRegistry.recordLayout?.lockSuffix else { throw LayoutUnavailable() }
        let sidecar = url.path + suffix
        // Opening the sidecar creates it, so it is a write like any other.
        try TestWriteGuard.check(URL(fileURLWithPath: sidecar))
        for _ in 0..<reopenLimit {
            let fd = open(sidecar, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK {
                    return .busy
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { flock(fd, LOCK_UN) }
            // A sweep removes a sidecar whose file is gone, under its lock
            // (`weir_leftover_sweep_v1`). One we opened before then is a lock
            // no other writer takes, so we take the one now at the path.
            guard isAtPath(fd, sidecar) else { continue }
            return try body()
        }
        return .busy
    }

    /// Whether the open `fd` is still the file at `path`: the same inode,
    /// not one removed while we waited for its lock.
    static func isAtPath(_ fd: Int32, _ path: String) -> Bool {
        var opened = stat()
        var named = stat()
        guard fstat(fd, &opened) == 0, lstat(path, &named) == 0 else { return false }
        return opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }
}
