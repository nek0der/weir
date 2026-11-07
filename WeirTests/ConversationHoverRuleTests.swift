// ConversationHoverRuleTests.swift
// Weir — which tab and which turn cards a hovered conversation marks.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("ConversationHoverRule")
struct ConversationHoverRuleTests {
    private let first = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
    private let second = ConversationKey(provider: .codex, conversationID: "c2", isFallback: false)

    @Test func cardEmphasis_noHover_isNone() {
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: nil, hasIdentity: true) == .none)
    }

    @Test func cardEmphasis_tabHoverSameConversation_isLit() {
        let hover = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: hover, hasIdentity: true) == .lit)
    }

    @Test(arguments: [true, false])
    func cardEmphasis_tabHoverOtherConversation_isDimmed(hasIdentity: Bool) {
        let other = ConversationKey(provider: .codex, conversationID: "c1", isFallback: false)
        let hover = ConversationHover(conversations: [other], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: hover, hasIdentity: hasIdentity) == .dimmed)
    }

    @Test func cardEmphasis_cardHover_neverDims() {
        let other = ConversationHover(conversations: [second], source: .card)
        let same = ConversationHover(conversations: [first], source: .card)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: other, hasIdentity: true) == .none)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: same, hasIdentity: true) == .none)
    }

    /// The hovered tab's own card with no color has none to be tinted in.
    @Test func cardEmphasis_noIdentity_isNone() {
        let same = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: same, hasIdentity: false) == .none)
    }

    @Test func cardEmphasis_noConversation_isNone() {
        let other = ConversationHover(conversations: [second], source: .tab)
        #expect(ConversationHoverRule.cardEmphasis(of: nil, hover: other, hasIdentity: false) == .none)
        #expect(ConversationHoverRule.cardEmphasis(of: nil, hover: other, hasIdentity: true) == .none)
    }

    /// A split tab answers for every conversation it runs: neither of its
    /// panes' cards steps back behind it.
    @Test func cardEmphasis_hoverOfATabRunningBoth_lightsTheCardsOfBoth() {
        let tab = ConversationHover(conversations: [first, second], source: .tab)
        let other = ConversationKey(provider: .claude, conversationID: "c3", isFallback: false)
        #expect(ConversationHoverRule.cardEmphasis(of: first, hover: tab, hasIdentity: true) == .lit)
        #expect(ConversationHoverRule.cardEmphasis(of: second, hover: tab, hasIdentity: true) == .lit)
        #expect(ConversationHoverRule.cardEmphasis(of: other, hover: tab, hasIdentity: true) == .dimmed)
    }

    /// The selected tab's pane is framed in sight, so the tab says nothing more.
    @Test func tabTint_selectedTab_isNone() {
        let card = ConversationHover(conversations: [first], source: .card)
        #expect(ConversationHoverRule.tabTint(running: [first: 2], isSelected: true, hover: card) == nil)
        #expect(ConversationHoverRule.tabTint(running: [first: 2], isSelected: false, hover: card) == 2)
    }

    @Test func framesPane_onlyUnderACardOfItsConversation() {
        let card = ConversationHover(conversations: [first], source: .card)
        let tab = ConversationHover(conversations: [first], source: .tab)
        let otherProvider = ConversationKey(provider: .codex, conversationID: "c1", isFallback: false)
        #expect(ConversationHoverRule.framesPane(of: first, hover: card))
        #expect(!ConversationHoverRule.framesPane(of: second, hover: card))
        #expect(!ConversationHoverRule.framesPane(of: otherProvider, hover: card))
        #expect(!ConversationHoverRule.framesPane(of: first, hover: tab))
        #expect(!ConversationHoverRule.framesPane(of: nil, hover: card))
    }

    @Test func tabTint_cardHoverOfConversationTheTabRuns_isThatColor() {
        let same = ConversationHover(conversations: [first], source: .card)
        let ownTab = ConversationHover(conversations: [first], source: .tab)
        #expect(ConversationHoverRule.tabTint(running: [first: 2], isSelected: false, hover: same) == 2)
        // Only a tab that runs the card's conversation, never for the
        // tab's own hover, and never without a color.
        #expect(ConversationHoverRule.tabTint(running: [second: 1], isSelected: false, hover: same) == nil)
        #expect(ConversationHoverRule.tabTint(running: [first: 2], isSelected: false, hover: ownTab) == nil)
        #expect(ConversationHoverRule.tabTint(running: [:], isSelected: false, hover: same) == nil)
        #expect(ConversationHoverRule.tabTint(running: [first: 2], isSelected: false, hover: nil) == nil)
    }

    /// A split tab whose title stands for one conversation is tinted for
    /// the card of the conversation in its second pane, in that one's color.
    @Test func tabTint_splitTab_answersForItsSecondPaneInItsColor() {
        let secondPane = ConversationHover(conversations: [second], source: .card)
        #expect(ConversationHoverRule.tabTint(running: [first: 0, second: 3], isSelected: false, hover: secondPane) == 3)
    }
}
