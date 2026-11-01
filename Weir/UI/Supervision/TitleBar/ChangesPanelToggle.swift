// ChangesPanelToggle.swift
// Weir — the title bar's button for the changes panel, counting the session's unviewed turns.

import SwiftUI

/// Opens and closes the changes panel, counting the session's turns waiting
/// to be read across its agents (none at zero). The count stays in sight
/// with the panel closed, and with the left rail hidden.
struct ChangesPanelToggle: View {
    let state: AppState
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale

    var body: some View {
        // Read once, for the badge and the hint both.
        let facts = ChangesPanelActions.toggleFacts(window: window, stores: state.changesPanelStores)
        let unviewed = facts.unviewed
        let shortcut = settings.settings.keyboard.shortcut(for: .toggleChangesPanel)?.displayString
        // A diff, which is what the panel reads, rather than the menu's
        // sidebar symbol, which says only where it goes.
        IconControlButton(
            placement: .below,
            systemImage: "plus.forwardslash.minus",
            name: "Changes",
            shortcut: shortcut,
            isSelected: window.selection.isChangesPanelPresented,
            badge: .counting(unviewed),
            hint: ChangesPanelText.toggleHint(shortcut: shortcut, unviewed: unviewed, agents: facts.agents, locale: locale),
            value: unviewed > 0 ? ConversationText.unviewedTurns(unviewed, locale: locale) : nil
        ) {
            ChangesPanelActions.toggle(window, session: state.session)
        }
        .heldKeyCap(.toggleChangesPanel)
        // The count needs the worktree's top level, closed panel or not.
        .task(id: ChangesPanelActions.folder(window: window, stores: state.changesPanelStores)) {
            await ChangesPanelActions.resolveRoot(window: window, stores: state.changesPanelStores)
        }
    }
}
