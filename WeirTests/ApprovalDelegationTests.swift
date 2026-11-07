// ApprovalDelegationTests.swift
// Weir — decisions sent through the ledger, and decisions another answer beat.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalDelegationTests {
    private struct Offline: Error {}
    private typealias SentDecision = (approval: ApprovalPresentation, resolution: ApprovalResolution)

    /// A store holding one pending request, whose decisions `sender` answers.
    private static func store(
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
    ) -> (ApprovalPresentationStore, ApprovalPresentation) {
        let store = ApprovalPresentationStore(decisionSender: sender)
        let request = ApprovalPresentation.test()
        store.receive([request])
        return (store, request)
    }

    @Test func aFailedSend_canBeRetried() async {
        let attempts = Recorded<[SentDecision]>([])
        let (store, request) = Self.store { approval, resolution in
            attempts.update { $0.append((approval, resolution)) }
            if attempts.value.count == 1 {
                throw Offline()
            }
        }

        store.resolve(request, .deny)
        await store.waitUntilResolved(request)
        guard case .sendFailed(.deny, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected a failed send")
            return
        }
        #expect(store.lastFailureID == request.id)
        #expect(attempts.value.map(\.approval) == [request])
        #expect(attempts.value.map(\.resolution) == [.deny])

        store.resolve(request, .deny)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .answered(.deny))
        #expect(store.lastFailureID == nil)
        #expect(attempts.value.map(\.approval) == [request, request])
        #expect(attempts.value.map(\.resolution) == [.deny, .deny])
    }

    @Test(arguments: [
        (BrokerTerminal.resolved(.deny), Optional(ApprovalRequestState.answered(.deny)), true),
        (.canceled, .withdrawn, false),
        (.expired, .timedOut, false),
        (.resolved(.delegate), nil, false)
    ])
    func alreadyTerminal_mapsState(
        terminal: BrokerTerminal,
        expected: ApprovalRequestState?,
        isAnsweredElsewhere: Bool
    ) async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(terminal)
        }

        let start = SuspendingClock.now
        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        let entry = store.ledger.entry(for: request)
        if let expected {
            #expect(entry?.state == expected)
        } else if case let .handedToTerminal(since)? = entry?.state {
            #expect((start...SuspendingClock.now).contains(since))
        } else {
            Issue.record("Expected the request to be handed to the terminal.")
        }
        #expect(entry?.isAnsweredElsewhere == isAnsweredElsewhere)
        #expect(store.lastFailureID == nil)
    }

    @Test func aLateResult_doesNotUndoWhatTheBrokerSaid() async throws {
        let gate = Gate<Void>()
        defer { gate.open() }
        let sent = Recorded<[SentDecision]>([])
        let (store, request) = Self.store { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
            await gate.wait()
        }

        store.resolve(request, .allowOnce)
        try await gate.waitUntilRequested()
        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.allowOnce])
        // Settle the ledger directly to leave the decision in flight while
        // recording the withdrawal.
        store.ledger.settle(id: request.id, by: .canceled, now: SuspendingClock.now)
        #expect(store.ledger.entry(for: request)?.state == .withdrawn)
        #expect(store.resolvingIDs.contains(request.id))
        gate.open()
        await store.waitUntilResolved(request)

        // The send finished, so its late success had its chance to land.
        #expect(!store.resolvingIDs.contains(request.id))
        #expect(store.ledger.entry(for: request)?.state == .withdrawn)
    }

    @Test func aRequestTheBrokerLost_hasAnUnknownResult() async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.recordMissing
        }

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .unknownResult)
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == false)
        #expect(store.lastFailureID == nil)
    }

    @Test func aTimedOutRequest_takesNoSecondDecision() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in await sent.next() }
        store.ledger.settle(id: request.id, by: .expired, now: SuspendingClock.now)

        #expect(store.pending == [request])
        store.resolve(request, .allowOnce)

        #expect(store.resolvingIDs.isEmpty)
        #expect(await sent.count == 0)
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
    }

    // MARK: - Handing held requests to the TUI

    @Test func anUnplacedHeldRequest_staysHeldWithoutAnEpisodeToRelease() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in await sent.next() }

        store.releaseStaleApprovals(in: WorkspaceSession())

        #expect(store.pending == [request])
        #expect(store.resolvingIDs.isEmpty)
        #expect(await sent.count == 0)
        #expect(store.ledger.entry(for: request)?.state == .held)
        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate])
    }

    @Test func withoutHolding_everyRequestGoesToTheTerminal() async {
        let sent = Recorded<[SentDecision]>([])
        let (store, first) = Self.store { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
        }
        let second = ApprovalPresentation.test(epoch: first.epoch)
        store.receive([first, second])

        store.handOverHeldRequests()
        await store.waitUntilResolved(first)
        await store.waitUntilResolved(second)

        #expect(Set(sent.value.map(\.approval.id)) == [first.id, second.id])
        #expect(sent.value.map(\.resolution) == [.delegate, .delegate])
        for request in [first, second] {
            guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
                Issue.record("Expected each request to be handed to the terminal.")
                return
            }
        }
        #expect(store.decisionsToSendAtQuit.isEmpty)
    }

    @Test func aRequestTheBrokerIsAnswering_isNotHandedOver() async throws {
        let gate = Gate<Void>()
        defer { gate.open() }
        let sent = Recorded<[SentDecision]>([])
        let (store, request) = Self.store { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
            await gate.wait()
        }
        store.resolve(request, .allowOnce)
        guard case .sending(.allowOnce, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("Expected the person's decision to be sending.")
            return
        }

        store.handOverHeldRequests()
        try await gate.waitUntilRequested()
        gate.open()
        await store.waitUntilResolved(request)

        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.allowOnce])
        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
    }

    @Test func atQuit_anAnswerStillOnItsWay_isPlannedForResend() async throws {
        let gate = Gate<Void>()
        defer { gate.open() }
        let (store, request) = Self.store { _, _ in await gate.wait() }
        store.resolve(request, .allowOnce)

        // The quit plan already includes the decision before the sender starts.
        #expect(gate.requests == 0)
        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.allowOnce])

        try await gate.waitUntilRequested()
        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.allowOnce])

        gate.open()
        await store.waitUntilResolved(request)
        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
        #expect(store.decisionsToSendAtQuit.isEmpty)
    }

    @Test func atQuit_anAnswerThatFailedToSend_plansAHandOver() async {
        let (store, request) = Self.store { _, _ in throw Offline() }
        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)
        guard case .sendFailed(.allowOnce, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("Expected the person's decision to have failed.")
            return
        }

        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate])
    }

    /// The ledger supplies the quit plan during a subscription gap, when
    /// pending is empty. The oldest request goes first so the quit budget
    /// is spent on the request that has waited longest.
    @Test func atQuit_afterSubscriptionDrop_plansEveryOpenRequestOldestFirst() async throws {
        let gate = Gate<Void>()
        defer { gate.open() }
        let store = ApprovalPresentationStore { _, _ in await gate.wait() }
        let older = ApprovalPresentation.test()
        let newer = ApprovalPresentation.test(epoch: older.epoch)
        store.receive([older], seenAt: Date(timeIntervalSince1970: 1))
        store.receive([older, newer], seenAt: Date(timeIntervalSince1970: 2))
        store.resolve(newer, .allowOnce)
        try await gate.waitUntilRequested()

        store.connectionDidDrop()

        #expect(store.pending.isEmpty)
        #expect(store.decisionsToSendAtQuit.map(\.approval) == [older, newer])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate, .allowOnce])
        gate.open()
        await store.waitUntilResolved(newer)
    }

    /// A readiness failure can stop the store while the service still holds
    /// the request. The quit plan still includes that request.
    @Test func atQuit_afterTheStoreStops_plansAHandOverForAHeldRequest() {
        let (store, request) = Self.store { _, _ in }

        store.stop()

        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate])
    }

    /// Demo mode's request has no service behind it, so a quit sends nothing.
    @Test func atQuit_demoModesRequest_getsNothing() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let request = ApprovalPresentation.test()

        store.stage(.test(pending: [request]), epoch: request.epoch, now: SuspendingClock.now)

        #expect(store.ledger.entry(for: request)?.state == .held)
        #expect(store.decisionsToSendAtQuit.isEmpty)
    }

    /// The hidden setting hands over what the ledger holds, not what the
    /// pending list shows, so a request held through a dropped subscription
    /// goes to the agent's prompt too.
    @Test func withoutHolding_aRequestHeldThroughADroppedSubscription_isHandedOver() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, resolution in
            #expect(resolution == .delegate)
            await sent.next()
        }
        store.connectionDidDrop()

        store.handOverHeldRequests()
        await store.waitUntilResolved(request)

        #expect(await sent.count == 1)
        guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be with the TUI")
            return
        }
    }

    @Test func atQuit_aRequestThatTimedOut_getsNothing() {
        let (store, request) = Self.store { _, _ in }
        store.ledger.settle(id: request.id, by: .expired, now: SuspendingClock.now)

        #expect(store.pending == [request])
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
        #expect(store.decisionsToSendAtQuit.isEmpty)
    }

    @Test func aFailedHandOver_staysForThePersonAndIsNotResent() async {
        let sent = Recorded<[SentDecision]>([])
        let (store, request) = Self.store { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
            throw Offline()
        }

        store.handOverHeldRequests()
        await store.waitUntilResolved(request)
        store.handOverHeldRequests()
        #expect(store.resolvingIDs.isEmpty)

        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.delegate])
        guard case .sendFailed(.delegate, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the failed hand-over to stay open")
            return
        }
        // Nobody pressed anything, so the card shows no failure line.
        #expect(store.lastFailureID == nil)
    }

    @Test func aHandOverAnAnswerBeat_isAnsweredButNotByAnotherPerson() async {
        let sent = Recorded<[SentDecision]>([])
        let (store, request) = Self.store { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.allowOnce))
        }

        store.handOverHeldRequests()
        await store.waitUntilResolved(request)

        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.delegate])
        #expect(store.lastFailureID == nil)
        let entry = store.ledger.entry(for: request)
        #expect(entry?.state == .answered(.allowOnce))
        #expect(entry?.isAnsweredElsewhere == false)
    }
}
