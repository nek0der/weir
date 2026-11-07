// SurfaceKeyboardTranslationTests.swift
// Weir — verifies the modifier boundary between AppKit text translation
// and the raw key event sent to libghostty.

import AppKit
import Carbon.HIToolbox
import GhosttyKit
import Testing
@testable import Weir
@testable import WeirDomain

/// A device-side modifier bit as AppKit carries it in `modifierFlags`.
private func device(_ mask: Int32) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: UInt(mask))
}

/// A modifier-only event and the action it has to reach libghostty as.
private struct ModifierChange: Sendable {
    let keyCode: Int
    let flags: NSEvent.ModifierFlags
    let isPress: Bool

    init(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, isPress: Bool) {
        self.keyCode = keyCode
        self.flags = flags
        self.isPress = isPress
    }
}

@Suite("Surface keyboard translation")
@MainActor
struct SurfaceKeyboardTranslationTests {
    @Test("An unchanged modifier decision reuses the original event")
    func unchangedModifiers_preserveEventIdentity() throws {
        let event = try NSEvent.testKeyDown(keyCode: 11, modifiers: [.shift, .option], characters: "b", timestamp: 1)
        let translated = SurfaceView.translationEvent(
            from: event,
            using: SurfaceView.translateMods(event.modifierFlags)
        )

        #expect(translated === event)
    }

    @Test("Option can be removed from text translation without changing the raw key")
    func optionAsAlt_separatesTranslationFromRawEvent() throws {
        let deviceRightOption = NSEvent.ModifierFlags(
            rawValue: UInt(NX_DEVICERALTKEYMASK)
        )
        let event = try NSEvent.testKeyDown(
            keyCode: 11,
            modifiers: [.option, .numericPad, deviceRightOption],
            characters: "b",
            timestamp: 1
        )
        let translated = SurfaceView.translationEvent(
            from: event,
            using: GHOSTTY_MODS_NONE
        )
        let rawKey = SurfaceView.makeKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            consumedMods: SurfaceView.translateMods(translated.modifierFlags)
        )

