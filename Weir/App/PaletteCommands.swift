// PaletteCommands.swift
// Weir — the View menu's palette, notification history, and review items.

import SwiftUI

/// The View menu's group after the toolbar items: Command Palette, Quick
/// Open, Notification History, and the two review items. The palette opens
/// in the key main window (`WindowRegistry.commandTarget`), and its items
/// are off while none is key.
struct PaletteCommands: Commands {
    let state: AppState

    /// The window the palette opens in: the key main window. `nil` with
    /// Settings or another window in front, where every item is off rather
    /// than opening in a window behind it.
    private var window: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            MainWindowCommandItems(state.quickTerminal) {
                ShortcutMenuButton(.commandPalette, in: state.settingsStore) {
                    openPalette(initialQuery: ">")
                }
                .disabled(window == nil)

                ShortcutMenuButton(.quickOpen, in: state.settingsStore) {
                    openPalette(initialQuery: "")
                }
                .disabled(window == nil)

                ShortcutMenuButton(.notificationHistory, in: state.settingsStore) {
                    guard let window else { return }
                    toggleNotificationHistory(window.notificationHistory, session: state.session)
                }
                .disabled(window == nil)

                ReviewChangesMenuItem(state: state, window: window?.id)
                ReviewLatestTurnMenuItem(state: state, window: window?.id)
            }
        }
    }

    private func openPalette(initialQuery: String) {
        guard let window else { return }
        CommandPaletteActions.openCommandPalette(
            state.session,
            in: window.id,
            settings: state.settingsStore,
            frecencyStore: state.frecencyStore,
            attention: state.attention,
            registry: state.registry,
            initialQuery: initialQuery,
            supervision: SupervisionPaletteFacts(
                window: window,
                session: state.session,
                restoreTurnNumber: RestoreActions.paletteTarget(window: window, state: state)?.displayNumber,
                installedAgents: state.installedAgents,
                toasts: state.toastCenter
            )
        )
    }
}
