// CwdEventProjectionTests.swift
// Weir — the host's half of the cwd events behind the worktree-move banner.
//
// Which moves are reported, and when, is the Rust rules' and is tested in
// `events.rs`. These check what the host adds: a reported move reaches
// `onCwdChanged`, and the files the rules sweep are removed from disk.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("CwdEventProjection")
struct CwdEventProjectionTests {
    private struct Move {
        let pane: UUID
        let newCwd: String
        let oldCwd: String?
    }

    private struct Harness {
        let adapter: AgentProjectionAdapter
        let session: WorkspaceSession
        let pane: UUID
        let events: URL
        /// Every cwd change the projection reported, in order.
        let moves: Recorded<[Move]>
    }

    private func harness(in root: URL) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let events = root.appendingPathComponent("cwd-events", isDirectory: true)
        for directory in [state, sessions, events] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let adapter = ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            cwdEvents: events,
            processStatus: { _ in .dead }
        )
        let moves = Recorded<[Move]>([])
        adapter.onCwdChanged = { pane, newCwd, oldCwd in moves.update { $0.append(Move(pane: pane, newCwd: newCwd, oldCwd: oldCwd)) } }
        return Harness(adapter: adapter, session: session, pane: pane, events: events, moves: moves)
    }

    private func write(
        _ harness: Harness,
        pane: UUID,
        newCwd: String = "/tmp/after",
        updatedAt: String,
        revision: Int? = nil
    ) throws {
        var record: [String: Any] = [
            "schemaVersion": 1,
            "paneId": pane.uuidString,
            "newCwd": newCwd,
            "oldCwd": "/tmp/before",
            "updatedAt": updatedAt
        ]
        record["revision"] = revision
        try SecureFileWrite.writeAtomic(
            JSONSerialization.data(withJSONObject: record),
            to: harness.events.appendingPathComponent(AgentRecordFixtures.cwdEventFileName(pane.uuidString))
        )
    }

    @Test("revisions distinguish same-second moves through the host and Rust bridge")
    func sameSecondMoves_dispatchOnceEach() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            let clock = { "2026-09-14T12:01:00Z" }
            // A legacy record at launch is remembered without announcing a move.
            try write(harness, pane: harness.pane, updatedAt: clock())
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())
            #expect(harness.moves.value.isEmpty)

            for (index, path) in ["/tmp/first", "/tmp/second", "/tmp/first"].enumerated() {
                try write(harness, pane: harness.pane, newCwd: path, updatedAt: clock(), revision: index + 1)
                harness.adapter.refresh()
                #expect(harness.moves.value.count == index + 1)
                #expect(harness.moves.value.last?.newCwd == path)
                #expect(harness.moves.value.last?.pane == harness.pane)
                harness.adapter.refresh()
                #expect(harness.moves.value.count == index + 1)
            }
            // An older helper can replace a revisioned record after a rollback.
            try write(harness, pane: harness.pane, newCwd: "/tmp/legacy", updatedAt: clock())
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 4)
            #expect(harness.moves.value.last?.newCwd == "/tmp/legacy")
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 4)
        }
    }

    private func exists(_ harness: Harness, pane: UUID) throws -> Bool {
        try FileManager.default.fileExists(
            atPath: harness.events.appendingPathComponent(AgentRecordFixtures.cwdEventFileName(pane.uuidString)).path
        )
    }

    @Test("a record with a new timestamp is reported exactly once")
    func freshRecord_dispatchesOnce() throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:01:00Z")
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 1)
            #expect(harness.moves.value.first?.pane == harness.pane)
            #expect(harness.moves.value.first?.newCwd == "/tmp/after")
            #expect(harness.moves.value.first?.oldCwd == "/tmp/before")
            #expect(try exists(harness, pane: harness.pane))

            // Freshness is the timestamp, not the file: another pass over the
            // same record does nothing even though the file is still there.
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 1)

            try write(harness, pane: harness.pane, newCwd: "/tmp/later", updatedAt: "2026-09-14T12:02:00Z")
            harness.adapter.refresh()
            #expect(harness.moves.value.count == 2)
            #expect(harness.moves.value.last?.pane == harness.pane)
            #expect(harness.moves.value.last?.newCwd == "/tmp/later")
        }
    }

    @Test("a pass drops closed panes' files and remembers live panes' moves", arguments: [nil, 1] as [Int?])
    func scan_cleansUpRecordsForClosedPanes(revision: Int?) throws {
        try withTempDir { root in
            let harness = try harness(in: root)
            let closed = UUID()
            try write(harness, pane: closed, updatedAt: "2026-09-14T12:00:00Z", revision: revision)
            try write(harness, pane: harness.pane, updatedAt: "2026-09-14T12:00:00Z", revision: revision)

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            #expect(try !exists(harness, pane: closed))
            #expect(try exists(harness, pane: harness.pane))
            // The startup pass remembers existing moves without offering them.
            #expect(harness.moves.value.isEmpty)
            harness.adapter.refresh()
            #expect(harness.moves.value.isEmpty)
        }
    }
}
