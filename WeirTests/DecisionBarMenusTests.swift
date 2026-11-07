// DecisionBarMenusTests.swift
// Weir — which pane's decision bar ⋯ Show Decision Bar Menu opens, and which bar may take it away.

import Foundation
import Testing
@testable import Weir

@MainActor
struct DecisionBarMenusTests {
    @MainActor
    private final class MenuProbe {
        var isShown: Bool
        private(set) var opens = 0

        init(isShown: Bool = true) {
            self.isShown = isShown
        }

        func menu(owner: UUID = UUID()) -> DecisionBarMenus.Menu {
            .init(owner: owner, isShown: { self.isShown }, open: { self.opens += 1 })
        }
    }

    @Test func open_opensThePanesMenu_onlyWhileItIsShown() {
        var menus = DecisionBarMenus()
        let (pane, otherPane) = (UUID(), UUID())
        let target = MenuProbe(isShown: false)
        let other = MenuProbe()
        menus.set(other.menu(), inPane: otherPane)
        #expect(!menus.open(inPane: pane))
        #expect(other.opens == 0)

        menus.set(target.menu(), inPane: pane)
        #expect(!menus.isShown(inPane: pane))
        #expect(!menus.open(inPane: pane))
        #expect(target.opens == 0)

        target.isShown = true
        #expect(menus.isShown(inPane: pane))
        #expect(menus.open(inPane: pane))
        #expect(target.opens == 1)
        #expect(other.opens == 0)

        target.isShown = false
        #expect(!menus.open(inPane: pane))
        #expect(menus.open(inPane: otherPane))
        #expect(target.opens == 1)
        #expect(other.opens == 1)
    }

    @Test func forget_takesAwayOnlyTheMenuItsOwnBarSet() {
        var menus = DecisionBarMenus()
        let pane = UUID()
        let (old, new) = (UUID(), UUID())
        let removed = MenuProbe()
        let replacement = MenuProbe()
        menus.set(removed.menu(owner: old), inPane: pane)
        #expect(menus.open(inPane: pane))
        menus.set(replacement.menu(owner: new), inPane: pane)

        menus.forget(pane: pane, by: old)
        #expect(menus.isShown(inPane: pane))
        #expect(menus.open(inPane: pane))
        #expect(removed.opens == 1)
        #expect(replacement.opens == 1)

        menus.forget(pane: pane, by: new)
        #expect(!menus.isShown(inPane: pane))
        #expect(!menus.open(inPane: pane))
        #expect(replacement.opens == 1)
    }

    @Test func thePaneItOpens_isTheFocusedOne_whileThePanesShow() throws {
        let (session, tab, firstPane) = WorkspaceSessionFixture.withLooseTab()
        let window = ProjectWindowState(selection: session.primarySelection)
        PaneActions.split(session, direction: .horizontal, in: session.primaryWindowID)
        let panes = try #require(session.tab(tab.id)?.splitTree.allLeafIDs())
        #expect(panes.count == 2)
        let secondPane = try #require(panes.first { $0 != firstPane })
        let first = MenuProbe()
        let second = MenuProbe()
        window.decisionBarMenus.set(first.menu(), inPane: firstPane)
        window.decisionBarMenus.set(second.menu(), inPane: secondPane)

        session.update(tab.id) { $0.splitTree.focusedLeafID = firstPane }
        #expect(window.decisionBarMenuPane(in: session) == firstPane)
        #expect(window.hasDecisionBarMenu(in: session))
        SupervisionWindowActions.showDecisionBarMenu(in: window, session: session)
        #expect(first.opens == 1)
        #expect(second.opens == 0)

        session.update(tab.id) { $0.splitTree.focusedLeafID = secondPane }
        #expect(window.decisionBarMenuPane(in: session) == secondPane)
        #expect(window.hasDecisionBarMenu(in: session))
        SupervisionWindowActions.showDecisionBarMenu(in: window, session: session)
        #expect(first.opens == 1)
        #expect(second.opens == 1)

        window.review = ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(window.arePanesHidden)
        #expect(window.decisionBarMenuPane(in: session) == nil)
        #expect(!window.hasDecisionBarMenu(in: session))
    }
}
