// StopLedgerTests.swift
// Weir — a stop stays until its conversation is back, and "Resume Same Conversation" resumes it without a fresh start.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct StopLedgerTests: StopLedgerFixture {
    /// A session never prompted has no transcript, so its stop offers no
    /// resume (one could only fail) but still a new conversation; the
    /// launch rules retire such a run rather than resume it, and the stop
    /// kept across the relaunch must agree. One that says nothing, or was
    /// prompted, offers the resume as before.
    @Test func aStopOfASessionNeverPrompted_offersANewConversation_notAResume() throws {
        var ledger = StopLedger()
        var never = Self.run("a", .error)
        never.hasPrompt = false
        _ = ledger.update(runtimes: [never], paneExists: Self.always, cwd: { _ in "/tmp/repo" })
        let record = try #require(ledger.record(StopLedger.itemID(of: never)))
        #expect(record.sessionID == nil)
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .unavailable)
        #expect(StopResumeRules.newConversationCommand(for: record) == "cd '/tmp/repo' && claude")
        // Reported again, it still has nothing to resume.
        _ = ledger.update(runtimes: [never], paneExists: Self.always)
        #expect(ledger.record(StopLedger.itemID(of: never))?.sessionID == nil)

        for hasPrompt in [true, nil] as [Bool?] {
            var other = StopLedger()
            var run = Self.run("b", .error)
            run.hasPrompt = hasPrompt
            _ = other.update(runtimes: [run], paneExists: Self.always)
            let resumable = try #require(other.record(StopLedger.itemID(of: run)))
            #expect(resumable.sessionID == Self.sessionID)
            #expect(StopResumeRules.offer(record: resumable, job: .shell, hasDraft: false) == .available)
            run.hasPrompt = false
            _ = other.update(runtimes: [run], paneExists: Self.always)
            let corrected = try #require(other.record(StopLedger.itemID(of: run)))
            #expect(corrected.sessionID == nil)
            #expect(StopResumeRules.offer(record: corrected, job: .shell, hasDraft: false) == .unavailable)
        }
    }

    @Test func aRunInError_isAStop_thatStaysAfterTheRunIsGone() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        #expect(ledger.record(id)?.reason == .error("overloaded"))
        // Listed by the run itself while it says so.
        #expect(ledger.retained(besides: [Self.run("a", .error)]).isEmpty)

        // The agent exited, and its record was cleaned up.
        _ = ledger.update(runtimes: [], paneExists: Self.always)
        #expect(ledger.retained(besides: []).map(\.itemID) == [id])
        // The run's end (`unknown`) is no return either.
        _ = ledger.update(runtimes: [Self.run("a", .unknown, at: 5)], paneExists: Self.always)
        #expect(ledger.record(id) != nil)
    }

    /// A run whose process died at work is in error for the one pass the
    /// projection shows it before its record is retired. The stop is
    /// the process's exit, and it keeps what the resume needs after the run
    /// is gone.
    @Test func aRunWhoseProcessDied_isAStopThatKeepsItsResume_afterItsOnePass() throws {
        let json = #"{"state":"error","updatedAt":"2026-10-13T05:00:00Z","stopReason":"processExited"}"#
        let badge = try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(json.utf8)).asAgentBadge
        var exited = Self.run("a", .error, turn: "T1")
        exited.hasProcessExited = badge.hasProcessExited
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [exited], paneExists: Self.always, cwd: { _ in "/repo" })
        _ = ledger.update(runtimes: [], paneExists: Self.always)

        let kept = ledger.retained(besides: [])
        #expect(kept.map(\.reason) == [.processExited])
        #expect(kept.first?.sessionID == Self.sessionID)
        #expect(kept.first?.cwd == "/repo")
        #expect(kept.first?.turnID == TurnID("T1"))
    }

    @Test func theSameRunActiveAgain_endsTheStop() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        // Typed on in the TUI, in the same second.
        let resumed = ledger.update(runtimes: [Self.run("a", .running, episode: "2")], paneExists: Self.always).resumed
        #expect(ledger.records.isEmpty)
        #expect(resumed.isEmpty)
    }

    @Test func anotherRunOfTheSameConversation_endsTheStop_andAResumeSaysSo() throws {
        var ledger = StopLedger()
        let window = WindowID()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        ledger.markResuming(id, at: Self.start.addingTimeInterval(10), window: window)

        let original = try #require(ledger.record(id))
        // A different conversation elsewhere, an older report, and a report
        // exactly at the stop cannot establish that this conversation resumed.
        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        for unrelated in [
            Self.run("b", .idle, at: 20, pane: UUID(), conversation: other, sessionID: "x"),
            Self.run("c", .idle, at: -5),
            Self.run("c", .idle, at: 0)
        ] {
            let update = ledger.update(runtimes: [unrelated], paneExists: Self.always)
            #expect(update.resumed.isEmpty)
            #expect(update.movedOn.isEmpty)
            let retained = try #require(ledger.record(id))
            #expect(retained.runtimeID == original.runtimeID)
            #expect(retained.resume == original.resume)
            #expect(Set(ledger.records.keys) == [id])
        }

        let resumed = ledger.update(runtimes: [Self.run("d", .idle, at: 30)], paneExists: Self.always).resumed
        #expect(ledger.record(id) == nil)
        #expect(resumed == [.init(paneID: Self.pane, window: window)])
    }

    struct ResumeIdentity: Sendable {
        let run: String
        let turn: String?
        let hasBegunATurn: Bool
    }

    @Test(arguments: [
        ResumeIdentity(run: "a", turn: "t1", hasBegunATurn: false),
        ResumeIdentity(run: "a", turn: "n1", hasBegunATurn: true),
        ResumeIdentity(run: "d", turn: nil, hasBegunATurn: false),
        ResumeIdentity(run: "d", turn: "n1", hasBegunATurn: true)
    ], [AgentState.idle, .running])
    func aResumeWhoseRunAlreadyBeganATurn_saysSo(identity: ResumeIdentity, state: AgentState) throws {
        let window = WindowID()
        var ledger = StopLedger()
        let stopped = Self.run("a", .error, turn: "t1")
        let id = StopLedger.itemID(of: stopped)
        _ = ledger.update(runtimes: [stopped], paneExists: Self.always)
        ledger.markResuming(id, at: Self.start.addingTimeInterval(10), window: window)
        let record = try #require(ledger.record(id))
        #expect(record.turnID == TurnID("t1"))
        // Run and turn identity determine the receipt independently of
        // whether the returning agent currently reports idle or running.
        let resumed = ledger.update(
            runtimes: [Self.run(identity.run, state, at: 30, episode: "2", turn: identity.turn)],
            paneExists: Self.always
        ).resumed
        #expect(ledger.records.isEmpty)
        #expect(resumed == [.init(paneID: Self.pane, window: window, hasBegunATurn: identity.hasBegunATurn)])
    }

    /// The agent started again by hand in the stop's pane, on a new
    /// conversation, is the person moving on: the bar must not call the
    /// pane stopped over a working agent. Only a run active after the
    /// stop, in that pane, does so; the stop says nothing came back.
    @Test func aNewConversationStartedByHandInThePane_endsTheStop() {
        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        let window = WindowID()
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        ledger.markResuming(id, at: Self.start.addingTimeInterval(10), window: window)
        // The agent exited; a run from before the stop, one that ended, one
        // in error, or one in another pane is not the person moving on.
        for run in [
            Self.run("b", .idle, at: -5, conversation: other, sessionID: "x"),
            Self.run("b", .unknown, at: 20, conversation: other, sessionID: "x"),
            Self.run("b", .error, at: 20, conversation: other, sessionID: "x"),
            Self.run("b", .idle, at: 20, pane: UUID(), conversation: other, sessionID: "x")
        ] {
            var kept = ledger
            _ = kept.update(runtimes: [run], paneExists: Self.always)
            #expect(kept.record(id) != nil)
        }

        // Another provider's agent moves on as well.
        var codex = ledger
        _ = codex.update(
            runtimes: [RuntimeFact.test("c", .idle, provider: .codex, pane: Self.pane, updatedAt: Self.start.addingTimeInterval(20))],
            paneExists: Self.always
        )
        #expect(codex.record(id) == nil)

        let ended = ledger.update(runtimes: [Self.run("b", .idle, at: 20, conversation: other, sessionID: "x")], paneExists: Self.always)
        #expect(ledger.record(id) == nil)
        #expect(ledger.retained(besides: []).isEmpty)
        // The pane moved on, which its "Done" lines end with; nothing came back.
        #expect(ended == StopLedger.Ended(movedOn: [Self.pane]))
    }

    /// The stopped run still in its error beside a new one (two tmux
    /// sessions in the pane) is still there to type on: its stop stays.
    @Test func aNewConversationBesideTheStoppedRunStillInError_keepsTheStop() {
        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        var ledger = StopLedger()
        let stopped = Self.run("a", .error)
        _ = ledger.update(runtimes: [stopped], paneExists: Self.always)
        _ = ledger.update(
            runtimes: [stopped, Self.run("b", .running, at: 20, conversation: other, sessionID: "x")],
            paneExists: Self.always
        )
        #expect(ledger.record(StopLedger.itemID(of: stopped)) != nil)
    }

    @Test func closingThePane_endsTheStop() {
        var ledger = StopLedger()
        let closed = Self.run("a", .error)
        let survivingPane = UUID()
        let surviving = Self.run("b", .error, pane: survivingPane)
        _ = ledger.update(runtimes: [closed, surviving], paneExists: Self.always)
        #expect(ledger.records.count == 2)
        let ended = ledger.update(runtimes: []) { $0 == survivingPane }
        #expect(Set(ledger.records.keys) == [StopLedger.itemID(of: surviving)])
        #expect(ended.resumed.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func aNewerStopOfTheConversationInThePane_replacesTheOlder(newerFirst: Bool, reverseReports: Bool) throws {
        let older = Self.run("a", .error, turn: "T1")
        let newer = Self.run("b", .error, at: 50, episode: "9", turn: "T2")
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [newerFirst ? newer : older], paneExists: Self.always)
        let reports = reverseReports ? [newer, older] : [older, newer]
        _ = ledger.update(runtimes: reports, paneExists: Self.always)
        let newerID = StopLedger.itemID(of: newer)
        #expect(Set(ledger.records.keys) == [newerID])
        let retained = try #require(ledger.record(newerID))
        #expect(retained.runtimeID == newer.runtimeID)
        #expect(retained.stoppedAt == Self.start.addingTimeInterval(50))
        #expect(retained.turnID == TurnID("T2"))
        let (previous, _) = AttentionQueueReducer.reduce(
            AttentionQueue(), input: .init(runtimes: [newerFirst ? newer : older])
        )
        let (queue, _) = AttentionQueueReducer.reduce(
            previous,
            input: .init(runtimes: reports, dismissedStops: ledger.dismissed)
        )
        #expect(queue.items.map(\.id) == [newerID])
        _ = ledger.update(runtimes: [older], paneExists: Self.always)
        let kept = ledger.retained(besides: [older]).map { record in
            AttentionQueueReducer.RetainedStop(
                itemID: record.itemID, runtimeID: record.runtimeID, provider: record.provider,
                paneID: record.paneID, tabID: nil, projectID: nil,
                reason: record.reason, stoppedAt: record.stoppedAt
            )
        }
        let (afterExit, effects) = AttentionQueueReducer.reduce(
            queue, input: .init(runtimes: [older], retainedStops: kept, dismissedStops: ledger.dismissed)
        )
        #expect(afterExit.items.map(\.id) == [newerID])
        #expect(effects.isEmpty)
        let nextEpisode = Self.run("a", .error, at: 100, episode: "2", turn: "T3")
        _ = ledger.update(runtimes: [nextEpisode], paneExists: Self.always)
        #expect(Set(ledger.records.keys) == [StopLedger.itemID(of: nextEpisode)])
    }

    /// Two runs of the same agent in one pane (two tmux sessions attached
    /// there, or a run left in its error beside a new one) are two stops:
    /// each row's resume needs its own record, whichever stopped first.
    @Test func twoRunsOfOtherConversationsInThePane_keepAStopEach() {
        let other = ConversationKey(provider: .claude, conversationID: "c2", isFallback: false)
        let first = Self.run("a", .error, turn: "T1")
        let second = Self.run("b", .error, at: 50, episode: "9", conversation: other, sessionID: "s2", turn: "T2")
        for order in [[first, second], [second, first]] {
            var ledger = StopLedger()
            _ = ledger.update(runtimes: [order[0]], paneExists: Self.always)
            _ = ledger.update(runtimes: order, paneExists: Self.always)
            #expect(ledger.records.count == 2)
            #expect(ledger.record(StopLedger.itemID(of: first))?.sessionID == Self.sessionID)
            #expect(ledger.record(StopLedger.itemID(of: second))?.sessionID == "s2")
        }
    }

    @Test func aResumeThatTimedOut_isFailed_butALaterOneIsNotTouched() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let first = Self.start.addingTimeInterval(10)
        let second = Self.start.addingTimeInterval(20)
        ledger.markResuming(id, at: first, window: nil)
        ledger.markResuming(id, at: second, window: nil)
        ledger.resumeTimedOut(id, since: first, isAgentInFront: false)
        #expect(ledger.record(id)?.resume == .resuming(since: second, window: nil))
        ledger.resumeTimedOut(id, since: second, isAgentInFront: false)
        #expect(ledger.record(id)?.resume == .failed)
    }

    /// The resume's command came back to the shell at once (no transcript,
    /// a bad session id): no run of the conversation ever reported, so the
    /// stop is back with its button and says the resume failed.
    @Test func aResumeWhoseCommandReturnedToTheShell_isFailed_andTheStopStays() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let since = Self.start.addingTimeInterval(10)
        ledger.markResuming(id, at: since, window: nil)
        // The command began after the resume was typed, and ran briefly.
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(0.2), runTime: 0.4) == .failed(id))
        #expect(ledger.record(id)?.resume == .failed)
        #expect(StopResumeRules.offer(record: ledger.record(id), job: .shell, hasDraft: false) == .failed)
        // Not a new conversation: the stop and its session stay for the
        // next press.
        #expect(ledger.record(id)?.sessionID == Self.sessionID)
        #expect(ledger.retained(besides: []).map(\.itemID) == [id])
        #expect(ledger.record(id).flatMap(StopResumeRules.command(for:)) != nil)
    }

    @Test func aCommandOfAnotherPane_orOneThatBeganBeforeTheResume_isNotTheResume() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let since = Self.start.addingTimeInterval(10)
        ledger.markResuming(id, at: since, window: nil)
        #expect(ledger.resumeCommandFinished(inPane: UUID(), startedAt: since.addingTimeInterval(1), runTime: 1) == nil)
        #expect(ledger.resumeCommandFinished(inPane: Self.pane, startedAt: since.addingTimeInterval(-1), runTime: 1) == nil)
        #expect(ledger.record(id)?.resume == .resuming(since: since, window: nil))
        // A stop with no resume on its way has nothing to fail.
        var untouched = StopLedger()
        _ = untouched.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        #expect(untouched.resumeCommandFinished(inPane: Self.pane, startedAt: since, runTime: 1) == nil)
        #expect(untouched.record(id)?.resume == StopLedger.Resume.none)
    }

    @MainActor
    @Test func aStopKeptAfterItsRun_staysOneItem_inTheAttentionList() throws {
        try withTempDir { directory in
            let (session, project) = WorkspaceSessionFixture.withProject()
            let tab = session.openTab(container: .project(project.id))
            let pane = try #require(tab.splitTree.allLeafIDs().first)
            let run = Self.run("a", .error, pane: pane)
            let id = StopLedger.itemID(of: run)
            let (first, effects) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [run]))
            #expect(first.items.map(\.id) == [id])
            #expect(!effects.isEmpty)
            let store = StopLedgerStore(directory: directory, writesFiles: false)
            _ = store.update(runtimes: [run], paneExists: Self.always)
            #expect(store.retained(besides: [run], session: session).isEmpty)
            _ = store.update(runtimes: [], paneExists: Self.always)
            let retained = store.retained(besides: [], session: session)
            #expect(retained == [.init(
                itemID: id, runtimeID: run.runtimeID, provider: .claude,
                paneID: pane, tabID: tab.id, projectID: project.id,
                reason: .error("overloaded"), stoppedAt: Self.start
            )])
            let (second, again) = AttentionQueueReducer.reduce(first, input: .init(retainedStops: retained))
            #expect(second.items.map(\.id) == [id])
            #expect(second.items.first?.subject.paneID == pane)
            // Keeping the same stop does not announce it again.
            #expect(again.isEmpty)
            session.moveTab(tab.id, to: .loose)
            let moved = store.retained(besides: [], session: session)
            #expect(moved == [.init(
                itemID: id, runtimeID: run.runtimeID, provider: .claude,
                paneID: pane, tabID: tab.id, projectID: nil,
                reason: .error("overloaded"), stoppedAt: Self.start
            )])
        }
    }

    @Test func aStopOffersTheResume_onlyWithASession_andTheShellInFront_withNothingTyped() throws {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error), Self.run("n", .error, pane: UUID(), sessionID: nil)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let record = try #require(ledger.record(id))
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .available)
        #expect(StopResumeRules.offer(record: record, job: .agent, hasDraft: false) == .unavailable)
        #expect(StopResumeRules.offer(record: record, job: .other, hasDraft: false) == .blocked(.notAtShell))
        #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: true) == .blocked(.draft))
        let noSession = try #require(ledger.record(StopLedger.itemID(of: Self.run("n", .error))))
        #expect(noSession.sessionID == nil)
        #expect(StopResumeRules.offer(record: noSession, job: .shell, hasDraft: false) == .unavailable)
        #expect(StopResumeRules.offer(record: nil, job: .shell, hasDraft: false) == .unavailable)
        ledger.markResuming(id, at: Self.start, window: nil)
        #expect(StopResumeRules.offer(record: ledger.record(id), job: .shell, hasDraft: false) == .resuming)
        ledger.resumeTimedOut(id, since: Self.start, isAgentInFront: false)
        #expect(StopResumeRules.offer(record: ledger.record(id), job: .shell, hasDraft: false) == .failed)
    }

    @Test func whatTheRunReportsLater_isTheStopsToo() throws {
        var ledger = StopLedger()
        var run = Self.run("a", .error, sessionID: nil)
        let id = StopLedger.itemID(of: run)
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        let initial = try #require(ledger.record(id))
        #expect(initial.sessionID == nil)
        #expect(initial.turnID == nil)
        let window = WindowID()
        ledger.markResuming(id, at: Self.start, window: window)
        run.sessionID = Self.sessionID
        run.currentTurnID = TurnID("t7")
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        let enriched = try #require(ledger.record(id))
        #expect(Set(ledger.records.keys) == [id])
        #expect(enriched.sessionID == Self.sessionID)
        #expect(enriched.turnID == TurnID("t7"))
        #expect(enriched.resume == .resuming(since: Self.start, window: window))
    }

    @Test(arguments: [false, true])
    func aConversationBackInAnotherPane_endsTheStop_withoutAReceiptInTheOriginalPane(oldStillReports: Bool) {
        var ledger = StopLedger()
        let old = Self.run("a", .error)
        let back = Self.run("b", .running, at: 30, pane: UUID())
        _ = ledger.update(runtimes: [old], paneExists: Self.always)
        // Returning in another pane clears the original stop whether or
        // not the old runtime still reports its error.
        let id = StopLedger.itemID(of: old)
        ledger.markResuming(id, at: Self.start, window: WindowID())
        let reports = oldStillReports ? [old, back] : [back]
        for _ in 0..<2 {
            let ended = ledger.update(runtimes: reports, paneExists: Self.always)
            #expect(ledger.records.isEmpty)
            #expect(ended.resumed.isEmpty)
        }
        #expect(ledger.dismissed.contains(id) == oldStillReports)
        // Nor does the list make it again from the old run's error.
        let (queue, _) = AttentionQueueReducer.reduce(
            AttentionQueue(),
            input: .init(runtimes: reports, dismissedStops: ledger.dismissed)
        )
        #expect(!queue.items.map(\.id).contains(id))
        // A later error of the old run is a new stop.
        let again = Self.run("a", .error, at: 60, episode: "2")
        _ = ledger.update(runtimes: [again], paneExists: Self.always)
        #expect(ledger.records[StopLedger.itemID(of: again)] != nil)
    }

    @Test func aDismissedStop_isNotKeptAgain_whileItsRunStillSaysSo() {
        var ledger = StopLedger()
        let run = Self.run("a", .error)
        let id = StopLedger.itemID(of: run)
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        ledger.dismiss(id)
        _ = ledger.update(runtimes: [run], paneExists: Self.always)
        #expect(ledger.records.isEmpty)
        #expect(ledger.dismissed == [id])
        // The attention list leaves it out too.
        let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [run], dismissedStops: ledger.dismissed))
        #expect(queue.items.isEmpty)
        // Once the run no longer says so, the mark is let go.
        _ = ledger.update(runtimes: [], paneExists: Self.always)
        #expect(ledger.dismissed.isEmpty)
        // A later error of the run is a stop again.
        _ = ledger.update(runtimes: [Self.run("a", .error, at: 60, episode: "2")], paneExists: Self.always)
        #expect(ledger.records.count == 1)
    }

    @Test func aNewConversation_thatCannotStart_saysWhy() {
        #expect(StopResumeRules.newConversationBlocker(job: .shell, hasDraft: false) == nil)
        #expect(StopResumeRules.newConversationBlocker(job: .shell, hasDraft: true) == .draft)
        #expect(StopResumeRules.newConversationBlocker(job: .agent, hasDraft: false) == .notAtShell)
        #expect(StopResumeRules.newConversationBlocker(job: .other, hasDraft: true) == .notAtShell)
        #expect(StopResumeRules.newConversationBlocker(job: .agent, hasDraft: true) == .notAtShell)
        #expect(StopResumeRules.newConversationBlocker(job: .other, hasDraft: false) == .notAtShell)
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(StopResumeRules.newConversationHelp(.notAtShell).resolved(in: en)
            == "To start a new conversation, return the pane to its shell prompt.")
        #expect(StopResumeRules.newConversationHelp(.draft).resolved(in: ja)
            == "新しい会話で開始するには、Control-C でプロンプトを空にしてください。")
        #expect(StopResumeRules.newConversationHelp(.draft).resolved(in: en)
            == "To start a new conversation, clear the prompt with Control-C.")
        #expect(StopResumeRules.newConversationHelp(.notAtShell).resolved(in: ja)
            == "新しい会話で開始するには、ペインをシェルのプロンプトに戻してください。")
    }

    struct FallbackSession: Sendable {
        let stopped: String?
        let returning: String?
        let differentKey: Bool
        let isBack: Bool
    }

    /// A fallback conversation key names the pane rather than the
    /// conversation, so on its own it matches nothing: a run is the stopped
    /// conversation back only when the stopped run had a session id and the
    /// new run reports the same one. The new run is in another pane: in the
    /// stop's own, any other conversation is the person moving on.
    @Test(arguments: [
        FallbackSession(stopped: nil, returning: nil, differentKey: false, isBack: false),
        FallbackSession(stopped: nil, returning: "returning-session", differentKey: false, isBack: false),
        FallbackSession(stopped: "stopped-session", returning: nil, differentKey: false, isBack: false),
        FallbackSession(stopped: "stopped-session", returning: "different-session", differentKey: false, isBack: false),
        FallbackSession(stopped: "same-session", returning: "same-session", differentKey: false, isBack: true),
        FallbackSession(stopped: "same-session", returning: "same-session", differentKey: true, isBack: true)
    ])
    func aFallbackConversation_isBackOnlyBySessionID(_ input: FallbackSession) throws {
        let stopped = input.stopped
        let returning = input.returning
        let differentKey = input.differentKey
        let isBack = input.isBack
        var ledger = StopLedger()
        let fallback = ConversationKey(provider: .claude, conversationID: "stopped-pane", isFallback: true)
        let returningKey = ConversationKey(
            provider: .claude,
            conversationID: differentKey ? "returning-pane" : "stopped-pane",
            isFallback: true
        )
        let original = Self.run("a", .error, conversation: fallback, sessionID: stopped)
        let id = StopLedger.itemID(of: original)
        _ = ledger.update(runtimes: [original], paneExists: Self.always)
        let record = try #require(ledger.record(id))
        #expect(record.sessionID == stopped)
        let update = ledger.update(
            runtimes: [Self.run("b", .idle, at: 5, pane: UUID(), conversation: returningKey, sessionID: returning)],
            paneExists: Self.always
        )
        #expect(ledger.records.isEmpty == isBack)
        #expect((ledger.record(id) == nil) == isBack)
        #expect(update.resumed.isEmpty)
    }

    /// The resume and a new conversation both start where the conversation
    /// ran, quoted as typed.
    @Test func bothCommands_runInTheConversationsFolder() {
        var ledger = StopLedger()
        _ = ledger.update(runtimes: [Self.run("a", .error)], paneExists: Self.always) { _ in "/tmp/it's here" }
        let record = ledger.record(StopLedger.itemID(of: Self.run("a", .error)))
        #expect(record.flatMap(StopResumeRules.command(for:)) == "cd '/tmp/it'\\''s here' && claude --resume \(Self.sessionID)")
        #expect(record.flatMap(StopResumeRules.newConversationCommand(for:)) == "cd '/tmp/it'\\''s here' && claude")
        // No folder on record: the agent alone, where the shell is.
        var bare = StopLedger()
        _ = bare.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let bareRecord = bare.record(StopLedger.itemID(of: Self.run("a", .error)))
        #expect(bareRecord.flatMap(StopResumeRules.newConversationCommand(for:)) == "claude")
        #expect(bareRecord.flatMap(StopResumeRules.command(for:)) == "claude --resume \(Self.sessionID)")
        // A folder whose name would be keys rather than a name: nothing typed.
        var unsafe = StopLedger()
        _ = unsafe.update(runtimes: [Self.run("a", .error)], paneExists: Self.always) { _ in "/tmp/a\nb" }
        let unsafeRecord = unsafe.record(StopLedger.itemID(of: Self.run("a", .error)))
        #expect(unsafeRecord != nil)
        #expect(unsafeRecord.flatMap(StopResumeRules.newConversationCommand(for:)) == nil)
        #expect(unsafeRecord.flatMap(StopResumeRules.command(for:)) == nil)
    }
}
