// SettingsCommand.swift
// Weir — how every place that opens Settings names it, draws it, and keys it.

import Foundation

/// Opening the Settings window, as the places that offer it show it.
///
/// Each place keeps the name its role gives it: the app menu's and the
/// menu bar item's "Settings…" (a menu item that opens a window), the
/// palette's verb "Open Settings", and the rail's icon-only "Settings".
/// Each name and the symbol are said once here, and the key once in
/// `StandardMenuShortcut`, so no place words or draws the command its own
/// way. `SettingsOpener` opens it.
enum SettingsCommand {
    /// The SF Symbol for Settings: the gear Settings → General and Project
    /// Settings… already show, so every place that opens Settings draws the
    /// same one.
    static let symbol = "gearshape"

    /// The item that opens Settings in a menu: the app menu, the menu bar
    /// item's ⋯, and the keyboard shortcut list's row for ⌘,.
    static let menuLabel = MenuItemLabel(title: LocalizedStringResource("Settings…"), symbol: symbol)

    /// The command as a verb: the palette's row, the alert that settings
    /// are not being saved, and the screen a libghostty failure leaves.
    static let openTitle = LocalizedStringResource("Open Settings")

    /// The rail's icon, named by its hover chip and VoiceOver label.
    static let railTitle = LocalizedStringResource("Settings")
}

/// The keys of the app menu items macOS gives every app, for the places
/// Weir uses them again: the app menu's own item, the menu bar item's ⋯ and
/// its key handler, a terminal's key handling, the libghostty failure
/// screen's Quit Weir, the rail's tooltip and key cap, the keyboard shortcut
/// list, and the generated libghostty config's header. Settings cannot
/// rebind them (`ReservedShortcuts`).
enum StandardMenuShortcut {
    /// Settings…, which macOS keeps on ⌘, in every app.
    static let settings = StoredShortcut(key: ",", modifiers: [.command])

    /// Quit, which macOS keeps on ⌘Q in every app.
    static let quit = StoredShortcut(key: "q", modifiers: [.command])
}
