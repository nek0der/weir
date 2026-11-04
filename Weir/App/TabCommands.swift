// TabCommands.swift
// Weir — the File and View menus' tab, pane-close, and sidebar items.

import SwiftUI

/// New Tab, New Worktree…, Create Worktree Now, Rename Tab, Reopen Closed
/// Tab, Close (⌘W),
/// Close Tab, and Toggle Sidebar. A `Commands` of its own, out of
/// `WeirApp.body`, so the app file stays readable: each item acts in the
/// main window that has the keyboard, and is off while no main window has
/// it (`WindowRegistry.commandTarget`).
struct TabCommands: Commands {
    let state: AppState

    /// The key main window; `nil` with Settings or another window in front.
    private var target: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// What ⌘W does now: the one item carries the key for every window
    /// (`CloseKeyCommand`). Whether the key main window has something to
    /// close is the answer its palette's Close row reads
    /// (`ShortcutAvailability`).
    private var closeKey: CloseKeyCommand {
        CloseKeyCommand.decide(
            isQuickTerminalKey: state.quickTerminal.isPanelKey,
            target: target,
            canClose: state.menuAvailability.isEnabled(.closeSurface)
        )
    }

    var body: some Commands {
        // ── File menu ──────────────────────────────────────
        // Groups that act on the main window's session are wrapped in
        // `MainWindowCommandItems`, which disables them while the quick
        // terminal has the keyboard.
        CommandGroup(replacing: .newItem) {
            MainWindowCommandItems(state.quickTerminal) {
                // Each item is on when its palette row is (`ShortcutAvailability`).
                let menu = state.menuAvailability
                ShortcutMenuButton(.newTab, in: state.settingsStore) {
                    guard let target else { return }
                    TabActions.newTab(state.session, in: target.id, intent: .person)
                }
                .disabled(!menu.isEnabled(.newTab))
                // New Worktree… (⌘N), the one item that opens the new
                // worktree sheet for the window's project, and ⌥⌘N, which
                // makes one at once with the sheet's last choices.
                // Asked of the window (`WindowCommand`) so its layout can
                // present the sheet even when its always-mounted sidebar is
                // disabled offscreen. Both are disabled when the window shows
                // no project, or one that cannot have a worktree made in it;
                // ⌥⌘N is also off while the window is making one. A
                // supervision window on a scratch tab still shows its
                // project, whose sheet opens.
                ShortcutMenuButton(.newWorktree, in: state.settingsStore) {
                    guard let target else { return }
                    target.commands.send(.newWorktree)
                }
                .disabled(!menu.isEnabled(.newWorktree))
                ShortcutMenuButton(.newWorktreeNow, in: state.settingsStore) {
                    guard let target else { return }
                    target.commands.send(.newWorktreeNow)
                }
                .disabled(!menu.isEnabled(.newWorktreeNow))
                ShortcutMenuButton(.renameTab, in: state.settingsStore) {
                    guard let target else { return }
                    TabActions.renameActiveTab(state.session, in: target.id, commands: state.windowRegistry)
                }
                .disabled(!menu.isEnabled(.renameTab))
                ShortcutMenuButton(.reopenClosedTab, in: state.settingsStore) {
                    guard let target else { return }
                    TabActions.reopenClosedTab(state.session, in: target.id, intent: .person)
                }
                .disabled(!menu.isEnabled(.reopenClosedTab))
            }
        }
        // SwiftUI's own Close and Close All. Our ⌘W item already closes the
        // key window when no supervision window has the keyboard, and the
        // standard pair would stay at the foot of this menu as a second
        // "Close" that has lost its key to ours, with Close All's ⌥⌘W as
        // an alternate over Close Tab's.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(after: .newItem) {
            // ⌘W — closes the focused pane, cascades
            // to the tab when only one pane is left.
            // With no supervision window key it closes the key window
            // (Settings) instead, as the standard Close would. Its label
            // does not change with that: a label that switched between
            // "Close Pane" and "Close" once made SwiftUI hand ⌘W to its own
            // "Close", which then closed the main window with a terminal
            // focused. So the one label is "Close", true of the pane, the
            // review tab, and the key window alike, and SwiftUI's own item
            // is removed above rather than left beside ours.
            // One item, one label, one ⌘W. The shortcut list's name, so the
            // menu and Settings › Keyboard never name ⌘W two ways.
            ShortcutMenuButton(.closeSurface, in: state.settingsStore) {
                switch closeKey {
                case .hideQuickTerminal:
                    state.quickTerminal.hide()
                case .closeReview:
                    _ = ReviewTabActions.closeIfInFront(in: target, stores: state.reviewTabStores)
                case .closePaneOrTab:
                    guard let target else { return }
                    PaneActions.closeActivePaneOrTab(
                        state.session,
                        registry: state.registry,
                        agentProjection: state.agentProjection,
                        in: target.id
                    )
                case .closeKeyWindow:
                    // Only a window with a close button: a sheet on a
                    // supervision window is key too, and `performClose`
                    // on it would only sound the alert.
                    if let key = NSApp.keyWindow, key.styleMask.contains(.closable) {
                        key.performClose(nil)
                    }
                case .nothing:
                    break
                }
            }
            // Outside `MainWindowCommandItems`, and enabled for the quick
            // terminal even with no tab in the main window.
            // `.closeSurface` has no libghostty action, so the bridge
            // binds its trigger to `ignore`; a disabled item would leave
            // ⌘W doing nothing in the panel.
            .disabled(!closeKey.isLive)
            // ⌘⌥W → close the entire tab regardless of how many
            // panes it contains (no per-pane cascade).
            MainWindowCommandItems(state.quickTerminal) {
                ShortcutMenuButton(.closeTab, in: state.settingsStore) {
                    guard !ReviewTabActions.closeIfInFront(in: target, stores: state.reviewTabStores), let target else { return }
                    TabActions.closeActiveTab(
                        state.session,
                        registry: state.registry,
                        agentProjection: state.agentProjection,
                        in: target.id
                    )
                }
                .disabled(!state.menuAvailability.isEnabled(.closeTab))
            }
        }
        // ── View menu ─────────────────────────────────────
        CommandGroup(after: .sidebar) {
            MainWindowCommandItems(state.quickTerminal) {
                ShortcutMenuButton(.toggleSidebar, in: state.settingsStore) {
                    guard let target else { return }
                    target.commands.send(.toggleSidebar)
                }
                .disabled(!state.menuAvailability.isEnabled(.toggleSidebar))
            }
        }
    }
}
