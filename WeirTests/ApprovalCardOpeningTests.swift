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

    /// Every state a request can be in. A case added later must be added
    /// here by hand; the exhaustive switch in the first test flags it.
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

    @Test func isAnswerableOnCard_onlyAnOpenRequestOfAKindWeirAnswers() {
        for state in Self.everyState {
            let isOpen = switch state {
            case .held, .sendFailed: true
            case .sending, .handedToTerminal, .timedOut, .withdrawn, .unknownResult, .answered: false
            }
            #expect(state.isAnswerableOnCard(supportsNativeAnswer: true) == isOpen, "\(state)")
            // A Codex question is never answered on the card, whatever its state.
            #expect(!state.isAnswerableOnCard(supportsNativeAnswer: false), "\(state)")
        }
    }

    /// An item's `canAnswerInWeir`, its fact, and the menu bar's question
    /// offer read the rule, and agree with it for every state.
    @Test func theItemAndTheMenuBarsQuestionOffer_readTheRule() {
        for state in Self.everyState {
            for supportsNativeAnswer in [true, false] {
                let fact = ApprovalFact.test(isQuestion: true, supportsNativeAnswer: supportsNativeAnswer, state: state)
                let rule = state.isAnswerableOnCard(supportsNativeAnswer: supportsNativeAnswer)
                let item = AttentionItem.testList([.question(fact)])[0]
                #expect(fact.isAnswerableOnCard == rule)
                #expect(item.canAnswerInWeir == rule)
                let offer = MenuBarApprovalRule.offer(
                    isQuestion: true,
                    supportsNativeAnswer: supportsNativeAnswer,
                    command: nil,
                    state: state
                )
                #expect((offer == .answerInWeir) == rule, "\(state), \(supportsNativeAnswer)")
            }
        }
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
        let item = AttentionItem.testList([.approval(held)])[0]
        #expect(item.answerKey(isHeld: { _ in true }, whileCardIsUp: .staysOffered) == held.key)
        #expect(item.answerKey(isHeld: { _ in false }, whileCardIsUp: .staysOffered) == nil, "no request for the card to show")

        let unanswerable: [AttentionItemKind] = [
            .approval(ApprovalFact.test(state: .timedOut)),
            .approval(ApprovalFact.test(state: .handedToTerminal(since: Self.now))),
            .approval(ApprovalFact.test(state: .sending(.allowOnce, since: Self.now))),
            .question(ApprovalFact.test(isQuestion: true, provider: .codex)),
            .prompt(PromptWait(detail: nil)),
            .stop(.processExited)
        ]
        for item in AttentionItem.testList(unanswerable) {
            #expect(item.answerKey(isHeld: { _ in true }, whileCardIsUp: .staysOffered) == nil, "\(item.kind)")
        }
    }

    /// A question the ledger holds offers Answer… even when it has no text
    /// to show: an empty first prompt and no summary.
    @Test func aSidebarRowsHeldQuestionWithNoText_stillOffersAnswer() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let request = ApprovalPresentation.test(
            summary: nil,
            questions: [ApprovalQuestion(header: nil, prompt: "", options: [], isMultiSelect: false)]
        )
        #expect(ApprovalRequestText(request).questionText == nil)
        let ledger = ApprovalLedger()
        ledger.observe(pending: [request], epoch: request.epoch)
        var queue = AttentionQueue()
        queue.insert(
            id: .question(request.key),
            kind: .question(ApprovalFact.test(key: request.key, isQuestion: true)),
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let row = try #require(SessionSidebarModel(
            project: project, session: session, queue: queue, runtimes: [], approvals: ledger,
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Locale(identifier: "en")
        ).rows.first)

        #expect(row.answerKey == request.key)
    }

    /// The rail hides its Answer… while the card is up for the request; every
    /// other surface keeps it.
    @Test func answerKey_whileTheCardIsUp_staysOrHidesAsTheSurfaceSays() {
        let fact = ApprovalFact.test()
        let other = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
        let item = AttentionItem.testList([.approval(fact)])[0]

        #expect(item.answerKey(isHeld: { _ in true }, whileCardIsUp: .staysOffered) == fact.key)
        #expect(item.answerKey(isHeld: { _ in true }, whileCardIsUp: .hidden(isCardUp: { $0 == fact.key })) == nil)
        #expect(
            item.answerKey(isHeld: { _ in true }, whileCardIsUp: .hidden(isCardUp: { $0 == other })) == fact.key,
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

    @Test func presentByKey_opensOnlyWhileTheLedgerHoldsTheCardOpen() {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        let card = WindowApprovalCard()
        #expect(!card.present(key: request.key, from: store), "a request the ledger does not hold")
        #expect(card.state.presentedID == nil)

        store.receive([request])
        #expect(card.present(key: request.key, from: store))
        #expect(card.isPresenting(request.key, in: store))
    }

    /// The route that going to a request no pane is known for, the menu bar,
    /// a notification, and a decision bar share: the card opens only while
    /// Weir can answer the request on it, not for one handed to the terminal
    /// or timed out.
    @Test func presentToAnswer_opensNoCardForARequestLeftToTheTerminal() {
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

        for request in [handed, timedOut] {
            #expect(store.cardRequest(for: request.key) != nil, "the ledger still holds it")
            #expect(!card.presentToAnswer(key: request.key, from: store))
            #expect(card.state.presentedID == nil)
        }
        #expect(card.presentToAnswer(key: held.key, from: store, openedFromPane: nil))
        #expect(card.isPresenting(held.key, in: store))
    }

    /// The store's `opensCard`, for the states a request reaches through its
    /// events, and the decision bar's card, for every state, read the rule
    /// too.
    @Test func opensCardAndTheDecisionBarsCard_readTheRule() throws {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let failed = ApprovalPresentation.test(epoch: epoch)
        let sending = ApprovalPresentation.test(epoch: epoch)
        let timedOut = ApprovalPresentation.test(epoch: epoch)
        store.receive([held, failed, sending, timedOut])
        store.ledger.record(.userDecided(.deny), for: failed.id, now: SuspendingClock.now)
        store.ledger.record(.sendFailed("offline"), for: failed.id, now: SuspendingClock.now)
        store.ledger.record(.userDecided(.allowOnce), for: sending.id, now: SuspendingClock.now)
        store.ledger.record(.deadlinePassed, for: timedOut.id, now: SuspendingClock.now)

        for request in [held, failed, sending, timedOut] {
            let entry = try #require(store.ledger.entry(for: request))
            let rule = entry.state.isAnswerableOnCard(supportsNativeAnswer: request.supportsNativeAnswer)
            #expect(store.opensCard(request.key) == rule, "\(entry.state)")
        }
        for state in Self.everyState {
            for supportsNativeAnswer in [true, false] {
                let fact = ApprovalFact.test(isQuestion: true, supportsNativeAnswer: supportsNativeAnswer, state: state)
                let isCard = if case .card = Self.answerPlace(of: fact) {
                    true
                } else {
                    false
                }
                #expect(isCard == state.isAnswerableOnCard(supportsNativeAnswer: supportsNativeAnswer), "\(state)")
            }
        }
    }

    /// Where the decision bar of a pane holding only `fact`'s question says
    /// it is answered.
    private static func answerPlace(of fact: ApprovalFact) -> DecisionBarContent.AnswerPlace? {
        let item = AttentionItem.testList([.question(fact)])[0]
        let content = DecisionBarContent.make(.init(
            items: [item],
            agent: SessionRowFact.Agent(provider: .claude, state: .needsInput, detail: nil)
        ))
        guard case let .question(_, answer) = content.body else { return nil }
        return answer
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
    }

    /// With no room beside it, the Needs Attention list gives way only to a
    /// card that opened.
    @Test func needsAttentionAnswer_inANarrowWindow_closesTheListOnlyForACardThatOpened() {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test()
        let (session, _) = WorkspaceSessionFixture.withProject()
        let window = WindowRegistry(primary: session.primarySelection).primary
        // The list's left edge leaves no room for the card beside it.
        let listFrame = CGRect(x: 20, y: 40, width: 320, height: 400)
        let list = TitleBarMenuRequest(menu: .needsAttention, anchor: .zero)
        window.titleBarMenu = list

        NeedsAttentionListView.answer(request.key, listFrame: listFrame, in: window, approvals: store)
        #expect(!window.approvalCard.isOpen(in: store))
        #expect(window.titleBarMenu == list, "no card opened, so the list stays")

        store.receive([request])
        NeedsAttentionListView.answer(request.key, listFrame: listFrame, in: window, approvals: store)
        #expect(window.approvalCard.isPresenting(request.key, in: store))
        #expect(window.titleBarMenu == nil)
        #expect(!window.approvalCard.state.standsLeftOfOpener)
    }

    // MARK: - The opener's frame

    @Test func anOpenerNeverMeasured_isNoOpener() {
        let frame = CGRect(x: 10, y: 20, width: 80, height: 24)
        #expect(ApprovalCardState.opener(measured: .zero) == nil)
        #expect(ApprovalCardState.opener(measured: frame) == frame)
    }
}
