// AppState+ShortcutAvailability.swift
// Weir — which of a window's actions can run now, and the palette it opens, built in one place for every caller.

import Foundation

extension AppState {
    /// What can run now in `window`: the one answer its menu bar items,
    /// its palette's rows, and its empty session's hints read.
    func shortcutAvailability(in window: ProjectWindowState) -> ShortcutAvailability {
        ShortcutAvailability(window: window, session: session, registry: registry, attention: attention)
    }

    /// The menu bar's answer, read in the key main window
    /// (`WindowRegistry.commandTarget`); every item that acts in a window is
    /// off while none is key.
    var menuAvailability: MenuAvailability {
        MenuAvailability(availability: windowRegistry.commandTarget.map(shortcutAvailability(in:)))
    }

    /// Everything the palette lists of `window`: its rows' enabled states,
    /// the turn its restore entry goes back to, the agents its "+" offers,
    /// and its toast's Undo. Read as the palette opens, and as the channel
    /// lists or runs a row.
    func paletteFacts(in window: ProjectWindowState) -> SupervisionPaletteFacts {
        SupervisionPaletteFacts(
            window: window,
            session: session,
            restoreTurnNumber: RestoreActions.paletteTarget(window: window, state: self)?.displayNumber,
            installedAgents: installedAgents,
            toasts: toastCenter
        )
    }

    /// The palette's rows for `window`, as it would list them now.
    func paletteItems(in window: ProjectWindowState) -> [CommandPaletteItem] {
        CommandPaletteCatalog.buildItems(
            session: session,
            settings: settingsStore,
            attention: attention,
            registry: registry,
            supervision: paletteFacts(in: window),
            window: window.id,
            locale: settingsStore.appLocale
        )
    }

    /// Opens the palette in `window` on `query` (">" for the commands, ""
    /// for Quick Open): the menu bar's items, the title bar's field, and the
    /// empty session's hint all open it here.
    func openPalette(in window: ProjectWindowState, query: String) {
        CommandPaletteActions.openCommandPalette(
            session,
            in: window.id,
            settings: settingsStore,
            frecencyStore: frecencyStore,
            attention: attention,
            registry: registry,
            initialQuery: query,
            supervision: paletteFacts(in: window)
        )
    }
}

/// The menu bar's view of `ShortcutAvailability`: off for every item while
/// no main window is key.
@MainActor
struct MenuAvailability {
    /// The key main window's; `nil` while none is.
    let availability: ShortcutAvailability?

    func isEnabled(_ action: WeirShortcutAction) -> Bool {
        availability?.isEnabled(action, on: .menu) ?? false
    }
}
