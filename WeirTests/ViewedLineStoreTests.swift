// ViewedLineStoreTests.swift
// Weir — each conversation's viewed line, kept across launches in viewed-lines.json, and its auxiliary ref.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Records the ref moves a store asks for, in order.
private final class RecordingRefs: ViewedLineRefWriting, @unchecked Sendable {
    struct Move: Equatable {
        let conversation: ConversationKey
        let from: SnapshotTree?
        let to: SnapshotTree?
    }

    private let lock = NSLock()
    enum Event: Equatable {
        case move(Move)
        case flush
    }

    private var recorded: [Event] = []
    private let onFlush: @Sendable () -> Void

    init(onFlush: @escaping @Sendable () -> Void = {}) {
        self.onFlush = onFlush
    }

    var events: [Event] {
        lock.withLock { recorded }
    }

    var moves: [Move] {
        events.compactMap {
            guard case let .move(move) = $0 else { return nil }
            return move
        }
    }

    func move(_ conversation: ConversationKey, from: SnapshotTree?, to: SnapshotTree?) {
        lock.withLock { recorded.append(.move(Move(conversation: conversation, from: from, to: to))) }
    }

    func waitForPendingMoves() {
        lock.withLock { recorded.append(.flush) }
        onFlush()
    }
}

@MainActor
@Suite("Viewed line store")
struct ViewedLineStoreTests {
    private typealias Fixture = TurnSummaryFixture
    private static let tree = SnapshotTree(tree: "abc", root: "/repo")

    private func file(in dir: URL) -> URL {
        dir.appendingPathComponent("viewed-lines.json")
    }

