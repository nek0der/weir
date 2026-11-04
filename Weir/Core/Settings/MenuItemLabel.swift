// MenuItemLabel.swift
// Weir — the name and symbol a menu item shows, taken from the one definition of its command.

import Foundation

/// What a menu item shows before its key: its name and its SF Symbol.
///
/// We keep the two together so a menu item takes both from the one place
/// that defines its command: a `WeirShortcutAction` (`menuLabel`), the
/// pane's zoom (`PaneZoomAction`), or the window's items below. The palette
/// and Settings › Keyboard read the same values, so no menu names or draws
/// a command its own way.
struct MenuItemLabel {
    let title: LocalizedStringResource
    let symbol: String
}

extension WeirShortcutAction {
    /// The menu bar item's name and symbol: the ones the palette and
    /// Settings › Keyboard show for the action.
    var menuLabel: MenuItemLabel {
        MenuItemLabel(title: localizedTitle, symbol: iconName)
    }
}

/// The View menu items whose name says what pressing them does now, so it
/// flips with the window, and the pane item no shortcut performs.
extension MenuItemLabel {
    /// View ▸ Show Changes or Hide Changes. The symbol is the action's, as
    /// the palette's Toggle Changes row draws it.
    static func changesPanel(isShown: Bool) -> MenuItemLabel {
        MenuItemLabel(
            title: isShown
                ? LocalizedStringResource("Hide Changes", comment: "View menu: closes the changes panel")
                : LocalizedStringResource("Show Changes", comment: "View menu: opens the changes panel"),
            symbol: WeirShortcutAction.toggleChangesPanel.iconName
        )
    }

    /// View ▸ Hide Icon Bars or Show Icon Bars, and the palette's row.
    static func iconBars(areHidden: Bool) -> MenuItemLabel {
        MenuItemLabel(
            title: areHidden
                ? LocalizedStringResource("Show Icon Bars", comment: "View menu: shows the window's rails again")
                : LocalizedStringResource("Hide Icon Bars", comment: "View menu: hides the window's rails"),
            symbol: "rectangle.lefthalf.inset.filled"
        )
    }

    /// The pane menus' item that moves a pane to a tab of its own: the
    /// header's ⋯, its VoiceOver action, the terminal's right-click menu,
    /// and the palette's row. Whether it is offered is
    /// `Tab.canMovePaneToNewTab`.
    static let movePaneToNewTab = MenuItemLabel(title: "Move Pane to New Tab", symbol: "rectangle.split.2x1")
}
