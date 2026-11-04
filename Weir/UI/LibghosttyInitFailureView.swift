// LibghosttyInitFailureView.swift
// Weir — fallback UI rendered when `GhosttyApp.init` throws and
// `AppState.ghosttyApp` ends up nil. The previous shape was a static
// `Text` with no way out: ⌘, didn't render (toolbar lives inside the
// failed layout), no Quit button, no log-revealing affordance. Most
// init failures come from a malformed user-side ghostty config
// (Layer 2 in `GhosttyConfigBridge`), so we give the user ways to
// escape: open Settings, open Console.app, reset `settings.json` to
// defaults, and relaunch. libghostty is set up once a launch, so a fix
// takes effect only on the next one, and the screen says so.

import AppKit
import SwiftUI

struct LibghosttyInitFailureView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 16) {
            Text("Couldn’t Initialize libghostty")
                .font(WeirFont.title)
            Text("libghostty \(GhosttyFFI.version())")
                .font(WeirFont.bodySecondary.monospaced())
                .foregroundStyle(WeirColor.secondaryText)
            // One literal: a `+` made it a runtime String, which Text shows
            // unlocalized.
            Text(
                """
                Most failures come from a malformed ~/.config/ghostty/config. Open Settings, turn off \
                Use Ghostty config file in Integrations, and relaunch Weir. Restore Default Settings \
                relaunches Weir with the default settings.
                """
            )
            .font(WeirFont.body)
            .foregroundStyle(WeirColor.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Open Settings") {
                    openWindow(id: WeirApp.settingsWindowID)
                }
                Button("Show Logs in Console") {
                    revealConsole()
                }
                .help(Text("In Console, search for com.nekoder.weir to see Weir’s logs."))
                Button("Restore Default Settings") {
                    state.settingsStore.restoreDefaultsForRelaunch()
                    AppRelaunch.relaunch()
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text(CommonText.quitApp)
                }
                .keyboardShortcut("q", modifiers: [.command])
                // The one way a change takes effect: libghostty is set up
                // once a launch.
                Button("Relaunch Weir") {
                    AppRelaunch.relaunch()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Launch Console.app. It takes no filter from outside, so the button's
    /// tooltip names the subsystem (`com.nekoder.weir`) to search for.
    private func revealConsole() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(url)
    }
}