    @Test func aLine_staysAcrossALaunch() throws {
        try withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            let turn = try Fixture.turn("b", changes: Fixture.changedFiles, number: 2)
            store.markViewed(through: turn, source: .decisionBar)
            store.flushSynchronously()

            let relaunched = ViewedLineStore(directory: dir)

            #expect(try relaunched.isViewed(Fixture.turn("a", number: 1)))
            #expect(relaunched.isViewed(turn))
            #expect(try !relaunched.isViewed(Fixture.turn("c", number: 3)))
        }
    }

    /// "Undo Restore" after a relaunch puts the line back as the restore
    /// found it: the moves the restore made are kept with the lines, once.
    /// A restore still to be undone keeps its journal however old it is,
    /// so its moves outlive the 30 days a finished journal is kept, and a
    /// late undo puts the line back while the moves are still the latest.
    @Test func aRestoresMoves_stayAcrossALaunch_pastAFinishedJournalsLifetime_untilTakenOnce() throws {
        try withTempDir { dir in
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            let store = ViewedLineStore(directory: dir, now: { clock })
            let a1 = try Self.turn("a", 1)
            let b1 = try Self.turn("b", 1)
            let moves = store.markViewed(through: [a1, b1], source: .restore).map(\.undo)
            #expect(moves.count == 2)
            store.noteRestoreMoves(moves, of: "OP", in: "/repo")
            store.flushSynchronously()

            clock = clock.addingTimeInterval(60 * 24 * 60 * 60)
            let relaunched = ViewedLineStore(directory: dir, now: { clock })
            let taken = relaunched.takeRestoreMoves(of: "OP")
            #expect(taken == moves)
            for move in taken {
                #expect(relaunched.undo(move.changeID, in: move.conversation))
            }
            #expect(!relaunched.isViewed(a1))
            #expect(!relaunched.isViewed(b1))
            #expect(relaunched.takeRestoreMoves(of: "OP").isEmpty)
            relaunched.flushSynchronously()
            #expect(ViewedLineStore(directory: dir, now: { clock }).takeRestoreMoves(of: "OP").isEmpty)
        }
    }

    /// A restore's move goes once its line can no longer take it back:
    /// taken back on its own, or gone with the line. Later moves past the
    /// history's limit do not push it out. The others of the same restore
    /// stay.
    @Test func aRestoresMoves_goWhenTheirLineCanNoLongerTakeThemBack() throws {
        try withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            let a1 = try Self.turn("a", 1)
            let b1 = try Self.turn("b", 1)
            let c1 = try Self.turn("c", 1)
            let moves = store.markViewed(through: [a1, b1, c1], source: .restore).map(\.undo)
            store.noteRestoreMoves(moves, of: "OP", in: "/repo")
            for number in 2...(ViewedLine.historyLimit + 5) {
                try store.markViewed(through: Self.turn("a", number), source: .turnRow)
            }
            store.forget([b1.conversation])
            let cMove = try #require(moves.first { $0.conversation == c1.conversation })
            #expect(store.undo(cMove.changeID, in: cMove.conversation))
            store.flushSynchronously()

            let relaunched = ViewedLineStore(directory: dir)
            #expect(relaunched.takeRestoreMoves(of: "OP") == moves.filter { $0.conversation == a1.conversation })
        }
    }

    /// A restore, then more viewed-line operations than the history keeps,
    /// in its lines and in another, then a relaunch: once the later moves
    /// of a restored line are unmarked, "Undo Restore" puts every line back
    /// as the restore found it. Till they are, the later moves stand.
    @Test func undoRestore_afterMoreMovesThanTheHistoryKeeps_putsTheLinesBack() throws {
        try withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            let a1 = try Self.turn("a", 1)
            let b1 = try Self.turn("b", 1)
            let a2 = try Self.turn("a", 2)
            let b2 = try Self.turn("b", 2)
            store.markViewed(through: [a1, b1], source: .turnRow)
            let moves = store.markViewed(through: [a2, b2], source: .restore).map(\.undo)
            store.noteRestoreMoves(moves, of: "OP", in: "/repo")
            let count = ViewedLine.historyLimit + 5
            for number in 3...count {
                try store.markViewed(through: Self.turn("a", number), source: .turnRow)
                try store.markViewed(through: Self.turn("c", number), source: .turnRow)
            }
            store.flushSynchronously()

            let relaunched = ViewedLineStore(directory: dir)
            let aLine = try #require(relaunched.line(of: a1.conversation))
            #expect(aLine.history.count == ViewedLine.historyLimit + 1)
            let restoreMove = try #require(moves.first { $0.conversation == a1.conversation })
            // Under later moves the restore's does not take the line back.
            let later = try Self.turn("a", count)
            try #require(aLine.position == ViewedLinePosition(later))
            #expect(!relaunched.undo(restoreMove.changeID, in: a1.conversation))
            #expect(relaunched.line(of: a1.conversation)?.position == ViewedLinePosition(later))
            for change in aLine.history.reversed() where change.id != restoreMove.changeID {
                #expect(relaunched.undo(change.id, in: a1.conversation))
            }
            let taken = relaunched.takeRestoreMoves(of: "OP")
            #expect(taken == moves)
            for move in taken {
                #expect(relaunched.undo(move.changeID, in: move.conversation))
            }
            #expect(relaunched.line(of: a1.conversation)?.position == ViewedLinePosition(a1))
            #expect(relaunched.line(of: b1.conversation)?.position == ViewedLinePosition(b1))
            #expect(!relaunched.isViewed(a2))
            #expect(!relaunched.isViewed(b2))
            let unrelated = try Self.turn("c", count)
            #expect(relaunched.line(of: unrelated.conversation)?.position == ViewedLinePosition(unrelated))
        }
    }

    /// The moves go when a whole reading of the journals says the restore
    /// can no longer be undone: listed as aborted, or, in its worktree while
    /// that is there, not listed at all. Listed as undone, from whatever
    /// undo, they are taken back. A reading of another worktree, of one not
    /// there now, or one that lists the restore as still to be undone keeps
    /// them. Once they go, the line's history is trimmed to its limit again.
    @Test func aWholeReading_takesBackTheUndone_dropsTheEnded_andKeepsTheRest() throws {
        try withTempDir { dir in
            let repo = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let otherRepo = dir.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: otherRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let unmounted = dir.appendingPathComponent("unmounted").path
            let store = ViewedLineStore(directory: dir)
            var turns: [String: TurnSummary] = [:]
            var expectedMoves: [String: [ViewedLineUndo]] = [:]
            let restores = [
                ("aborted", "OP-ABORTED", repo.path),
                ("pruned", "OP-PRUNED", repo.path),
                ("undone", "OP-UNDONE", repo.path),
                ("stale", "OP-STALE", repo.path),
                ("unmounted", "OP-UNMOUNTED", unmounted),
                ("applied", "OP-APPLIED", repo.path),
                ("writing", "OP-WRITING", repo.path),
                ("newer", "OP-NEWER", repo.path),
                ("other", "OP-OTHER", otherRepo.path)
            ]
            for (conversation, opID, root) in restores {
                let turn = try Self.turn(conversation, 1)
                turns[conversation] = turn
                let moves = store.markViewed(through: [turn], source: .restore).map(\.undo)
                expectedMoves[opID] = moves
                store.noteRestoreMoves(moves, of: opID, in: root)
            }
            for number in 2...(ViewedLine.historyLimit + 3) {
                try store.markViewed(through: Self.turn("aborted", number), source: .turnRow)
            }
            let staleLater = try Self.turn("stale", 2)
            store.markViewed(through: staleLater, source: .turnRow)
            let abortedLater = try Self.turn("aborted", ViewedLine.historyLimit + 3)
            let aborted = try #require(turns["aborted"]).conversation
            #expect(store.line(of: aborted)?.history.count == ViewedLine.historyLimit + 1)

            let journals = [
                ("aborted", "OP-ABORTED", #"{"kind":"aborted","reason":"externalChangeDetected"}"#),
                ("undone", "OP-UNDONE", #"{"kind":"undone","by":"U"}"#),
                ("stale", "OP-STALE", #"{"kind":"undone","by":"U2"}"#),
                ("applied", "OP-APPLIED", #"{"kind":"applied"}"#),
                ("writing", "OP-WRITING", #"{"kind":"writing"}"#),
                ("newer", "OP-NEWER", #"{"kind":"somethingNew"}"#)
            ]
            let listing = try journals.map { conversation, opID, stage in
                let turn = try #require(turns[conversation])
                return try RestoreJournalFixture.make(
                    stageJSON: stage,
                    fields: .init(opID: opID, root: repo.path, turnID: turn.turnID.rawValue, turnNumber: turn.displayNumber)
                )
            }
            store.settleRestoreMoves(readOf: { $0 == repo.path || $0 == unmounted }, listing: listing)

            // Undone from elsewhere: its line goes back.
            #expect(try !store.isViewed(#require(turns["undone"])))
            // Ended or pruned: dropped, and the lines stay as they are.
            #expect(try store.isViewed(#require(turns["pruned"])))
            #expect(store.line(of: aborted)?.history.count == ViewedLine.historyLimit)
            #expect(store.line(of: aborted)?.position == ViewedLinePosition(abortedLater))
            #expect(store.line(of: staleLater.conversation)?.position == ViewedLinePosition(staleLater))
            store.flushSynchronously()

            let relaunched = ViewedLineStore(directory: dir)
            for opID in ["OP-ABORTED", "OP-PRUNED", "OP-UNDONE", "OP-STALE"] {
                #expect(relaunched.takeRestoreMoves(of: opID).isEmpty)
            }
            // Still to be undone, still settling, at a stage this build
            // cannot read, in a worktree not there now, or another's.
            for opID in ["OP-UNMOUNTED", "OP-APPLIED", "OP-WRITING", "OP-NEWER", "OP-OTHER"] {
                let kept = try #require(expectedMoves[opID])
                try #require(kept.count == 1)
                #expect(relaunched.takeRestoreMoves(of: opID) == kept)
            }
        }
    }

    /// A mark is its `markID`, and the latest mark is told by
    /// its place among the store's marks, which the file keeps. Two marks
    /// a moment apart, even when the clock goes backward and the file
    /// keeps both at the same second, offer only the later one; one mark
    /// over two conversations takes back both, whatever the filter shows.
    @Test func theMarks_areTheSameBeforeAndAfterALaunch_andWhateverTheFilter() throws {
        try withTempDir { dir in
            var clock = Date(timeIntervalSince1970: 1_800_000_000.8)
            let store = ViewedLineStore(directory: dir, now: { clock })
            let a1 = try Self.turn("a", 1)
            let b1 = try Self.turn("b", 1)
            let a2 = try Self.turn("a", 2)
            let b2 = try Self.turn("b", 2)

            let aMove = try #require(store.markViewed(through: [a1], source: .turnRow).first)
            clock = Date(timeIntervalSince1970: 1_800_000_000.1)
            let bMove = try #require(store.markViewed(through: [b1], source: .turnRow).first)
            let sequence = try #require(bMove.change.sequence)
            #expect(aMove.change.at > bMove.change.at, "the wall clock moved backward")
            #expect(aMove.change.sequence == sequence - 1)
            let alone = [bMove.undo]
            #expect(try Self.unmark(store, turns: [a1, b1]) == alone, "the later of two marks in one second")
            store.flushSynchronously()
            let relaunched = ViewedLineStore(directory: dir, now: { clock })
            let aReloaded = try #require(relaunched.line(of: a1.conversation)?.history.last)
            let bReloaded = try #require(relaunched.line(of: b1.conversation)?.history.last)
            #expect(aReloaded.at == Date(timeIntervalSince1970: 1_800_000_000))
            #expect(bReloaded.at == aReloaded.at)
            #expect(bReloaded.sequence == sequence)
            #expect(try Self.unmark(relaunched, turns: [a1, b1]) == alone, "the same after a relaunch")

            clock = Date(timeIntervalSince1970: 1_800_000_001.2)
            let moves = relaunched.markViewed(through: [a2, b2], source: .turnRow)
            #expect(moves.map(\.change.sequence) == [sequence + 1, sequence + 1])
            let together = moves.map(\.undo)
            #expect(together.count == 2)
            #expect(try Set(Self.unmark(relaunched, turns: [a1, b1, a2, b2])) == Set(together))
            #expect(
                try Set(Self.unmark(relaunched, turns: [a1, b1, a2, b2], chosen: a1.conversation)) == Set(together),
                "narrowed to one conversation, the whole mark"
            )
            relaunched.flushSynchronously()
            let again = ViewedLineStore(directory: dir, now: { clock })
            #expect(try Set(Self.unmark(again, turns: [a1, b1, a2, b2], chosen: b1.conversation)) == Set(together))
            let written = try String(contentsOf: file(in: dir), encoding: .utf8)
            #expect(written.contains("markID") && written.contains("sequence"))
        }
    }

    /// A turn of conversation `conversation` that changed files.
    private static func turn(_ conversation: String, _ number: Int) throws -> TurnSummary {
        var extras = Fixture.Extras()
        extras.conversationID = conversation
        return try Fixture.turn("\(conversation)\(number)", changes: Fixture.changedFiles, number: number, extras: extras)
    }

    /// What "Unmark as Viewed" on the changes panel's line would take back,
    /// with `turns` listed and the filter at `chosen`.
    private static func unmark(_ lines: ViewedLineStore, turns: [TurnSummary], chosen: ConversationKey? = nil) throws -> [ViewedLineUndo] {
        var byConversation: [ConversationKey: [TurnSummary]] = [:]
        for turn in turns {
            byConversation[turn.conversation, default: []].append(turn)
        }
        let agents = byConversation.keys.sorted { $0.conversationID < $1.conversationID }.map {
            ChangesPanelModel.Agent(conversation: $0, turns: byConversation[$0] ?? [])
        }
        var input = ChangesPanelModel.Input(agents: agents, line: { lines.line(of: $0) })
        input.chosen = chosen
        guard case let .turns(list) = ChangesPanelModel.make(input) else { throw CancellationError() }
        return try #require(list.line).undo
    }

    @Test func viewedLine_survivesResumeWithNewRun() throws {
        // The line is the conversation's, not the run's: resumed in a new
        // run, its turns before the line stay viewed and the new one is not.
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let viewed = try Fixture.turn("before", changes: Fixture.changedFiles, number: 4)
        store.markViewed(through: viewed, source: .decisionBar)
        var extras = Fixture.Extras()
        extras.runID = "new-run"
        let resumed = try Fixture.turn("after", changes: Fixture.changedFiles, number: 5, extras: extras)
        let independent = try Self.turn("other", 1)
        #expect(viewed.runID != resumed.runID)
        #expect(store.isViewed(viewed))
        #expect(!store.isViewed(resumed))
        #expect(!store.isViewed(independent))
        let history = [Fixture.conversation: [viewed]]
        let newRun = TurnReadRuntime(
            runID: resumed.runID,
            activeAttachmentPaneIDs: [UUID()],
            conversation: Fixture.conversation,
            currentTurnID: resumed.turnID,
            isFinished: true
        )

        let priorRun = TurnReadRuntime(
            runID: viewed.runID,
            activeAttachmentPaneIDs: [UUID()],
            conversation: Fixture.conversation,
            currentTurnID: viewed.turnID,
            isFinished: true
        )
        #expect(TurnReadRules.isEpisodeRead(priorRun, history: history, isRead: store.isViewed) == true)
        #expect(TurnReadRules.isEpisodeRead(
            newRun,
            history: [Fixture.conversation: [viewed, resumed]],
            isRead: store.isViewed
        ) == false)
    }

    @Test func undo_isSavedToo() throws {
        try withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            let first = try Fixture.turn("a", changes: Fixture.changedFiles, number: 1)
            let second = try Fixture.turn("b", changes: Fixture.changedFiles, number: 2)
            store.markViewed(through: first, source: .decisionBar)
            let change = try #require(store.markViewed(through: second, source: .decisionBar))

            #expect(store.undo(change.id, in: Fixture.conversation))
            #expect(!store.undo(change.id, in: Fixture.conversation), "taken back once")
            store.flushSynchronously()

            let relaunched = ViewedLineStore(directory: dir)
            #expect(relaunched.isViewed(first))
            #expect(!relaunched.isViewed(second))
        }
    }

}

extension ViewedLineStoreTests {
    @Test func changesOutsideTurnsMarkedViewed_stayAcrossALaunch_andUndoWithTheLine() throws {
        try withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            let turn = try Fixture.turn("a", changes: Fixture.changedFiles, number: 1)
            let change = try #require(store.markViewed(through: turn, source: .review))
            // A worktree that exists: one that is gone is dropped on reading.
            store.markOutsideTurnsViewed(["notes.md": "blob:1"], in: dir.path, with: change.id)
            let missing = dir.appendingPathComponent("gone").path
            store.markOutsideTurnsViewed(["old.md": "blob:1"], in: missing, with: UUID())
            #expect(store.outsideTurns == [dir.path: ["notes.md": "blob:1"], missing: ["old.md": "blob:1"]])
            store.flushSynchronously()
            #expect(ViewedLineStore(directory: dir).outsideTurns == [dir.path: ["notes.md": "blob:1"]])

            #expect(store.undo(change.id, in: Fixture.conversation))
            #expect(store.outsideTurns[dir.path] == nil, "one Undo takes back both")
            #expect(!store.isViewed(turn))
            store.flushSynchronously()
            let reopened = ViewedLineStore(directory: dir)
            #expect(reopened.outsideTurns.isEmpty)
            #expect(!reopened.isViewed(turn))
            #expect(reopened.line(of: turn.conversation)?.position == nil)
        }
    }

    @Test func aFileFromBeforeChangesOutsideTurnsWereKept_isRead() throws {
        try withTempDir { dir in
            let historical = Data(#"""
            {"schemaVersion":1,"lines":[{"conversation":{"provider":"claude","conversationId":"s1","isFallback":false},
            "position":{"turnID":"old","displayNumber":2},"history":[]}]}
            """#.utf8)
            try historical.write(to: file(in: dir))

            let store = ViewedLineStore(directory: dir)

            #expect(try store.isViewed(Fixture.turn("old", number: 2)))
            #expect(try !store.isViewed(Fixture.turn("next", number: 3)))
            #expect(store.outsideTurns.isEmpty)
            #expect(try Data(contentsOf: file(in: dir)) == historical)
        }
    }

    @Test func changesOutsideTurnsMarkedAlone_undo_andALaterMarkComesFirst() {
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let first = UUID()
        let second = UUID()
        store.markOutsideTurnsViewed(["a.md": "blob:1"], in: "/repo", with: first)
        store.markOutsideTurnsViewed(["a.md": "blob:2"], in: "/repo", with: second)

        #expect(store.undo(second, in: Fixture.conversation), "no line, and still taken back")
        #expect(store.outsideTurns["/repo"] == ["a.md": "blob:1"])
        #expect(store.undo(first, in: Fixture.conversation))
        #expect(store.outsideTurns["/repo"] == nil)
    }

    /// The spans are saved as they are noted, with no flush: the deletion queue lets go
    /// of its own copy once this says they are saved. A worktree merely
    /// missing (a volume not mounted) keeps its spans across a launch;
    /// only its removal lets them go.
    @Test func theDeletedTurnsSpans_areJoinedByWorktree_andSavedAtOnce() async throws {
        try await withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            let first = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 100)
            let overlapping = DateInterval(start: Date(timeIntervalSince1970: 1050), duration: 100)
            let apart = DateInterval(start: Date(timeIntervalSince1970: 5000), duration: 10)
            let unmounted = "/Volumes/not-mounted-\(UUID().uuidString)/repo"
            #expect(await store.noteDeletedTurns([dir.path: [apart, first]]))
            #expect(await store.noteDeletedTurns([dir.path: [overlapping], unmounted: [apart]]))
            let joined = DateInterval(start: first.start, end: overlapping.end)
            #expect(store.deletedTurns { $0 == dir.path } == [joined, apart])

            let relaunched = ViewedLineStore(directory: dir)
            #expect(relaunched.deletedTurns == [dir.path: [joined, apart], unmounted: [apart]], "on disk already")

            relaunched.forgetDeletedTurns { $0 == unmounted }
            #expect(relaunched.deletedTurns == [dir.path: [joined, apart]])
            relaunched.flushSynchronously()
            #expect(ViewedLineStore(directory: dir).deletedTurns.keys.sorted() == [dir.path])
        }
    }

    @Test(.enabled(if: geteuid() != 0))
    func theDeletedTurnsSpans_thatCannotBeSaved_areSaidSo() async throws {
        try await withTempDir { dir in
            let store = ViewedLineStore(directory: dir)
            // In a folder that cannot be written in, the write fails.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            let span = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 100)
            let spans = [dir.path: [span]]
            #expect(await store.noteDeletedTurns(spans) == false)
            #expect(store.deletedTurns == spans)
            #expect(!FileManager.default.fileExists(atPath: file(in: dir).path))

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            #expect(await store.noteDeletedTurns(spans))
            #expect(ViewedLineStore(directory: dir).deletedTurns == spans)
        }
    }

    /// These are the roots `AppState.isRemovedRoot` counts as removed, and
    /// so whose spans a removal takes: one removed, one in a removed folder,
    /// or one holding a removed folder, unless it holds a folder still kept.
    @Test func isRemovedRoot_takesARemovedRootAndWhatIsInIt_notOneHoldingAKeptFolder() {
        let removed: Set = ["/code/app-wt", "/code/lib/sub"]
        let kept: Set = ["/code/app", "/code/lib/other"]
        #expect(AppState.isRemovedRoot("/code/app-wt", removed: removed, kept: kept))
        #expect(AppState.isRemovedRoot("/code/app-wt/nested", removed: removed, kept: kept))
        #expect(!AppState.isRemovedRoot("/code/app", removed: removed, kept: kept))
        #expect(!AppState.isRemovedRoot("/code/lib", removed: removed, kept: kept), "it holds a project still kept")
        #expect(AppState.isRemovedRoot("/code/lib", removed: removed, kept: ["/code/app"]))
        #expect(AppState.isRemovedRoot(
            "/code/app/.worktrees/x",
            removed: ["/code/app/.worktrees/x"],
            kept: kept
        ), "a worktree inside its project's folder")
    }

    @Test func pastTheLimit_theEarliestSpansAreJoined() {
        let spans = (0..<(ViewedLineStore.deletedSpanLimit + 2)).map {
            DateInterval(start: Date(timeIntervalSince1970: Double($0) * 100), duration: 10)
        }
        let merged = ViewedLineStore.merge(spans)
        let joined = DateInterval(start: spans[0].start, end: spans[2].end)
        #expect(merged == [joined] + spans.dropFirst(3))
    }

    @Test func aMarkWithNoConversation_isTakenBackAlone() {
        // A review opened from a shell pane: nothing moved a line with it.
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let first = UUID()
        let second = UUID()
        store.markOutsideTurnsViewed(["a.md": "blob:1"], in: "/repo", with: first)
        store.markOutsideTurnsViewed(["a.md": "blob:2"], in: "/repo", with: second)

        #expect(!store.undoOutsideTurnsMark(first), "the later mark stands")
        #expect(store.undoOutsideTurnsMark(second))
        #expect(store.outsideTurns["/repo"] == nil)
        #expect(!store.undoOutsideTurnsMark(second), "taken back already")
    }

    @Test func anEarlierMarkTakenBackFirst_doesNotComeBackWithTheLater() {
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let first = UUID()
        let second = UUID()
        store.markOutsideTurnsViewed(["a.md": "blob:1"], in: "/repo", with: first)
        store.markOutsideTurnsViewed(["a.md": "blob:2"], in: "/repo", with: second)

        #expect(!store.undo(first, in: Fixture.conversation), "the later mark stands")
        #expect(store.outsideTurns["/repo"] == ["a.md": "blob:2"])
        #expect(store.undo(second, in: Fixture.conversation))
        #expect(store.outsideTurns["/repo"] == nil, "both taken back: neither stays")
    }

    @Test func markingAViewedTurnAgain_offersNoUndo() throws {
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let turn = try Fixture.turn("a", number: 3)
        #expect(store.markViewed(through: turn, source: .decisionBar) != nil)

        #expect(store.markViewed(through: turn, source: .decisionBar) == nil)
    }

    /// One mark of several conversations' turns moves each line under one
    /// `markID` and at one time; a turn already viewed moves nothing and is
    /// left out.
    @Test func markingSeveralConversations_isOneMark_withOneTime() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false, now: {
            let at = clock
            clock = clock.addingTimeInterval(1)
            return at
        })
        var otherExtras = Fixture.Extras()
        otherExtras.conversationID = "other"
        let first = try Fixture.turn("c4", changes: Fixture.changedFiles, number: 4)
        let second = try Fixture.turn("x1", changes: Fixture.changedFiles, number: 1, extras: otherExtras)
        let viewed = try Fixture.turn("x0", changes: Fixture.changedFiles, number: 0, extras: otherExtras)
        let prior = try #require(store.markViewed(through: viewed, source: .decisionBar))
        let priorSequence = try #require(prior.sequence)
        let markTime = clock

        let moves = store.markViewed(through: [first, second, viewed], source: .turnRow)

        #expect(moves.map(\.conversation) == [first.conversation, second.conversation], "the viewed turn moved nothing")
        #expect(moves.map(\.change.at) == [markTime, markTime])
        #expect(clock == markTime.addingTimeInterval(1))
        #expect(moves.map(\.change.sequence) == [priorSequence + 1, priorSequence + 1])
        #expect(moves.first?.change.markID != nil)
        #expect(Set(moves.map(\.change.markID)).count == 1)
        #expect(moves.map(\.undo.changeID) == moves.map(\.change.id))
        #expect(store.isViewed(first) && store.isViewed(second))
        for move in moves {
            #expect(store.undo(move.undo.changeID, in: move.undo.conversation))
        }
        #expect(!store.isViewed(first) && !store.isViewed(second))
        #expect(store.isViewed(viewed), "the earlier mark stands")
    }

}

extension ViewedLineStoreTests {
    @Test func markingNotViewed_movesTheLineAboveTheTurn() throws {
        let store = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        let turns = try (1...3).map { try Fixture.turn("t\($0)", number: $0) }
        store.markViewed(through: turns[2], source: .decisionBar)

        store.markNotViewed(from: turns[1], turns: turns, source: .turnRow)

        #expect(store.line(of: Fixture.conversation)?.lastViewedTurnID == TurnID("t1"))
        #expect(!store.isViewed(turns[1]))
    }

    @Test func eachMove_movesTheRefToTheTreeTheLineStandsAt() throws {
        try withTempDir { dir in
            let refs = RecordingRefs()
            let store = ViewedLineStore(directory: dir, refs: refs)
            let taken = try Fixture.turn("a", changes: Fixture.changedFiles, number: 1, endTree: Self.tree)
            let untaken = try Fixture.turn("b", changes: Fixture.changedFiles, number: 2)

            let first = try #require(store.markViewed(through: taken, source: .decisionBar))
            #expect(first.to == ViewedLinePosition(taken))
            let change = try #require(store.markViewed(through: untaken, source: .decisionBar))
            #expect(change.from == ViewedLinePosition(taken))
            #expect(change.to == ViewedLinePosition(untaken))
            #expect(store.undo(change.id, in: Fixture.conversation))
            #expect(store.line(of: Fixture.conversation)?.position == ViewedLinePosition(taken))
            store.forget([Fixture.conversation])
            store.flushSynchronously()

            let conversation = Fixture.conversation
            #expect(refs.events == [
                .move(.init(conversation: conversation, from: nil, to: Self.tree)),
                .move(.init(conversation: conversation, from: Self.tree, to: nil)),
                .move(.init(conversation: conversation, from: nil, to: Self.tree)),
                .move(.init(conversation: conversation, from: Self.tree, to: nil)),
                .flush
            ])
            #expect(store.line(of: conversation) == nil)
        }
    }

    @Test(arguments: [false, true])
    func aRunThatMayNotWrite_keepsLinesInMemoryOnly(hasExistingFile: Bool) throws {
        try withTempDir { dir in
            let original = Data(#"""
            {"schemaVersion":1,"lines":[{"conversation":{"provider":"claude","conversationId":"s1","isFallback":false},
            "position":{"turnID":"t3","displayNumber":3},"history":[]}]}
            """#.utf8)
            if hasExistingFile {
                try original.write(to: file(in: dir))
                #expect(try ViewedLineStore(directory: dir).isViewed(Fixture.turn("t3", number: 3)), "the fixture can be loaded")
            }
            let refs = RecordingRefs()
            let store = ViewedLineStore(directory: dir, writesFiles: false, refs: refs)
            #expect(try !store.isViewed(Fixture.turn("t3", number: 3)))
            let turn = try Fixture.turn("a", number: 1, endTree: Self.tree)
            store.markViewed(through: turn, source: .decisionBar)
            store.flushSynchronously()

            #expect(store.isViewed(turn))
            if hasExistingFile {
                #expect(try Data(contentsOf: file(in: dir)) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: file(in: dir).path))
            }
            #expect(refs.moves.isEmpty, "nor the person's repositories")
        }
    }

    @Test func aNewerBuildsFile_isReadButNotRewritten() throws {
        try withTempDir { dir in
            let newer = Data(#"""
            {"schemaVersion":2,"lines":[{"conversation":{"provider":"claude","conversationId":"s1","isFallback":false},
            "position":{"turnID":"t3","displayNumber":3},"history":[]}],"more":true}
            """#.utf8)
            try newer.write(to: file(in: dir))
            let store = ViewedLineStore(directory: dir)

            #expect(try store.isViewed(Fixture.turn("t2", number: 2)))
            #expect(try store.isViewed(Fixture.turn("t3", number: 3)))
            #expect(try !store.isViewed(Fixture.turn("t4", number: 4)))
            try store.markViewed(through: Fixture.turn("t4", number: 4), source: .decisionBar)
            store.flushSynchronously()

            #expect(try store.isViewed(Fixture.turn("t4", number: 4)), "updated in memory")
            #expect(try Data(contentsOf: file(in: dir)) == newer)
        }
    }

    @Test(.tags(.smoke)) func theRef_pointsAtTheTreeInTheRepository() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("a", to: "a.txt")
        try await repo.git(["add", "a.txt"])
        let tree = try await repo.git(["write-tree"])
        let refs = ViewedLineRefs()
        let snapshot = SnapshotTree(tree: tree, root: repo.url.path)
        let ref = ViewedLineRefs.refName(of: Fixture.conversation)

        refs.move(Fixture.conversation, from: nil, to: snapshot)
        refs.waitForPendingMoves()
        let pointed = try await GitProcess.run(["rev-parse", ref], cwd: repo.url)
        #expect(pointed.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == tree)

        refs.move(Fixture.conversation, from: snapshot, to: nil)
        refs.waitForPendingMoves()
        #expect(try await !GitProcess.run(["rev-parse", "--verify", "--quiet", ref], cwd: repo.url).succeeded)
    }

    @Test(.tags(.smoke)) func aLineMovingToAnotherRepository_takesItsRefAlong() async throws {
        let first = try await TempGitRepo.make()
        defer { first.cleanup() }
        let second = try await TempGitRepo.make()
        defer { second.cleanup() }
        let refs = ViewedLineRefs()
        let ref = ViewedLineRefs.refName(of: Fixture.conversation)
        try second.write("destination", to: "destination.txt")
        try await second.git(["add", "destination.txt"])
        let firstTree = try await first.git(["write-tree"])
        let secondTree = try await second.git(["write-tree"])
        try #require(firstTree != secondTree)
        let from = SnapshotTree(tree: firstTree, root: first.url.path)

        refs.move(Fixture.conversation, from: nil, to: from)
        refs.waitForPendingMoves()
        #expect(try await first.git(["rev-parse", ref]) == firstTree)
        refs.move(Fixture.conversation, from: from, to: SnapshotTree(tree: secondTree, root: second.url.path))
        refs.waitForPendingMoves()

        #expect(try await !GitProcess.run(["rev-parse", "--verify", "--quiet", ref], cwd: first.url).succeeded)
        #expect(try await second.git(["rev-parse", ref]) == secondTree)
    }

    // MARK: - A file that cannot be read

    // The file holds the deleted turns' spans and the restores' moves as
    // well as the lines; dropping it would lose them for good.

    @Test func aFileThatDoesNotDecode_isMovedAside_notSavedOver() throws {
        try withTempDir { dir in
            let garbled = Data(#"{ "schemaVersion": 1, "lines": "#.utf8)
            try garbled.write(to: file(in: dir))

            let store = ViewedLineStore(directory: dir)
            let turn = try Fixture.turn("b", number: 2)
            #expect(!store.isViewed(turn))
            #expect(!FileManager.default.fileExists(atPath: file(in: dir).path))
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            try #require(names.count == 1)
            let kept = try #require(names.first { $0.hasPrefix("viewed-lines.json.bak-decode-failed-") })
            try #require(Data(contentsOf: dir.appendingPathComponent(kept)) == garbled)
            store.markViewed(through: turn, source: .decisionBar)
            store.flushSynchronously()

            #expect(try Data(contentsOf: dir.appendingPathComponent(kept)) == garbled)
            #expect(ViewedLineStore(directory: dir).line(of: turn.conversation)?.position == ViewedLinePosition(turn))
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func aMalformedFile_thatCannotBeMovedAside_isNeverSavedOver() throws {
        try withTempDir { dir in
            let garbled = Data(#"{ "schemaVersion": 1, "lines": "#.utf8)
            try garbled.write(to: file(in: dir))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = ViewedLineStore(directory: dir)
            try #require(store.suspendedFile == file(in: dir))
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [file(in: dir).lastPathComponent])
            // A rejected write must not hide a missing saving suspension.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try store.markViewed(through: Fixture.turn("b", number: 2), source: .decisionBar)
            store.flushSynchronously()

            #expect(try Data(contentsOf: file(in: dir)) == garbled)
        }
    }

    /// A folder that cannot be searched hides the file in it, which is not
    /// a first launch: the check that a file exists answers no there too.
    /// Saving stops, and says so, so a save once the folder opens up again
    /// cannot replace the file with what this launch recorded.
    @Test(.enabled(if: geteuid() != 0))
    func aFileInAFolderThatCannotBeSearched_isNeverSavedOver() async throws {
        try await withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let span = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 100)
            try #require(await ViewedLineStore(directory: dir).noteDeletedTurns([dir.path: [span]]))
            let original = try Data(contentsOf: file(in: dir))
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            try #require(throws: (any Error).self) { try Data(contentsOf: file(in: dir)) }
            let store = ViewedLineStore(directory: dir)
            try #require(store.suspendedFile == file(in: dir))
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try store.markViewed(through: Fixture.turn("b", number: 2), source: .decisionBar)
            store.flushSynchronously()

            #expect(try Data(contentsOf: file(in: dir)) == original, "the deleted turns' spans are still there")
            #expect(store.suspendedFile == file(in: dir))
        }
    }

    /// The deleted turns' spans are written on their own, with the debounce
    /// canceled. A quit while that write is still on its way must wait for
    /// it: the spans are the only record of when those turns ran.
    @Test func flush_waitsForTheDeletedTurnsSpansWriteOnItsWay() async throws {
        try await withTempDir { dir in
            let queue = DispatchQueue(label: "viewed-lines-test")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let queueEntered = Recorded(false)
            let queueReleased = Recorded(false)
            queue.async {
                queueEntered.value = true
                queueReleased.value = release.wait(timeout: .now() + 10) == .success
            }
            await pollUntil { queueEntered.value }
            try #require(queueEntered.value)

            let refs = RecordingRefs {
                // The flush calls the ref writer before waiting on the
                // persistence queue. Release only once that call is reached.
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) { release.signal() }
            }
            let store = ViewedLineStore(directory: dir, refs: refs, saveQueue: queue)
            let span = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 100)
            let spans = [dir.path: [span]]
            let noting = Task { await store.noteDeletedTurns(spans) }
            await pollUntil { store.deletedTurns == spans }
            #expect(store.deletedTurns == spans)
            #expect(!FileManager.default.fileExists(atPath: file(in: dir).path))

            store.flushSynchronously()

            #expect(refs.events == [.flush])
            #expect(queueReleased.value)
            #expect(ViewedLineStore(directory: dir).deletedTurns == spans)
            #expect(await noting.value)
        }
    }
}
