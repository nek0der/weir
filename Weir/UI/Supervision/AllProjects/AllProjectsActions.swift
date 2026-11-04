// AllProjectsActions.swift
// Weir — what the all projects sheet does: answer a card's request, open its session (switching this window to its project), and close.

import AppKit
import WeirDomain

@MainActor
enum AllProjectsActions {
    /// A card's Answer…: the approval card, beside the card's button at
    /// `actionFrame`, with this window and its pane as they are. A button
    /// not measured yet names no opener (`ApprovalCardState.opener`), so the
    /// card stands where it would with none rather than at the corner.
    static func answer(
        _ key: ApprovalKey,
        actionFrame: CGRect,
        in window: ProjectWindowState,
        approvals: ApprovalPresentationStore
    ) {
        window.approvalCard.present(key: key, from: approvals, openedFrom: ApprovalCardState.opener(measured: actionFrame))
    }

    /// Opens `card`: the pane of the item it shows, reached the same way
    /// ⌘J and the Needs Attention list reach it; otherwise its session. Either
    /// way this window switches to the card's project in place, or the
    /// window that shows it comes forward
    /// (`WindowRegistry.show(project:in:from:intent:)`). Another project
    /// counts toward project ▾'s order as choosing it there does. The sheet
    /// closes either way.
    ///
    /// ⌘-click or ⌘Return (`opensInNewWindow`) opens a card of another project in
    /// a new window instead (`WindowRegistry.openInNewWindow`), on the same
    /// item or session; a card of this window's project opens here.
    static func open(
        _ card: AllProjectsModel.Card,
        from window: ProjectWindowState,
        stores: AllProjectsStores,
        opensInNewWindow: Bool = false
    ) {
        window.isAllProjectsPresented = false
        let isOtherProject = card.projectID != window.selection.shownProjectID
        if isOtherProject {
            stores.frecency.record(ProjectMenuModel.frecencyKey(card.projectID))
        }
        let opensInNewWindow = opensInNewWindow && isOtherProject
        if let id = card.leadItemID, let item = stores.attentionQueue.queue.item(id) {
            stores.attentionQueue.focus(item, from: window, opensInNewWindow: opensInNewWindow)
            return
        }
        let registry = stores.windows
        let shown = opensInNewWindow
            ? registry.openInNewWindow(project: card.projectID, in: stores.session, from: window)
            : registry.show(project: card.projectID, in: stores.session, from: window, intent: .person)
        guard let target = shown else {
            return
        }
        stores.session.setActiveContainer(card.id, in: target.id, intent: .person)
        // A session already in front shows no new terminal to take the
        // keyboard the field held: its terminal is handed it.
        returnKeyboard(in: target, stores: stores)
    }

    /// Closes the sheet and hands the keyboard back to the window's
    /// terminal.
    static func close(_ window: ProjectWindowState, stores: AllProjectsStores) {
        window.isAllProjectsPresented = false
        returnKeyboard(in: window, stores: stores)
    }

    /// Gives the keyboard to `window`'s terminal unless a terminal has it,
    /// on the next turn, after the pane a card opened is drawn. The sheet's
    /// field still holds the keyboard while the sheet fades out, so, unlike
    /// after a rename, a text field does not get to keep it
    /// (`keeper: .terminal`).
    private static func returnKeyboard(in window: ProjectWindowState, stores: AllProjectsStores) {
        KeyboardHandoff.returnToFocusedPane(
            in: window.id,
            session: stores.session,
            registry: stores.registry,
            keeper: .terminal,
            timing: .nextTurn
        )
    }
}
