// OpenSettingsCommand.swift
// Weir — menu command that routes ⌘, to the Settings Window scene.

import SwiftUI

/// Wraps the "Settings…" menu button so we can capture
/// `\.openWindow` (only available inside a `View`, not `App`'s
/// body) and route ⌘, to our `Window(id:)` Settings scene through
/// `SettingsOpener`.
struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            SettingsOpener(openWindow).open()
        } label: {
            Label(SettingsCommand.menuLabel)
        }
        // The key is fixed, since macOS keeps ⌘, for Settings in every app,
        // so it is not among the keys a person rebinds.
        .standardMenuShortcut(StandardMenuShortcut.settings)
    }
}
