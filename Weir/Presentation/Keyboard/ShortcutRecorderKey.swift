// ShortcutRecorderKey.swift
// Weir — what a key does while a shortcut recorder is armed, the same in Keyboard and Quick Terminal.

import Foundation
import WeirDomain

/// The meaning of the next key a recorder takes. ⌫ restores the
/// default in both panes, so one key never means two things: for an action
/// that is its built-in shortcut, for the quick terminal's hotkey it is
/// none. Unassigning is the row's menu item, not a key. Only the bare
/// ⎋ and ⌫ mean something of their own: with a modifier held they are
/// keys to record, so ⌘⌫ can become a shortcut.
enum ShortcutRecorderKey: Equatable {
    case cancel
    case restoreDefault
    case record

    static func meaning(of key: NamedKey?, modifiers: KeyModifiers) -> Self {
        guard modifiers.isEmpty else { return .record }
        return switch key {
        case .escape: .cancel
        case .backspace: .restoreDefault
        default: .record
        }
    }
}
