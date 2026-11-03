// DecisionBarMenusTests.swift
// Weir — which pane's decision bar ⋯ Show Decision Bar Menu opens, and which bar may take it away.

import Foundation
import Testing
@testable import Weir

@MainActor
struct DecisionBarMenusTests {
    private final class Opened {
        var count = 0
    }

    private static func menu(owner: UUID, isShown: Bool, opened: Opened) -> DecisionBarMenus.Menu {
        DecisionBarMenus.Menu(owner: owner, isShown: { isShown }, open: { opened.count += 1 })
    }

    @Test func open_opensThePanesMenu_onlyWhileItIsShown() {
        var menus = DecisionBarMenus()
        let pane = UUID()
        let opened = Opened()
        #expect(!menus.open(inPane: pane), "a pane with no bar")

        menus.set(Self.menu(owner: UUID(), isShown: false, opened: opened), inPane: pane)
        #expect(!menus.isShown(inPane: pane))
        #expect(!menus.open(inPane: pane), "a bar with no ⋯")

        menus.set(Self.menu(owner: UUID(), isShown: true, opened: opened), inPane: pane)
        #expect(menus.isShown(inPane: pane))
        #expect(menus.open(inPane: pane))
        #expect(opened.count == 1)
    }

    /// A pane's next bar may be drawn before the last one goes; the last
    /// one going leaves the next one's ⋯ in place.
    @Test func forget_takesAwayOnlyTheMenuItsOwnBarSet() {
        var menus = DecisionBarMenus()
        let pane = UUID()
        let (old, new) = (UUID(), UUID())
        let opened = Opened()
        menus.set(Self.menu(owner: old, isShown: true, opened: opened), inPane: pane)
        menus.set(Self.menu(owner: new, isShown: true, opened: opened), inPane: pane)
        menus.forget(pane: pane, by: old)
        #expect(menus.isShown(inPane: pane))
        menus.forget(pane: pane, by: new)
        #expect(!menus.isShown(inPane: pane))
    }

    /// The focused pane's, and none while the review stands where the
    /// panes were.
    @Test func thePaneItOpens_isTheFocusedOne_whileThePanesShow() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let window = ProjectWindowState(selection: session.primarySelection)
        let focused = session.activeTab(in: session.primaryWindowID)?.splitTree.effectiveFocusedLeafID
        #expect(focused != nil)
        #expect(window.decisionBarMenuPane(in: session) == focused)

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
    }
}
