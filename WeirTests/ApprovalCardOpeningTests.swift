// ApprovalCardOpeningTests.swift
// Weir — the one rule for whether, and on which request, a window's approval card opens.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalCardOpeningTests {
    private nonisolated static let now = SuspendingClock().now

    /// Representative values for the state cases, including both sending destinations.
    private static let everyState: [ApprovalRequestState] = [
        .held,
        .sending(.allowOnce, since: now),
        .sending(.delegate, since: now),
        .handedToTerminal(since: now),
        .timedOut,
        .withdrawn,
        .unknownResult,
        .sendFailed(.deny, error: "offline"),
        .answered(.allowOnce)
    ]

    // MARK: - The Domain rule

    @Test func questionFactsAndItems_preserveAnswerability() {
        for state in Self.everyState {
            let isOpen = switch state {
            case .held, .sendFailed: true
            case .sending, .handedToTerminal, .timedOut, .withdrawn, .unknownResult, .answered: false
            }
            for provider in [AgentKind.claude, .codex] {
                let fact = ApprovalFact.test(isQuestion: true, provider: provider, state: state)
                let item = Self.items([.question(fact)])[0]
                let expected = isOpen && provider == .claude
                #expect(fact.isAnswerableOnCard == expected, "\(state), \(provider)")
                #expect(item.canAnswerInWeir == expected, "\(state), \(provider)")
            }
        }
    }

    private static func items(_ kinds: [AttentionItemKind]) -> [AttentionItem] {
        var queue = AttentionQueue()
        for (index, kind) in kinds.enumerated() {
            let episode = EpisodeKey(origin: .runtime("r\(index)"), episodeToken: "1")
            let id: AttentionItemID = switch kind {
            case let .approval(fact): .approval(fact.key)
            case let .question(fact): .question(fact.key)
            case .prompt: .prompt(episode)
            case .stop: .stop(episode)
            case let .unread(turn): .unread(turn.turnID)
            }
            queue.insert(
                id: id,
                kind: kind,
                subject: .unplaced(provider: kind.approvalFact?.provider ?? .claude),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        return queue.items
    }

    // MARK: - The request behind an item

    @Test func approvalFactAndRequestKey_areTheRequestsOnly() {
        let approval = ApprovalFact.test()
        let question = ApprovalFact.test(isQuestion: true)
        let episode = EpisodeKey(origin: .runtime("r"), episodeToken: "1")
        let turn = UnreadTurn(turnID: TurnID("t"), changes: .unknown)

        #expect(AttentionItemKind.approval(approval).approvalFact == approval)
        #expect(AttentionItemKind.question(question).approvalFact == question)
        #expect(AttentionItemKind.prompt(PromptWait(detail: nil)).approvalFact == nil)
        #expect(AttentionItemKind.stop(.processExited).approvalFact == nil)
        #expect(AttentionItemKind.unread(turn).approvalFact == nil)

        #expect(AttentionItemID.approval(approval.key).requestKey == approval.key)
        #expect(AttentionItemID.question(question.key).requestKey == question.key)
        #expect(AttentionItemID.prompt(episode).requestKey == nil)
        #expect(AttentionItemID.stop(episode).requestKey == nil)
        #expect(AttentionItemID.unread(turn.turnID).requestKey == nil)
    }

    // MARK: - Which key a row's Answer… opens

    @Test func answerKey_needsARequestWeirCanAnswer_thatTheLedgerHolds() {
        let held = ApprovalFact.test()
        let item = Self.items([.approval(held)])[0]
        let unrelated = ApprovalFact.test().key
        let keys: Set<ApprovalKey> = [held.key, unrelated]
        #expect(item.answerKey(isHeld: keys.contains, whileCardIsUp: .staysOffered) == held.key)
        #expect(item.answerKey(isHeld: { $0 == unrelated }, whileCardIsUp: .staysOffered) == nil)

        let unanswerable: [AttentionItemKind] = [
            .approval(ApprovalFact.test(state: .timedOut)),
            .approval(ApprovalFact.test(state: .handedToTerminal(since: Self.now))),
            .approval(ApprovalFact.test(state: .sending(.allowOnce, since: Self.now))),
            .question(ApprovalFact.test(isQuestion: true, provider: .codex)),
            .prompt(PromptWait(detail: nil)),
            .stop(.processExited),
            .unread(UnreadTurn(turnID: TurnID("unread"), changes: .unknown))
        ]
        for item in Self.items(unanswerable) {
            #expect(item.answerKey(isHeld: { _ in true }, whileCardIsUp: .staysOffered) == nil, "\(item.kind)")
        }
    }

    /// The rail hides its Answer… while the card is up for the request; every
    /// other surface keeps it.
    @Test func answerKey_whileTheCardIsUp_staysOrHidesAsTheSurfaceSays() {
        let fact = ApprovalFact.test()
        let other = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
        let item = Self.items([.approval(fact)])[0]

        #expect(item.answerKey(isHeld: { $0 == fact.key }, whileCardIsUp: .staysOffered) == fact.key)
        #expect(item.answerKey(isHeld: { $0 == fact.key }, whileCardIsUp: .hidden(isCardUp: { $0 == fact.key })) == nil)
        #expect(
            item.answerKey(isHeld: { $0 == fact.key }, whileCardIsUp: .hidden(isCardUp: { $0 == other })) == fact.key,
            "a card up for another request hides nothing"
        )
    }

    // MARK: - The store's card request

    @Test func cardRequest_followsTheLedgersHoldOnTheCard() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let timedOut = ApprovalPresentation.test(epoch: epoch)
        let withdrawn = ApprovalPresentation.test(epoch: epoch)
        store.receive([held, timedOut, withdrawn])
        store.ledger.record(.deadlinePassed, for: timedOut.id, now: SuspendingClock.now)
        store.ledger.record(.brokerTerminal(.canceled), for: withdrawn.id, now: SuspendingClock.now)

        #expect(store.cardRequest(for: held.key) == held)
        // Held open to say where to answer, though not answered on it.
        #expect(store.cardRequest(for: timedOut.key) == timedOut)
        #expect(!store.opensCard(timedOut.key))
        #expect(store.cardRequest(for: withdrawn.key) == nil)
        #expect(store.cardRequest(for: ApprovalKey(epoch: epoch, runID: UUID(), requestID: UUID())) == nil)
        // The same rule as the card's lookup by its string ID.
        for request in [held, timedOut, withdrawn] {
            #expect(store.cardRequest(for: request.key) == store.approvalForCard(request.id))
        }
    }

    @Test func presentByKey_opensOnlyWhileTheLedgerHoldsTheCardOpen() throws {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        let card = WindowApprovalCard()
        #expect(!card.present(key: request.key, from: store), "a request the ledger does not hold")
        #expect(card.state.presentedID == nil)

        store.receive([request])
        #expect(card.present(key: request.key, from: store))
        #expect(card.isPresenting(request.key, in: store))
        store.ledger.record(.deadlinePassed, for: request.id, now: SuspendingClock.now)
        card.dismiss()
        try #require(!store.opensCard(request.key))
        #expect(card.present(key: request.key, from: store))
        #expect(card.isPresenting(request.key, in: store))
    }

    /// The route that going to a request no pane is known for, the menu bar,
    /// a notification, and a decision bar share: the card opens only while
    /// Weir can answer the request on it, not for one handed to the terminal
    /// or timed out.
    @Test func presentToAnswer_preservesTheShownCardWhenAnotherRequestCannotBeAnswered() throws {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let handed = ApprovalPresentation.test(epoch: epoch)
        let timedOut = ApprovalPresentation.test(epoch: epoch)
        store.receive([held, handed, timedOut])
        store.ledger.record(.handedOverBySetting, for: handed.id, now: SuspendingClock.now)
        store.ledger.record(.sendSucceeded, for: handed.id, now: SuspendingClock.now)
        store.ledger.record(.deadlinePassed, for: timedOut.id, now: SuspendingClock.now)
        let card = WindowApprovalCard()
        let pane = UUID()
        try #require(card.presentToAnswer(key: held.key, from: store, openedFromPane: pane, focusesClose: true))
        let shown = card.state

        for request in [handed, timedOut] {
            #expect(store.cardRequest(for: request.key) != nil, "the ledger still holds it")
            #expect(!card.presentToAnswer(key: request.key, from: store))
            #expect(card.state == shown)
            #expect(card.isPresenting(held.key, in: store))
        }
        let unknown = ApprovalPresentation.test(epoch: epoch)
        #expect(!card.presentToAnswer(key: unknown.key, from: store))
        #expect(card.state == shown)
    }

    // MARK: - The routes that open a card

    /// Going to a request no pane is known for (⌘J, a list row) takes this
    /// branch of `AppState.go(to:opensTurnReview:in:)`: a request left to
    /// the terminal opens no card.
    @Test func goingToAnUnplacedRequest_opensTheCardOnlyWhileItIsAnswerableThere() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let timedOut = ApprovalPresentation.test(epoch: epoch)
        store.receive([held, timedOut])
        store.ledger.record(.deadlinePassed, for: timedOut.id, now: SuspendingClock.now)
        let (session, _) = WorkspaceSessionFixture.withProject()
        let window = WindowRegistry(primary: session.primarySelection).primary

        AppState.openCard(forUnplaced: Self.unplaced(timedOut), in: window, approvals: store)
        #expect(!window.approvalCard.isOpen(in: store))

        AppState.openCard(forUnplaced: Self.unplaced(held), in: window, approvals: store)
        #expect(window.approvalCard.isPresenting(held.key, in: store))
    }

    private static func unplaced(_ request: ApprovalPresentation) -> AttentionItem {
        var queue = AttentionQueue()
        queue.insert(
            id: .approval(request.key),
            kind: .approval(ApprovalFact.test(key: request.key)),
            subject: .unplaced(provider: .claude),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        return queue.items[0]
    }

    /// All Projects' Answer… before its button reported a frame names no
    /// opener, as the other controls do.
    @Test func allProjectsAnswer_withAnUnmeasuredButton_namesNoOpener() {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        store.receive([request])
        let (session, _) = WorkspaceSessionFixture.withProject()
        let window = WindowRegistry(primary: session.primarySelection).primary

        AllProjectsActions.answer(request.key, actionFrame: .zero, in: window, approvals: store)
        #expect(window.approvalCard.isPresenting(request.key, in: store))
        #expect(window.approvalCard.state.openedFrom == nil)

        let button = CGRect(x: 300, y: 200, width: 80, height: 24)
        AllProjectsActions.answer(request.key, actionFrame: button, in: window, approvals: store)
        #expect(window.approvalCard.state.openedFrom == button)
        #expect(window.approvalCard.isPresenting(request.key, in: store))
    }

    @Test(arguments: [false, true])
    func needsAttentionAnswer_placesTheCardAndClosesOnlyAnOverlappingList(hasRoom: Bool) {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        let (session, _) = WorkspaceSessionFixture.withProject()
        let window = WindowRegistry(primary: session.primarySelection).primary
        let listFrame = CGRect(x: hasRoom ? 700 : 20, y: 40, width: 320, height: 400)
        let anchor = CGRect(x: 100, y: 20, width: 24, height: 24)
        window.needsAttentionAnchor = anchor
        let list = TitleBarMenuRequest(menu: .needsAttention, anchor: .zero)
        window.titleBarMenu = list

        NeedsAttentionListView.answer(request.key, listFrame: listFrame, in: window, approvals: store)
        #expect(!window.approvalCard.isOpen(in: store))
        #expect(window.titleBarMenu == list, "no card opened, so the list stays")

        store.receive([request])
        NeedsAttentionListView.answer(request.key, listFrame: listFrame, in: window, approvals: store)
        #expect(window.approvalCard.isPresenting(request.key, in: store))
        #expect(window.titleBarMenu == (hasRoom ? list : nil))
        #expect(window.approvalCard.state.standsLeftOfOpener == hasRoom)
        #expect(window.approvalCard.state.openedFrom == (hasRoom ? listFrame : anchor))
    }

}
