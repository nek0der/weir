// SettingsAwareFindCommands.swift
// Weir — Routes Find to the focused Settings, Review, or terminal surface.

import SwiftUI

struct SettingsAwareFindCommands: Commands {
    let state: AppState
    @FocusedValue(\.settingsSearchFocusAction) private var settingsSearchFocusAction

    /// The window Find acts in: its review, or its focused pane. `nil`
    /// while no main window is key; Settings then has Find for its own
    /// search field, and the rest is off.
    private var window: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// Whether Find goes to the window's review tab: while that is the tab
    /// in front.
    private var isReviewShown: Bool {
        window?.review?.isShown == true
    }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            let performFind: (WeirShortcutAction) -> Void = { action in
                guard let window else { return }
                ReviewPresentationCommand.find(
                    action,
                    session: state.session,
                    isReviewShown: isReviewShown,
                    registry: state.registry,
                    commands: state.windowRegistry,
                    window: window.id
                )
            }
            let activeTab = window.flatMap { state.session.activeTab(in: $0.id) }
            let focusedPaneID = activeTab?.splitTree.effectiveFocusedLeafID
            let hasActiveSearch = focusedPaneID.map {
                state.session.paneSearchStates[$0] != nil
            } ?? false

            // The quick terminal has no find overlay; routing Find to the
            // main window would search a pane the user cannot see.
            MainWindowCommandItems(state.quickTerminal) {
                Section {
                    ShortcutMenuButton(.find, in: state.settingsStore) {
                        if let settingsSearchFocusAction {
                            settingsSearchFocusAction()
                        } else {
                            performFind(.find)
                        }
                    }
                    ShortcutMenuButton(.findNext, in: state.settingsStore) {
                        performFind(.findNext)
                    }
                    .disabled(!hasActiveSearch && !isReviewShown)
                    ShortcutMenuButton(.findPrevious, in: state.settingsStore) {
                        performFind(.findPrevious)
                    }
                    .disabled(!hasActiveSearch && !isReviewShown)
                }
                .disabled(settingsSearchFocusAction == nil && activeTab == nil && !isReviewShown)
            }
        }
    }
}
