// ApprovalEpisodeEndTests+RunBinding.swift
// Weir — which run a request belongs to when one conversation runs in two.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension ApprovalEpisodeEndTests {
    private typealias SentDecision = (approval: ApprovalPresentation, resolution: ApprovalResolution)

    private static func pendingStore(
        _ request: ApprovalPresentation,
        recording sent: Recorded<[SentDecision]>
    ) -> ApprovalPresentationStore {
        let store = ApprovalPresentationStore { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
        }
        store.receive([request], seenAt: seenAt)
        return store
    }

    /// A Claude run of the fixture's conversation in `state`, having taken
    /// its last prompt at `runStartedAt` (`nil` once a turn has ended), shown
    /// in `pane`.
    private static func run(
        _ id: String,
        _ state: AgentState = .running,
        prompt runStartedAt: Date?,
        sessionStartedAt: Date? = nil,
        in pane: UUID
    ) -> AgentRuntimePresentation {
        var badge = AgentBadge(state: state, runStartedAt: runStartedAt, updatedAt: Date())
        badge.sessionStartedAt = sessionStartedAt
        return AgentRuntimePresentation.test(runID: id, badge: badge, paneIDs: [pane], sessionID: "session")
    }

    @Test func aRequestNamingItsRun_isBoundToThatRun_andAResumedRunsPromptLeavesIt() {
        // The conversation is resumed in a second run while the first still
        // has the request with its TUI. The second run is the likelier one by
        // every guess (in a turn, started last), but the request names the
        // first.
        let asking = UUID()
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate), agentRunID: asking)
        let pane = fixture.paneID
        let first = Self.run(asking.uuidString, prompt: Self.ownPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        let resumed = Self.run("resumed", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        fixture.store.runtimes = { [first, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [first.id])
        #expect(fixture.store.run(for: fixture.request, in: fixture.session)?.id == first.id)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        let resumedDone = Self.run("resumed", .finished, prompt: nil, sessionStartedAt: Self.laterPrompt, in: pane)
        fixture.store.runtimes = { [first, resumedDone] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [first.id])
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        let firstAgain = Self.run(asking.uuidString, prompt: Self.laterPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [firstAgain, resumedDone] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aStuckRun_doesNotHoldTheRequestsOfAnotherRunOfItsConversation() async {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let resumedID = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: resumedID)
        let sent = Recorded<[SentDecision]>([])
        let store = Self.pendingStore(request, recording: sent)
        let stuck = Self.run("stuck", prompt: Self.ownPrompt.addingTimeInterval(-60), in: pane)
        let resumed = Self.run(resumedID.uuidString, .needsInput, prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [stuck, resumed] }

        store.bindRequestsToRuns(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [resumed.id])
        store.resolve(request, .delegate)
        await store.waitUntilResolved(request)
        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.delegate])
        guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
            Issue.record("Expected the request to be handed to its own run.")
            return
        }

        store.receive([], epoch: request.epoch)
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [resumed.id])

        store.runtimes = { [stuck, Self.run(resumedID.uuidString, .finished, prompt: nil, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func anAnsweredRequest_endsWithItsTurn_thoughNoCleanupPassSawItRunning() async {
        // Binding at request arrival reads the running badge. The first
        // cleanup pass sees the completed turn.
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let sent = Recorded<[SentDecision]>([])
        let store = Self.pendingStore(request, recording: sent)
        let session = WorkspaceSession()
        let pane = UUID()
        let run = Self.run(asking.uuidString, prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [run] }
        store.bindRequestsToRuns(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [run.id])

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)
        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.allowOnce])
        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))

        store.receive([], epoch: request.epoch)
        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
        store.runtimes = { [Self.run(asking.uuidString, .finished, prompt: nil, in: pane)] }
        store.releaseStaleApprovals(in: session)

        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aRequestsNamedRunGoingAway_endsItOnceHandedOver_andKeepsItWhileHeld() {
        let asking = UUID()
        let handedOver = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate), agentRunID: asking)
        let pane = handedOver.paneID
        let original = Self.run(asking.uuidString, prompt: Self.ownPrompt, in: pane)
        let decoy = Self.run("resumed", prompt: Self.laterPrompt, in: pane)
        handedOver.store.runtimes = { [original, decoy] }
        handedOver.store.releaseStaleApprovals(in: handedOver.session)
        #expect(handedOver.store.ledger.entry(for: handedOver.request)?.runtimeIDs == [original.id])
        #expect(handedOver.store.ledger.entry(for: handedOver.request)?.state == .handedToTerminal(since: Self.now))

        handedOver.store.runtimes = { [decoy] }
        handedOver.store.releaseStaleApprovals(in: handedOver.session)
        #expect(handedOver.store.ledger.entry(for: handedOver.request) == nil)

        // Pending requests still belong to the broker when their run goes.
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let held = Self.pendingStore(request, seenAt: Self.seenAt)
        held.runtimes = { [original, decoy] }
        held.releaseStaleApprovals(in: handedOver.session)
        #expect(held.ledger.entry(for: request)?.runtimeIDs == [original.id])

        held.runtimes = { [decoy] }
        held.releaseStaleApprovals(in: handedOver.session)
        #expect(held.pending == [request])
        #expect(held.turnStanding(for: request, in: handedOver.session) == nil)
        #expect(held.resolvingIDs.isEmpty)
        #expect(held.ledger.entry(for: request)?.state == .held)
    }

    @Test func aRequestWhoseNamedRunIsNeverListed_endsOnceTheBrokerIsDoneWithIt() {
        // The agent died while Weir was not running, and its record went
        // with it: the request's run is never listed. Once the broker has
        // timed the request out, nothing will place it.
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: UUID())
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        store.releaseStaleApprovals(in: session)
        #expect(store.turnStanding(for: request, in: session) == .awaitingRun)
        #expect(store.ledger.entry(for: request)?.state == .held)

        store.receive([], epoch: request.epoch)
        store.releaseStaleApprovals(in: session)
        #expect(store.pending.isEmpty)
        #expect(store.turnStanding(for: request, in: session) == .awaitingRun)
        #expect(store.ledger.entry(for: request)?.state == .held)

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .expired]),
            epoch: request.epoch,
            now: Self.now
        )
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aNamedRunListedLater_isBoundThen_andEndsTheRequestWithItsTurn() {
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let decoy = Self.run("other", prompt: Self.laterPrompt, in: pane)
        store.runtimes = { [decoy] }
        store.releaseStaleApprovals(in: session)
        #expect(store.pending == [request])
        #expect(store.ledger.entry(for: request)?.runtimeIDs == nil)
        #expect(store.turnStanding(for: request, in: session) == .awaitingRun)
        #expect(store.ledger.entry(for: request)?.state == .held)
        #expect(store.resolvingIDs.isEmpty)

        let run = Self.run(asking.uuidString, .needsInput, prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [decoy, run] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [run.id])

        // The broker hands the request to the terminal while its turn is active.
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.delegate)]),
            epoch: request.epoch,
            now: Self.now
        )
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.state == .handedToTerminal(since: Self.now))
        store.runtimes = { [decoy, Self.run(asking.uuidString, .finished, prompt: nil, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test func aDetachedTmuxRunsRequest_followsItsOwnAttachment() {
        let asking = UUID()
        let request = ApprovalPresentation.test(sessionID: "session", agentRunID: asking)
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        fixture.session.update(fixture.tabA.id) {
            $0.agentSessions[.claude] = [fixture.paneA: AgentSessionInfo(sessionId: "session", cwd: nil)]
        }
        let detached = AgentRuntimePresentation.test(
            runID: asking.uuidString,
            badge: AgentBadge(state: .needsInput, runStartedAt: Self.ownPrompt, updatedAt: Self.seenAt),
            attachmentResolution: .detached,
            sessionID: "session"
        )
        let decoy = Self.run("other", prompt: Self.laterPrompt, in: fixture.paneA)
        store.runtimes = { [detached, decoy] }
        store.bindRequestsToRuns(in: fixture.session)

        #expect(store.ledger.entry(for: request)?.runtimeIDs == [detached.id])
        #expect(store.panes(for: request, in: fixture.session).isEmpty)
        #expect(store.ledger.entry(for: request)?.state == .held)

        let attached = Self.run(asking.uuidString, .needsInput, prompt: Self.ownPrompt, in: fixture.paneB)
        store.runtimes = { [attached, decoy] }
        let panes = store.panes(for: request, in: fixture.session)
        #expect(panes.map(\.tabID) == [fixture.tabB.id])
        #expect(panes.map(\.paneID) == [fixture.paneB])
    }

    // MARK: - Requests that name no run

    @Test func aHandedOverRequest_endsWithItsOwnRunsNextPrompt_notWithAResumedRuns() {
        // A request that names no run is bound to the run in a turn when it
        // was seen; a run that started later is not a candidate.
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let pane = fixture.paneID
        let first = Self.run("first", prompt: Self.ownPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [first] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [first.id])

        let resumed = Self.run("resumed", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        fixture.store.runtimes = { [first, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))
        #expect(fixture.store.run(for: fixture.request, in: fixture.session)?.id == first.id)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [first.id])

        let firstAgain = Self.run("first", prompt: Self.laterPrompt, sessionStartedAt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [firstAgain, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aHeldRequest_isNotReleasedByAResumedRunsPrompt() async {
        let request = ApprovalPresentation.test(sessionID: "session")
        let sent = Recorded<[SentDecision]>([])
        let store = Self.pendingStore(request, recording: sent)
        let session = WorkspaceSession()
        let pane = UUID()
        let first = Self.run("first", .needsInput, prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [first] }
        store.releaseStaleApprovals(in: session)

        let resumed = Self.run("resumed", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        store.runtimes = { [first, resumed] }
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs.isEmpty)
        #expect(sent.value.isEmpty)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [first.id])
        #expect(store.ledger.entry(for: request)?.state == .held)

        // Its own run's next prompt releases it, and the release ends it.
        store.runtimes = { [Self.run("first", prompt: Self.laterPrompt, in: pane), resumed] }
        store.releaseStaleApprovals(in: session)
        #expect(store.resolvingIDs == [request.id])
        await store.waitUntilResolved(request)
        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.delegate])
        #expect(store.ledger.entry(for: request) == nil)
    }

    @Test(arguments: [-5.0, 0.0])
    func aRequestSeenBeforeAnyRunIsInATurn_isBoundToTheRunThatThenIs(sessionStartOffset: TimeInterval) {
        // The projection can reach us after the request: the run's badge
        // still shows its last turn. A run started after the request is not
        // the one that asked.
        let request = ApprovalPresentation.test(sessionID: "session")
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let session = WorkspaceSession()
        let pane = UUID()
        store.runtimes = { [Self.run("asking", .finished, prompt: nil, sessionStartedAt: Self.ownPrompt, in: pane)] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == nil)

        let sessionStart = Self.seenAt.addingTimeInterval(sessionStartOffset)
        let asking = Self.run("asking", .needsInput, prompt: Self.ownPrompt, sessionStartedAt: sessionStart, in: pane)
        let later = Self.run("later", prompt: Self.laterPrompt, sessionStartedAt: Self.laterPrompt, in: pane)
        store.runtimes = { [asking, later] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [asking.id])
    }

    @Test(arguments: [("other", "one"), ("one", "other")])
    func aRequestEitherOfTwoRunsCouldHaveAsked_endsOnceBothTurnsHaveEnded(first: String, last: String) {
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let pane = fixture.paneID
        let one = Self.run("one", prompt: Self.ownPrompt, in: pane)
        let other = Self.run("other", prompt: Self.ownPrompt, in: pane)
        let lastRunning = last == "one" ? one : other
        func inProjectionOrder(_ firstEnding: AgentRuntimePresentation, _ lastEnding: AgentRuntimePresentation)
            -> [AgentRuntimePresentation]
        {
            firstEnding.runID == "one" ? [firstEnding, lastEnding] : [lastEnding, firstEnding]
        }
        fixture.store.runtimes = { [one, other] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [one.id, other.id])

        // A newer prompt ends only the turn it overtook.
        fixture.store.runtimes = { inProjectionOrder(Self.run(first, prompt: Self.laterPrompt, in: pane), lastRunning) }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        let firstFinished = Self.run(first, .finished, prompt: nil, in: pane)
        fixture.store.runtimes = { inProjectionOrder(firstFinished, lastRunning) }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))

        fixture.store.runtimes = { inProjectionOrder(firstFinished, Self.run(last, .finished, prompt: nil, in: pane)) }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aRequestEitherOfTwoRunsCouldHaveAsked_followsTheOtherOnceOneHasGone() {
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let pane = fixture.paneID
        let one = Self.run("one", prompt: Self.ownPrompt, in: pane)
        let other = Self.run("other", prompt: Self.ownPrompt, in: pane)
        fixture.store.runtimes = { [one, other] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [one.id, other.id])

        fixture.store.runtimes = { [one] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.turnStanding(for: fixture.request, in: fixture.session) == .known(one.badge))
        #expect(fixture.store.ledger.entry(for: fixture.request) != nil)

        fixture.store.runtimes = { [Self.run("one", .finished, prompt: nil, in: pane)] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request) == nil)
    }

    @Test func aRequestNamingNoRun_beforeAnyRunReportsItsSession_isBoundToTheOneRunInItsHintedPane() {
        let fixture = Self.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
        let unnamed = AgentRuntimePresentation.test(
            runID: "unnamed",
            badge: AgentBadge(state: .running, runStartedAt: Self.ownPrompt, updatedAt: Date()),
            paneIDs: [fixture.paneID]
        )
        fixture.store.runtimes = { [unnamed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.runtimeIDs == [unnamed.id])

        // A later same-session run must not replace the bound unnamed run.
        let resumed = Self.run("resumed", prompt: Self.laterPrompt, in: fixture.paneID)
        fixture.store.runtimes = { [unnamed, resumed] }
        fixture.store.releaseStaleApprovals(in: fixture.session)
        #expect(fixture.store.run(for: fixture.request, in: fixture.session)?.id == unnamed.id)
        #expect(fixture.store.ledger.entry(for: fixture.request)?.state == .handedToTerminal(since: Self.now))
    }

    @Test func aScopedQuestionEitherOfTwoRunsCouldHaveAsked_endsOnceNeitherIsInATurn() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let request = ApprovalPresentation.test(
            sessionID: "session",
            operationID: AgentQuestionTurnCompletion.operationIDPrefix + "turn",
            toolName: "AskUserQuestion",
            questions: [ApprovalQuestion(
                header: "Color",
                prompt: "Which color?",
                options: [.init(label: "Red", description: nil)],
                isMultiSelect: false
            )]
        )
        let store = Self.pendingStore(request, seenAt: Self.seenAt)
        let one = Self.run("one", prompt: Self.ownPrompt, in: pane)
        let other = Self.run("other", prompt: Self.ownPrompt, in: pane)
        store.runtimes = { [one, other] }
        store.bindRequestsToRuns(in: session)
        #expect(request.hasQuestionTurnCompletion)
        #expect(store.ledger.entry(for: request)?.runtimeIDs == [one.id, other.id])
        store.apply(.test(pending: [], terminals: [request.id: .resolved(.delegate)]), epoch: request.epoch, now: Self.now)

        // A newer prompt in both runs would end an ordinary request.
        let oneAgain = Self.run("one", prompt: Self.laterPrompt, in: pane)
        let otherAgain = Self.run("other", prompt: Self.laterPrompt, in: pane)
        store.runtimes = { [oneAgain, otherAgain] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.state == .handedToTerminal(since: Self.now))

        let otherDone = Self.run("other", .finished, prompt: nil, in: pane)
        store.runtimes = { [oneAgain, otherDone] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request)?.state == .handedToTerminal(since: Self.now))

        store.runtimes = { [Self.run("one", .finished, prompt: nil, in: pane), otherDone] }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
    }
}
