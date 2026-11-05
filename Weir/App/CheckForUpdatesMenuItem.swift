// CheckForUpdatesMenuItem.swift
// Weir — the app menu's Check for Updates item.

import SwiftUI

/// SwiftUI menu item suitable for placement in
/// `CommandGroup(after: .appInfo)`. It starts a check through
/// `UpdaterStack.checkForUpdates()`, as Settings and Retry do; the button
/// disables itself on `UpdateStateModel.disablesCheckForUpdates`, which
/// keeps it on while Sparkle can answer it.
///
/// We don't gate on Sparkle's `canCheckForUpdates`, which stays false
/// while a session is open, including one that only shows its result; a
/// check asked for then waits for that session to end.
struct CheckForUpdatesMenuItem: View {
    let updaterStack: UpdaterStack

    var body: some View {
        Button("Check for Updates…") {
            updaterStack.checkForUpdates()
        }
        // The state model isn't injected into the CommandGroup
        // environment, so we observe it directly via Bindable rather
        // than `@Environment`. The closure-style read keeps SwiftUI's
        // dependency tracking honest.
        .disabled(updaterStack.stateModel.disablesCheckForUpdates)
    }
}
