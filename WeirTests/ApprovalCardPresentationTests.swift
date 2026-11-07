// ApprovalCardPresentationTests.swift
// Weir — a window's approval card: which request it shows, its focus and
// draft, and when it closes.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalCardPresentationTests {
    private nonisolated static let now = SuspendingClock.now

    private static func approval(
        epoch: UUID = UUID(),
        sessionID: String? = nil,
        questions: [ApprovalQuestion] = []
    ) -> ApprovalPresentation {
        ApprovalPresentation.test(
            epoch: epoch,
            sessionID: sessionID,
            toolName: questions.isEmpty ? "Bash" : "AskUserQuestion",
            summary: questions.isEmpty ? "rm -rf build" : nil,
            questions: questions
        )
    }

    // MARK: - Which request the card shows

    @Test func newRequest_opensNoCardByItself() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let first = Self.approval(epoch: epoch)
        let second = Self.approval(epoch: epoch)

        store.receive([first])
        #expect(card.presentedApproval == nil)
        card.present(first)
        #expect(card.presentedApproval == first)
        store.receive([first, second])
        #expect(card.presentedApproval == first)
        card.dismissCard()
        let third = Self.approval(epoch: epoch)
        store.receive([first, second, third])
        #expect(card.presentedApproval == nil)

        // An empty projection or a new service epoch does not open a card either.
        store.receive([], epoch: epoch)
        store.receive([first, second, third])
        #expect(card.presentedApproval == nil)
        store.receive([Self.approval(epoch: UUID())])
        #expect(card.presentedApproval == nil)
    }

    @Test func aPresentedRequestLeavingTheList_promotesNoOtherRequest() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let first = Self.approval(epoch: epoch)
        let second = Self.approval(epoch: epoch)
        store.receive([first, second])
        card.present(first)

        // Still held, so its card stays on it rather than moving on.
        store.receive([second])
        #expect(card.presentedApproval == first)

        // Withdrawn: its card closes, and no other request's opens.
        store.receive([second], terminals: [first.id: .canceled])
        #expect(card.presentedApproval == nil)
        #expect(!card.isCardOpen)
    }

    @Test func present_requestsCardFocusOnlyWhenAsked() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval()

        store.receive([request])
        card.present(request, shouldFocusCard: false)
        #expect(card.presentedID == request.id)
        #expect(card.cardFocusRequestID == nil)
        #expect(!card.isCardFocused)

        card.present(request)
        #expect(card.presentedID == request.id)
        #expect(card.cardFocusRequestID == request.id)
        #expect(!card.isCardFocused)
    }

    @Test func theCardTracksFocusWithoutDismissingOnFocusLoss() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval()
        store.receive([request])
        card.present(request)
        #expect(!card.isCardFocused)

        card.cardFocusChanged(true, for: request)
        #expect(card.isCardFocused)

        card.cardFocusChanged(false, for: request)
        #expect(!card.isCardFocused)
        #expect(card.isCardOpen)
        #expect(card.presentedApproval == request)

        card.dismissCard()
        #expect(card.presentedApproval == nil)
        #expect(!card.isCardOpen)
    }

    @Test func staleFocusEvents_leaveTheReplacementCardAlone() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let first = Self.approval()
        let second = Self.approval(epoch: first.epoch)

        store.receive([first, second])
        card.present(first)
        card.present(second)
        card.cardFocusChanged(true, for: first)
        card.cardFocusRequestCompleted(for: first)
        #expect(card.presentedID == second.id)
        #expect(card.cardFocusRequestID == second.id)
        #expect(!card.isCardFocused)

        card.cardFocusChanged(true, for: second)
        #expect(card.isCardFocused)
        card.cardFocusChanged(false, for: first)
        #expect(card.presentedID == second.id)
        #expect(card.isCardFocused)
    }

    @Test func aCardThatGotNoFocus_staysOpen() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval()

        store.receive([request])
        card.present(request)
        #expect(card.cardFocusRequestID == request.id)
        card.cardFocusRequestCompleted(for: request)

        #expect(card.presentedID == request.id)
        #expect(card.presentedApproval == request)
        #expect(card.cardFocusRequestID == nil)
        #expect(!card.isCardFocused)
    }

    @Test func questionCard_closesLikeAnyCardAndKeepsItsDraft() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let request = Self.approval(questions: [Self.question])
        store.receive([request])
        card.present(request)
        var draft = store.answerDraft(for: request)
        draft.toggle(label: "Red", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: request)

        card.dismissCard()
        #expect(card.presentedID == nil)

        card.present(request)
        #expect(card.presentedApproval == request)
        #expect(store.answerDraft(for: request) == draft)
        #expect(store.answerDraft(for: request).answers(for: [Self.question]) == ["Which color?": "Red"])
    }

    @Test func anotherRowsCard_replacesQuestionCardWithoutLosingDraft() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let first = Self.approval(questions: [Self.question])
        let second = Self.approval(epoch: first.epoch, questions: [Self.question])
        store.receive([first, second])
        card.present(first)
        var draft = store.answerDraft(for: first)
        draft.setFreeText("Green", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: first)

        card.present(second)
        #expect(card.presentedID == second.id)
        #expect(store.answerDraft(for: second) == ApprovalAnswerDraft())

        card.present(first)
        #expect(card.presentedApproval == first)
        #expect(store.answerDraft(for: first) == draft)
    }

    @Test func answerDraft_leavesWithItsRequest() {
        let store = ApprovalPresentationStore()
        let request = Self.approval(questions: [Self.question])
        store.receive([request])
        var draft = store.answerDraft(for: request)
        draft.toggle(label: "Red", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: request)

        store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])
        #expect(store.pending.isEmpty)
        #expect(store.ledger.entry(for: request)?.state == .withdrawn)
        #expect(store.answerDraft(for: request) == draft)

        store.receive([], epoch: UUID())
        #expect(store.ledger.entry(for: request) == nil)
        #expect(store.answerDraft(for: request) == ApprovalAnswerDraft())

        // A request the store no longer knows cannot gain a draft either.
        store.updateAnswerDraft(draft, for: request)
        #expect(store.answerDraft(for: request) == ApprovalAnswerDraft())
    }

    private static let question = ApprovalQuestion(
        header: "Color",
        prompt: "Which color?",
        options: [.init(label: "Red", description: nil)],
        isMultiSelect: false
    )

    // MARK: - When the card closes

    private struct Presented {
        let store: ApprovalPresentationStore
        let card: TestApprovalCard
        let request: ApprovalPresentation
        let epoch: UUID
    }

    /// A store with one request presented on its card.
    private static func presentedStore(
        questions: [ApprovalQuestion] = [],
        sender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void = { _, _ in }
    ) -> Presented {
        let store = ApprovalPresentationStore(decisionSender: sender)
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let request = approval(epoch: epoch, questions: questions)
        store.apply(.test(pending: [request]), epoch: epoch, now: now)
        card.present(request)
        return Presented(store: store, card: card, request: request, epoch: epoch)
    }

    @Test(arguments: [
        (BrokerTerminal.resolved(.delegate), ApprovalRequestState.handedToTerminal(since: now)),
        (.expired, .timedOut)
    ])
    func aRequestThatLeavesThePendingList_keepsItsCardWhileOpen(
        terminal: BrokerTerminal,
        expected: ApprovalRequestState
    ) {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card

        store.apply(.test(pending: [], terminals: [request.id: terminal]), epoch: epoch, now: Self.now)

        #expect(store.pending.isEmpty)
        #expect(store.ledger.entry(for: request)?.state == expected)
        #expect(card.presentedID == request.id)
        #expect(card.presentedApproval == request)
    }

    @Test(arguments: [
        (Optional(BrokerTerminal.resolved(.allowOnce)), ApprovalRequestState.answered(.allowOnce)),
        (.some(.canceled), .withdrawn),
        (nil, .unknownResult)
    ])
    func aSettledOrMissingRequest_closesItsCard(terminal: BrokerTerminal?, expected: ApprovalRequestState) {
        let presented = Self.presentedStore()
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card

        let projection: ApprovalControllerConnection.Projection = if let terminal {
            .test(pending: [], terminals: [request.id: terminal])
        } else {
            .test(pending: [], missing: [request.id])
        }
        store.apply(projection, epoch: epoch, now: Self.now)

        #expect(store.pending.isEmpty)
        #expect(store.ledger.entry(for: request)?.state == expected)
        #expect(card.presentedID == nil)
        #expect(card.presentedApproval == nil)
    }

    @Test func anAnswerThatLost_keepsTheCardToSaySo() async {
        let presented = Self.presentedStore { _, _ in
            throw ApprovalControllerConnection.DecisionRefusal.alreadySettled(.resolved(.deny))
        }
        let (store, request) = (presented.store, presented.request)
        let card = presented.card

        store.resolve(request, .allowOnce)
        await store.waitUntilResolved(request)

        #expect(card.presentedApproval == request)
        #expect(store.ledger.entry(for: request)?.state == .answered(.deny))
        #expect(store.ledger.entry(for: request)?.isAnsweredElsewhere == true)
        let model = ApprovalCardModel(approval: request, in: store)
        #expect(model?.status == .alreadyAnswered)
        #expect(model?.actions == .some(.none))
    }

    @Test func anAnswerKeepsTheCardOpenUntilTheBrokerAcceptsIt() async throws {
        let gate = Gate<Void>()
        defer { gate.open() }
        let sent = Recorded<[(approval: ApprovalPresentation, resolution: ApprovalResolution)]>([])
        let presented = Self.presentedStore { approval, resolution in
            sent.update { $0.append((approval, resolution)) }
            await gate.wait()
        }
        let (store, request) = (presented.store, presented.request)
        let card = presented.card

        store.resolve(request, .allowOnce)
        guard case .sending(.allowOnce, _)? = store.ledger.entry(for: request)?.state else {
            Issue.record("Expected the decision to be sending before the first suspension.")
            return
        }
        try await gate.waitUntilRequested()
        #expect(sent.value.map(\.approval) == [request])
        #expect(sent.value.map(\.resolution) == [.allowOnce])
        #expect(card.presentedID == request.id)
        #expect(card.presentedApproval == request)
        #expect(ApprovalCardModel(approval: request, in: store)?.actions == .sending)

        gate.open()
        await store.waitUntilResolved(request)

        #expect(store.ledger.entry(for: request)?.state == .answered(.allowOnce))
        #expect(store.lastFailureID == nil)
        #expect(card.presentedID == nil)
        #expect(!card.isCardOpen)
    }

    @Test func aCardHandedToTheTerminal_closesWhenTheTurnEnds() {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let card = TestApprovalCard(store)
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .running, updatedAt: Date())]
        }
        let epoch = UUID()
        let request = Self.approval(epoch: epoch, sessionID: "session")
        store.apply(ApprovalControllerConnection.Projection.test(pending: [request]), epoch: epoch, now: Self.now)
        card.present(request)
        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [], terminals: [request.id: .resolved(.delegate)]),
            epoch: epoch,
            now: Self.now
        )

        store.releaseStaleApprovals(in: session)
        #expect(card.presentedApproval == request)
        #expect(store.ledger.entry(for: request)?.state == .handedToTerminal(since: Self.now))

        session.applyAcrossTabs { tab in
            tab.agentBadges[.claude] = [paneID: AgentBadge(state: .finished, updatedAt: Date())]
        }
        store.releaseStaleApprovals(in: session)
        #expect(store.ledger.entry(for: request) == nil)
        #expect(card.presentedID == nil)
        #expect(!card.isCardOpen)
    }

    @Test func anEndedRequestAStaleProjectionStillLists_getsNoCard() {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let request = Self.approval(epoch: epoch)
        store.apply(ApprovalControllerConnection.Projection.test(pending: [request]), epoch: epoch, now: Self.now)
        store.ledger.endEpisode(id: request.id)

        store.receive([request], epoch: epoch)
        #expect(store.pending == [request])
        #expect(store.ledger.entry(for: request) == nil)
        #expect(!card.card.present(key: request.key, from: store))

        #expect(card.presentedID == nil)
        #expect(!card.isCardOpen)
    }

    @Test func aSendFailureIsShownOnlyForItsOwnCardModel() async {
        struct Offline: Error {}
        let store = ApprovalPresentationStore(decisionSender: { _, _ in throw Offline() })
        let first = Self.approval()
        let second = Self.approval(epoch: first.epoch)
        store.receive([first, second])

        store.resolve(first, .deny)
        await store.waitUntilResolved(first)
        #expect(ApprovalCardModel(approval: first, in: store)?.status == .sendFailed)

        store.resolve(second, .allowOnce)
        await store.waitUntilResolved(second)

        guard case .sendFailed(.deny, _)? = store.ledger.entry(for: first)?.state,
              case .sendFailed(.allowOnce, _)? = store.ledger.entry(for: second)?.state
        else {
            Issue.record("Expected both requests to retain their failed decisions.")
            return
        }
        #expect(store.lastFailureID == second.id)
        #expect(ApprovalCardModel(approval: first, in: store)?.status == .some(.none))
        #expect(ApprovalCardModel(approval: second, in: store)?.status == .sendFailed)
    }

    @Test func anAnchorAndDraftOutliveThePendingList() {
        let presented = Self.presentedStore(questions: [Self.question])
        let (store, request, epoch) = (presented.store, presented.request, presented.epoch)
        let card = presented.card
        let row = CGRect(x: 0, y: 100, width: 280, height: 40)
        card.updateRowAnchor(row, for: request)
        var draft = ApprovalAnswerDraft()
        draft.setFreeText("Green", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: request)

        store.apply(.test(pending: [], terminals: [request.id: .resolved(.delegate)]), epoch: epoch, now: Self.now)

        #expect(store.pending.isEmpty)
        #expect(card.rowAnchor(for: request) == row)
        #expect(store.answerDraft(for: request) == draft)

        let movedRow = row.offsetBy(dx: 0, dy: 40)
        card.updateRowAnchor(movedRow, for: request)
        draft.setFreeText("Blue", questionIndex: 0, in: Self.question)
        store.updateAnswerDraft(draft, for: request)

        #expect(card.rowAnchor(for: request) == movedRow)
        #expect(store.answerDraft(for: request) == draft)
    }
}
