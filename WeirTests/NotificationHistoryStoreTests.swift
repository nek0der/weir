// NotificationHistoryStoreTests.swift
// Weir — the notification history store: ordering, unread bookkeeping,
// pane-scoped mark-read, capacity ceiling, per-id delete, and what a row
// keeps on disk. Each test injects an isolated temporary directory via
// `init(directory:)`: the app's `init(writesFiles:)` uses Weir's data
// folder rather than one of the test's own, and `clearAll()` would empty it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("NotificationHistoryStore")
@MainActor
struct NotificationHistoryStoreTests {

    // MARK: - Demo mode

    @Test("demo mode neither reads nor writes the history")
    func demoMode_readsAndWritesNothing() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let real = NotificationHistoryStore(directory: dir)
            real.record(NotificationEntry.test(title: "real"))
            real.flushSynchronously()
            let onDisk = try Data(contentsOf: file)

            let demo = NotificationHistoryStore(directory: dir, writesFiles: false)
            #expect(demo.entries.isEmpty, "a demo's screenshot shows none of the person's rows")
            demo.record(NotificationEntry.test(title: "demo"))
            demo.markAllRead()
            demo.flushSynchronously()
            #expect(try Data(contentsOf: file) == onDisk)
        }
    }

    // MARK: - record / ordering

    @Test("record prepends entries so the newest is at index 0")
    func record_putsNewestEntryFirst() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let first = NotificationEntry.test(title: "first")
            let second = NotificationEntry.test(title: "second")
            store.record(first)
            store.record(second)
            #expect(store.entries == [second, first])
        }
    }

    @Test("recording past the cap drops the oldest entries")
    func record_pastCap_dropsOldestEntries() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for i in 0..<600 {
                store.record(NotificationEntry.test(title: "n\(i)"))
            }
            let expected = (100..<600).reversed().map { "n\($0)" }
            #expect(store.entries.map(\.title) == expected)
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries.map(\.title) == expected)
        }
    }

    // MARK: - unreadCount

    @Test("unreadCount tracks freshly-recorded (unread) entries")
    func unreadCount_tracksRecordedEntries() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            #expect(store.unreadCount == 0)
            store.record(NotificationEntry.test())
            store.record(NotificationEntry.test(isRead: true))
            store.record(NotificationEntry.test())
            #expect(store.unreadCount == 2)
        }
    }

    // MARK: - markRead

    @Test("markRead(_:) on a known id flips that entry to read")
    func markRead_knownID_flipsToRead() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            var target = NotificationEntry.test(timestamp: Date(timeIntervalSince1970: 100), title: "target")
            let other = NotificationEntry.test(timestamp: Date(timeIntervalSince1970: 100), title: "other")
            store.record(target)
            store.record(other)
            store.flushSynchronously()
            try #require(NotificationHistoryStore(directory: dir).entries == [other, target])
            store.markRead(target.id)
            target.isRead = true
            #expect(store.entries == [other, target])
            #expect(store.unreadCount == 1)
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries == [other, target])
        }
    }

    @Test("markRead(_:) on an unknown id is a no-op")
    func markRead_unknownID_isNoOp() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test())
            let before = store.entries
            store.markRead(UUID())
            #expect(store.entries == before)
        }
    }

    @Test("markAllRead clears every unread entry in one pass")
    func markAllRead_clearsAllUnread() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let entries = [
                NotificationEntry.test(kind: .commandFinished, timestamp: Date(timeIntervalSince1970: 100)),
                NotificationEntry.test(kind: .agentNeedsInput, timestamp: Date(timeIntervalSince1970: 100)),
                NotificationEntry.test(kind: .desktop, timestamp: Date(timeIntervalSince1970: 100), isRead: true)
            ]
            for entry in entries {
                store.record(entry)
            }
            store.flushSynchronously()
            try #require(NotificationHistoryStore(directory: dir).entries == Array(entries.reversed()))
            let expected = entries.reversed().map { entry in
                var read = entry
                read.isRead = true
                return read
            }
            store.markAllRead()
            #expect(store.unreadCount == 0)
            #expect(store.entries == expected)
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries == expected)
        }
    }

    @Test("markRead(forPanes:) only flips entries whose paneID is in the set")
    func markRead_forPanes_onlyAffectsMatchingPanes() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let paneA = UUID()
            let paneB = UUID()
            let paneC = UUID()
            store.record(NotificationEntry.test(paneID: paneA))
            store.record(NotificationEntry.test(paneID: paneB))
            store.record(NotificationEntry.test(paneID: paneC))
            let unscoped = NotificationEntry.test(paneID: nil)
            store.record(unscoped)

            store.markRead(forPanes: [paneA, paneB])

            let byPane = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.paneID, $0.isRead) })
            #expect(byPane[paneA] == true)
            #expect(byPane[paneB] == true)
            #expect(byPane[paneC] == false)
            #expect(store.entries.first { $0.id == unscoped.id } == unscoped)
        }
    }

    @Test("markRead(forPanes:) leaves every agent row to runtime reconciliation")
    func markRead_forPanes_keepsAgentRowsUnread() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let paneID = UUID()
            store.record(NotificationEntry.test(kind: .agentFinished, paneID: paneID))
            store.record(NotificationEntry.test(kind: .agentNeedsInput, paneID: paneID))
            store.record(NotificationEntry.test(kind: .agentError, paneID: paneID))

            store.markRead(forPanes: [paneID])

            #expect(store.entries.first { $0.kind == .agentFinished }?.isRead == false)
            #expect(store.entries.first { $0.kind == .agentNeedsInput }?.isRead == false)
            #expect(store.entries.first { $0.kind == .agentError }?.isRead == false)
            #expect(store.unreadCount == 3)
        }
    }

    // MARK: - delete / clearAll

    @Test("delete removes the matching entry from the list")
    func delete_knownID_removesEntry() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let id = UUID()
            store.record(NotificationEntry.test(id: id))
            store.record(NotificationEntry.test())
            store.delete(id)
            #expect(store.entries.count == 1)
            #expect(store.entries.contains { $0.id == id } == false)
        }
    }

    @Test("delete on an unknown id is a no-op")
    func delete_unknownID_isNoOp() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test())
            let before = store.entries
            store.delete(UUID())
            #expect(store.entries == before)
        }
    }

    @Test("clearAll empties the list and resets unreadCount")
    func clearAll_emptiesEverything() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for _ in 0..<3 {
                store.record(NotificationEntry.test())
            }
            store.flushSynchronously()
            try #require(NotificationHistoryStore(directory: dir).entries.count == 3)
            store.clearAll()
            #expect(store.entries.isEmpty)
            #expect(store.unreadCount == 0)
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries.isEmpty)
        }
    }

    @Test("markRead(where:) flips only the matching unread entries")
    func markReadWhere_flipsMatchingEntries() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            let other = NotificationEntry.test(kind: .commandFinished, timestamp: Date(timeIntervalSince1970: 100))
            var target = NotificationEntry.test(kind: .agentNeedsInput, timestamp: Date(timeIntervalSince1970: 100))
            let alreadyRead = NotificationEntry.test(kind: .agentNeedsInput, timestamp: Date(timeIntervalSince1970: 100), isRead: true)
            for entry in [other, target, alreadyRead] {
                store.record(entry)
            }
            store.flushSynchronously()
            try #require(NotificationHistoryStore(directory: dir).entries == [alreadyRead, target, other])

            store.markRead { $0.kind == .agentNeedsInput }
            target.isRead = true
            #expect(store.unreadCount == 1)
            #expect(store.entries == [alreadyRead, target, other])
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries == [alreadyRead, target, other])
        }
    }

    @Test("request and container keys persist, and older rows can omit them")
    func requestAndContainerKeys_roundTripAndDecodeWhenAbsent() throws {
        let key = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
        let project = UUID()
        let worktree = UUID()
        let entry = NotificationEntry.test(
            kind: .agentNeedsInput,
            timestamp: Date(timeIntervalSince1970: 0),
            containerLabel: "project / branch",
            containerID: .worktree(projectID: project, worktreeID: worktree),
            title: "t",
            body: "b",
            runtimeID: "claude:abc",
            requestKey: key
        )
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(entry)
            store.flushSynchronously()

            let data = try Data(contentsOf: dir.appendingPathComponent("notifications.json"))
            let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            try #require(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row["requestKey"] as? [String: String] == [
                "epoch": key.epoch.uuidString, "runID": key.runID.uuidString, "requestID": key.requestID.uuidString
            ])
            #expect(row["containerID"] as? [String: [String: String]] == [
                "worktree": ["projectID": project.uuidString, "worktreeID": worktree.uuidString]
            ])
            #expect(NotificationHistoryStore(directory: dir).entries == [entry])
        }
        try withTempDir { dir in
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"agentNeedsInput","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false,"runtimeID":"claude:abc","containerLabel":"Quick Tabs"}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let legacy = try #require(NotificationHistoryStore(directory: dir).entries.first)
            #expect(legacy.requestKey == nil)
            #expect(legacy.containerID == nil)
            #expect(legacy.containerLabel == "Quick Tabs")
            #expect(legacy.runtimeID == "claude:abc")
        }
    }

    @Test("runtime identity survives a disk round-trip and event tokens are optional on decode")
    func runtimeIdentity_roundTripsAndEventTokenDecodesWhenAbsent() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test(
                kind: .agentFinished,
                title: "t",
                body: "b",
                runtimeID: "codex:abc",
                eventToken: "42"
            ))
            store.flushSynchronously()
            let reloaded = NotificationHistoryStore(directory: dir)
            #expect(reloaded.entries.first?.runtimeID == "codex:abc")
            #expect(reloaded.entries.first?.eventToken == "42")
        }
        try withTempDir { dir in
            // A pre-`runtimeID` file has no such key at all.
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"desktop","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let store = NotificationHistoryStore(directory: dir)
            let legacy = try #require(store.entries.first)
            #expect(legacy.runtimeID == nil)
            #expect(legacy.eventToken == nil)
        }
        try withTempDir { dir in
            // Runtime identity shipped before event identity. Keep that
            // intermediate shape readable without guessing which later
            // waiting episode it belongs to.
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"agentNeedsInput","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false,"runtimeID":"codex:abc"}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let store = NotificationHistoryStore(directory: dir)
            let legacyAgent = try #require(store.entries.first)
            #expect(legacyAgent.runtimeID == "codex:abc")
            #expect(legacyAgent.eventToken == nil)
        }
    }

    // MARK: - Events on disk

    @Test func aHistoryWithAnUnreadableEvent_loadsWhole() throws {
        try withTempDir { dir in
            let unknown = UUID()
            let known = UUID()
            let date = try #require(ISO8601DateFormatter().date(from: "2026-10-18T00:00:00Z"))
            let json = """
            [
              {"id":"\(unknown.uuidString)","kind":"agentNeedsInput","timestamp":"2026-10-18T00:00:00Z",\
              "title":"New event","body":"Recorded fallback","isRead":true,"event":{"type":"hologram","agent":"claude"}},
              {"id":"\(known.uuidString)","kind":"agentNeedsInput","timestamp":"2026-10-18T00:00:00Z",\
              "title":"Waiting","body":"Read notes","isRead":false,\
              "event":{"type":"wait","agent":"claude","wait":"approval","fact":"notes.txt"}}
            ]
            """
            let file = dir.appendingPathComponent("notifications.json")
            let bytes = Data(json.utf8)
            try bytes.write(to: file)

            let store = NotificationHistoryStore(directory: dir)
            #expect(store.entries == [
                .test(id: unknown, kind: .agentNeedsInput, timestamp: date, title: "New event", body: "Recorded fallback", isRead: true),
                .test(
                    id: known, kind: .agentNeedsInput, timestamp: date, title: "Waiting", body: "Read notes",
                    event: .wait(agent: .claude, wait: .approval, fact: "notes.txt")
                )
            ])
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func everyEvent_roundTripsThroughDisk() throws {
        let turn = NotificationEvent.Turn(
            number: 4,
            changes: .changed(files: 2, added: 94, removed: 0),
            check: CheckSummary(command: "swift test", isFiltered: true, exitCode: 1, earlierFailures: 2)
        )
        let events: [NotificationEvent] = [
            .wait(agent: .claude, wait: .approval, fact: "notes.txt"),
            .wait(agent: .codex, wait: .response, fact: nil),
            .turnFinished(
                agent: .claude,
                turn: turn,
                prompt: "Add the tests",
                promptKind: .text,
                reply: "Added two tests; one still fails."
            ),
            .turnFinished(
                agent: .codex,
                turn: .init(number: 1, changes: .unavailable(reason: "endMissing"), check: nil),
                prompt: nil,
                promptKind: .subagentMessage,
                reply: nil
            ),
            .stopped(agent: .claude, reason: "Rate limited")
        ]
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            for event in events {
                store.record(NotificationEntry.test(event: event))
            }
            store.flushSynchronously()
            #expect(NotificationHistoryStore(directory: dir).entries.map(\.event) == events.reversed())
        }
    }

    // MARK: - Kind decoding

    @Test("an unknown kind on disk decodes to .desktop instead of quarantining the file")
    func load_unknownKind_fallsBackToDesktop() throws {
        try withTempDir { dir in
            // Shape a newer build might write: one row whose kind this
            // build has never heard of. Without the defensive decoder the
            // whole array fails and `load()` moves the file aside.
            let json = """
            [{"id":"\(UUID().uuidString)","kind":"holographic","timestamp":"2026-09-12T00:00:00Z",\
            "title":"t","body":"b","isRead":false}]
            """
            try Data(json.utf8).write(to: dir.appendingPathComponent("notifications.json"))
            let store = NotificationHistoryStore(directory: dir)
            #expect(store.entries.count == 1)
            #expect(store.entries.first?.kind == .desktop)
        }
    }

    @Test("agent kinds round-trip through disk and map to their AgentState")
    func agentKinds_roundTripAndMapToState() throws {
        try withTempDir { dir in
            let store = NotificationHistoryStore(directory: dir)
            store.record(NotificationEntry.test(kind: .agentNeedsInput))
            store.record(NotificationEntry.test(kind: .agentFinished))
            store.record(NotificationEntry.test(kind: .agentError))
            store.flushSynchronously()
            let reloaded = NotificationHistoryStore(directory: dir)
            #expect(reloaded.entries.map(\.kind) == [.agentError, .agentFinished, .agentNeedsInput])
        }
        #expect(NotificationEntry.Kind.agentNeedsInput.agentState == .needsInput)
        #expect(NotificationEntry.Kind.agentFinished.agentState == .finished)
        #expect(NotificationEntry.Kind.agentError.agentState == .error)
        #expect(NotificationEntry.Kind.commandFinished.agentState == nil)
        #expect(NotificationEntry.Kind.desktop.agentState == nil)
    }

    // MARK: - A file that cannot be read

    // The history's own file, read and moved aside as the settings file is
    // (`SettingsStoreMigrationTests`).

    @Test(.disabled(if: geteuid() == 0, "root reads files without read permission"))
    func aHistoryThatCannotBeRead_isMovedAside_notSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let original = Data(#"[{"unreadableOriginal":"preserve these bytes"}]"#.utf8)
            try original.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

            let history = NotificationHistoryStore(directory: dir)
            let entry = NotificationEntry.test(kind: .bell, title: "make", body: "")
            history.record(entry)
            history.flushSynchronously()

            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let backup = try dir.appendingPathComponent(#require(names.first {
                $0.hasPrefix("notifications.json.bak-read-failed-")
            }))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            #expect(try Data(contentsOf: backup) == original)
            #expect(NotificationHistoryStore(directory: dir).entries.map(\.id) == [entry.id])
        }
    }

    @Test func aHistoryThatDoesNotDecode_isMovedAside_andNewEntriesAreSaved() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let garbled = Data(#"[ { "broken": "#.utf8)
            try garbled.write(to: file)

            let history = NotificationHistoryStore(directory: dir)
            let entry = NotificationEntry.test(kind: .bell, title: "make", body: "")
            history.record(entry)
            history.flushSynchronously()

            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let backup = try #require(names.first { $0.hasPrefix("notifications.json.bak-decode-failed-") })
            #expect(try Data(contentsOf: dir.appendingPathComponent(backup)) == garbled)
            #expect(NotificationHistoryStore(directory: dir).entries.map(\.id) == [entry.id])
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func anUnreadableHistory_thatCannotBeMovedAside_isNeverSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notifications.json")
            let garbled = Data(#"[ { "broken": "#.utf8)
            try garbled.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let history = NotificationHistoryStore(directory: dir)
            try #require(history.suspendedFile == file)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [file.lastPathComponent])
            // A rejected write must not hide a missing saving suspension.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            history.record(NotificationEntry.test(kind: .bell, title: "make", body: ""))
            history.flushSynchronously()
            #expect(try Data(contentsOf: file) == garbled)
        }
    }

    /// A folder that cannot be searched hides the file in it, which is not
    /// a first launch: the check that a file exists answers no there too.
    /// Saving stops, and says so, so a save once the folder opens up again
    /// cannot replace the file with what this launch recorded.
    @Test func aHistoryInAFolderThatCannotBeSearched_isNeverSavedOver() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("notifications.json")
            let original = Data("[]".utf8)
            try original.write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let history = NotificationHistoryStore(directory: dir)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            history.record(NotificationEntry.test(kind: .bell, title: "make", body: ""))
            history.flushSynchronously()

            #expect(try Data(contentsOf: file) == original)
            #expect(history.suspendedFile == file)
        }
    }

    /// No file at all is a first launch: nothing is suspended, and the
    /// first save writes the file.
    @Test func noHistoryFile_isAFirstLaunch_andSaves() throws {
        try withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            history.record(NotificationEntry.test(kind: .bell, title: "make", body: ""))
            history.flushSynchronously()

            #expect(history.suspendedFile == nil)
            #expect(NotificationHistoryStore(directory: dir).entries.count == 1)
        }
    }
}
