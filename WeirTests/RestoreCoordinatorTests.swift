// RestoreCoordinatorTests.swift
// Weir — restores and their undo through the Rust bridge against a real repository, and the journals the app keeps.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct RestoreCoordinatorTests {
    /// A repository whose `a.txt` and `b.txt` changed after a turn began, and the turn,
    /// recorded the way the hook records one.
    private struct Scene {
        let repo: TempGitRepo
        let root: String
        let states: URL
        let turn: TurnSummary
        let coordinator: RestoreCoordinator

        var index: URL {
            URL(fileURLWithPath: root).appendingPathComponent(".git/index")
        }

        func contents(_ name: String = "a.txt") throws -> String {
            try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name), encoding: .utf8)
        }

        func cleanup() {
            repo.cleanup()
        }
    }

    /// The scene, with the agent's state directory at `states`.
    private static func scene(states: URL) async throws -> Scene {
        let repo = try await TempGitRepo.make()
        var didBuildScene = false
        defer {
            if !didBuildScene {
                repo.cleanup()
            }
        }
        try repo.write("a\n", to: "a.txt")
        try repo.write("b\n", to: "b.txt")
        try await repo.git(["add", "a.txt", "b.txt"])
        try await repo.git(["commit", "-q", "-m", "a"])
        let root = try await repo.git(["rev-parse", "--show-toplevel"])
        let tree = try await repo.git(["rev-parse", "HEAD^{tree}"])
        let head = try await repo.git(["rev-parse", "HEAD"])
        let turns = states.appendingPathComponent("turns")
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let turnID = UUID().uuidString.uppercased()
        let record = """
        {"schemaVersion":1,"turnId":"\(turnID)","provider":"claude",
         "conversation":{"provider":"claude","conversationId":"s1","isFallback":false},
         "runId":"R","paneId":"P","displayNumber":7,"startedAt":"2026-10-13T00:00:00Z","phase":"finished",
         "gitContext":{"head":"\(head)","branch":"main","root":"\(root)"},
         "begin":{"kind":"captured","tree":"\(tree)","root":"\(root)"},"end":{"kind":"pending"},
         "changes":{"kind":"unchanged"}}
        """
        try record.write(to: turns.appendingPathComponent("\(turnID).turn.json"), atomically: true, encoding: .utf8)
        for name in ["a", "b"] {
            let file = URL(fileURLWithPath: root).appendingPathComponent("\(name).txt")
            try "\(name)\nchanged\n".write(to: file, atomically: true, encoding: .utf8)
        }
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: tree, root: root)
        let turn = try TurnSummaryFixture.turn(turnID, number: 7, extras: extras)
        let coordinator = RestoreCoordinator(stateDirectories: [RestoreStateDirectory(provider: .claude, directory: states)])
        didBuildScene = true
        return Scene(repo: repo, root: root, states: states, turn: turn, coordinator: coordinator)
    }

    private static func journal(_ outcome: RestoreOutcome?) throws -> RestoreJournal {
        guard case let .finished(journal) = outcome else { throw CocoaError(.coderInvalidValue) }
        return journal
    }

    /// A restore is refused while an agent of the worktree runs, which the
    /// coordinator reads from the state directories it is given; once none
    /// does, the restore and its undo move the working tree and the records.
    @Test(.tags(.smoke, .slow)) func restore_isRefusedWhileAnAgentRuns_thenItAndItsUndoMoveTheTreeAndTheRecords() async throws {
        try await withTempDir { states in
            let scene = try await Self.scene(states: states)
            defer { scene.cleanup() }
            let coordinator = scene.coordinator
            try scene.repo.write("a\nstaged\n", to: "a.txt")
            try await scene.repo.git(["add", "a.txt"])
            try scene.repo.write("a\nchanged\n", to: "a.txt")
            let originalIndex = try Data(contentsOf: scene.index)
            let running = scene.states.appendingPathComponent("R2.state.json")
            try """
            {"schemaVersion":3,"paneId":"P2","runId":"R2","revision":1,"state":"running",
             "updatedAt":"2026-10-13T00:00:00Z","turnRoot":"\(scene.root)"}
            """.write(to: running, atomically: true, encoding: .utf8)

            #expect(await coordinator.restore(scene.turn) == .refused(.agentActive(.claude)))
            #expect(try scene.contents() == "a\nchanged\n")
            #expect(try scene.contents("b.txt") == "b\nchanged\n")
            #expect(try Data(contentsOf: scene.index) == originalIndex)
            #expect(coordinator.latestUndoable(in: scene.root) == nil)
            try FileManager.default.removeItem(at: running)

            let restored = try await Self.journal(coordinator.restore(scene.turn))
            #expect(restored.stage == .applied)
            #expect(try scene.contents() == "a\n")
            #expect(try scene.contents("b.txt") == "b\n")
            #expect(try Data(contentsOf: scene.index) == originalIndex)
            #expect(coordinator.latestUndoable(in: scene.root) == restored)
            #expect(restored.turnNumber == 7, "the record names the turn by its own copy of the number")
            #expect(!coordinator.isBusy(scene.root))

            let undo = try await Self.journal(coordinator.undo(restored))
            #expect(undo.stage == .applied)
            #expect(undo.undoes == restored.opID)
            #expect(try scene.contents() == "a\nchanged\n")
            #expect(try scene.contents("b.txt") == "b\nchanged\n")
            #expect(try Data(contentsOf: scene.index) == originalIndex)
            #expect(coordinator.latestUndoable(in: scene.root) == nil)
            #expect(coordinator.journals[scene.root]?.first { $0.opID == restored.opID }?.stage == .undone(by: undo.opID))
        }
    }

    /// A restore a quit cut short is told of when the journals are read at
    /// launch, once, and is kept as the worktree's undoable restore. How the
    /// bridge classifies the journal is its own tests' subject
    /// (`recover_classifies_interrupted_journal`).
    @Test(.tags(.smoke, .slow)) func recover_settlesARestoreCutShort() async throws {
        try await withTempDir { states in
            let scene = try await Self.scene(states: states)
            defer { scene.cleanup() }
            let restored = try await Self.journal(scene.coordinator.restore(scene.turn))
            // As a quit leaves it: still writing.
            let file = URL(fileURLWithPath: scene.root).appendingPathComponent(".git/weir/restores/\(restored.opID).json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["stage"] = ["kind": "writing", "done": [String]()]
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            // One path written, the other not yet: the restore stopped partway.
            let other = URL(fileURLWithPath: scene.root).appendingPathComponent("b.txt")
            try "b\nchanged\n".write(to: other, atomically: true, encoding: .utf8)

            #expect(try scene.contents() == "a\n")
            #expect(try scene.contents("b.txt") == "b\nchanged\n")
            let coordinator = RestoreCoordinator(stateDirectories: [])
            let report = await coordinator.recover(roots: [scene.repo.url.path])

            let settled = try #require(coordinator.latestUndoable(in: scene.root))
            #expect(settled.opID == restored.opID)
            #expect(settled.stage == .partiallyApplied(reason: .interrupted, kept: [], failed: []))
            #expect(report.stops == [RestoreCoordinator.RecoveredStop(settled: settled, undoable: settled)])
            #expect(report.unsettledRoots.isEmpty)
            #expect(try scene.contents() == "a\n")
            #expect(try scene.contents("b.txt") == "b\nchanged\n")

            let again = await coordinator.recover(roots: [scene.repo.url.path])
            #expect(again == RestoreCoordinator.RecoveryReport())
            #expect(coordinator.latestUndoable(in: scene.root) == settled)
            #expect(try WeirRestoreBridge.recover(root: scene.root) == RestoreRecovery(journals: [settled], settled: []))
        }
    }

    /// Journals that are there but cannot be read are no empty list, from
    /// Rust through the bridge to the coordinator: the reading says it is
    /// incomplete, the restore known stays undoable, the worktree stays
    /// marked, and it is read again, as one a hook kept locked is.
    @Test(.tags(.slow), .enabled(if: geteuid() != 0))
    func journalsThatCannotBeRead_areAnIncompleteReading_notNone() async throws {
        try await withTempDir { states in
            let scene = try await Self.scene(states: states)
            defer { scene.cleanup() }
            let restored = try await Self.journal(scene.coordinator.restore(scene.turn))
            let journals = URL(fileURLWithPath: scene.root).appendingPathComponent(".git/weir/restores")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journals.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journals.path) }

            try #require(throws: (any Error).self) {
                try FileManager.default.contentsOfDirectory(atPath: journals.path)
            }
            let reading = try WeirRestoreBridge.recover(root: scene.root)
            #expect(reading == RestoreRecovery(journals: [], settled: [], isIncomplete: true))
            let report = await scene.coordinator.recover(roots: [scene.root])

            #expect(report.unsettledRoots == [scene.root])
            #expect(scene.coordinator.incompleteRoots == [scene.root])
            #expect(scene.coordinator.latestUndoable(in: scene.root) == restored)

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journals.path)
            let complete = await scene.coordinator.recover(roots: [scene.root])
            #expect(complete.unsettledRoots.isEmpty)
            #expect(scene.coordinator.incompleteRoots.isEmpty)
            #expect(scene.coordinator.latestUndoable(in: scene.root) == restored)
        }
    }

    /// An incomplete reading at launch is taken in for what it read: the
    /// discard it settled is told with Undo and the restore it read is
    /// offered, while the worktree stays marked and is read again. A later
    /// incomplete reading that leaves the restore out does not drop it; a
    /// whole one stands for every journal there is, and clears the mark.
    @Test func anIncompleteReading_takesInWhatItRead_andKeepsTheRest() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let later = "2026-10-13T00:01:00Z"
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: Self.cutShort, operation: "discard", ranAt: later)
        let updated = try Self.decodedJournal(root: "/repo", opID: "D", operation: "discard", ranAt: later)
        let readings = Recorded([
            RestoreRecovery(journals: [discard, restore], settled: ["D"], isIncomplete: true),
            RestoreRecovery(journals: [updated], settled: [], isIncomplete: true),
            RestoreRecovery(journals: [updated], settled: [], isIncomplete: false)
        ])
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in
                var next: RestoreRecovery?
                readings.update { next = $0.isEmpty ? nil : $0.removeFirst() }
                guard let next else { throw WeirRestoreBridgeError.rust(-1) }
                return next
            }
        ))
        // Only the whole reading is heard: what a restore keeps while it can
        // be undone must not go for a journal a reading could not read.
        let heard = Recorded<[[String]]>([])
        coordinator.onWholeReading = { root, journals in
            heard.update { $0.append([root] + journals.map(\.opID)) }
        }

        let first = await coordinator.recover(roots: ["/repo"])
        #expect(first.stops == [RestoreCoordinator.RecoveredStop(settled: discard, undoable: discard)])
        #expect(first.unsettledRoots == ["/repo"])
        #expect(coordinator.journals["/repo"] == [restore, discard])
        #expect(coordinator.incompleteRoots == ["/repo"])
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")

        let second = await coordinator.recover(roots: ["/repo"])
        #expect(second.interrupted.isEmpty)
        #expect(second.unsettledRoots == ["/repo"])
        #expect(coordinator.journals["/repo"] == [restore, updated])
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")

        let whole = await coordinator.recover(roots: ["/repo"])
        #expect(whole.unsettledRoots.isEmpty)
        #expect(coordinator.incompleteRoots.isEmpty)
        #expect(coordinator.journals["/repo"] == [updated])
        #expect(coordinator.latestUndoable(in: "/repo") == nil)
        #expect(heard.value == [["/repo", "D"]])
    }

    enum Contender: CaseIterable, Sendable {
        case restore, undo, discard
    }

    /// Hold the first bridge call until the contender returns, or release
    /// it on the test deadline so a broken guard cannot hang the runner.
    @Test(arguments: Contender.allCases)
    func anOperationUnderWay_keepsAnotherFromStarting(contender: Contender) async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = Recorded<[String]>([])
        let released = Recorded(false)
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in
                calls.update { $0.append("restore") }
                if calls.value == ["restore"] {
                    released.value = release.wait(timeout: .now() + 10) == .success
                }
                return .refused(.agentRecording)
            },
            undo: { _, _, _ in
                calls.update { $0.append("undo") }
                return .refused(.unknown)
            },
            recover: { _ in
                calls.update { $0.append("recover") }
                return RestoreRecovery(journals: [], settled: [])
            },
            discard: { _, _ in
                calls.update { $0.append("discard") }
                return .finished(nil, [])
            }
        ))
        let turn = try TurnSummaryFixture.restorable(1)
        let journal = try Self.decodedJournal(root: "/repo")
        let range = try TurnSummaryFixture.range()
        let call = RestoreCoordinator.DiscardCall(range: range, lastTurnNumber: 1, paneID: "P", files: [])
        try #require(range.root == journal.root && turn.beginTree?.root == journal.root)

        let first = Task { await coordinator.restore(turn) }
        await pollUntil(timeout: .seconds(5)) { calls.value == ["restore"] }
        try #require(calls.value == ["restore"] && coordinator.isBusy("/repo"))
        let refused = Recorded<Bool?>(nil)
        let second = Task {
            switch contender {
            case .restore: refused.value = await coordinator.restore(turn) == nil
            case .undo: refused.value = await coordinator.undo(journal) == nil
            case .discard: refused.value = await coordinator.discard(call) == nil
            }
        }
        await pollUntil(timeout: .seconds(5)) { refused.value != nil }
        #expect(refused.value == true)
        #expect(calls.value == ["restore"])

        release.signal()
        #expect(await first.value == .refused(.agentRecording))
        await second.value
        #expect(released.value)
        #expect(!coordinator.isBusy("/repo"))
        #expect(calls.value == ["restore", "recover"])
        if contender == .discard {
            #expect(await coordinator.discard(call) == .finished(nil, []))
            #expect(calls.value == ["restore", "recover", "discard", "recover"])
        }
    }

    /// A later restore clears the previous Undo Restore result.
    @Test func anUndoThatFellShort_isKept_untilTheNextRestore() async throws {
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.mergeInProgress) },
            undo: { _, _, _ in .refused(.changedSinceRestore(paths: ["a.txt"])) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) }
        ))
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        let turn = try TurnSummaryFixture.turn("T1", extras: extras)

        let journal = try Self.decodedJournal(root: "/repo")
        _ = await coordinator.undo(journal)
        #expect(coordinator.undoResults["/repo"] == .refused(.changedSinceRestore(paths: ["a.txt"])))

        _ = await coordinator.restore(turn)
        #expect(coordinator.undoResults["/repo"] == nil)
    }

    /// A discard is no restore: it has no record, and how its undo fell
    /// short is its hunk's to say, not the record's.
    @Test func aDiscard_isLeftOutOfTheRestoreRecord_andItsUndoResult() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", operation: "discard", ranAt: "2026-10-13T00:01:00Z")
        let undone = Recorded<[String]>([])
        let refusal = RestoreRefusal.changedSinceRestore(paths: ["a.txt"])
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, op, _ in
                undone.update { $0.append(op) }
                return .refused(refusal)
            },
            recover: { _ in RestoreRecovery(journals: [restore, discard], settled: []) }
        ))
        _ = await coordinator.recover(roots: ["/repo"])

        #expect(coordinator.latestUndoable(in: "/repo") == restore)
        #expect(await coordinator.undo(discard) == .refused(refusal))
        #expect(coordinator.undoResults["/repo"] == nil)
        #expect(await coordinator.undo(restore) == .refused(refusal))
        #expect(coordinator.undoResults["/repo"] == .refused(refusal))
        #expect(undone.value == ["D", "R"])
    }

    /// A discard a crash cut short is told at launch, as a restore is: no
    /// review offers its undo once the app has quit.
    @Test func aDiscardCutShort_isToldAtLaunch() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: Self.cutShort, operation: "discard")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [discard], settled: ["D"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.stops == [RestoreCoordinator.RecoveredStop(settled: discard, undoable: discard)])
        #expect(report.unsettledRoots.isEmpty)
        #expect(RecoveryNews.kind(report.stops) == .discardInterrupted)
    }

    /// A restore a crash cut short that an undo settled before it began is
    /// told by the reading after the undo, as the launch tells one; a
    /// reading that names none tells nothing.
    @Test func whatAnOperationSettledFirst_isToldByTheReadingAfterIt() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R", stage: #"{"kind":"applied"}"#, operation: "restore")
        let cutShort = try Self.decodedJournal(root: "/repo", opID: "C", stage: Self.cutShort, operation: "restore")
        let readings = Recorded([
            RestoreRecovery(journals: [restore, cutShort], settled: ["C"]),
            RestoreRecovery(journals: [restore, cutShort], settled: [])
        ])
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in
                var next: RestoreRecovery?
                readings.update { next = $0.isEmpty ? nil : $0.removeFirst() }
                guard let next else { throw WeirRestoreBridgeError.rust(-1) }
                return next
            }
        ))
        var told: [RestoreCoordinator.RecoveryReport] = []
        coordinator.onSettled = { told.append($0) }

        _ = await coordinator.undo(restore)
        _ = await coordinator.undo(restore)

        #expect(told == [RestoreCoordinator.RecoveryReport(
            stops: [RestoreCoordinator.RecoveredStop(settled: cutShort, undoable: cutShort)]
        )])
        #expect(readings.value.isEmpty)
    }

    /// A discard that ended as the app quit is told too, with the saves
    /// recovery kept aside: its review, and the hunk's undo, went with the
    /// app. A restore that ended so has its record, and is not.
    @Test func aDiscardEndedAtQuit_isToldAtLaunch_withTheSavesKeptAside() async throws {
        let whole = #"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
            + #""failed":[{"path":"f.txt","reason":"keptAside:.weir-D/target/ready-1/f.txt"}]}"#
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: whole, operation: "discard")
        let restore = try Self.decodedJournal(root: "/repo", opID: "R", stage: #"{"kind":"applied"}"#, operation: "restore")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [restore, discard], settled: ["R", "D"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.stops == [RestoreCoordinator.RecoveredStop(settled: discard, undoable: discard)])
        #expect(report.keptAside == [RestoreKeptAside(path: "f.txt", location: ".weir-D/target/ready-1/f.txt")])
        #expect(RecoveryNews.kind(report.stops) == .discardSettled)
    }

    /// The interrupted Undo determines the notice kind. Its original
    /// discard remains the operation the user can undo.
    @Test func anInterruptedUndoNotice_describesTheUndo() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", stage: #"{"kind":"applied"}"#, operation: "discard")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [discard, undo], settled: ["U"]) }
        ))

        let report = await coordinator.recover(roots: ["/repo"])

        #expect(report.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: discard)])
        #expect(RecoveryNews.kind(report.stops) == .undoInterrupted)
    }

    @Test func recoveryReports_mergeDistinctOperationsAndSavedPathsKeepingTheLatestRoots() throws {
        let firstJournal = try Self.decodedJournal(root: "/repo", opID: "D", stage: Self.cutShort, operation: "discard")
        let firstStop = RestoreCoordinator.RecoveredStop(settled: firstJournal, undoable: firstJournal)
        let laterJournal = try Self.decodedJournal(root: "/other", opID: "later", stage: Self.cutShort)
        let laterStop = RestoreCoordinator.RecoveredStop(settled: laterJournal, undoable: laterJournal)
        let firstSave = RestoreKeptAside(path: "a.txt", location: ".weir-D/a.txt")
        let laterSave = RestoreKeptAside(path: "b.txt", location: ".weir-later/b.txt")
        let first = RestoreCoordinator.RecoveryReport(stops: [firstStop], keptAside: [firstSave], unsettledRoots: ["/repo"])
        let later = RestoreCoordinator.RecoveryReport(
            stops: [firstStop, laterStop],
            keptAside: [firstSave, laterSave],
            unsettledRoots: ["/other"]
        )
        let merged = first.adding(later)
        #expect(merged.stops == [firstStop, laterStop])
        #expect(RecoveryNews.kind(merged.stops) == .operationsInterrupted(count: 2))
        #expect(RecoveryNews.kind([]) == nil)
        #expect(merged.keptAside == [firstSave, laterSave])
        #expect(merged.unsettledRoots == ["/other"])
    }

}

