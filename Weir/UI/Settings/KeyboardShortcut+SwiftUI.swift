// KeyboardShortcut+SwiftUI.swift
// Weir — the shortcut model in SwiftUI's vocabulary, for the Settings pane
// and the menu bar.

import SwiftUI
import WeirDomain

extension WeirShortcutCategory {
    /// SwiftUI-only `Text` literal (consumed by `Text(_:)` directly).
    /// Kept as `LocalizedStringKey` rather than the broader
    /// `LocalizedStringResource` because category titles are only
    /// ever rendered inside the Settings pane — we never need to
    /// concatenate them or resolve them to a `String`. Surfaces that do
    /// (the cheat sheet, Settings search) use `resourceTitle`, and the
    /// action vocabulary uses `LocalizedStringResource` throughout.
    var sectionTitle: LocalizedStringKey {
        switch self {
        case .file: "File"
        case .view: "View"
        case .navigation: "Navigation"
        case .splits: "Splits"
        case .search: "Find"
        case .terminal: "Terminal"
        case .font: "Font"
        case .help: "Help"
        }
    }
}

extension KeyModifiers {
    /// SwiftUI `EventModifiers` equivalent — used by
    /// `View+weirShortcut` to wire the menu bar shortcut.
    var swiftUIEventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) {
            out.insert(.command)
        }
        if contains(.shift) {
            out.insert(.shift)
        }
        if contains(.option) {
            out.insert(.option)
        }
        if contains(.control) {
            out.insert(.control)
        }
        return out
    }
}

extension StoredShortcut {

    /// Stored key → SwiftUI `KeyEquivalent`. Named keys come from
    /// `NamedKey.keyEquivalent`; single-character keys (letters / digits /
    /// punctuation) wrap as `KeyEquivalent(Character(key))`. Returns
    /// `nil` only for a stored value that is neither, which a hand-edited
    /// settings file can produce.
    var swiftUIKeyEquivalent: KeyEquivalent? {
        if let named = NamedKey(storedName: key) {
            return named.keyEquivalent
        }
        return key.count == 1 ? KeyEquivalent(Character(key)) : nil
    }
}

extension NamedKey {
    /// The key a menu item needs to fire on this key. `KeyEquivalent` has
    /// constants only for the keys it names; for a function key we hand it
    /// the character AppKit itself uses for that key, one of the private-use
    /// characters from `NSF1FunctionKey` (U+F704) upward. SwiftUI passes the
    /// character through to `NSMenuItem.keyEquivalent` unchanged, so the
    /// menu both shows the key and fires on it, and a menu-owned action bound
    /// to a function key works like one bound to a letter.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .return: .return
        case .tab: .tab
        case .space: .space
        case .escape: .escape
        case .backspace: .delete
        case .delete: .deleteForward
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            KeyEquivalent(Character(Self.functionKeyCharacter(number: functionKeyNumber ?? 1)))
        }
    }

    /// AppKit numbers the function-key characters contiguously from F1, so
    /// F*n* is U+F704 + *n* − 1. The tests check each key against AppKit's
    /// constants.
    private static func functionKeyCharacter(number: Int) -> Unicode.Scalar {
        // The sum stays inside the Private Use Area for every key we name,
        // which is never a surrogate, so the initializer cannot fail; the
        // fallback only keeps the accessor total.
        Unicode.Scalar(UInt32(0xF704 + number - 1)) ?? "\u{F704}"
    }
}
