// MenuShortcut.swift
// Weir — which shortcut an item in one of Weir's own menus (right-click, a header's ⋯, a row's) shows.

import Foundation

/// A command one of Weir's menus offers that a keyboard shortcut also
/// performs: the menu item is another way in to the same command, such as
/// the decision bar's ⋯ "Review Unviewed" for the menu bar's.
///
/// The rule every such menu follows: an item whose command a shortcut
/// performs shows that shortcut, read from the user's settings, so a
/// rebinding shows up here the moment it shows up in the menu bar. An item
/// no shortcut performs shows none, and so has no case here.
///
/// Apple's HIG lets a context menu leave shortcuts out, since the menu bar
/// already lists them. We show them anyway: most of Weir's shortcuts
/// (⌘D to split, ⌘⇧↩ to zoom a pane) belong to commands people reach for
/// in the pane they are working in, and the menu they open there is the
/// one place they would otherwise never meet the key.
///
/// A menu only shows the key; the menu bar stays the one place a shortcut
/// is live, so a keystroke made with no menu open does what it always did.
///
/// Each case also names the item (`title`, `icon`), so every menu that
/// offers the command words and draws it alike.
enum MenuCommand: CaseIterable {
    case copy
    case paste
    case selectAll
    case find
    case splitRight
    case splitDown
    case togglePaneZoom
    case closePane
    /// ⌘W as an item that is not a pane's: the review tab's own menu, whose
    /// ⌘W closes the review while it is in front.
    case close
    case renameTab
    case closeTab
    case newWorktree
    case keyboardShortcuts
    case reviewChanges

    var shortcutSource: MenuShortcutSource {
        switch self {
        case .copy: .standardEdit(StandardEditShortcut.copy)
        case .paste: .standardEdit(StandardEditShortcut.paste)
        case .selectAll: .standardEdit(StandardEditShortcut.selectAll)
        case .find: .action(.find)
        case .splitRight: .action(.splitRight)
        case .splitDown: .action(.splitDown)
        case .togglePaneZoom: .action(.toggleSplitZoom)
        case .closePane: .action(.closeSurface)
        case .close: .action(.closeSurface)
        case .renameTab: .action(.renameTab)
        case .closeTab: .action(.closeTab)
        case .newWorktree: .action(.newWorktree)
        case .keyboardShortcuts: .action(.keyboardShortcuts)
        case .reviewChanges: .action(.review)
        }
    }

    /// The item's name. Two menus word theirs from what they act on instead:
    /// a pane's zoom says what pressing it does now (`PaneZoomAction`), and
    /// the sidebar's New Worktree names its project.
    ///
    /// A pane's menus say "Close Pane", which ⌘W does to the focused pane,
    /// where the menu bar says "Close" for every window ⌘W may close. A
    /// tab's menu says "Rename…", the tab being the thing it was opened on.
    var title: LocalizedStringResource {
        switch self {
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .find: WeirShortcutAction.find.localizedTitle
        case .splitRight: WeirShortcutAction.splitRight.localizedTitle
        case .splitDown: WeirShortcutAction.splitDown.localizedTitle
        case .togglePaneZoom: WeirShortcutAction.toggleSplitZoom.localizedTitle
        case .closePane: "Close Pane"
        case .close: WeirShortcutAction.closeSurface.localizedTitle
        case .renameTab: "Rename…"
        case .closeTab: WeirShortcutAction.closeTab.localizedTitle
        case .newWorktree: WeirShortcutAction.newWorktree.localizedTitle
        case .keyboardShortcuts: WeirShortcutAction.keyboardShortcuts.localizedTitle
        // The decision bar's words for the review on the unviewed turns.
        case .reviewChanges: LocalizedStringResource(
                "Review Unviewed",
                comment: "Changes panel and decision bar: opens the unviewed turns in review"
            )
        }
    }

    /// The item's SF Symbol, or nil for an item drawn without one: the Edit
    /// commands, as the Edit menu draws them, and the decision bar's words.
    var icon: String? {
        switch self {
        case .copy, .paste, .selectAll, .find: nil
        case .splitRight: WeirShortcutAction.splitRight.iconName
        case .splitDown: WeirShortcutAction.splitDown.iconName
        case .togglePaneZoom: WeirShortcutAction.toggleSplitZoom.iconName
        case .closePane: WeirShortcutAction.closeSurface.iconName
        // The review tab's mark for closing, as its own ✕ draws it.
        case .close: "xmark"
        case .renameTab: WeirShortcutAction.renameTab.iconName
        case .closeTab: WeirShortcutAction.closeTab.iconName
        case .newWorktree: WeirShortcutAction.newWorktree.iconName
        case .keyboardShortcuts: WeirShortcutAction.keyboardShortcuts.iconName
        case .reviewChanges: nil
        }
    }

    /// The shortcut the item shows, with the user's overrides applied.
    func shortcut(in keyboard: KeyboardSettings) -> StoredShortcut? {
        shortcut { keyboard.shortcut(for: $0) }
    }

    /// The shortcut the item shows, with `lookup` answering for Weir's
    /// rebindable actions. A menu with no settings to read passes a lookup
    /// that answers nil, and still shows the Edit menu's fixed keys.
    func shortcut(resolving lookup: (WeirShortcutAction) -> StoredShortcut?) -> StoredShortcut? {
        switch shortcutSource {
        case let .action(action): lookup(action)
        case let .standardEdit(shortcut): shortcut
        }
    }
}

/// Where a menu item's shortcut comes from.
enum MenuShortcutSource: Equatable {
    /// One of Weir's rebindable actions, read from settings.
    case action(WeirShortcutAction)
    /// A key the standard Edit menu owns.
    case standardEdit(StoredShortcut)
}

/// The standard Edit menu's keys for the commands Weir's menus repeat.
/// SwiftUI's default Edit menu owns them and sends them down the responder
/// chain, and Settings cannot rebind them (`WeirShortcutAction` leaves
/// Copy and Paste out for that reason), so they are fixed, and this is the
/// one place a menu reads them from.
enum StandardEditShortcut {
    static let copy = StoredShortcut(key: "c", modifiers: [.command])
    static let paste = StoredShortcut(key: "v", modifiers: [.command])
    static let selectAll = StoredShortcut(key: "a", modifiers: [.command])
}
