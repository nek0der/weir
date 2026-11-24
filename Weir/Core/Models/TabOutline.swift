// TabOutline.swift
// Weir — a tab as the readers of where conversations run take it, without its agents' badges.

import Foundation

/// A tab without what its agents report as they work. A pass writes each
/// tab's badges on every hook, so a reader of the tabs is drawn again each
/// time; the changes panel, its title bar button, and the restore gate read
/// these instead, which change only when what they hold does
/// (`WorkspaceSession.tabOutlines`).
struct TabOutline: Equatable {
    let id: UUID
    let container: ContainerID
    /// The tab's panes, in the split tree's order (`SplitTree.allLeafIDs`).
    let panes: [UUID]
    /// The pane whose agent session started last (`Tab.latestAgentSessionPaneID`).
    let latestAgentSessionPaneID: UUID?
    /// The pane the keyboard is in (`SplitTree.effectiveFocusedLeafID`).
    let focusedPaneID: UUID?
    /// What the person sees the tab called (`Tab.shownTitle`).
    let shownTitle: String
    let titleOverride: String?

    init(_ tab: Tab) {
        id = tab.id
        container = tab.container
        panes = tab.splitTree.allLeafIDs()
        latestAgentSessionPaneID = tab.latestAgentSessionPaneID
        focusedPaneID = tab.splitTree.effectiveFocusedLeafID
        shownTitle = tab.shownTitle
        titleOverride = tab.titleOverride
    }
}
