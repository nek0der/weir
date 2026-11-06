// VersionedListFile.swift
// Weir — a small JSON file of one versioned list that is gone while the list is empty.

import Foundation
import OSLog

/// The shape of a `VersionedListFile` on disk: a version and one list. Each
/// file names its list's key itself (`hints`, `turns`) through its own
/// `CodingKeys`, so the files already written keep reading.
protocol VersionedListDocument: Codable {
    associatedtype Element: Codable
    var schemaVersion: Int { get }
    var elements: [Element] { get }
    init(schemaVersion: Int, elements: [Element])
}

/// What one read of a `VersionedListFile` found.
struct VersionedListRead<Element> {
    /// The list, or none when there is no file, or the file this build
    /// could not use was moved aside or kept.
    var elements: [Element]
    /// Whether this launch may write the file. False while it keeps a file
    /// it could not use: one it could neither read nor move aside, or one a
    /// newer build wrote, which this build's shape could drop part of.
    var isWritable: Bool
    /// Whether the file is kept because it could not be read or decoded and
    /// could not be moved aside, which the person is told; a newer build's
    /// file is kept as a matter of course.
    var isKeptUnread: Bool

    static func usable(_ elements: [Element]) -> Self {
        Self(elements: elements, isWritable: true, isKeptUnread: false)
    }
}

/// Reads and writes a list that must outlive a relaunch but is not worth a
/// migration: the files that keep work still to finish
/// (`AgentForgottenHintFile`, `TurnDeletionFile`, `RestorePendingStopFile`).
///
/// One type for all of them, so how a missing, unreadable, or newer file reads,
/// and how an empty list removes the file, cannot drift between them.
struct VersionedListFile<Document: VersionedListDocument>: Sendable {
    let schemaVersion: Int
    /// What the list is, for the log (`ended session hints`).
    let label: String
    let log: Logger

    /// The elements `url` holds. Only a missing file holds none and may be
    /// written: a file that cannot be read, or does not decode as this
    /// version, is moved aside first, and one that cannot be moved, or that
    /// a newer build wrote, is kept as it is and not written this launch.
    /// Each holds work still to finish, which a write of this launch's list
    /// would replace.
    func read(_ url: URL) -> VersionedListRead<Document.Element> {
        let data: Data
        switch PersistedRead.read(url) {
        case .absent:
            return .usable([])
        case let .data(bytes):
            data = bytes
        case let .unreadable(error):
            log.error("\(label, privacy: .public) unreadable: \(String(describing: error), privacy: .private)")
            return keep(url, unless: SecureFileWrite.setAsideUnreadable(url))
        }
        if let found = (try? JSONDecoder().decode(Version.self, from: data))?.schemaVersion, found > schemaVersion {
            log.notice("\(label, privacy: .public) from a newer build; kept and not written")
            return VersionedListRead(elements: [], isWritable: false, isKeptUnread: false)
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == schemaVersion
        else {
            log.error("\(label, privacy: .public) do not decode")
            return keep(url, unless: SecureFileWrite.setAside(url, reason: "decode-failed"))
        }
        return .usable(document.elements)
    }

    /// No elements, and no writes this launch when the file stayed where
    /// it was.
    private func keep(_ url: URL, unless result: SecureFileWrite.SetAsideResult) -> VersionedListRead<Document.Element> {
        guard result == .keptInPlace else { return .usable([]) }
        log.error("\(label, privacy: .public) stay in place; not written this launch")
        return VersionedListRead(elements: [], isWritable: false, isKeptUnread: true)
    }

    /// The version alone, read before the rest so a newer build's file is
    /// told from one that does not decode.
    private struct Version: Decodable {
        let schemaVersion: Int
    }

    /// Writes `elements` to `url`, or removes the file when there are none.
    /// Returns whether the file now holds them; a failure is logged here.
    @discardableResult
    func write(_ elements: [Document.Element], to url: URL) -> Bool {
        do {
            if elements.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try SecureFileWrite.removeItem(at: url)
                }
                return true
            }
            let data = try JSONEncoder().encode(Document(schemaVersion: schemaVersion, elements: elements))
            SecureFileWrite.ensureUserOnlyDirectory(url.deletingLastPathComponent())
            try SecureFileWrite.writeAtomic(data, to: url)
            return true
        } catch {
            let reason = error.localizedDescription
            log.error("\(label, privacy: .public) not saved: \(reason, privacy: .private)")
            return false
        }
    }
}
