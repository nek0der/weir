// SupervisionPaletteFacts+Window.swift
// Weir — reads a supervision window's palette facts, and what its actions can do now, from its state.

import Foundation

extension SupervisionPaletteFacts {
    /// Reads what `window` shows: its project, its session rows, whether its
    /// strip shows a review tab (one opened from the session it is on), and
    /// whether that tab is in front, the
    /// same facts its menu reads. `restoreTurnNumber` is the turn the
    /// palette's restore entry goes back to, which the window's restore
    /// handler works out. `sections` are the sidebar's
    /// (`AppState.sidebarSections(in:)`); without them, the sections it last
    /// drew, which are enough to tell whether there is more than one row,
    /// and to list each project's rows in the sidebar's order.
    /// `installedAgents` are the agents found on this Mac, read for the
    /// window's session as its "+" reads them. `toasts` holds the toast
    /// whose Undo the palette lists.
    @MainActor
    init(
        window: ProjectWindowState,
        session: WorkspaceSession,
        sections: SidebarPresentedSections? = nil,
        restoreTurnNumber: Int? = nil,
        installedAgents: InstalledAgentsStore? = nil,
        toasts: ToastCenter? = nil
    ) {
        let selection = window.selection
        let sections = sections ?? window.presentedSections
        // The facts the menu reads one by one, read here all at once.
        let live = ShortcutWindowFacts(window: window, session: session, sections: sections)
        self.init(
            projectID: live.projectID(),
            sessionRowCount: live.sessionRowCount(),
            hasReviewTab: live.hasReviewTab(),
            restoreTurnNumber: restoreTurnNumber,
            rowOrder: session.projects.flatMap { sections.ordered($0).map(\.row) },
            rowSections: sections.sections,
            arePanesHidden: live.arePanesHidden(),
            isChoosingProject: live.isChoosingProject(),
            areRailsHidden: live.areRailsHidden(),
            hasWorktreeMenu: live.hasWorktreeMenu(),
            hasDecisionBarMenu: live.hasDecisionBarMenu(),
            isCreatingWorktreeAtOnce: live.isCreatingWorktreeAtOnce(),
            installedAgents: installedAgents?.installedAgents(for: selection.activeContainerID.projectID),
            toastUndo: toasts?.current(in: window.id).flatMap(SupervisionPaletteFacts.ToastUndo.init)
        )
    }
}

extension ShortcutWindowFacts {
    /// Reads each fact from `window` as an action asks for it: the menu bar
    /// draws an item from the facts its answer reads, and observes no other.
    /// `sections` default to the ones the sidebar last drew, as for the
    /// palette.
    @MainActor
    init(window: ProjectWindowState, session: WorkspaceSession, sections: SidebarPresentedSections? = nil) {
        self.init(
            projectID: { window.selection.shownProjectID },
            sessionRowCount: {
                SessionRowNavigation.rows(in: window, session: session, sections: sections ?? window.presentedSections).count
            },
            hasReviewTab: { window.review?.belongs(to: window.selection.activeContainerID, in: session) ?? false },
            arePanesHidden: { window.arePanesHidden },
            isChoosingProject: { window.selection.isChoosingProject },
            areRailsHidden: { window.areRailsHidden },
            hasWorktreeMenu: {
                window.selection.shownProjectID.flatMap { session.project($0) }.map(CheckoutName.hasWorktreeMenu) ?? false
            },
            hasDecisionBarMenu: { window.hasDecisionBarMenu(in: session) },
            isCreatingWorktreeAtOnce: { window.isCreatingWorktreeAtOnce }
        )
    }
}

extension ShortcutAvailability {
    /// What can run now in `window`, each fact read from the window's state
    /// and its session only when an action asks: the value the menu bar and
    /// the window's own controls ask.
    @MainActor
    init(window: ProjectWindowState, session: WorkspaceSession, registry: (any PaneSurfaceProviding)?, attention: AttentionState) {
        self.init(
            session: session,
            window: window.id,
            facts: ShortcutWindowFacts(window: window, session: session),
            registry: registry,
            attention: attention
        )
    }
}

extension SupervisionPaletteFacts.ToastUndo {
    /// `item`'s Undo, `nil` for a toast with nothing to take back.
    init?(_ item: ToastItem) {
        guard item.undo != nil else { return nil }
        self.init(id: item.id, message: item.message, label: item.undoLabel)
    }
}
