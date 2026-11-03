// ShortcutValidation.swift
// Weir — why Settings → Keyboard takes or refuses a combination for an action.

import Foundation

/// Outcome of `KeyboardSettings.validate`. The recorder surfaces
/// these to the user as a small warning under the row; `.ok` is the
/// only outcome that commits.
enum ShortcutValidation: Equatable {
    case ok
    /// Another action is already bound to the same trigger.
    case conflict(WeirShortcutAction)
    /// Two actions that share keys (`WeirShortcutAction.sharesKeys`) are
    /// both bound to the trigger, so the message names both.
    case conflictWithPair(WeirShortcutAction, WeirShortcutAction)
    /// The place the action answers in uses the trigger already
    /// (`WeirShortcutAction.keysItsPlaceKeeps`): the sidebar's ⌥← ⌥→.
    case keptBySidebar
    /// Trigger is one Weir reserves (⌘Q, ⇧⏎, ⌘⏎, ⌘1…⌘9, ⌘⌃1…⌘⌃9).
    /// See `ReservedShortcuts`.
    case reserved
    /// Modifier-less binding — would hijack every plain keystroke
    /// of that character and break terminal input. The recorder
    /// requires at least one of ⌘/⌥/⌃/⇧.
    case missingModifier
    /// libghostty cannot read the key in a keybind line
    /// (`StoredShortcut.hasWritableKey`), so the binding would never fire.
    case unwritableKey
    /// ⇧ or ⌥ alone on a key that types (`StoredShortcut.typesText`):
    /// the binding would take that character from every pane.
    case typesText
    /// A menu item macOS and SwiftUI give every app holds the trigger
    /// (`ReservedShortcuts.standardMenuTriggers`), so the binding would
    /// never fire, or would take the keys from Copy or Paste.
    case standardMenuItem
    /// The quick terminal's global hotkey uses the same trigger. Carbon
    /// takes a registered hotkey before the menu bar sees it, so the
    /// menu item would never fire.
    case quickTerminalConflict
}

extension KeyboardSettings {
    /// Why no action may hold `keys`, whatever the other bindings are, or
    /// `nil` when one may. `normalize` asks the same of a stored binding, so
    /// a hand edit cannot keep what the recorder refuses.
    static func refusal(ofKeys keys: StoredShortcut) -> ShortcutValidation? {
        if !keys.hasWritableKey {
            return .unwritableKey
        }
        // Require at least one of ⌘/⌥/⌃/⇧. A bare letter would
        // hijack every plain keypress of that character and make
        // the terminal untypeable.
        if keys.modifiers.isEmpty {
            return .missingModifier
        }
        if ReservedShortcuts.triggers.contains(keys.ghosttyTrigger) {
            return .reserved
        }
        if ReservedShortcuts.standardMenuTriggers.contains(keys.ghosttyTrigger) {
            return .standardMenuItem
        }
        if keys.typesText {
            return .typesText
        }
        return nil
    }
}
