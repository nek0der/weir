// TurnGarbageCollectorTests.swift
// Weir — deleting the turns the sweep chose, through the Rust bridge, off the main actor.

import Foundation
import Testing
@testable import Weir

@Suite("Turn garbage collector")
struct TurnGarbageCollectorTests {
    /// What becomes of each turn is the bridge's own rule
    /// (`each_turn_reports_what_became_of_it`); here, that its answer
    /// reaches Swift, read turn by turn.
    @Test func theBridgesAnswer_isReadTurnByTurn() throws {
        try withTempDir { directory in
            let missing = UUID().uuidString
            let invalid = "not a turn"
            let deletions = try WeirTurnBridge.deleteTurns([missing, invalid], in: directory)

            #expect(deletions.map(\.turnID) == [missing, invalid])
            #expect(deletions.map(\.outcome) == [.alreadyGone, .failed])
            #expect(deletions.map(\.reason) == [nil, .other("not a turn id")])
        }
    }

    /// What a sweep removes is the bridge's own rule (`leftovers` in the
    /// hook runtime); here, that its answer reaches Swift.
    @Test func theBridgesSweep_reportsWhatItRemoved() throws {
        try withTempDir { directory in
            FileManager.default.createFile(atPath: directory.appendingPathComponent("gone.json.flock").path, contents: nil)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("kept.json").path, contents: nil)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("kept.json.flock").path, contents: nil)

            let swept = try WeirTurnBridge.sweepLeftovers(in: [directory])

            #expect(swept == LeftoverSweep(sidecars: 1, temporaries: 0, counters: 0))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("gone.json.flock").path))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("kept.json").path))
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("kept.json.flock").path))
        }
    }

    @Test func theLaunchSweep_coversEveryDirectoryTheRecordsAreWrittenIn() throws {
        let root = URL(fileURLWithPath: "/states")
        let owner = AgentDirectories(
            state: root.appendingPathComponent("agent-states", isDirectory: true),
            sessions: root.appendingPathComponent("sessions", isDirectory: true),
            cwdEvents: root.appendingPathComponent("cwd-events", isDirectory: true)
        )

        let swept = AgentDirectories.leftoverSweep(of: [owner, owner])

        let expected = try [
            owner.state, owner.sessions, owner.retired,
            #require(owner.cwdEvents), #require(owner.worktreeEvents), #require(owner.turns)
        ]
        #expect(Set(swept) == Set(expected))
        #expect(swept.count == expected.count, "each directory once")
    }

    @Test func aBatchTheBridgeRefuses_reportsNoDeletions() async {
        struct Refused: Error {}
        let attempts = Recorded(0)
        let collector = TurnGarbageCollector(priority: .userInitiated) { _, _ in
            attempts.update { $0 += 1 }
            throw Refused()
        }

        let deletions = await collector.delete(["A"], in: URL(fileURLWithPath: "/nonexistent"))

        #expect(attempts.value == 1)
        #expect(deletions.isEmpty)
    }

    @Test func aBatch_reachesTheBridgeWithItsDirectory() async {
        let asked = Recorded<[(ids: [String], directory: URL)]>([])
        let collector = TurnGarbageCollector(priority: .userInitiated) { ids, directory in
            asked.update { $0.append((ids, directory)) }
            return ids.map { TurnDeletion(outcome: .deleted, turnID: $0, reason: nil, roots: nil) }
        }
        let directory = URL(fileURLWithPath: "/states/claude/turns")

        let deletions = await collector.delete(["A", "B"], in: directory)

        #expect(deletions.map(\.turnID) == ["A", "B"])
        #expect(deletions.map(\.outcome) == [.deleted, .deleted])
        #expect(asked.value.map(\.ids) == [["A", "B"]])
        #expect(asked.value.map(\.directory) == [directory])
    }

    @Test func aQueuedBatch_reachesTheBridge_andAnEmptyOneToo() async {
        let asked = Recorded<[(ids: [String], directory: URL)]>([])
        let collector = TurnGarbageCollector(priority: .userInitiated) { ids, directory in
            asked.update { $0.append((ids, directory)) }
            return []
        }

        // An empty batch finishes the deletions a quit cut short.
        let claude = URL(fileURLWithPath: "/states/claude/turns")
        let codex = URL(fileURLWithPath: "/states/codex/turns")
        collector.enqueue([], in: claude)
        collector.enqueue(["A"], in: codex)

        await pollUntilTurnsDeleted { asked.value.count == 2 }
        #expect(asked.value.count == 2)
        #expect(asked.value.first { $0.directory == claude }?.ids == [])
        #expect(asked.value.first { $0.directory == codex }?.ids == ["A"])
    }

    @Test func anOutcomeANewerBridgeAdded_doesNotFailTheBatch() throws {
        let data = Data(#"[{"outcome":"somethingNewer","turnId":"A"},{"outcome":"deleted","turnId":"B"}]"#.utf8)
        let deletions = try JSONDecoder().decode([TurnDeletion].self, from: data)
        #expect(deletions.map(\.turnID) == ["A", "B"])
        #expect(deletions.map(\.outcome) == [.unknown, .deleted])
    }

    /// Only a restore under way is acted on; any other reason is kept as the
    /// bridge spelled it, for the log.
    @Test func aRestoreUnderWay_isReadFromTheReason() throws {
        let data = Data(#"""
        [{"outcome":"failed","turnId":"A","reason":"restoreInProgress"},
         {"outcome":"failed","turnId":"B","reason":"moving the record failed"},
         {"outcome":"deleted","turnId":"C"}]
        """#.utf8)
        let deletions = try JSONDecoder().decode([TurnDeletion].self, from: data)
        #expect(deletions.map(\.reason) == [.restoreInProgress, .other("moving the record failed"), nil])
        #expect(deletions[1].reason?.text == "moving the record failed")
    }
}
