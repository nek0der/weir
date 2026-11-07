// RestorePresentationTests.swift
// Weir — what a restore says and decides: the confirmation, how it ended, the record, and the turns it took back.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct RestorePresentationTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let other = ConversationKey(provider: .claude, conversationID: "s2", isFallback: false)

    private static let changes = #"{"kind":"changed","files":1,"added":10,"removed":2}"#
    private static let appliedStage = #"{"kind":"applied"}"#
    private static let wholeWithSaveStage = #"{"kind":"partiallyApplied","reason":"keptAside","currentTree":"c","#
        + #""failed":[{"path":"a.txt","reason":"keptAside:.weir-OP/target/ready-1/a.txt"}]}"#

    private static func turn(
        _ number: Int,
        changes: String = changes,
        hasPrompt: Bool = true,
        root: String = "/repo",
        conversationID: String = "s1",
        startedAt: String? = nil
    ) throws -> TurnSummary {
        try TurnSummaryFixture.restorable(
            number, changes: changes, hasPrompt: hasPrompt, root: root, conversationID: conversationID, startedAt: startedAt
        )
    }

    private static func gate(_ turn: TurnSummary, agents: [RestoreGate.Agent] = []) -> RestoreGate.Input {
        RestoreGate.Input(turn: turn, agents: agents, isWaiting: false, isRestoring: false)
    }

    // MARK: - The confirmation

    @Test func theConfirmation_namesTheTurnsUndone_andAddsUpTheirChanges() throws {
        let turns = try [Self.turn(5), Self.turn(6), Self.turn(7, changes: #"{"kind":"unchanged"}"#)]
        let undone = RestoreConfirmation.undone(by: turns[0], in: [TurnSummaryFixture.conversation: turns])
        let confirmation = RestoreConfirmation.make(turn: turns[0], undone: undone, gate: Self.gate(turns[0]), locale: Self.english)

        #expect(undone.map(\.displayNumber) == [5, 6, 7])
        #expect(confirmation.text == "Discard the changes in T5–T7 (+20 −4) and restore the code to before turn 5.")
        #expect(confirmation.note == "The conversation, staged changes, and commits aren’t changed")
        #expect(confirmation.blockedReason == nil)
        let japanese = RestoreConfirmation.make(turn: turns[0], undone: undone, gate: Self.gate(turns[0]), locale: Self.japanese)
        #expect(japanese.text == "T5〜T7 の変更（+20 −4）を破棄し、コードを T5 の前の状態に復元します。", "a run of turns as one range")
        #expect(japanese.note == "会話、ステージ済みの変更、コミットは変わりません")
        #expect(confirmation.textRuns(locale: Self.english) == [
            ReceiptRun(text: "Discard the changes in T5–T7 (", role: .emphasized),
            ReceiptRun(text: "+20", role: .added(isEmphasized: true)),
            ReceiptRun(text: " ", role: .emphasized),
            ReceiptRun(text: "−4", role: .removed(isEmphasized: true)),
            ReceiptRun(text: ") and restore the code to before turn 5.", role: .emphasized)
        ])
    }

    @Test func theConfirmationsCounts_areGroupedAsThePanelWritesThem_andFoundForTheirColors() {
        let text = RestoreText.confirmation(first: 5, last: 5, added: 12345, removed: 2, locale: Self.english)
        #expect(text == "Discard the changes in T5 (+12,345 −2) and restore the code to before turn 5.")
        let confirmation = RestoreConfirmation(text: text, note: "", blockedReason: nil, added: 12345, removed: 2)
        #expect(confirmation.textRuns(locale: Self.english).filter { $0.role != .emphasized } == [
            ReceiptRun(text: "+12,345", role: .added(isEmphasized: true)),
            ReceiptRun(text: "−2", role: .removed(isEmphasized: true))
        ])
    }

    /// Unprompted work is counted without adding its turn number to the heading.
    @Test(arguments: [(7, true, "+10 −2"), (5, false, "+20 −4")])
    func aSingleNamedTurn_keepsUnpromptedChangesInItsCounts(number: Int, isAlone: Bool, counts: String) throws {
        let turn = try Self.turn(number)
        let turns = try isAlone ? [turn] : [turn, Self.turn(number + 1, hasPrompt: false)]
        let undone = RestoreConfirmation.undone(by: turn, in: [turn.conversation: turns])
        let confirmation = RestoreConfirmation.make(turn: turn, undone: undone, gate: Self.gate(turn), locale: Self.english)
        #expect(undone.map(\.turnID) == turns.map(\.turnID))
        #expect(confirmation.text == "Discard the changes in T\(number) (\(counts)) and restore the code to before turn \(number).")
    }

    @Test func aSharedWorktree_saysOthersChangesGoToo_andABlockedGateSaysWhy() throws {
        let turn = try Self.turn(5)
        let agents = [
            RestoreGate.Agent(provider: .claude, state: .idle, isTurnsOwn: true),
            RestoreGate.Agent(provider: .codex, state: .running, isTurnsOwn: false)
        ]
        let confirmation = RestoreConfirmation.make(
            turn: turn,
            undone: [turn],
            gate: Self.gate(turn, agents: agents),
            locale: Self.japanese
        )
        #expect(confirmation.note == "会話、ステージ済みの変更、コミットは変わりません · 同じワークツリーのほかのエージェントによる変更と手動の変更も復元されます")
        let english = RestoreConfirmation.make(turn: turn, undone: [turn], gate: Self.gate(turn, agents: agents), locale: Self.english)
        #expect(english.blockedReason == "Unavailable while Codex is running in the same worktree.")
        #expect(english.help(locale: Self.english) == english.text
            + " The counts don’t include the lines of other conversations’ turns in this worktree.")
        let own = RestoreGate.Agent(provider: .claude, state: .idle, isTurnsOwn: true)
        let foreign = RestoreGate.Agent(provider: .codex, state: .idle, isTurnsOwn: false)
        let sharedIdle = RestoreConfirmation.make(
            turn: turn, undone: [turn], gate: Self.gate(turn, agents: [own, foreign]), locale: Self.japanese
        )
        #expect(sharedIdle.note == confirmation.note)
        #expect(sharedIdle.blockedReason == nil)

        let ownOnly = RestoreConfirmation.make(
            turn: turn, undone: [turn], gate: Self.gate(turn, agents: [own]), locale: Self.english
        )
        #expect(ownOnly.blockedReason == nil)
        #expect(ownOnly.note == "The conversation, staged changes, and commits aren’t changed")
        #expect(ownOnly.help(locale: Self.english) == ownOnly.text)
        // Japanese sentences run on without a space between them.
        #expect(confirmation.help(locale: Self.japanese)
            == confirmation.text + RestoreText.countsOwnTurnsOnly(locale: Self.japanese))
    }

    @Test func undone_leavesEarlierTurnsOtherWorktreesAndRestoredTurnsOut() throws {
        let turns = try [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(8, root: "/other")]
        let foreign = try Self.turn(7, conversationID: "s2")
        let undone = RestoreConfirmation.undone(by: turns[1], in: [
            TurnSummaryFixture.conversation: turns, foreign.conversation: [foreign]
        ]) { $0.turnID == turns[2].turnID }
        #expect(undone.map(\.turnID) == [turns[1].turnID])
    }

    @Test func theStrip_givesWayToWhatTheAgentAsks_butNotToUnreadTurnsOrAStop() {
        let pane = UUID()
        let passive = [AttentionItem.testUnread(pane: pane), .testStop(pane: pane)]
        let request = AttentionItem.testPrompt(PromptWait(detail: nil), pane: pane)
        #expect(!RestoreStrip.yields(to: []))
        #expect(!RestoreStrip.yields(to: passive))
        #expect(RestoreStrip.yields(to: passive + [request]))
    }

    // MARK: - The palette's turn

    private static func line(through turn: TurnSummary) -> ViewedLine {
        ViewedLine(conversation: turn.conversation, position: ViewedLinePosition(turn))
    }

    /// The first unviewed turn that can be restored to, else the latest.
    @Test func thePalette_restoresToTheFirstUnviewedTurn_elseTheLatest() throws {
        let turns = try [
            Self.turn(4),
            Self.turn(5, changes: #"{"kind":"unchanged"}"#),
            Self.turn(6, hasPrompt: false),
            Self.turn(7),
            Self.turn(8)
        ]
        let viewedThrough4 = Self.line(through: turns[0])

        #expect(RestoreEntryTarget.turn(in: turns, line: viewedThrough4)?.displayNumber == 7)
        #expect(RestoreEntryTarget.turn(in: turns, line: nil) { $0.displayNumber == 4 }?.displayNumber == 7)
        let allViewed = Self.line(through: turns[4])
        #expect(RestoreEntryTarget.turn(in: turns, line: allViewed)?.displayNumber == 8)
        #expect(RestoreEntryTarget.turn(in: [turns[1]], line: nil) == nil)
        // Still running, or its start not recorded: passed over.
        var recorded = TurnSummaryFixture.Extras()
        recorded.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("b", 9), root: "/repo")
        let running = try TurnSummaryFixture.turn("run", phase: "started", changes: Self.changes, number: 9, extras: recorded)
        var unrecorded = TurnSummaryFixture.Extras()
        unrecorded.beginTree = nil
        let unrecordedTurn = try TurnSummaryFixture.turn("unrec", changes: Self.changes, number: 10, extras: unrecorded)
        #expect(RestoreEntryTarget.turn(in: [running], line: nil) == nil)
        #expect(RestoreEntryTarget.turn(in: [unrecordedTurn], line: nil) == nil)
    }

    // MARK: - How it ended

    @Test func eachOutcome_endsAsTheAppTakesIt() throws {
        for stage in [Self.appliedStage, Self.wholeWithSaveStage] {
            let journal = try RestoreJournalFixture.restore(stage)
            #expect(RestoreEnding(.finished(journal)) == .applied(journal))
        }
        let partial = try RestoreJournalFixture.restore(
            #"{"kind":"partiallyApplied","reason":"externalChangeDetected","kept":["a"],"currentTree":"c","failed":["#
                + #"{"path":"b","reason":"writeFailed"},{"path":"c","reason":"keptAside:.weir-OP/ready/c"}]}"#
        )
        #expect(RestoreEnding(.finished(partial)) == .partial(
            partial, kept: ["a"], failed: ["b"], keptAside: [RestoreKeptAside(path: "c", location: ".weir-OP/ready/c")]
        ))
        let edited = try RestoreJournalFixture.restore(#"{"kind":"aborted","reason":"externalChangeDetected"}"#)
        #expect(RestoreEnding(.finished(edited)) == .canceled(.otherChanges))
        let prompted = try RestoreJournalFixture.restore(#"{"kind":"aborted","reason":"agentStarted"}"#)
        #expect(RestoreEnding(.finished(prompted)) == .canceled(.refused(.agentStarted)))
        #expect(RestoreEnding(.refused(.mergeInProgress)) == .canceled(.refused(.mergeInProgress)))
        let elsewise = try RestoreJournalFixture.restore(#"{"kind":"aborted","reason":"someday"}"#)
        #expect(RestoreEnding(.finished(elsewise)) == .canceled(.unknown))
        // Not known: nothing may say no file was changed.
        #expect(RestoreEnding(nil) == .unknown(opID: nil))
        let writing = try RestoreJournalFixture.restore(#"{"kind":"writing"}"#)
        #expect(RestoreEnding(.finished(writing)) == .unknown(opID: "OP"))
        #expect(try RestoreEnding(.finished(RestoreJournalFixture.restore(#"{"kind":"someday"}"#))) == .unknown(opID: "OP"))
    }

    @Test func theStrip_saysWhetherFilesWereWritten() {
        #expect(RestoreText.ended(.canceled(.refused(.mergeInProgress)), locale: Self.english)
            == "Restore canceled. A merge, a rebase, or a conflict is in progress.")
        #expect(RestoreText.ended(.canceled(.otherChanges), locale: Self.japanese)
            == "復元を中止しました。ほかの変更が見つかったため、ファイルは変更していません。")
        #expect(RestoreText.ended(.canceled(.unknown), locale: Self.english) == "Restore canceled. No files were changed.")
        #expect(RestoreText.ended(.canceled(.unknown), locale: Self.japanese) == "復元を中止しました。ファイルは変更していません。")
        // A refusal the person cannot act on says only that nothing was written.
        #expect(RestoreText.ended(.canceled(.refused(.lockUnavailable)), locale: Self.english)
            == "Restore canceled. No files were changed.")
        #expect(RestoreText.ended(.partial(kept: ["a.txt"], failed: ["b"]), locale: Self.english)
            == "Restored only part of the code. Kept the files changed meanwhile: a.txt. Couldn’t write: b.")
        #expect(RestoreText.ended(.partial(kept: ["a.txt"], failed: ["b", "c", "d", "e"]), locale: Self.english)
            == "Restored only part of the code. Kept the files changed meanwhile: a.txt. Couldn’t write: b, c, d, and 1 more.")
        #expect(RestoreText.ended(.partial(kept: [], failed: ["b", "c", "d", "e"]), locale: Self.japanese)
            == "コードの一部だけを復元しました。書き込めなかったファイル：b、c、d ほか 1 件。")
        // A save another writer made into a file the restore took out was
        // moved aside, and the strip says where.
        let aside = [RestoreKeptAside(path: "a.txt", location: ".weir-OP/ready-1/a.txt")]
        #expect(RestoreText.ended(.partial(kept: [], failed: [], keptAside: aside), locale: Self.japanese)
            == "コードの一部だけを復元しました。その間に保存された内容は .weir-OP/ready-1/a.txt に移動しました。")
        #expect(RestoreText.ended(.canceled(.refused(.unsupportedVolume)), locale: Self.english)
            == "Restore canceled. These files can’t be swapped in one step where they are, so this isn’t available here.")
        #expect(RestoreText.ended(.canceled(.refused(.renamedInPlace(["Name.txt"]))), locale: Self.japanese)
            == "復元を中止しました。このボリュームが同じ名前として扱う名前への変更（大文字と小文字だけの違いなど）があります：Name.txt。")
        #expect(RestoreText.ended(.unknown, locale: Self.english)
            == "Couldn’t tell how the restore ended. Check the working tree before going on.")
    }

    @Test func aRecoveryToast_includesWhereAnInterveningSaveWasKept() throws {
        let whole = try RestoreJournalFixture.restore(Self.wholeWithSaveStage)
        #expect(RestoreText.toast(
            ToastKind.restoreInterrupted.message.resolved(in: Self.japanese),
            note: RestoreText.keptAsideSentence(whole.stage.keptAside, locale: Self.japanese),
            locale: Self.japanese
        ) == "前回の終了時に、コードの復元が途中で中断されました。その間に保存された内容は .weir-OP/target/ready-1/a.txt に移動しました。")
    }

    @Test func theRecord_namesTheTurn_andSaysWhenOnlyPartIsThere() throws {
        #expect(try RestoreText.record(RestoreJournalFixture.restore(#"{"kind":"applied"}"#), locale: Self.japanese) == "T5 の前に復元済み")
        let partial = #"{"kind":"partiallyApplied","reason":"interrupted","currentTree":"c"}"#
        #expect(try RestoreText.record(RestoreJournalFixture.restore(partial), locale: Self.english) == "Partly restored to before T5")
        let unnamed = try RestoreJournalFixture.make(stageJSON: #"{"kind":"applied"}"#, fields: .init(turnID: "T5", at: "x"))
        #expect(RestoreText.record(unnamed, locale: Self.japanese) == "コードを復元済み")
        let whole = try RestoreJournalFixture.restore(Self.wholeWithSaveStage)
        #expect(RestoreText.record(whole, locale: Self.english) == "Restored to before T5")
        #expect(RestoreText.recordHelp(locale: Self.english).hasPrefix("Only the working tree was restored."))
    }

    @Test func anUndoThatFellShort_saysHow() {
        #expect(RestoreText.undoResult(.refused(.changedSinceRestore(paths: ["a", "b", "c", "d"])), locale: Self.english)
            == "Couldn’t undo the restore. Files changed since then: a, b, c, and 1 more.")
        #expect(RestoreText.undoResult(.refused(.restoreNotFound), locale: Self.japanese)
            == "復元を取り消せませんでした。ファイルは変更していません。")
        #expect(RestoreText.undoResult(.partial(keptAside: []), locale: Self.japanese) == "復元の一部だけを取り消しました。")
        let aside = [RestoreKeptAside(path: "a.txt", location: ".weir-OP/out/a.txt")]
        #expect(RestoreText.undoResult(.partial(keptAside: aside), locale: Self.english)
            == "Undid only part of the restore. Saves made meanwhile were moved to .weir-OP/out/a.txt.")
        #expect(RestoreText.undoResult(.unknown, locale: Self.japanese)
            == "復元の取り消しの結果を確認できませんでした。続ける前に作業ツリーを確認してください。")
    }

    @Test func theUndoResult_isKeptOnlyWhenTheUndoFellShort() throws {
        let undone = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(undone)) == nil)
        let partial = try RestoreJournalFixture.restore(
            #"{"kind":"partiallyApplied","reason":"writeFailed","currentTree":"c","failed":["#
                + #"{"path":"a.txt","reason":"keptAside:.weir-OP/target/ready-1/a.txt"},"#
                + #"{"path":"b.txt","reason":"writeFailed"}]}"#
        )
        #expect(RestoreCoordinator.UndoResult(.finished(partial)) == .partial(keptAside: [
            RestoreKeptAside(path: "a.txt", location: ".weir-OP/target/ready-1/a.txt")
        ]))
        let aside = try RestoreJournalFixture.restore(Self.wholeWithSaveStage)
        #expect(RestoreCoordinator.UndoResult(.finished(aside)) == nil)
        // A refusal an agent's stop lifts may change; one of a gone
        // operation never does.
        #expect(RestoreCoordinator.UndoResult.refused(.agentActive(.claude)).mayChange)
        #expect(!RestoreCoordinator.UndoResult.refused(.notUndoable).mayChange)
        let aborted = try RestoreJournalFixture.restore(#"{"kind":"aborted","reason":"externalChangeDetected"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(aborted)) == .canceled)
        #expect(RestoreCoordinator.UndoResult(.refused(.notUndoable)) == .refused(.notUndoable))
        let writing = try RestoreJournalFixture.restore(#"{"kind":"writing"}"#)
        #expect(RestoreCoordinator.UndoResult(.finished(writing)) == .unknown)
        #expect(RestoreCoordinator.UndoResult(nil) == .unknown)
    }

    @Test func undoNews_saysWhereItKeptNewSavesOnlyOnce() throws {
        let plain = try RestoreJournalFixture.restore(Self.appliedStage)
        let aside = try RestoreJournalFixture.restore(Self.wholeWithSaveStage)
        #expect(RestoreText.keptAsideNews(.finished(aside), locale: Self.japanese)
            == "その間に保存された内容は .weir-OP/target/ready-1/a.txt に移動しました。")
        #expect(RestoreText.keptAsideNews(.finished(plain), locale: Self.japanese) == nil)
        let reported = [RestoreKeptAside(path: "a.txt", location: ".weir-OP/target/ready-1/a.txt")]
        #expect(RestoreText.keptAsideNews(.finished(aside), besides: reported, locale: Self.japanese) == nil)
    }

    @Test(arguments: [
        (RestoreGate.Blocker.notRecorded, "このターンの開始時点が記録されていないため、復元できません。"),
        (.turnRunning, "ターンの実行中は使用できません。"),
        (.agentRunning(other: nil), "エージェントの実行中は使用できません。"),
        (.agentRunning(other: .codex), "同じワークツリーで Codex が実行中のため使用できません。"),
        (.agentWaiting, "承認待ちまたは回答待ちのエージェントがあるため使用できません。"),
        (.restoring, "このワークツリーで復元または破棄を実行中です。")
    ])
    func everyBlocker_hasItsReason(blocker: RestoreGate.Blocker, message: String) {
        #expect(RestoreText.blocker(blocker, locale: Self.japanese) == message)
    }

    // MARK: - The turns a restore took back

    private static func isRepo(_ root: String) -> Bool {
        root == "/repo"
    }

    @Test func aRestore_tookBackEveryConversationsTurnsInItsWorktree_untilItRan() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(9)],
            Self.other: [Self.turn(7, conversationID: "s2"), Self.turn(8, root: "/other", conversationID: "s2")]
        ]
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#)

        let restored = RestoredTurns.of(journal, history: history, isRoot: Self.isRepo)

        // T4 began before the turn restored to, T8 elsewhere, and T9 after
        // the restore ran.
        #expect(Set(restored.map(\.turnID.rawValue)) == ["s1-T5", "s1-T6", "s2-T7"])
        #expect(RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
        var before = history
        before[TurnSummaryFixture.conversation]?.removeLast()
        #expect(!RestoredTurns.isSuperseded(journal, history: before, isRoot: Self.isRepo))
        try before[Self.other]?.append(Self.turn(10, conversationID: "s2"))
        #expect(RestoredTurns.isSuperseded(journal, history: before, isRoot: Self.isRepo))
    }

    /// The turns read as restored until the restore is undone, whichever
    /// list asks: a turn begun after it ends its record, not the fact that
    /// those changes are gone.
    @Test func theTurnsARestoreTookBack_staySo_untilItIsUndone() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(9)],
            Self.other: [Self.turn(7, conversationID: "s2")]
        ]
        let applied = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#)
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }
        #expect(RestoredTurns.isSuperseded(applied, history: history, isRoot: Self.isRepo))

        let ids = RestoredTurns.ids(journals: ["/repo": [applied]], history: history, isRoot: isRoot)
        #expect(Set(ids.map(\.rawValue)) == ["s1-T5", "s1-T6", "s2-T7"])
        let undone = try RestoreJournalFixture.restore(#"{"kind":"undone","by":"U"}"#)
        #expect(RestoredTurns.ids(journals: ["/repo": [undone]], history: history, isRoot: isRoot).isEmpty)
    }

    /// A restore that left some paths as another writer changed them, or
    /// could not write them, took back nothing whole: its turns keep their
    /// changes and are read as before. One that only moved saves aside is
    /// whole.
    @Test func onlyAWholeRestore_readsItsTurnsAsRestored() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(6)]
        ]
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }
        let whole = try RestoreJournalFixture.restore(Self.wholeWithSaveStage)
        #expect(whole.stage.isWhole)
        #expect(RestoredTurns.ids(journals: ["/repo": [whole]], history: history, isRoot: isRoot) == [
            TurnID("s1-T5"), TurnID("s1-T6")
        ])
        let partial = try RestoreJournalFixture.restore(
            #"{"kind":"partiallyApplied","reason":"externalChangeDetected","kept":["a"],"currentTree":"c"}"#
        )
        let discard = try RestoreJournalFixture.make(
            stageJSON: Self.appliedStage, fields: .init(operation: "discard", turnID: "s1-T5")
        )
        let undo = try RestoreJournalFixture.make(
            stageJSON: Self.appliedStage, fields: .init(turnID: "s1-T5", undoes: "prior")
        )
        let unknown = try RestoreJournalFixture.make(
            stageJSON: Self.appliedStage, fields: .init(operation: "future", turnID: "s1-T5")
        )
        for journal in [partial, discard, undo, unknown] {
            #expect(RestoredTurns.ids(journals: ["/repo": [journal]], history: history, isRoot: isRoot).isEmpty)
        }
    }

    /// Times are kept to the second, so a turn can start in the second the
    /// restore ran. Such a turn counts as begun after it
    /// (`RestoredTurns.began`): it is not taken back, and it ends the
    /// record. One a second earlier is the restore's.
    @Test func aTurnStartingInTheSecondTheRestoreRan_beganAfterIt() throws {
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#, at: "2026-10-12T00:07:30Z")
        let justBefore = try [TurnSummaryFixture.conversation: [
            Self.turn(5),
            Self.turn(6, startedAt: "2026-10-12T00:07:29Z")
        ]]
        #expect(Set(RestoredTurns.of(journal, history: justBefore, isRoot: Self.isRepo).map(\.turnID.rawValue)) == ["s1-T5", "s1-T6"])
        #expect(!RestoredTurns.isSuperseded(journal, history: justBefore, isRoot: Self.isRepo))

        let sameSecond = try [TurnSummaryFixture.conversation: [
            Self.turn(5),
            Self.turn(6, startedAt: "2026-10-12T00:07:30Z")
        ]]
        #expect(RestoredTurns.of(journal, history: sameSecond, isRoot: Self.isRepo).map(\.turnID.rawValue) == ["s1-T5"])
        #expect(RestoredTurns.isSuperseded(journal, history: sameSecond, isRoot: Self.isRepo))
        let isRoot: (String) -> (String) -> Bool = { root in { $0 == root } }
        #expect(RestoredTurns.ids(journals: ["/repo": [journal]], history: sameSecond, isRoot: isRoot).map(\.rawValue) == ["s1-T5"])
    }

    /// A journal whose time cannot be read ends no record, and takes back
    /// every turn from the one it went back to.
    @Test func aRestoreWithNoTimeKnown_isNeverSuperseded() throws {
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#, at: "someday")
        let history = try [TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(9)]]
        #expect(Set(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).map(\.turnID.rawValue)) == ["s1-T5", "s1-T9"])
        #expect(!RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
    }

    /// A restore a crash cut short is settled by a later recovery, which
    /// writes its journal again (`at`); when it ran stays (`ranAt`). A turn
    /// begun between the two began after the restore: its changes are not
    /// taken back, and it ends the record. One from before it still is.
    @Test func aTurnBegunBeforeRecoverySettledTheRestore_beganAfterIt() throws {
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#, at: "2026-10-12T00:20:00Z", ranAt: "2026-10-12T00:07:30Z")
        let history = try [TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(6), Self.turn(9)]]

        #expect(Set(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).map(\.turnID.rawValue)) == ["s1-T5", "s1-T6"])
        #expect(RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
    }

    /// A journal from before `ranAt` is read by its `at`, as before.
    @Test func aJournalWithoutRanAt_ranWhenItWasWritten() throws {
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#, at: "2026-10-12T00:20:00Z")
        #expect(journal.ranAt == "2026-10-12T00:20:00Z")
        let history = try [TurnSummaryFixture.conversation: [Self.turn(5), Self.turn(9), Self.turn(21)]]
        #expect(Set(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).map(\.turnID.rawValue)) == ["s1-T5", "s1-T9"])
        #expect(RestoredTurns.isSuperseded(journal, history: history, isRoot: Self.isRepo))
    }

    @Test func aRestoreWhoseTurnIsGone_tookBackNothingThatCanBeNamed() throws {
        let history = try [TurnSummaryFixture.conversation: [Self.turn(6)]]
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#)
        #expect(RestoredTurns.of(journal, history: history, isRoot: Self.isRepo).isEmpty)
    }

    /// The index built once for many journals answers as each journal
    /// asked alone does, so sharing it changes no turn's reading.
    @Test func everyStandingRestore_readFromOneIndex_answersAsEachAlone() throws {
        let history: [ConversationKey: [TurnSummary]] = try [
            TurnSummaryFixture.conversation: [Self.turn(4), Self.turn(5), Self.turn(6), Self.turn(9)],
            Self.other: [
                Self.turn(3, root: "/other", conversationID: "s2"),
                Self.turn(5, root: "/other", conversationID: "s2"),
                Self.turn(7, root: "/other-link", conversationID: "s2"),
                Self.turn(8, root: "/other", conversationID: "s2")
            ]
        ]
        let first = try RestoreJournalFixture.restore(Self.appliedStage)
        let second = try RestoreJournalFixture.make(
            stageJSON: Self.appliedStage,
            fields: .init(opID: "OTHER", root: "/other", turnID: "s2-T5", turnNumber: 5, at: "2026-10-12T00:07:30Z")
        )
        let isRoot: (String) -> (String) -> Bool = { root in
            { $0 == root || (root == "/other" && $0 == "/other-link") }
        }

        let ids = RestoredTurns.ids(journals: ["/repo": [first], "/other": [second]], history: history, isRoot: isRoot)

        let alone = [first, second].flatMap { RestoredTurns.of($0, history: history, isRoot: isRoot($0.root)) }
        #expect(ids == Set(alone.map(\.turnID)))
        #expect(Set(ids.map(\.rawValue)) == ["s1-T5", "s1-T6", "s2-T5", "s2-T7"])
    }

    /// The restored turns are worked out again only when the history, the
    /// journals (an Undo, a new restore, the sweep), or the path spellings
    /// moved; otherwise the kept answer is read.
    @Test func theRestoredTurns_areWorkedOutAgain_onlyWhenASourceMoved() throws {
        let applied = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#)
        let undone = try RestoreJournalFixture.restore(#"{"kind":"undone","by":"U"}"#)
        let cases: [(RestoredTurnsMemo.Key, Set<TurnID>)] = [
            (.init(historyRevision: 1, journals: ["/repo": [applied]], pathGeneration: 0), [TurnID("initial")]),
            (.init(historyRevision: 2, journals: ["/repo": [applied]], pathGeneration: 0), [TurnID("history")]),
            (.init(historyRevision: 2, journals: ["/repo": [undone]], pathGeneration: 0), []),
            (.init(historyRevision: 2, journals: [:], pathGeneration: 0), [TurnID("swept")]),
            (.init(historyRevision: 2, journals: [:], pathGeneration: 1), [TurnID("paths")])
        ]
        var kept: RestoredTurnsMemo?
        var computed: [RestoredTurnsMemo.Key] = []
        for (key, result) in cases {
            let compute: (RestoredTurnsMemo.Key) -> Set<TurnID> = { asked in
                computed.append(asked)
                return result
            }
            #expect(RestoredTurnsMemo.ids(for: key, kept: &kept, compute: compute) == result)
            #expect(RestoredTurnsMemo.ids(for: key, kept: &kept, compute: compute) == result)
        }
        #expect(computed == cases.map(\.0))
    }

    /// The history's revision moves with its turns and only with them, so
    /// the kept restored turns are asked again exactly when they may differ.
    @MainActor
    @Test func theHistorysRevision_movesOnlyWhenItsTurnsChange() throws {
        let history = TurnHistory()
        let emptyRevision = history.revision
        let turns = try ConversationTurns(key: TurnSummaryFixture.conversation, turns: [Self.turn(5)])
        history.replace(with: [turns])
        let afterFirst = history.revision
        #expect(afterFirst != emptyRevision)
        history.replace(with: [turns])
        #expect(history.revision == afterFirst)
        let changed = try ConversationTurns(key: turns.key, turns: [Self.turn(5, root: "/other")])
        history.replace(with: [changed])
        let afterReplacement = history.revision
        #expect(afterReplacement != afterFirst)
        history.replace(with: [changed])
        #expect(history.revision == afterReplacement)
        try history.replace(with: [ConversationTurns(key: turns.key, turns: [Self.turn(5), Self.turn(6)])])
        #expect(history.revision != afterReplacement)
    }

    /// Letting go of a project's spellings moves the resolver's generation,
    /// as a folder made again may link elsewhere.
    @MainActor
    @Test func forgettingSpellings_movesThePathGeneration() {
        let paths = WorktreePathResolver(resolveLinks: { $0 })
        _ = paths.resolved("/repo")
        let before = paths.generation
        paths.forget([])
        #expect(paths.generation == before)
        paths.forget(["/repo"])
        #expect(paths.generation != before)
    }

    // MARK: - The bar after a restore

    @Test func theBar_saysTheRestoreIsNotInTheConversation_andOffersItsUndo() {
        let done = RestoreDone(opID: "OP", root: "/repo", turnNumber: 5)
        let content = DecisionBarContent.make(.init(done: .init(result: .restored(done), next: nil)))
        let model = DecisionBarModel(content: content, locale: Self.japanese)
        #expect(model.text == "T5 の前に復元済み · 会話には反映されていません")
        #expect(model.restoreDone == done)
        #expect(!model.isAtRest)
    }

    @Test(arguments: [
        (DecisionBarContent.Body.summary(.idle), true),
        (.summary(.running("Bash: swift test")), false),
        (.summary(.compacting), false),
        (.lastTurn(UnreadTurn(turnID: TurnID("t"), changes: .unchanged)), true),
        (.question(provider: .claude, answer: .terminal), false),
        (.prompt(provider: .claude, wait: .signIn), false),
        (.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown)), false)
    ])
    func theBar_yieldsToARestoreRecordOnlyAtRest(body: DecisionBarContent.Body, isAtRest: Bool) {
        let content = DecisionBarContent(body: body, position: nil, itemID: nil)
        #expect(DecisionBarModel(content: content, locale: Self.english).isAtRest == isAtRest)
    }
}
