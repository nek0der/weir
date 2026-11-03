// SidebarKeyRoute.swift
// Weir — which keys the sidebar takes ahead of the menus: Move Project Up and Down, and ⌘⌫, while it has the keyboard.

import Foundation

/// The keys the sidebar takes at the window, ahead of the menu bar
/// (`WindowKeyDownMonitor`): Move Project Up and Down (⌥⌘↑ ⌥⌘↓ unless the
/// person bound others) move a project's header, but only while the
/// sidebar has the keyboard (⌥⌘0). By default the pane menu holds the
/// same keys for moving between panes, and disables them when there is no
/// pane that way, so a menu item could not hand them on; the monitor sees
/// them first. Anywhere else, and for any other keys, they go on to the
/// menus, so a split tab's panes still move. ⌘⌫ clears the fold line the
/// keys are on (`SidebarKeyboardCursor`); held with ⌘, it never reaches the
/// sidebar's own key handling, so it is taken here too.
enum SidebarKeyRoute {
    /// The header to move, by how many places (−1 up, +1 down).
    enum Route: Equatable {
        /// The key goes on to the window and the menus.
        case pass
        case moveProject(by: Int)
        /// ⌘⌫: the fold line the keys are on is cleared, if it can be.
        case clearFold
    }

    /// The route for the keys pressed (`pressed`, `nil` for a key with no
    /// shortcut of its own, such as a lone modifier) against the keys Move
    /// Project Up and Down have now (`moveUp`, `moveDown`; `nil` for one
    /// the person unassigned), and the key that clears a fold line (`clear`;
    /// `nil` while an action has it). `hasKeyboard` is whether the sidebar
    /// holds the keyboard; `isComposing`, whether an input method is
    /// composing text, whose keys are the input method's.
    static func route(
        pressed: StoredShortcut?,
        moveUp: StoredShortcut?,
        moveDown: StoredShortcut?,
        clear: StoredShortcut? = nil,
        hasKeyboard: Bool,
        isComposing: Bool
    ) -> Route {
        guard hasKeyboard, !isComposing, let pressed else { return .pass }
        if pressed == moveUp {
            return .moveProject(by: -1)
        }
        if pressed == moveDown {
            return .moveProject(by: 1)
        }
        return pressed == clear ? .clearFold : .pass
    }

    /// The route for `pressed` with the keys `keyboard` gives the two
    /// actions.
    static func route(pressed: StoredShortcut?, keyboard: KeyboardSettings, hasKeyboard: Bool, isComposing: Bool) -> Route {
        route(
            pressed: pressed,
            moveUp: keyboard.shortcut(for: .moveProjectUp),
            moveDown: keyboard.shortcut(for: .moveProjectDown),
            clear: SidebarKeyboardCursor.isClearKeyFree(in: keyboard) ? SidebarKeyboardCursor.clearKey : nil,
            hasKeyboard: hasKeyboard,
            isComposing: isComposing
        )
    }
}