extension RestoreCoordinatorTests {
    private static func decodedJournal(
        root: String,
        opID: String = "OP",
        undoes: String? = nil,
        stage: String = #"{"kind":"applied"}"#,
        operation: String? = nil,
        ranAt: String? = nil
    ) throws -> RestoreJournal {
        try RestoreJournalFixture.make(
            stageJSON: stage,
            fields: .init(opID: opID, operation: operation, root: root, turnID: "T1", undoes: undoes, ranAt: ranAt)
        )
    }

    private static let cutShort = #"{"kind":"partiallyApplied","reason":"interrupted","currentTree":"c"}"#

    /// A coordinator whose readings are `readings`, one per call, and that
    /// keeps its pending notices at `pending`.
    private static func readingInTurn(
        _ readings: Recorded<[RestoreRecovery]>,
        pending: URL? = nil,
        requests: Recorded<[String]>? = nil,
        now: @escaping () -> Date = Date.init
    ) -> RestoreCoordinator {
        RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { root in
                requests?.update { $0.append(root) }
                var next: RestoreRecovery?
                readings.update { next = $0.isEmpty ? nil : $0.removeFirst() }
                guard let next else { throw WeirRestoreBridgeError.rust(-1) }
                return next
            }
        ), pendingStopsURL: pending, now: now)
    }

    /// An undo cut short whose discard could not be read when recovery
    /// settled it is told once, when a later reading lists the discard:
    /// Rust names the undo as settled only the first time.
    @Test func anUndoCutShort_whoseOperationIsReadLater_isToldOnce() async throws {
        let discard = try Self.decodedJournal(root: "/repo", opID: "D", operation: "discard")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let readings = Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: [undo], settled: [], isIncomplete: true),
            RestoreRecovery(journals: [discard, undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [discard, undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [], settled: [], isIncomplete: false)
        ])
        let coordinator = Self.readingInTurn(readings)

        let first = await coordinator.recover(roots: ["/repo"])
        #expect(first.stops.isEmpty)
        #expect(first.unsettledRoots == ["/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])
        // Still incomplete: it keeps waiting.
        let second = await coordinator.recover(roots: ["/repo"])
        #expect(second.stops.isEmpty)
        #expect(second.unsettledRoots == ["/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])

        let whole = await coordinator.recover(roots: ["/repo"])
        #expect(whole.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: discard)])
        #expect(RecoveryNews.kind(whole.stops) == .undoInterrupted)
        #expect(coordinator.pendingStopRoots.isEmpty)
        #expect(await coordinator.recover(roots: ["/repo"]) == RestoreCoordinator.RecoveryReport())
        #expect(await coordinator.recover(roots: ["/repo"]) == RestoreCoordinator.RecoveryReport())
        #expect(readings.value.isEmpty)
    }

    /// If the settled undo's original operation is already readable, tell
    /// it at once for both restore and discard.
    @Test(arguments: ["restore", "discard"])
    func anUndoCutShort_whoseOperationIsAlreadyRead_isToldOnce(operation: String) async throws {
        let original = try Self.decodedJournal(root: "/repo", opID: "O", operation: operation)
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "O", stage: Self.cutShort, operation: operation)
        let readings = Recorded([
            RestoreRecovery(journals: [original, undo], settled: ["U"]),
            RestoreRecovery(journals: [original, undo], settled: [])
        ])
        let coordinator = Self.readingInTurn(readings)

        let report = await coordinator.recover(roots: ["/repo"])
        #expect(report.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: original)])
        #expect(report.unsettledRoots.isEmpty)
        #expect(coordinator.pendingStopRoots.isEmpty)
        #expect(await coordinator.recover(roots: ["/repo"]) == RestoreCoordinator.RecoveryReport())
        #expect(readings.value.isEmpty)
    }

    /// A worktree asked by another spelling than its journals' root: its
    /// notice waits under the journals' root, an empty reading by the other
    /// spelling cannot say the operation is gone.
    @Test func aPendingNotice_waitsUnderItsJournalsRoot() async throws {
        let restore = try Self.decodedJournal(root: "/repo", opID: "R")
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "R", stage: Self.cutShort)
        let requests = Recorded<[String]>([])
        let coordinator = Self.readingInTurn(Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: [], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false),
            RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false)
        ]), requests: requests)

        let first = await coordinator.recover(roots: ["/link/repo"])
        #expect(first.stops.isEmpty)
        #expect(first.unsettledRoots == ["/link/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])
        #expect(await coordinator.recover(roots: ["/link/repo"]) == RestoreCoordinator.RecoveryReport())
        #expect(coordinator.pendingStopRoots == ["/repo"])
        let found = await coordinator.recover(roots: ["/link/repo"])
        #expect(found.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: restore)])
        #expect(coordinator.pendingStopRoots.isEmpty)
        #expect(await coordinator.recover(roots: ["/repo"]) == RestoreCoordinator.RecoveryReport())
        #expect(requests.value == ["/link/repo", "/link/repo", "/link/repo", "/repo"])
    }

    @Test func launchRecoveryRoots_unionProjectsAndPending_thenExcludeReadRoots() {
        #expect(AppState.launchRestoreRoots(projects: ["/link/repo", "/b"], pending: ["/repo", "/b"])
            == ["/b", "/link/repo", "/repo"])
        #expect(AppState.laterRestoreRoots(history: ["/z", "/repo", "/c"], readAtOnce: ["/b", "/repo"]) == ["/z", "/c"])
    }

    /// A complete reading can say the operation is gone. An incomplete
    /// reading can also settle the notice when it lists a final operation.
    @Test(arguments: [false, true])
    func aPendingNotice_isDropped_whenItsOperationCannotBeUndone(isFinal: Bool) async throws {
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let final = try Self.decodedJournal(
            root: "/repo",
            opID: "D",
            stage: #"{"kind":"aborted","reason":"interrupted"}"#,
            operation: "discard"
        )
        let readings = Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            RestoreRecovery(journals: isFinal ? [undo, final] : [undo], settled: [], isIncomplete: isFinal)
        ])
        let coordinator = Self.readingInTurn(readings)

        let first = await coordinator.recover(roots: ["/repo"])
        #expect(first.stops.isEmpty)
        #expect(first.unsettledRoots == ["/repo"])
        #expect(coordinator.pendingStopRoots == ["/repo"])
        let second = await coordinator.recover(roots: ["/repo"])
        #expect(second.stops.isEmpty)
        #expect(second.unsettledRoots == (isFinal ? ["/repo"] : []))
        #expect(coordinator.pendingStopRoots.isEmpty)
        #expect(readings.value.isEmpty)
    }

    @Test func aPendingNotice_expiresOnlyAfterItsLifetime() async throws {
        let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "D", stage: Self.cutShort, operation: "discard")
        let unreadable = RestoreRecovery(journals: [undo], settled: [], isIncomplete: true)
        let readings = Recorded([
            RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
            unreadable, unreadable, unreadable
        ])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Recorded(start)
        let coordinator = Self.readingInTurn(readings) { clock.value }

        _ = await coordinator.recover(roots: ["/repo"])
        try #require(coordinator.pendingStopRoots == ["/repo"])
        for offset in [-1.0, 0.0, 1.0] {
            clock.value = start.addingTimeInterval(RestorePendingStopFile.lifetime + offset)
            let report = await coordinator.recover(roots: ["/repo"])
            #expect(report.stops.isEmpty)
            #expect(report.unsettledRoots == ["/repo"])
            #expect(coordinator.pendingStopRoots == (offset > 0 ? [] : ["/repo"]))
        }
        #expect(readings.value.isEmpty)
    }

    /// A notice whose operation stays unreadable until the app quits waits
    /// in its file, and the next launch tells it once its operation reads;
    /// one that never reads is never told, and no reading fails for it.
    @Test func aPendingNotice_outlivesARelaunch_andIsToldOnce() async throws {
        try await withTempDir { directory in
            let file = directory.appendingPathComponent(RestorePendingStopFile.fileName)
            let restore = try Self.decodedJournal(root: "/repo", opID: "R")
            let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "R", stage: Self.cutShort)
            let unreadable = RestoreRecovery(journals: [undo], settled: [], isIncomplete: true)

            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let notice = RestorePendingStop(root: "/repo", settledID: "U", undoableID: "R", since: date)
            let first = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true),
                unreadable,
                unreadable
            ]), pending: file, now: { date })
            for _ in 0..<3 {
                let report = await first.recover(roots: ["/repo"])
                #expect(report.stops.isEmpty)
                #expect(report.unsettledRoots == ["/repo"])
            }
            #expect(RestorePendingStopFile.read(file).elements == [notice])

            // Never readable this launch either: kept, and never told.
            let second = Self.readingInTurn(Recorded([unreadable, unreadable]), pending: file, now: { date })
            #expect(second.pendingStopRoots == ["/repo"])
            for _ in 0..<2 {
                let report = await second.recover(roots: ["/repo"])
                #expect(report.stops.isEmpty)
                #expect(report.unsettledRoots == ["/repo"])
            }
            #expect(RestorePendingStopFile.read(file).elements == [notice])

            let third = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false),
                RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false)
            ]), pending: file, now: { date })
            let told = await third.recover(roots: ["/repo"])
            #expect(told.stops == [RestoreCoordinator.RecoveredStop(settled: undo, undoable: restore)])
            #expect(told.unsettledRoots.isEmpty)
            #expect(await third.recover(roots: ["/repo"]) == RestoreCoordinator.RecoveryReport())
            #expect(!FileManager.default.fileExists(atPath: file.path))

            let fourth = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [restore, undo], settled: [], isIncomplete: false)
            ]), pending: file)
            #expect(fourth.pendingStopRoots.isEmpty)
            #expect(await fourth.recover(roots: ["/repo"]).stops.isEmpty)
        }
    }

    /// A folder that cannot be searched hides the pending notices' file,
    /// which may hold a discard's only way back: it is kept as it is, not
    /// written over by this launch's notices, and reported.
    @Test(.enabled(if: geteuid() != 0))
    func pendingNoticesInAFolderThatCannotBeSearched_areNeverSavedOver() async throws {
        try await withTempDir { root in
            let directory = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent(RestorePendingStopFile.fileName)
            let earlier = RestorePendingStop(root: "/earlier", settledID: "E", undoableID: "D", since: Date())
            RestorePendingStopFile.write([earlier], to: file)
            let original = try Data(contentsOf: file)
            let undo = try Self.decodedJournal(root: "/repo", opID: "U", undoes: "R", stage: Self.cutShort)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

            try #require(throws: (any Error).self) { try Data(contentsOf: file) }
            let coordinator = Self.readingInTurn(Recorded([
                RestoreRecovery(journals: [undo], settled: ["U"], isIncomplete: true)
            ]), pending: file)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Settles an undo whose operation cannot be read yet: a notice
            // to keep, which writes the file.
            #expect(await coordinator.recover(roots: ["/repo"]).stops.isEmpty)

            #expect(coordinator.pendingStopRoots == ["/repo"], "kept in memory for this launch")
            #expect(coordinator.suspendedPendingStopsFile == file)
            #expect(try Data(contentsOf: file) == original)
        }
    }

    /// Each reading's finds are told as they come, and a worktree a hook
    /// kept locked is read again.
    @Test func recoveryAtLaunch_tellsEachReading_andReadsALockedWorktreeAgain() async throws {
        let stopped = try Self.decodedJournal(root: "/a", opID: "A", stage: Self.cutShort)
        let locked = try Self.decodedJournal(root: "/b", opID: "B", stage: #"{"kind":"writing","done":[]}"#)
        let settledLater = try Self.decodedJournal(root: "/b", opID: "B", stage: Self.cutShort)
        let trace = Recorded<[String]>([])
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { root in
                trace.update { $0.append("read \(root)") }
                if root == "/a" {
                    return RestoreRecovery(journals: [stopped], settled: ["A"])
                }
                let isFirst = trace.value.filter { $0 == "read /b" }.count == 1
                return isFirst
                    ? RestoreRecovery(journals: [locked], settled: [])
                    : RestoreRecovery(journals: [settledLater], settled: ["B"])
            }
        ))
        var told: [RestoreCoordinator.RecoveryReport] = []

        await coordinator.recoverAtLaunch(roots: ["/a", "/b"], attempts: 3, retry: .milliseconds(1)) { found in
            trace.update { $0.append("reported " + found.interrupted.map(\.opID).joined()) }
            told.append(found)
        }

        #expect(told == [
            RestoreCoordinator.RecoveryReport(
                stops: [RestoreCoordinator.RecoveredStop(settled: stopped, undoable: stopped)], unsettledRoots: ["/b"]
            ),
            RestoreCoordinator.RecoveryReport(
                stops: [RestoreCoordinator.RecoveredStop(settled: settledLater, undoable: settledLater)]
            )
        ])
        #expect(trace.value == ["read /a", "read /b", "reported A", "read /b", "reported B"])
    }

    /// A reading of the journals that fails after a restore is not an
    /// empty list: the restore's record keeps its Undo, and the worktree is
    /// read again.
    @Test(.timeLimit(.minutes(1))) func aFailedReadingAfterARestore_keepsItsUndo_andReadsAgain() async throws {
        let restored = try Self.decodedJournal(root: "/repo", opID: "R")
        let later = try Self.decodedJournal(root: "/repo", opID: "later")
        let readings = Recorded(0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let wasReleased = Recorded(false)
        let coordinator = RestoreCoordinator(
            stateDirectories: [],
            bridge: .init(
                restore: { _, _, _, _ in .finished(restored) },
                undo: { _, _, _ in .refused(.unknown) },
                recover: { _ in
                    readings.update { $0 += 1 }
                    guard readings.value > 1 else { throw WeirRestoreBridgeError.rust(-1) }
                    wasReleased.value = release.wait(timeout: .now() + 10) == .success
                    return RestoreRecovery(journals: [later], settled: [])
                }
            ),
            rereadDelay: .milliseconds(10)
        )
        var wholeReadings: [[String]] = []
        coordinator.onWholeReading = { root, journals in
            wholeReadings.append([root] + journals.map(\.opID))
        }
        var extras = TurnSummaryFixture.Extras()
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        let turn = try TurnSummaryFixture.turn("T1", extras: extras)

        #expect(await coordinator.restore(turn) == .finished(restored))

        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")
        await pollUntil(timeout: .seconds(5)) { readings.value > 1 }
        try #require(readings.value == 2)
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "R")
        #expect(wholeReadings.isEmpty)
        release.signal()
        await pollUntil(timeout: .seconds(5)) { coordinator.latestUndoable(in: "/repo")?.opID == "later" }
        #expect(coordinator.latestUndoable(in: "/repo")?.opID == "later")
        #expect(wholeReadings == [["/repo", "later"]])
        #expect(wasReleased.value)
    }

    /// A worktree whose journals could not be read at launch is read again,
    /// as one a hook kept locked is.
    @Test func aFailedReadingAtLaunch_isReadAgain() async throws {
        let recovered = try Self.decodedJournal(root: "/repo", opID: "recovered", stage: Self.cutShort)
        let readings = Recorded(0)
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in
                readings.update { $0 += 1 }
                guard readings.value > 1 else { throw WeirRestoreBridgeError.rust(-1) }
                return RestoreRecovery(journals: [recovered], settled: ["recovered"])
            }
        ))

        var reports: [RestoreCoordinator.RecoveryReport] = []
        await coordinator.recoverAtLaunch(roots: ["/repo"], attempts: 2, retry: .zero) {
            reports.append($0)
        }

        #expect(readings.value == 2)
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.interrupted == [recovered])
        #expect(report.unsettledRoots.isEmpty)
        #expect(coordinator.latestUndoable(in: "/repo") == recovered)
    }

    @Test func aTurnWithoutItsStart_isNotSentToRust() async throws {
        let coordinator = RestoreCoordinator(stateDirectories: [], bridge: .init(
            restore: { _, _, _, _ in Issue.record("called")
                return .refused(.unknown)
            },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) }
        ))
        let turn = try TurnSummaryFixture.turn("T1")
        #expect(await coordinator.restore(turn) == nil)
    }
}
