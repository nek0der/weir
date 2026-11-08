// ApprovalPresentationStoreTests.swift
// Weir — the person's decisions the store sends, what a failed one leaves,
// and where the store places each request.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalPresentationStoreTests {
    @Test func resolve_answer_sendsAnswersAndClearsResolving() async {
        let recorded = DecisionRecorder()
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append(approval.id, resolution)
        })
        let request = approval(questions: [ApprovalQuestion(
            header: "Color", prompt: "Which color?", options: [.init(label: "Red", description: nil)], isMultiSelect: false
        )])
        store.receive([request])
        let answer = ApprovalResolution.answer(["Which color?": "Red"])
        store.resolve(request, answer)
        await recorded.waitForCount(1)
        await store.waitUntilResolved(request)
        let sent = await recorded.entries
        #expect(sent.map(\.id) == [request.id])
        #expect(sent.map(\.resolution) == [answer])
        #expect(store.resolvingIDs.isEmpty)
        #expect(store.ledger.entry(for: request)?.state == .answered(answer))
    }

    private struct Offline: Error, CustomStringConvertible {
        let description = "offline"
    }

    @Test func resolve_failure_clearsResolvingState() async {
        let recorded = DecisionRecorder()
        let store = ApprovalPresentationStore(decisionSender: { request, resolution in
            await recorded.append(request.id, resolution)
            throw Offline()
        })
        let request = approval(epoch: UUID())
        store.receive([request])
        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)
        let sent = await recorded.entries
        #expect(sent.map(\.id) == [request.id])
        #expect(sent.map(\.resolution) == [.allowOnce])
        #expect(store.resolvingIDs.isEmpty)
        #expect(store.lastFailureID == request.id)
        #expect(store.ledger.entry(for: request)?.state == .sendFailed(.allowOnce, error: "offline"))
        #expect(store.opensCard(request.key))
    }

    @Test func resolve_keepsTheFailureOfAnotherRequest() async {
        let recorded = DecisionRecorder()
        let failing = approval(epoch: UUID())
        let succeeding = approval(epoch: failing.epoch)
        let failingID = failing.id
        let store = ApprovalPresentationStore(decisionSender: { approval, resolution in
            await recorded.append(approval.id, resolution)
            if approval.id == failingID {
                throw Offline()
            }
        })
        store.receive([failing, succeeding])

        store.resolve(failing, .allowOnce)
        await store.waitUntilResolved(failing)
        #expect(store.lastFailureID == failing.id)

        store.resolve(succeeding, .deny)
        await store.waitUntilResolved(succeeding)
        let sent = await recorded.entries
        #expect(sent.map(\.id) == [failing.id, succeeding.id])
        #expect(sent.map(\.resolution) == [.allowOnce, .deny])
        #expect(store.ledger.entry(for: succeeding)?.state == .answered(.deny))
        #expect(store.ledger.entry(for: failing)?.state == .sendFailed(.allowOnce, error: "offline"))
        #expect(store.lastFailureID == failing.id)
    }

    /// A request is placed on the run that reported its session, or listed
    /// with no place when no run did.
    @Test func aLedgerRequest_isPlacedOnItsRuntimeOrListedUnplaced() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
        }
        let epoch = UUID()
        let placed = ApprovalPresentation.test(epoch: epoch, sessionID: "session")
        let unknown = ApprovalPresentation.test(epoch: epoch, sessionID: "elsewhere")
        store.receive([placed, unknown])

        store.runtimes = { [AgentRuntimePresentation.test(paneIDs: [paneID], sessionID: "session")] }
        let approvals = store.placedApprovals(in: session)
        let subjects = Dictionary(uniqueKeysWithValues: approvals.map { ($0.fact.key, $0.subject) })

        #expect(subjects[placed.key] == .runtime(
            id: "claude:run", provider: .claude, paneID: paneID, tabID: tab.id, projectID: nil
        ))
        #expect(subjects[unknown.key] == .unplaced(provider: .claude))
    }

    private func approval(epoch: UUID = UUID(), questions: [ApprovalQuestion] = []) -> ApprovalPresentation {
        ApprovalPresentation.test(epoch: epoch, deadlineMilliseconds: 0, questions: questions)
    }

    // MARK: - The run and pane a request belongs to, its wait, and its card

    @Test func aTmuxRunsRequest_isPlacedWhereTheRunIsAttachedNow() throws {
        // A tmux run writes no session hint; its request goes to the pane its
        // tmux pane is open in, not the one it started in.
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, _, launchPane) = WorkspaceSessionFixture.withLooseTab()
        let attachedTab = session.openTab(container: .loose)
        let attachedPane = try #require(attachedTab.splitTree.allLeafIDs().first)
        let run = AgentRuntimePresentation.test(
            badge: AgentBadge(state: .needsInput, updatedAt: Date()),
            paneIDs: [attachedPane],
            sessionID: "session"
        )
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch, sessionID: "session")
        #expect(store.paneLocation(for: request, in: session) == nil, "no run known yet, and no hint")

        store.runtimes = { [run] }
        let location = store.paneLocation(for: request, in: session)
        #expect(location?.0 == attachedTab.id)
        #expect(location?.1 == attachedPane)
        #expect(location?.1 != launchPane)

        // Another agent's run with the same session id is not this one.
        store.runtimes = { [AgentRuntimePresentation.test(
            kind: .codex,
            runID: "other",
            badge: AgentBadge(state: .needsInput, updatedAt: Date()),
            paneIDs: [launchPane],
            sessionID: "session"
        )] }
        #expect(store.paneLocation(for: request, in: session) == nil)
    }

    private static func run(
        id runID: String = "run",
        kind: AgentKind = .claude,
        state: AgentState = .needsInput,
        episode: String = "w1",
        panes: Set<UUID>,
        sessionID: String? = "session",
        sessionStartedAt: Date? = nil,
        updatedAt: Date = Date()
    ) -> AgentRuntimePresentation {
        var badge = AgentBadge(state: state, updatedAt: updatedAt)
        badge.sessionStartedAt = sessionStartedAt
        return AgentRuntimePresentation.test(
            kind: kind,
            runID: runID,
            badge: badge,
            paneIDs: panes,
            stateEpisodeToken: episode,
            sessionID: sessionID
        )
    }

    private static func storeWithRequest(
        in session: WorkspaceSession
    ) -> (store: ApprovalPresentationStore, request: ApprovalPresentation) {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch, sessionID: "session")
        store.apply(
            ApprovalControllerConnection.Projection(
                sequence: 1, requests: [request], terminals: [:], missingIDs: [],
                unevictableCount: 1, deadlines: [:]
            ),
            epoch: epoch,
            now: SuspendingClock.now
        )
        return (store, request)
    }

    @Test func onlyTheRequestsOwnWait_isSpokenForByItsBanner() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let (store, request) = Self.storeWithRequest(in: session)
        let waiting = Self.run(panes: [paneID])
        store.runtimes = { [waiting] }

        // Its first wait, before and after it is noted.
        #expect(store.isWaitOfRequest(runtimeID: waiting.id, episodeToken: "w1", in: session))
        store.noteWaitEpisodes(in: session)
        #expect(store.ledger.entry(for: request)?.waitEpisodeToken == "w1")
        #expect(store.isWaitOfRequest(runtimeID: waiting.id, episodeToken: "w1", in: session))

        // A later wait of the same run, or another run in the same pane.
        #expect(!store.isWaitOfRequest(runtimeID: waiting.id, episodeToken: "w2", in: session))
        let other = Self.run(id: "other", panes: [paneID], sessionID: "another")
        store.runtimes = { [waiting, other] }
        #expect(!store.isWaitOfRequest(runtimeID: other.id, episodeToken: "w1", in: session))

        // Timed out: its banner is gone, so the TUI's prompt announces itself.
        store.ledger.record(.deadlinePassed, for: request.id, now: SuspendingClock.now)
        #expect(!store.isWaitOfRequest(runtimeID: waiting.id, episodeToken: "w1", in: session))
    }

    @Test func aRunsWait_belongsToItsOldestListedRequest() throws {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        let run = UUID()
        let high = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let first = ApprovalPresentation.test(epoch: epoch, runID: run, requestID: high, sessionID: "session")
        let second = ApprovalPresentation.test(epoch: epoch, runID: run, requestID: low, sessionID: "session", toolName: "Edit")
        let earlier = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        store.receive([first], epoch: epoch, seenAt: earlier)
        store.receive([second, first], epoch: epoch, seenAt: later)
        try #require(store.ledger.entry(for: first)?.firstSeenAt == earlier)
        try #require(store.ledger.entry(for: second)?.firstSeenAt == later)
        try #require(first.id > second.id)

        store.runtimes = { [Self.run(panes: [paneID])] }
        store.noteWaitEpisodes(in: session)

        #expect(store.ledger.entry(for: first)?.waitEpisodeToken == "w1")
        #expect(store.ledger.entry(for: second)?.waitEpisodeToken == nil)
    }

    @Test func aRequestAfterAnEarlierOne_getsTheWaitThatFollows() {
        // A was handed to the terminal and holds w1 until the turn ends; the
        // same turn then asks B, and the run waits again as w2.
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let (store, first) = Self.storeWithRequest(in: session)
        store.runtimes = { [Self.run(panes: [paneID])] }
        store.noteWaitEpisodes(in: session)
        store.ledger.record(.handedOverBySetting, for: first.id, now: SuspendingClock.now)
        store.ledger.record(.sendSucceeded, for: first.id, now: SuspendingClock.now)

        let second = ApprovalPresentation.test(epoch: first.epoch, sessionID: "session", toolName: "Edit")
        store.apply(
            ApprovalControllerConnection.Projection(
                sequence: 2, requests: [first, second], terminals: [:], missingIDs: [],
                unevictableCount: 2, deadlines: [:]
            ),
            epoch: first.epoch,
            now: SuspendingClock.now
        )
        let run = Self.run(episode: "w2", panes: [paneID])
        store.runtimes = { [run] }
        store.noteWaitEpisodes(in: session)

        #expect(store.ledger.entry(for: first)?.waitEpisodeToken == "w1")
        #expect(store.ledger.entry(for: second)?.waitEpisodeToken == "w2")
        // A wait after both is announced as itself.
        #expect(!store.isWaitOfRequest(runtimeID: run.id, episodeToken: "w3", in: session))
    }

    @Test func aRequestHandedToTheTerminal_staysWhileTheTurnRuns() {
        // Another tool can move the run on while the TUI still asks: only the
        // turn's end lets the request go.
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let (store, request) = Self.storeWithRequest(in: session)
        store.runtimes = { [Self.run(panes: [paneID])] }
        store.noteWaitEpisodes(in: session)
        store.ledger.record(.handedOverBySetting, for: request.id, now: SuspendingClock.now)
        store.ledger.record(.sendSucceeded, for: request.id, now: SuspendingClock.now)

        store.runtimes = { [Self.run(state: .running, episode: "r1", panes: [paneID])] }
        store.noteWaitEpisodes(in: session)
        guard case .handedToTerminal = store.ledger.entry(for: request)?.state else {
            Issue.record("still with the terminal")
            return
        }
    }

    @Test func aRequestIsBoundToItsRun_bySessionElseByTheOnlyUnnamedRunInItsPane() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let (store, request) = Self.storeWithRequest(in: session)
        #expect(store.run(for: request, in: session) == nil)

        let bySession = Self.run(panes: [UUID()])
        store.runtimes = { [bySession] }
        #expect(store.run(for: request, in: session)?.id == bySession.id)

        // Before the run's record carries the session: the hinted pane's run
        // that has none yet, only when it is the pane's one such run.
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
        }
        let lone = Self.run(id: "lone", panes: [paneID], sessionID: nil)
        store.runtimes = { [lone] }
        #expect(store.run(for: request, in: session)?.id == lone.id)
        let second = Self.run(id: "second", panes: [paneID], sessionID: nil)
        store.runtimes = { [lone, second] }
        #expect(store.run(for: request, in: session) == nil, "two runs in the pane: no guess")
        let elsewhere = Self.run(id: "elsewhere", panes: [paneID], sessionID: "another")
        store.runtimes = { [elsewhere] }
        #expect(store.run(for: request, in: session) == nil, "a run of another session is not this one")
    }

    @Test func aResumedSession_isBoundToTheRunThatIsShownAndStartedLast() {
        // Resuming keeps the session id; the run before the resume is still
        // listed until it is retired.
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let (store, request) = Self.storeWithRequest(in: session)
        let before = Self.run(
            id: "before", state: .finished, panes: [paneID], sessionStartedAt: Date(timeIntervalSince1970: 100)
        )
        let after = Self.run(id: "after", panes: [paneID], sessionStartedAt: Date(timeIntervalSince1970: 200))
        store.runtimes = { [after, before] }
        #expect(store.run(for: request, in: session)?.id == after.id)
        store.runtimes = { [before, after] }
        #expect(store.run(for: request, in: session)?.id == after.id)

        // The run in a turn asks, even while its tmux pane is not known yet;
        // between two runs out of a turn, the one shown somewhere wins.
        let detached = Self.run(id: "detached", panes: [], sessionStartedAt: Date(timeIntervalSince1970: 300))
        store.runtimes = { [detached, before] }
        #expect(store.run(for: request, in: session)?.id == detached.id)
        let detachedIdle = Self.run(
            id: "idle", state: .idle, panes: [], sessionStartedAt: Date(timeIntervalSince1970: 300)
        )
        store.runtimes = { [detachedIdle, before] }
        #expect(store.run(for: request, in: session)?.id == before.id)

        let older = Self.run(
            id: "older", panes: [paneID], sessionStartedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        let newer = Self.run(
            id: "newer", panes: [paneID], sessionStartedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        store.runtimes = { [newer, older] }
        #expect(store.run(for: request, in: session)?.id == newer.id)
        store.runtimes = { [older, newer] }
        #expect(store.run(for: request, in: session)?.id == newer.id)

        let unknown = Self.run(
            id: "unknown", state: .unknown, panes: [paneID], sessionStartedAt: Date(timeIntervalSince1970: 500)
        )
        store.runtimes = { [before, unknown] }
        #expect(store.run(for: request, in: session)?.id == before.id)
    }

    @Test func aTmuxRunWithoutAPane_providesItsOwnTurnState() {
        // The topology probe has not reported: the run has no pane, and its
        // prompt still waits. Its state, not the missing pane, decides.
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let (store, request) = Self.storeWithRequest(in: session)
        store.runtimes = { [Self.run(panes: [])] }
        #expect(store.paneLocation(for: request, in: session) == nil)
        guard case let .known(badge)? = store.turnStanding(for: request, in: session) else {
            Issue.record("expected the run's own badge")
            return
        }
        #expect(badge.state == .needsInput)
    }

    @Test func onlyAnOpenRequestAWeirCanAnswer_opensItsCard() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let epoch = UUID()
        func request(_ provider: AgentKind, isQuestion: Bool) -> ApprovalPresentation {
            ApprovalPresentation.test(
                epoch: epoch,
                provider: provider,
                questions: isQuestion ? [ApprovalQuestion(header: "h", prompt: "p", options: [], isMultiSelect: false)] : []
            )
        }
        let held = request(.claude, isQuestion: false)
        let codexQuestion = request(.codex, isQuestion: true)
        let handed = request(.claude, isQuestion: false)
        let failed = request(.claude, isQuestion: false)
        let sending = request(.claude, isQuestion: false)
        let timedOut = request(.claude, isQuestion: false)
        let all = [held, codexQuestion, handed, failed, sending, timedOut]
        store.apply(
            ApprovalControllerConnection.Projection(
                sequence: 1, requests: all, terminals: [:], missingIDs: [],
                unevictableCount: all.count, deadlines: [:]
            ),
            epoch: epoch,
            now: SuspendingClock.now
        )
        store.apply(
            ApprovalControllerConnection.Projection(
                sequence: 2, requests: [held, codexQuestion, failed, sending, timedOut],
                terminals: [handed.id: .resolved(.delegate)],
                missingIDs: [], unevictableCount: 5, deadlines: [:]
            ),
            epoch: epoch,
            now: SuspendingClock.now
        )
        store.ledger.record(.userDecided(.deny), for: failed.id, now: SuspendingClock.now)
        store.ledger.record(.sendFailed("offline"), for: failed.id, now: SuspendingClock.now)
        store.ledger.record(.userDecided(.allowOnce), for: sending.id, now: SuspendingClock.now)
        store.ledger.record(.deadlinePassed, for: timedOut.id, now: SuspendingClock.now)

        #expect(store.opensCard(held.key))
        #expect(store.opensCard(failed.key), "a failed send can be tried again on the card")
        #expect(!store.opensCard(sending.key))
        #expect(!store.opensCard(timedOut.key))
        #expect(!store.opensCard(codexQuestion.key))
        #expect(!store.opensCard(handed.key))
        #expect(!store.opensCard(ApprovalKey(epoch: epoch, runID: UUID(), requestID: UUID())))
    }

    /// A stop while the observer waits for the service's reply ends the wait
    /// at once, rather than holding a thread for the subscription's minute.
    @Test(.timeLimit(.minutes(1)))
    func observe_stoppedWhileOpening_releasesTheCallSynchronously() async throws {
        let service = HeldXPCService(holding: .everything)
        try await expectStopEndsTheObserver(waitingOn: service, callNumber: 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func observe_stoppedWhileSubscribed_releasesTheCallSynchronously() async throws {
        let artifact = try AgentIntegrationServiceArtifact.bundled(in: Bundle.main.bundleURL)
        let service = HeldXPCService(holding: .afterOpening(artifact))
        try await expectStopEndsTheObserver(waitingOn: service, callNumber: 4)
    }

    @Test(.timeLimit(.minutes(1)))
    func observe_stoppedRightAfterStart_ends() async throws {
        let service = HeldXPCService(holding: .everything)
        let store = ApprovalPresentationStore(controllerClient: { try service.client() })
        store.start()
        defer { store.stop() }
        let stopped = try #require(store.stop())
        await stopped.value
        #expect(!store.isRunning)
    }

    private func expectStopEndsTheObserver(waitingOn service: HeldXPCService, callNumber: Int) async throws {
        let wait = HeldReplyWait(callNumber: callNumber)
        let store = ApprovalPresentationStore(controllerClient: {
            try service.client(timeoutSeconds: 30, waitForReply: wait.wait)
        })
        store.start()
        defer { store.stop() }
        await service.waitUntilHeld()
        await wait.waitUntilWaiting()
        let stopped = store.stop()
        let wasReleased = wait.releaseAfterCheckingSignal()
        await stopped?.value
        try #require(stopped != nil)
        try #require(service.heldCount == 1)
        #expect(wasReleased)
        #expect(!store.isRunning)
    }
}