        #expect(translated !== event)
        #expect(translated.keyCode == event.keyCode)
        #expect(!translated.modifierFlags.contains(.option))
        #expect(translated.modifierFlags.contains(.numericPad))
        #expect(rawKey.keycode == 11)
        #expect(rawKey.action == GHOSTTY_ACTION_PRESS)
        #expect(rawKey.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(rawKey.mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue != 0)
        #expect(rawKey.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue == 0)
    }

    @Test("A modifier-only event never enters AppKit character translation")
    func flagsChanged_skipsCharacterTranslation() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let coreEvent = try #require(CGEvent(
            keyboardEventSource: source,
            virtualKey: 58,
            keyDown: true
        ))
        coreEvent.type = .flagsChanged
        coreEvent.flags = .maskAlternate
        let event = try #require(NSEvent(cgEvent: coreEvent))

        let translated = SurfaceView.translationEvent(
            from: event,
            using: GHOSTTY_MODS_NONE
        )
        let key = SurfaceView.makeKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            consumedMods: GHOSTTY_MODS_NONE
        )

        #expect(translated === event)
        #expect(SurfaceView.bindingText(from: event).isEmpty)
        #expect(key.unshifted_codepoint == 0)
    }

    // MARK: - Modifier press and release

    @Test("A modifier's release is sent as a release, judged by the key's own side", arguments: [
        // Left ⇧ down, then up.
        ModifierChange(kVK_Shift, [.shift, device(NX_DEVICELSHIFTKEYMASK)], isPress: true),
        ModifierChange(kVK_Shift, [], isPress: false),
        // Left ⇧ up while right ⇧ is still held: the generic flag stays.
        ModifierChange(kVK_Shift, [.shift, device(NX_DEVICERSHIFTKEYMASK)], isPress: false),
        // Right ⇧ up while left ⇧ is still held.
        ModifierChange(kVK_RightShift, [.shift, device(NX_DEVICELSHIFTKEYMASK)], isPress: false),
        ModifierChange(kVK_RightShift, [.shift, device(NX_DEVICERSHIFTKEYMASK)], isPress: true),
        ModifierChange(kVK_RightOption, [.option, device(NX_DEVICERALTKEYMASK)], isPress: true),
        ModifierChange(kVK_Option, [], isPress: false),
        ModifierChange(kVK_Command, [.command, device(NX_DEVICELCMDKEYMASK)], isPress: true),
        ModifierChange(kVK_RightControl, [.control, device(NX_DEVICELCTLKEYMASK)], isPress: false),
        // An event with no device bit, as a synthetic one can be.
        ModifierChange(kVK_Control, [.control], isPress: true),
        ModifierChange(kVK_CapsLock, [.capsLock], isPress: true),
        ModifierChange(kVK_CapsLock, [], isPress: false)
    ])
    private func modifierKeyAction_readsTheDirectionFromTheFlagsLeft(_ change: ModifierChange) {
        let action = SurfaceView.modifierKeyAction(keyCode: UInt16(change.keyCode), modifierFlags: change.flags)
        let expected = change.isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        #expect(action?.rawValue == expected.rawValue)
    }

    @Test("A key libghostty does not encode as a modifier is not forwarded")
    func modifierKeyAction_otherKey_isNil() {
        let function = SurfaceView.modifierKeyAction(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
        let letter = SurfaceView.modifierKeyAction(keyCode: UInt16(kVK_ANSI_A), modifierFlags: [.shift])
        #expect(function == nil)
        #expect(letter == nil)
    }

    // MARK: - ⌘⏎

    @Test("Command with the keypad's Enter is the same press as with Return")
    func keypadEnter_isTreatedTheSame() {
        let fromReturn = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command, .capsLock],
            isComposing: false,
            isRepeat: false
        )
        let fromKeypad = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_ANSI_KeypadEnter),
            modifierFlags: [.command, .numericPad, .function],
            isComposing: false,
            isRepeat: false
        )
        #expect(fromReturn == PrimaryKeyPress(isCommandOnly: true, isComposing: false))
        #expect(fromKeypad == fromReturn)
    }

    @Test("A taken key's release is held back once, and a missed release ends the wait")
    func takenKeyRelease_holdsBackOnlyItsOwnRelease() {
        let returnKey = UInt16(kVK_Return)
        var release = TakenKeyRelease()
        release.take(keyCode: returnKey)
        let otherKey = release.takesRelease(keyCode: UInt16(kVK_ANSI_J))
        #expect(!otherKey)
        release.notePress(keyCode: returnKey, isRepeat: true)
        let first = release.takesRelease(keyCode: returnKey)
        let second = release.takesRelease(keyCode: returnKey)
        #expect(first)
        #expect(!second, "only once")

        // ⌘ held to the end: AppKit sends no key-up, so the next plain
        // Return is released as usual.
        release.take(keyCode: returnKey)
        release.notePress(keyCode: returnKey, isRepeat: false)
        let afterMissed = release.takesRelease(keyCode: returnKey)
        #expect(!afterMissed)

        release.take(keyCode: returnKey)
        release.reset()
        let afterReset = release.takesRelease(keyCode: returnKey)
        #expect(!afterReset)
    }

    @Test("A composition, another chord, and other keys are not the bar's")
    func compositionOtherChordsAndOtherKeys_areNotTheBars() {
        let composing = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command],
            isComposing: true,
            isRepeat: true
        )
        #expect(composing == PrimaryKeyPress(isCommandOnly: true, isComposing: true, isRepeat: true))
        let optionCommand = SurfaceView.primaryKeyPress(
            keyCode: UInt16(kVK_Return),
            modifierFlags: [.command, .option],
            isComposing: false,
            isRepeat: false
        )
        #expect(optionCommand == PrimaryKeyPress(isCommandOnly: false, isComposing: false))
        #expect(SurfaceView
            .primaryKeyPress(keyCode: UInt16(kVK_Return), modifierFlags: [.shift], isComposing: false, isRepeat: false) == nil)
        #expect(SurfaceView
            .primaryKeyPress(keyCode: UInt16(kVK_ANSI_J), modifierFlags: [.command], isComposing: false, isRepeat: false) == nil)
    }
}
