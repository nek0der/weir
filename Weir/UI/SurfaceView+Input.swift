// SurfaceView+Input.swift
// Weir — static helpers for translating `NSEvent` into the
// `ghostty_input_key_s` struct libghostty expects. Lives outside
// `SurfaceView.swift` purely to keep that file's line count under
// the SwiftLint cap; logically these belong to the surface view.

import AppKit
import Carbon.HIToolbox
import GhosttyKit

extension SurfaceView {

    /// `NSEvent.modifierFlags` → libghostty's `ghostty_input_mods_e`.
    /// We forward the four primary modifiers, caps lock, and the right-side
    /// device bits. The latter let settings such as
    /// `macos-option-as-alt=left` distinguish the two Option keys.
    static func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) {
            mods |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if flags.contains(.control) {
            mods |= GHOSTTY_MODS_CTRL.rawValue
        }
        if flags.contains(.option) {
            mods |= GHOSTTY_MODS_ALT.rawValue
        }
        if flags.contains(.command) {
            mods |= GHOSTTY_MODS_SUPER.rawValue
        }
        if flags.contains(.capsLock) {
            mods |= GHOSTTY_MODS_CAPS.rawValue
        }
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue
        }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue
        }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue
        }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 {
            mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue
        }
        return ghostty_input_mods_e(mods)
    }

    /// Whether a modifier-only event pressed or released its key, or nil
    /// when the key is not one of the modifiers libghostty encodes.
    ///
    /// AppKit reports both directions as `flagsChanged`, so we read the
    /// direction from the flags the event leaves behind. The generic flag
    /// stays set while the other side's key is held, so where the event
    /// carries device bits we judge by this key's side; an event without
    /// any device bit for the modifier falls back to the generic flag.
    static func modifierKeyAction(
        keyCode: UInt16,
        modifierFlags flags: NSEvent.ModifierFlags
    ) -> ghostty_input_action_e? {
        if Int(keyCode) == kVK_CapsLock {
            return flags.contains(.capsLock) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        }
        guard let key = ModifierKey(keyCode: keyCode) else { return nil }
        guard flags.contains(key.flag) else { return GHOSTTY_ACTION_RELEASE }
        let rawFlags = flags.rawValue
        guard rawFlags & (key.deviceBit | key.otherSideDeviceBit) != 0 else {
            return GHOSTTY_ACTION_PRESS
        }
        return rawFlags & key.deviceBit != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    /// Applies libghostty's text-translation modifier decision to an AppKit
    /// event without changing the raw event later sent to the terminal.
    ///
    /// We preserve AppKit's private modifier bits because dead-key and input
    /// method handling depends on them. Reusing the original object when the
    /// public modifiers are unchanged is also required by some input methods.
    @MainActor
    static func translationEvent(
        from event: NSEvent,
        using translationMods: ghostty_input_mods_e
    ) -> NSEvent {
        guard event.type == .keyDown || event.type == .keyUp else { return event }
        var flags = event.modifierFlags
        let mappings: [(NSEvent.ModifierFlags, ghostty_input_mods_e)] = [
            (.shift, GHOSTTY_MODS_SHIFT),
            (.control, GHOSTTY_MODS_CTRL),
            (.option, GHOSTTY_MODS_ALT),
            (.command, GHOSTTY_MODS_SUPER)
        ]
        for (appKitFlag, ghosttyFlag) in mappings {
            if translationMods.rawValue & ghosttyFlag.rawValue != 0 {
                flags.insert(appKitFlag)
            } else {
                flags.remove(appKitFlag)
            }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    @MainActor
    static func translationEvent(
        from event: NSEvent,
        surface: ghostty_surface_t
    ) -> NSEvent {
        let mods = GhosttyFFI.keyTranslationMods(
            for: surface,
            original: translateMods(event.modifierFlags)
        )
        return translationEvent(from: event, using: mods)
    }

    /// Build a `ghostty_input_key_s` from an NSEvent. Shared scaffold
    /// for the three call sites that hand events to libghostty
    /// (`performKeyEquivalent` fast-path, ctrl-only keyDown bypass,
    /// `forward`). Text is set separately because each site has its
    /// own opinion about shift-folding.
    @MainActor
    static func makeKeyEvent(
        from event: NSEvent,
        action: ghostty_input_action_e,
        consumedMods: ghostty_input_mods_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = (event.type == .keyDown && event.isARepeat) ? GHOSTTY_ACTION_REPEAT : action
        key.keycode = UInt32(event.keyCode)
        key.mods = translateMods(event.modifierFlags)
        key.consumed_mods = consumedMods
        key.composing = false
        if event.type == .keyDown || event.type == .keyUp,
           let unshifted = event.characters(byApplyingModifiers: []),
           let scalar = unshifted.unicodeScalars.first
        {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// Keystroke re-encoded with shift/option only — strips
    /// command/control so JIS ⌘⇧- produces "=" instead of bare "-".
    /// libghostty's utf8 binding match relies on this; same trick
    /// Ghostty's macOS app uses for its translation event.
    static func bindingText(from event: NSEvent) -> String {
        guard event.type == .keyDown || event.type == .keyUp else { return "" }
        let textMods = event.modifierFlags.subtracting([.command, .control])
        return event.characters(byApplyingModifiers: textMods)
            ?? event.charactersIgnoringModifiers
            ?? ""
    }

    /// Does libghostty have a binding that would unconditionally
    /// fire on this event? Returns `false` for `performable`
    /// bindings — those need libghostty's live surface-state check,
    /// so we let them follow the normal keyDown path instead of
    /// short-circuiting here.
    @MainActor
    static func eventHitsKeybind(
        event: NSEvent,
        surface: ghostty_surface_t
    ) -> Bool {
        let translationEvent = translationEvent(from: event, surface: surface)
        var key = makeKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            consumedMods: translateMods(
                translationEvent.modifierFlags.subtracting([.control, .command])
            )
        )
        let text = bindingText(from: translationEvent)
        return text.withCString { ptr in
            key.text = text.isEmpty ? nil : ptr
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, key, &flags) else {
                return false
            }
            let isPerformable = (flags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0
            return !isPerformable
        }
    }

    /// Synthesize a Return keypress (press + release) on `surface`.
    /// Used by `typeInitialCommand(_:)` and `typeAgentCommand(_:)` to
    /// submit typed text without depending on shell paste-mode quirks.
    func sendReturnKey(to surface: ghostty_surface_t) {
        let returnKeyCode = UInt32(NamedKey.return.primaryKeyCode)
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var key = ghostty_input_key_s()
            key.action = action
            key.keycode = returnKeyCode
            key.mods = ghostty_input_mods_e(0)
            key.consumed_mods = ghostty_input_mods_e(0)
            key.unshifted_codepoint = 0x0D
            key.composing = false
            if action == GHOSTTY_ACTION_PRESS {
                "\r".withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            } else {
                key.text = nil
                _ = ghostty_surface_key(surface, key)
            }
        }
    }
}

/// One side of a modifier, as AppKit tells the two keys apart: the
/// generic flag both sides share and this key's own device bit.
private struct ModifierKey {
    let flag: NSEvent.ModifierFlags
    let deviceBit: UInt
    let otherSideDeviceBit: UInt

    init?(keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_Shift: self.init(.shift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK)
        case kVK_RightShift: self.init(.shift, NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK)
        case kVK_Control: self.init(.control, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK)
        case kVK_RightControl: self.init(.control, NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK)
        case kVK_Option: self.init(.option, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK)
        case kVK_RightOption: self.init(.option, NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK)
        case kVK_Command: self.init(.command, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK)
        case kVK_RightCommand: self.init(.command, NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK)
        default: return nil
        }
    }

    private init(_ flag: NSEvent.ModifierFlags, _ deviceBit: Int32, _ otherSideDeviceBit: Int32) {
        self.flag = flag
        self.deviceBit = UInt(deviceBit)
        self.otherSideDeviceBit = UInt(otherSideDeviceBit)
    }
}
