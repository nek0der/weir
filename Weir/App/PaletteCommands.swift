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
                // Each item is on when its palette row is (`ShortcutAvailability`),
                // except Command Palette and Quick Open, whose rows are off in
                // the palette they open.
                let menu = state.menuAvailability
                ShortcutMenuButton(.commandPalette, in: state.settingsStore) {
                    guard let window else { return }
                    state.openPalette(in: window, query: ">")
                }
                .disabled(!menu.isEnabled(.commandPalette))

                ShortcutMenuButton(.quickOpen, in: state.settingsStore) {
                    guard let window else { return }
                    state.openPalette(in: window, query: "")
                }
                .disabled(!menu.isEnabled(.quickOpen))

                ShortcutMenuButton(.notificationHistory, in: state.settingsStore) {
                    guard let window else { return }
                    toggleNotificationHistory(window.notificationHistory, session: state.session)
                }
                .disabled(!menu.isEnabled(.notificationHistory))

                ReviewChangesMenuItem(state: state, window: window?.id)
                ReviewLatestTurnMenuItem(state: state, window: window?.id)
            }
        }
    }
}
