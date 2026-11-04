// PaneCommands.swift
// Weir — the "Pane" menu (splits, zoom, focus, tab cycling). Split
// out of `WeirApp` so the app file stays under the file-length limit;
// the menu is self-contained and only needs `AppState`.

import SwiftUI

struct PaneCommands: Commands {
    let state: AppState

    /// The window the menu acts in: its active tab is the one split,
    /// zoomed, or stepped through. `nil` while no main window is key
    /// (Settings in front), where every item is off.
    private var target: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// This is the window whose panes the split, zoom, and focus items act
    /// on. It is `nil` while the window's review stands where the terminal
    /// was, as those items would change its panes out of sight
    /// (`ProjectWindowState.arePanesHidden`). The palette's rows ask the
    /// same.
    private var paneTarget: ProjectWindowState? {
        target.flatMap { $0.arePanesHidden ? nil : $0 }
    }

    /// This is the active tab of `paneTarget`, whose zoom state gives the
    /// zoom item its label. It is `nil` while no main window is key or the
    /// review hides the panes.
    private var paneTab: Tab? {
        paneTarget.flatMap { state.session.activeTab(in: $0.id) }
    }

    /// ⇧⌘[ ⇧⌘]: the review tab is one of the tabs they step through.
    private func cycleTab(forward: Bool) {
        guard let window = target else { return }
        ReviewTabActions.cycleTab(
            forward: forward,
            window: window,
            session: state.session,
            registry: state.registry,
            paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry)
        )
    }

    var body: some Commands {
        CommandMenu("Pane") {
            // Splits, zoom, and focus act on the main window's active tab.
            // The quick terminal is a single pane, so the whole menu steps
            // aside while it has the keyboard.
            MainWindowCommandItems(state.quickTerminal) {
                // Each item is on when its palette row is (`ShortcutAvailability`),
                // and the split, zoom, and focus items are off while the
                // review hides the panes.
                let menu = state.menuAvailability
                ShortcutMenuButton(.splitRight, in: state.settingsStore) {
                    split(.horizontal)
                }
                .disabled(!menu.isEnabled(.splitRight))
                ShortcutMenuButton(.splitDown, in: state.settingsStore) {
                    split(.vertical)
                }
                .disabled(!menu.isEnabled(.splitDown))
                ShortcutMenuButton(.equalizeSplits, in: state.settingsStore) {
                    guard let paneTarget else { return }
                    PaneActions.equalizeSplits(state.session, in: paneTarget.id)
                }
                .disabled(!menu.isEnabled(.equalizeSplits))
                // ⌘⇧↩ is the conventional "maximize pane" chord.
                // ⌘⇧Z would steal the system Redo shortcut. Named for what
                // it does now, as the header's item is.
                ShortcutMenuButton(
                    .toggleSplitZoom,
                    label: PaneHeaderRules.zoomAction(isZoomed: paneTab?.zoomedLeafID != nil).menuLabel,
                    in: state.settingsStore
                ) {
                    guard let paneTarget else { return }
                    PaneActions.toggleZoom(state.session, in: paneTarget.id)
                }
                .disabled(!menu.isEnabled(.toggleSplitZoom))

                // ⌥⌘+arrow focuses the neighbor. Moving a pane to another
                // slot is ⌥⌘ + drag, not a directional shortcut —
                // see `PaneSwapDropOverlay` for the drop side.
                Divider()
                paneDirectionButton(.focusPaneLeft, .left, menu: menu)
                paneDirectionButton(.focusPaneRight, .right, menu: menu)
                paneDirectionButton(.focusPaneUp, .up, menu: menu)
                paneDirectionButton(.focusPaneDown, .down, menu: menu)

                Divider()
                ShortcutMenuButton(.nextTab, in: state.settingsStore) {
                    cycleTab(forward: true)
                }
                .disabled(!menu.isEnabled(.nextTab))
                ShortcutMenuButton(.previousTab, in: state.settingsStore) {
                    cycleTab(forward: false)
                }
                .disabled(!menu.isEnabled(.previousTab))
            }
        }
    }

    /// One Focus menu item for `direction`, named and drawn by its shortcut
    /// action; the item is off when no neighbor is reachable that way
    /// (`PaneActions.adjacentLeaf`, through `ShortcutAvailability`), so an
    /// edge pane grays out the directions it can't reach rather than
    /// offering a silent no-op.
    private func paneDirectionButton(
        _ action: WeirShortcutAction,
        _ direction: SpatialDirection,
        menu: MenuAvailability
    ) -> some View {
        ShortcutMenuButton(action, in: state.settingsStore) {
            focus(direction)
        }
        .disabled(!menu.isEnabled(action))
    }

    private func focus(_ direction: SpatialDirection) {
        guard let paneTarget else { return }
        PaneActions.focusPane(state.session, registry: state.registry, direction: direction, in: paneTarget.id)
    }

    private func split(_ direction: SplitDirection) {
        guard let paneTarget else { return }
        PaneActions.split(
            state.session,
            direction: direction,
            registry: state.registry,
            minPaneSize: state.settingsStore.settings.terminal.paneMinimumSize,
            toastCenter: state.toastCenter,
            in: paneTarget.id
        )
    }
}
