// SupervisionPaletteFacts+Window.swift
// Weir — reads a supervision window's palette facts from its state.

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
        self.init(
            projectID: selection.shownProjectID,
            sessionRowCount: SessionRowNavigation.rows(in: window, session: session, sections: sections).count,
            hasReviewTab: window.review?.belongs(to: selection.activeContainerID, in: session) ?? false,
            restoreTurnNumber: restoreTurnNumber,
            rowOrder: session.projects.flatMap { sections.ordered($0).map(\.row) },
            rowSections: sections.sections,
            arePanesHidden: window.arePanesHidden,
            isChoosingProject: selection.isChoosingProject,
            areRailsHidden: window.areRailsHidden,
            hasWorktreeMenu: selection.shownProjectID.flatMap { session.project($0) }.map(CheckoutName.hasWorktreeMenu) ?? false,
            hasDecisionBarMenu: window.hasDecisionBarMenu(in: session),
            installedAgents: installedAgents?.installedAgents(for: selection.activeContainerID.projectID),
            toastUndo: toasts?.current(in: window.id).flatMap(SupervisionPaletteFacts.ToastUndo.init)
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
