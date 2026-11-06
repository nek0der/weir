// ApprovalDelegationTests.swift
// Weir — decisions sent through the ledger, and decisions another answer beat.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalDelegationTests {
    private struct Offline: Error {}

    /// A store holding one pending request, whose decisions `sender` answers.
    private static func store(
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
    ) -> (ApprovalPresentationStore, ApprovalPresentation) {
        let store = ApprovalPresentationStore(decisionSender: sender)
        let request = ApprovalPresentation.test()
        store.receive([request])
        return (store, request)
    }

    @Test func aDecision_goesThroughSendingToAnswered() async {
        let (store, request) = Self.store { _, _ in }

        store.resolve(request, .allowOnce)
        guard case .sending(.allowOnce, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be sending")
            return
        }
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
    }

    @Test func aFailedSend_canBeRetried() async {
        let attempts = DecisionRecorder()
        let (store, request) = Self.store { _, _ in
            if await attempts.next() == 1 {
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

        store.resolve(request, .deny)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .answered(.deny))
        #expect(store.lastFailureID == nil)
    }

    @Test(arguments: [
        (BrokerTerminal.resolved(.deny), ApprovalRequestState.answered(.deny), true),
        (.canceled, .withdrawn, false),
        (.expired, .timedOut, false)
    ])
    func alreadyTerminal_mapsState(
        terminal: BrokerTerminal,
        expected: ApprovalRequestState,
        isAnsweredElsewhere: Bool
    ) async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(terminal)
        }

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == expected)
        // Only an answer beat the decision; a timeout or a withdrawal is told
        // as what it is.
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == isAnsweredElsewhere)
        #expect(store.lastFailureID == nil)
    }

    @Test func alreadyTerminal_byADelegation_isHandedToTheTerminal() async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.delegate))
        }

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be with the TUI")
            return
        }
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == false)
    }

    @Test func aLateResult_doesNotUndoWhatTheBrokerSaid() async {
        let gate = Gate<Void>()
        let (store, request) = Self.store { _, _ in await gate.wait() }

        store.resolve(request, .allowOnce)
        // While the send is in flight, the broker reports the request
        // withdrawn. Settled on the ledger directly, so the send stays in
        // flight; `waitUntilResolved` then waits for its late success to
        // land.
        store.ledger.settle(id: request.id, by: .canceled, now: SuspendingClock.now)
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
        #expect(store.lastFailureID == nil)
    }

    @Test func aSettledRequest_takesNoSecondDecision() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in await sent.next() }
        store.ledger.settle(id: request.id, by: .expired, now: SuspendingClock.now)

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(await sent.count == 0)
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
    }

    // MARK: - Handing held requests to the TUI

    @Test func aHeldRequest_staysHeldUntilSomeoneDecides() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in await sent.next() }

        // Nothing hands a request over by itself: not its pane coming into
        // sight, not a pass of the projection.
        store.releaseStaleApprovals(in: WorkspaceSession())

        #expect(store.resolvingIDs.isEmpty)
        #expect(await sent.count == 0)
        #expect(store.ledger.entry(for: request)?.state == .held)
        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate])
    }

    @Test func withoutHolding_everyRequestGoesToTheTerminal() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, resolution in
            #expect(resolution == .delegate)
            await sent.next()
        }

        store.handOverHeldRequests()
        await store.waitUntilResolved(request)

        #expect(await sent.count == 1)
        guard case .handedToTerminal? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the request to be with the TUI")
            return
        }
        #expect(store.decisionsToSendAtQuit.isEmpty)
    }

    @Test func aRequestTheBrokerIsAnswering_isNotHandedOver() async {
        let gate = Gate<Void>()
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in
            await sent.next()
            await gate.wait()
        }
        store.resolve(request, .allowOnce)

        store.handOverHeldRequests()
        gate.open()
        await store.waitUntilResolved(request)

        // Only the person's answer went out.
        #expect(await sent.count == 1)
        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
    }

    /// The send of the person's answer may not have started before the quit
    /// took the main thread. The quit sends that answer again rather than a
    /// hand-over, so whichever reaches the broker first, the agent gets the
    /// person's decision and no other.
    @Test func atQuit_anAnswerStillOnItsWay_goesAgainAsItIs() async {
        let gate = Gate<Void>()
        let (store, request) = Self.store { _, _ in await gate.wait() }
        store.resolve(request, .allowOnce)
        await gate.waitUntilRequested()

        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.allowOnce])

        gate.open()
        await store.waitUntilResolved(request)
        #expect(store.decisionsToSendAtQuit.isEmpty, "the answer landed")
    }

    @Test func atQuit_anAnswerThatFailedToSend_isHandedOver() async {
        let (store, request) = Self.store { _, _ in throw Offline() }
        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(store.decisionsToSendAtQuit.map(\.approval) == [request])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate])
    }

    /// A dropped subscription empties the pending list for the two seconds
    /// before it reconnects, while the ledger keeps every request. A quit
    /// in that gap still owes each held request its hand-over, and an
    /// answer on its way its resend: the agent under tmux would otherwise
    /// wait out its deadline. The oldest goes first, so a short budget
    /// spends itself on the request that has waited longest.
    @Test func atQuit_afterTheSubscriptionDropped_everyOpenRequestStillGoes() async {
        let gate = Gate<Void>()
        let store = ApprovalPresentationStore { _, _ in await gate.wait() }
        let older = ApprovalPresentation.test()
        let newer = ApprovalPresentation.test(epoch: older.epoch)
        store.receive([older], seenAt: Date(timeIntervalSince1970: 1))
        store.receive([older, newer], seenAt: Date(timeIntervalSince1970: 2))
        store.resolve(newer, .allowOnce)
        await gate.waitUntilRequested()

        store.connectionDidDrop()

        #expect(store.pending.isEmpty)
        #expect(store.decisionsToSendAtQuit.map(\.approval) == [older, newer])
        #expect(store.decisionsToSendAtQuit.map(\.resolution) == [.delegate, .allowOnce])
        gate.open()
        await store.waitUntilResolved(newer)
    }

    /// A readiness check that fails once stops the store, while the service
    /// may run on with the agent's request. The quit still hands it over;
    /// a service that is gone only makes that send fail within its budget.
    @Test func atQuit_afterTheStoreStopped_aHeldRequestStillGoes() {
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

        #expect(store.decisionsToSendAtQuit.isEmpty)
    }

    @Test func aFailedHandOver_staysForThePersonAndIsNotResent() async {
        let sent = DecisionRecorder()
        let (store, request) = Self.store { _, _ in
            await sent.next()
            throw Offline()
        }

        store.handOverHeldRequests()
        await store.waitUntilResolved(request)
        store.handOverHeldRequests()
        #expect(store.resolvingIDs.isEmpty)

        #expect(await sent.count == 1)
        guard case .sendFailed(.delegate, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("expected the failed hand-over to stay open")
            return
        }
        // Nobody pressed anything, so the card shows no failure line.
        #expect(store.lastFailureID == nil)
    }

    @Test func aHandOverAnAnswerBeat_isAnsweredButNotByAnotherPerson() async {
        let (store, request) = Self.store { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.allowOnce))
        }

        store.handOverHeldRequests()
        await store.waitUntilResolved(request)

        let entry = store.ledger.entry(for: request)
        #expect(entry?.state == .answered(.allowOnce))
        #expect(entry?.isAnsweredElsewhere == false)
    }
}
