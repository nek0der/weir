// SupervisionPaletteFacts.swift
// Weir — what the palette knows about the supervision window it opens in.

import Foundation
import WeirDomain

/// The window the palette opened in, as far as its rows' enabled states
/// need it: read by the window's own code, since Core cannot name a
/// window's session rows or its review tab.
struct SupervisionPaletteFacts: Equatable {
    /// The window's project, kept while a scratch tab is selected.
    var projectID: UUID?
    /// How many session rows ⌘[ ⌘] walk.
    var sessionRowCount: Int
    /// Whether the window's strip shows a review tab, which ⇧⌘[ ⇧⌘] step
    /// through with the terminal tabs.
    var hasReviewTab: Bool
    /// The number of the turn "Restore Code to Before This Turn…" restores
    /// to (`RestoreEntryTarget`), `nil` when there is none to offer.
    var restoreTurnNumber: Int?
    /// Every project's rows in the order the window's sidebar lists them,
    /// which the palette lists each project's worktrees in. Empty
    /// leaves them in the projects' own order.
    var rowOrder: [ContainerID] = []
    /// The section each row is listed in, as the window's sidebar shows
    /// it (a row not named is a working one), so a worktree the palette
    /// marks as one of the other worktrees is one the sidebar lists there.
    /// Empty when the window gives none; then the palette goes by what the
    /// row holds alone (`SidebarSectionRule.isUnopened`).
    var rowSections: [ContainerID: SidebarSection] = [:]
    /// Whether the window's review tab is in front, standing where the
    /// terminal was (`ProjectWindowState.arePanesHidden`): the pane
    /// commands are off then (`isOffPaneCommand`).
    var arePanesHidden = false
    /// Whether the window offers the projects to open instead of a
    /// session, so it has no pane strip for Open Tabs to hang from.
    var isChoosingProject = false
    /// Whether the rail is hidden, and with it the button the plan usage
    /// panel hangs from.
    var areRailsHidden = false
    /// Whether the title bar shows the worktree ▾ (`CheckoutName.hasWorktreeMenu`).
    var hasWorktreeMenu = false
    /// Whether the focused pane's decision bar shows a ⋯ for Show
    /// Decision Bar Menu to open.
    var hasDecisionBarMenu = false
    /// The agents found on this Mac for the window's session, which the
    /// pane strip's "+" offers (`InstalledAgentsStore`); `nil` until they were
    /// looked for once, when every agent is offered (`InstalledAgentRule`).
    var installedAgents: [AgentKind]?
    /// The window's toast while it offers Undo, which the palette lists
    /// as a row; `nil` while it shows none, or one with nothing to undo.
    var toastUndo: ToastUndo?

    /// A toast's Undo as the palette lists it.
    struct ToastUndo: Equatable {
        /// The toast's id, which the row takes back and no other.
        let id: UUID
        let message: DisplayText
        /// What Undo takes back, where "Undo" does not say it (`ToastItem.undoLabel`).
        let label: LocalizedStringResource?
    }

    /// Whether ⇧⌘[ ⇧⌘] have a tab to step to among `tabCount` terminal
    /// tabs: another one, or the window's review tab (`facts`). The menu
    /// and the palette ask the same question.
    static func canCycleTab(tabCount: Int, facts: Self) -> Bool {
        tabCount > (facts.hasReviewTab ? 0 : 1)
    }

    /// Whether `action` is a pane command (split, equalize, zoom, focus a
    /// neighbor) while the window's panes are hidden, which leaves it off.
    static func isOffPaneCommand(_ action: WeirShortcutAction, arePanesHidden: Bool) -> Bool {
        arePanesHidden && action.category == .splits
    }
}
