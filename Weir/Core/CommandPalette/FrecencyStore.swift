// FrecencyStore.swift
// Weir — frequency + recency scoring for command palette items.
// Persisted to frecency.json with debounced writes following the
// same pattern as NotificationHistoryStore.

import Foundation
import OSLog

private let log = Logger.weir("frecency")

@MainActor
final class FrecencyStore {

    struct Entry: Codable {
        var count: Int
        var lastUsed: Date
    }

    /// Half-life of 3 days. An action used 3 days ago retains ~50%
    /// of its recency weight; after 2 weeks it's near zero.
    private static let halfLifeSeconds: Double = 259_200
    private static let decayFactor: Double = 0.693 / halfLifeSeconds

    /// Entries untouched for this long are dropped on load and before
    /// each write. Against a 3-day half-life a 30-day-old entry keeps
    /// roughly 0.1% of its recency weight, so dropping it cannot move a
    /// ranking.
    ///
    /// This is eviction, not tidiness. Keys are per-object identities
    /// (`tab.<uuid>`, `worktree.<projectID>.<worktreeID>`, `reopen.<uuid>`,
    /// …), and closing a tab or deleting a worktree does not remove the
    /// row — nothing did. The map is also persisted and reloaded every
    /// launch, so without an age bound both `frecency.json` and the
    /// in-memory dictionary grow for the life of the install. Aging it
    /// out here keeps the bound inside the store, so call sites that
    /// destroy objects do not each have to remember to clean up.
    private static let entryLifetime: TimeInterval = 30 * 24 * 60 * 60

    private(set) var entries: [String: Entry] = [:]
    private let fileURL: URL
    private let saveDebounce = DebouncedSave()
    private let saveQueue = DispatchQueue(label: "com.nekoder.weir.frecency")
    /// False in demo mode: what is used is ranked in memory only, and the
    /// person's own ranking is neither read nor written.
    private let writesFiles: Bool
    /// Set when a file that could not be read could not be moved aside
    /// either. Saving would then write over the only copy, so every save is
    /// skipped until the next launch tries again.
    private var isSavingSuspended = false

    convenience init(writesFiles: Bool) {
        self.init(directory: WeirPaths.applicationSupportDirectory(), writesFiles: writesFiles)
    }

    init(directory: URL, writesFiles: Bool = true) {
        self.writesFiles = writesFiles
        self.fileURL = directory.appendingPathComponent("frecency.json")
        if writesFiles {
            SecureFileWrite.ensureUserOnlyDirectory(directory)
            load()
        }
    }

    // MARK: - Scoring

    func score(for itemID: String, now: Date = .now) -> Double {
        guard let entry = entries[itemID] else { return 0 }
        let age = now.timeIntervalSince(entry.lastUsed)
        let recency = exp(-Self.decayFactor * max(age, 0))
        return Double(entry.count) * recency
    }

    // MARK: - Recording

    func record(_ itemID: String) {
        if var existing = entries[itemID] {
            existing.count += 1
            existing.lastUsed = .now
            entries[itemID] = existing
        } else {
            entries[itemID] = Entry(count: 1, lastUsed: .now)
        }
        scheduleSave()
    }

    // MARK: - Persistence

    func flushSynchronously() {
        // Nothing changed this launch: the file already holds the ranking.
        // Rows past their lifetime wait there for the next change, and the
        // next load drops them anyway.
        let hasChanges = saveDebounce.hasPending
        saveDebounce.cancel()
        guard writesFiles, !isSavingSuspended, hasChanges else { return }
        pruneExpired()
        let snapshot = entries
        let url = fileURL
        saveQueue.sync {
            Self.write(snapshot, to: url)
        }
    }

    private func load() {
        // No file yet is the first launch; a file that is there but cannot
        // be read is kept like one that does not decode.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.error("failed to read frecency.json: \(String(describing: error), privacy: .private)")
            setAside(reason: "read-failed")
            return
        }
        do {
            let decoder = PersistenceCoders.makeDecoder()
            entries = try decoder.decode([String: Entry].self, from: data)
            pruneExpired()
        } catch {
            log.error("failed to decode frecency.json: \(String(describing: error), privacy: .private)")
            setAside(reason: "decode-failed")
        }
    }

    /// The next `record` would otherwise write over the file with this
    /// launch's ranking alone. Move it aside first, as the other stores do,
    /// or stop saving when it cannot be moved.
    private func setAside(reason: String) {
        if SecureFileWrite.setAside(fileURL, reason: reason) == .keptInPlace {
            log.error("frecency.json stays in place; saving is suspended for this launch")
            isSavingSuspended = true
        }
    }

    /// Drop entries whose recency weight has decayed to nothing. Runs on
    /// load and before each write, which is often enough to bound the map
    /// and rare enough that the O(n) pass does not matter.
    private func pruneExpired(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.entryLifetime)
        entries = entries.filter { $0.value.lastUsed > cutoff }
    }

    private func scheduleSave() {
        // Not canceled first: `schedule` replaces the pending save and keeps
        // the burst's deadline, which a cancel would start over each time.
        guard writesFiles, !isSavingSuspended else { return }
        pruneExpired()
        let snapshot = entries
        let url = fileURL
        saveDebounce.schedule { [saveQueue] in
            saveQueue.async {
                Self.write(snapshot, to: url)
            }
        }
    }

    private nonisolated static func write(_ entries: [String: Entry], to url: URL) {
        do {
            let encoder = PersistenceCoders.makeEncoder()
            let data = try encoder.encode(entries)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("failed to write frecency.json: \(String(describing: error), privacy: .private)")
        }
    }
}
