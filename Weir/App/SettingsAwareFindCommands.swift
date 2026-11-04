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
            // Each item is on when its palette row is (`ShortcutAvailability`):
            // while the review is in front, Find and its steps go to the
            // review's own search.
            let menu = state.menuAvailability

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
                    .disabled(!menu.isEnabled(.findNext))
                    ShortcutMenuButton(.findPrevious, in: state.settingsStore) {
                        performFind(.findPrevious)
                    }
                    .disabled(!menu.isEnabled(.findPrevious))
                }
                // The section stays on with Settings in front, whose Find goes
                // to its own search field.
                .disabled(settingsSearchFocusAction == nil && !menu.isEnabled(.find))
            }
        }
    }
}
