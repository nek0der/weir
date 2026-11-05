// PersistedRead.swift
// Weir — reads a store's file and says whether it is absent, read, or there but unreadable.

import Foundation

/// What one read of a store's file found. Only a file that is not there is
/// absent: a file the read could not open for any other reason (its
/// permissions, a folder that cannot be searched, an I/O error) may still
/// hold the user's data, so a store must not treat it as a first launch and
/// later save its defaults over it.
enum PersistedRead {
    /// No file at the name: a first launch, or a file never saved yet.
    case absent
    case data(Data)
    /// There, or not provably gone, and not readable now.
    case unreadable(any Error)

    /// Reads `url` once. Absence is judged from the read's own error rather
    /// than a separate existence check, because a folder that cannot be
    /// searched makes that check answer no for a file that is there.
    static func read(_ url: URL) -> PersistedRead {
        do {
            return try .data(Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .unreadable(error)
        }
    }

    var isAbsent: Bool {
        if case .absent = self {
            return true
        }
        return false
    }

    /// The bytes read; nil when absent or unreadable.
    var data: Data? {
        if case let .data(data) = self {
            return data
        }
        return nil
    }
}
