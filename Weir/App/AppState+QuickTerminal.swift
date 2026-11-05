// AppState+QuickTerminal.swift
// Weir — builds the quick terminal and its global hotkey for `AppState`.

import Foundation

extension AppState {
    /// Environment the quick terminal's shell gets on top of the process
    /// environment. Deliberately not the pane environment: without the
    /// agent shims on `PATH` and the `ZDOTDIR` redirect that keeps them
    /// there, `claude` and `codex` run unwrapped and write no hook records,
    /// so the panel's agents get no badge, turn, or attention item. Only the
    /// quit gate reads the panel's foreground job (`hasAgentAQuitWouldEnd`).
    /// libghostty's own shell integration still runs.
    static let quickTerminalEnvironment = ["WEIR_QUICK_TERMINAL": "1"]

    static func makeQuickTerminal(
        ghosttyApp: GhosttyApp?,
        settingsStore: SettingsStore,
        reduceTransparencyResolver: ReduceTransparencyResolver,
        clipboard: ClipboardConfirmationCoordinator,
        secureInputManager: SecureInputManager
    ) -> QuickTerminalController {
        QuickTerminalController(
            settingsStore: settingsStore,
            reduceTransparencyResolver: reduceTransparencyResolver,
            clipboard: clipboard,
            secureInputManager: secureInputManager,
            surfaceFactory: { [weak ghosttyApp] in
                guard let ghosttyApp else { return nil }
                let view = PaneHostRepresentable.makeSurfaceView(
                    ghosttyApp: ghosttyApp,
                    environment: quickTerminalEnvironment
                )
                view.initialWorkingDirectory = NSHomeDirectory()
                return view
            }
        )
    }

    static func makeQuickTerminalHotKeyCenter(
        isTerminalAvailable: Bool,
        settingsStore: SettingsStore,
        quickTerminal: QuickTerminalController
    ) -> QuickTerminalHotKeyCenter {
        // Without libghostty the panel could only show an empty frame, so
        // the hotkey is never registered.
        QuickTerminalHotKeyCenter(
            isTerminalAvailable: isTerminalAvailable,
            hotKeyProvider: { [weak settingsStore] in
                settingsStore?.settings.quickTerminal.hotKey
            },
            menuShortcutsProvider: { [weak settingsStore] in
                settingsStore?.settings.keyboard
            },
            onPress: { [weak quickTerminal] in
                quickTerminal?.toggle()
            }
        )
    }

    /// Every live terminal surface: the panes plus the quick terminal's.
    /// Config and color-scheme passes use it so a hidden panel does not
    /// come back showing a stale configuration, and the quit gate so an
    /// agent at work in the panel is asked about (`hasAgentAQuitWouldEnd`).
    var allSurfaceViews: [SurfaceView] {
        Self.allSurfaceViews(registry: registry, quickTerminal: quickTerminal)
    }

    /// Returns every live surface: the views `registry` holds for panes, and
    /// the quick terminal's while its shell runs.
    static func allSurfaceViews(
        registry: SurfaceRegistry,
        quickTerminal: QuickTerminalController
    ) -> [SurfaceView] {
        registry.allViews + (quickTerminal.surfaceView.map { [$0] } ?? [])
    }
}
