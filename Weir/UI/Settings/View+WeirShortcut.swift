// View+WeirShortcut.swift
// Weir — SwiftUI bridge that reads a `WeirShortcutAction`'s
// effective shortcut from `SettingsStore` and applies it via
// `.keyboardShortcut(...)`. This is the menu-bar half of Pattern A:
// menu items declare an action, the store decides the trigger,
// libghostty (via `GhosttyConfigBridge`) sees the same trigger in
// its keybind table.
//
// When the user rebinds an action in Settings → Keyboard, every
// menu Button using `.weirShortcut(.thatAction, …)` re-evaluates
// because `SettingsStore` is `@Observable`. Result: the menu shows
// the new key glyph and intercepts the new keystroke without any
// per-menu code change.

import SwiftUI

extension View {

    /// Bind this view's `.keyboardShortcut` to whatever the user has
    /// configured for `action`. Falls through to the action's
    /// built-in default when no override is set. Every named key and
    /// every single character has a `KeyEquivalent`; the shortcut is
    /// dropped only for a stored key that is neither, which only a
    /// hand-edited settings file can produce.
    func weirShortcut(
        _ action: WeirShortcutAction,
        in store: SettingsStore
    ) -> some View {
        applyingShortcut(store.settings.keyboard.shortcut(for: action))
    }

    /// Show `shortcut` beside an item of a `.contextMenu`, or no key for
    /// `nil`. See `MenuCommand` for which items show one.
    ///
    /// Only inside `.contextMenu`. SwiftUI builds that menu when it opens
    /// and drops it when it closes, so the item answers its key only while
    /// the menu is open and the keystroke otherwise reaches the menu bar.
    /// Inside a `Menu`, SwiftUI keeps the shortcut live in the window after
    /// the first open, ahead of the menu bar; `PopUpMenuButton` is for those.
    func contextMenuShortcut(_ shortcut: StoredShortcut?) -> some View {
        applyingShortcut(shortcut)
    }

    fileprivate func applyingShortcut(_ shortcut: StoredShortcut?) -> some View {
        Group {
            if let shortcut, let key = shortcut.swiftUIKeyEquivalent {
                self.keyboardShortcut(key, modifiers: shortcut.modifiers.swiftUIEventModifiers)
            } else {
                self
            }
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// A menu item's name and symbol, as one command's definition gives
    /// them (`MenuItemLabel`).
    init(_ label: MenuItemLabel) {
        self.init {
            Text(label.title)
        } icon: {
            Image(systemName: label.symbol)
        }
    }
}

extension Label where Title == Text, Icon == Image? {
    /// An item of one of Weir's own menus, named and drawn as every menu
    /// that offers the command does (`MenuCommand`); without a symbol for
    /// a command drawn without one.
    init(_ command: MenuCommand) {
        self.init {
            Text(command.title)
        } icon: {
            command.icon.map { Image(systemName: $0) }
        }
    }
}

/// A menu bar item for one of Weir's rebindable actions: its name, its
/// symbol, and its key all come from the action, so the menu names and
/// draws a command as the palette and Settings › Keyboard do. An item whose
/// name says what it does now (Zoom Pane or Unzoom Pane) passes that
/// `label`, from the one place that defines it.
struct ShortcutMenuButton: View {
    let action: WeirShortcutAction
    let label: MenuItemLabel
    let settings: SettingsStore
    let perform: () -> Void

    init(
        _ action: WeirShortcutAction,
        label: MenuItemLabel? = nil,
        in settings: SettingsStore,
        perform: @escaping () -> Void
    ) {
        self.action = action
        self.label = label ?? action.menuLabel
        self.settings = settings
        self.perform = perform
    }

    /// The key the item answers and shows: the person's binding for the
    /// action, as `weirShortcut` reads it.
    var shortcut: StoredShortcut? {
        settings.settings.keyboard.shortcut(for: action)
    }

    var body: some View {
        Button(action: perform) {
            Label(label)
        }
        // The name the item shows now, Unzoom Pane while zoomed included.
        .accessibilityLabel(Text(label.title))
        .applyingShortcut(shortcut)
    }
}
