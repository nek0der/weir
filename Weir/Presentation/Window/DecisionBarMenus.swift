// DecisionBarMenus.swift
// Weir — the decision bars' ⋯ menus a window can open from the keyboard.

import Foundation

/// Each pane's decision bar ⋯, as its bar hands it over: whether it is on
/// screen, and how to open it. Show Decision Bar Menu opens the focused
/// pane's, since the bar's buttons stay out of ⇥'s stops.
@MainActor
struct DecisionBarMenus {
    /// One bar's ⋯. A closure rather than the menu button, so the window
    /// does not hold an AppKit view.
    struct Menu {
        /// The bar that handed it over: a pane's next bar may be drawn
        /// before this one goes, and only the bar that set it takes it away.
        let owner: UUID
        /// Whether the ⋯ is on screen now; a row too narrow for any of its
        /// items, or one with none, shows no ⋯.
        let isShown: @MainActor () -> Bool
        let open: @MainActor () -> Void
    }

    private var menus: [UUID: Menu] = [:]

    mutating func set(_ menu: Menu, inPane paneID: UUID) {
        menus[paneID] = menu
    }

    /// Takes the pane's ⋯ away, if `owner` is the bar that set it.
    mutating func forget(pane paneID: UUID, by owner: UUID) {
        if menus[paneID]?.owner == owner {
            menus[paneID] = nil
        }
    }

    /// Whether the pane's bar shows a ⋯ to open.
    func isShown(inPane paneID: UUID) -> Bool {
        menus[paneID]?.isShown() ?? false
    }

    /// Opens the pane's ⋯ and says whether there was one to open.
    @discardableResult
    func open(inPane paneID: UUID) -> Bool {
        guard let menu = menus[paneID], menu.isShown() else { return false }
        menu.open()
        return true
    }
}

extension ProjectWindowState {
    /// The pane whose bar's ⋯ Show Decision Bar Menu opens: the selected
    /// tab's focused pane, while the panes are on screen.
    func decisionBarMenuPane(in session: WorkspaceSession) -> UUID? {
        guard !arePanesHidden else { return nil }
        return session.focusedPaneID(in: id)
    }

    /// Whether Show Decision Bar Menu has a ⋯ to open now.
    func hasDecisionBarMenu(in session: WorkspaceSession) -> Bool {
        decisionBarMenuPane(in: session).map(decisionBarMenus.isShown(inPane:)) ?? false
    }
}
