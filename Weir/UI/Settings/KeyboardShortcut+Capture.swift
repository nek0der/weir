// KeyboardShortcut+Capture.swift
// Weir — the AppKit-touching half of the shortcut model: `NSEvent`
// translation, which only the UI's key handlers read. The layout lookup
// it shares with the global hotkey is in Core
// (`KeyboardShortcut+Layout.swift`).

import AppKit
import WeirDomain

extension StoredShortcut {

    /// Capture a `StoredShortcut` from a `keyDown` event. Returns
    /// `nil` if the event has no usable key (modifier-only press,
    /// dead key, etc.).
    @MainActor
    static func capture(from event: NSEvent) -> StoredShortcut? {
        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard let key = ghosttyKey(from: event) else { return nil }
        return StoredShortcut(key: key, modifiers: modifiers)
    }

    /// `NSEvent.keyCode` → stored key string. Named keys come from
    /// `NamedKey`; everything else translates the hardware
    /// keyCode through the active layout with **all** modifiers
    /// stripped. `charactersIgnoringModifiers` would otherwise still
    /// honor Shift, so a `⇧]` press would capture as `}` and the
    /// stored binding could never match the literal `]` libghostty
    /// expects in its keybind line.
    @MainActor
    private static func ghosttyKey(from event: NSEvent) -> String? {
        if let named = event.namedKey {
            return named.rawValue
        }
        if let translated = translateKeyCodeIgnoringShift(event.keyCode), !translated.isEmpty {
            return translated.lowercased()
        }
        // Last-ditch fallback: better to round-trip the shifted glyph
        // than to refuse the capture entirely.
        guard let raw = event.charactersIgnoringModifiers?.lowercased(),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Translate `keyCode` through the active input source with zero
    /// modifiers. Uses Carbon's `UCKeyTranslate` because it's the only
    /// AppKit-side API that exposes the "no modifiers" mapping. The
    /// non-shifted character is what we store: `keyCode = 30` on a US
    /// layout returns `"]"` regardless of whether the live event held
    /// Shift, so the user's `⇧]` capture round-trips through
    /// libghostty's keybind file as `shift+]=…` instead of `}`.
    @MainActor
    private static func translateKeyCodeIgnoringShift(_ keyCode: UInt16) -> String? {
        currentLayoutTranslator()?(keyCode)
    }
}

extension NSEvent {
    /// The named key this event is for, or nil for a key that types a
    /// character.
    var namedKey: NamedKey? {
        NamedKey(keyCode: keyCode)
    }
}

extension KeyModifiers {
    /// Reads the four modifiers AppKit's `flags` hold, for a shortcut captured
    /// here and for a key rule the UI reads (`NewSessionKey`). Anything
    /// outside them (caps lock, the function key, …) is dropped: we never
    /// bind to those.
    init(_ flags: NSEvent.ModifierFlags) {
        let pairs: [(flag: NSEvent.ModifierFlags, modifier: KeyModifiers)] = [
            (.command, .command), (.shift, .shift), (.option, .option), (.control, .control)
        ]
        self = pairs.reduce(into: []) { modifiers, pair in
            if flags.contains(pair.flag) {
                modifiers.insert(pair.modifier)
            }
        }
    }
}
