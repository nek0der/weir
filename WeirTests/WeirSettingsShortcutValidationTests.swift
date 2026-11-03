// WeirSettingsShortcutValidationTests.swift
// Weir — which keys the shortcut recorder refuses for an action, and what a load does with a stored binding on them.

import Foundation
import Testing
@testable import Weir

@MainActor
struct WeirSettingsShortcutValidationTests {
    /// ⇧ or ⌥ alone on a key that types would take that character from
    /// every pane: ⇧T is the capital T, ⌥T the character macOS puts there.
    @Test(arguments: [
        StoredShortcut(key: "t", modifiers: [.shift]),
        StoredShortcut(key: "t", modifiers: [.option]),
        StoredShortcut(key: "t", modifiers: [.option, .shift]),
        StoredShortcut(key: "1", modifiers: [.shift]),
        StoredShortcut(key: "space", modifiers: [.shift]),
        StoredShortcut(key: "tab", modifiers: [.shift]),
        StoredShortcut(key: "backspace", modifiers: [.option]),
        StoredShortcut(key: "escape", modifiers: [.shift])
    ])
    func validate_refusesShiftOrOptionAlone_onAKeyThatTypes(shortcut: StoredShortcut) {
        #expect(KeyboardSettings().validate(shortcut, for: .newTab) == .typesText)
    }

    /// A key that types nothing keeps working with ⇧ or ⌥ alone, and ⌃ or
    /// ⌘ makes any key a shortcut.
    @Test(arguments: [
        StoredShortcut(key: "f5", modifiers: [.shift]),
        StoredShortcut(key: "f5", modifiers: [.option]),
        StoredShortcut(key: "home", modifiers: [.shift]),
        StoredShortcut(key: "t", modifiers: [.control, .shift]),
        StoredShortcut(key: "t", modifiers: [.command, .option]),
        StoredShortcut(key: "backspace", modifiers: [.command])
    ])
    func validate_takesKeys_thatTypeNothing(shortcut: StoredShortcut) {
        #expect(KeyboardSettings().validate(shortcut, for: .newTab) == .ok)
    }

    /// ⌥← and ⌥→ are the sidebar's, which says so rather than the rule
    /// for keys that type.
    @Test func validate_optionArrow_staysTheSidebars() {
        let optionLeft = StoredShortcut(key: "left", modifiers: [.option])
        #expect(KeyboardSettings().validate(optionLeft, for: .moveProjectUp) == .keptBySidebar)
        #expect(KeyboardSettings().validate(optionLeft, for: .newTab) == .ok)
    }

    /// Settings… and the Edit menu answer these keys before any binding of
    /// ours, so the recorder does not hand them out.
    @Test(arguments: [
        StoredShortcut(key: ",", modifiers: [.command]),
        StoredShortcut(key: "c", modifiers: [.command]),
        StoredShortcut(key: "v", modifiers: [.command]),
        StoredShortcut(key: "a", modifiers: [.command]),
        StoredShortcut(key: "x", modifiers: [.command]),
        StoredShortcut(key: "z", modifiers: [.command]),
        StoredShortcut(key: "z", modifiers: [.command, .shift]),
        StoredShortcut(key: "h", modifiers: [.command]),
        StoredShortcut(key: "m", modifiers: [.command])
    ])
    func validate_refusesAStandardMenuItemsKeys(shortcut: StoredShortcut) {
        #expect(KeyboardSettings().validate(shortcut, for: .newTab) == .standardMenuItem)
    }

    /// No default sits on a key the recorder would refuse, or a load would
    /// retire it.
    @Test func noDefault_isOnRefusedKeys() {
        for action in WeirShortcutAction.allCases {
            guard let shortcut = action.defaultShortcut else { continue }
            #expect(KeyboardSettings.refusal(ofKeys: shortcut) == nil, "\(action)")
        }
    }

    /// Every refusal has words to show under the row, and the words for a
    /// key that types speak of input, not only of characters: ⌥⌫ and ⇧⎋
    /// type none.
    @Test(arguments: [
        (ShortcutValidation.typesText, "With only ⇧ or ⌥, this key is input to the terminal. Add ⌃ or ⌘"),
        (.standardMenuItem, "A standard macOS menu item uses these keys"),
        (.unwritableKey, "This key can’t be used in a shortcut")
    ])
    func refusal_hasItsMessage(result: ShortcutValidation, english: String) throws {
        let message = try #require(result.message)
        #expect(message.key == english)
    }

    /// libghostty splits a trigger at every `>`, so the recorder refuses
    /// it rather than store a binding that never fires.
    @Test func validate_refusesAKey_thatCannotBeWritten() {
        let shortcut = StoredShortcut(key: ">", modifiers: [.command])
        #expect(KeyboardSettings().validate(shortcut, for: .newTab) == .unwritableKey)
    }

    /// A hand edit can put a binding the recorder refuses into
    /// `settings.json`. A load moves it to `retired`, where the update
    /// notice shows it, and the action's default comes back.
    @Test(arguments: [
        StoredShortcut(key: "t", modifiers: [.shift]),
        StoredShortcut(key: "c", modifiers: [.command]),
        StoredShortcut(key: "k", modifiers: []),
        StoredShortcut(key: ">", modifiers: [.command]),
        StoredShortcut(key: "numpad_add", modifiers: [.control])
    ])
    func normalize_retiresAStoredBinding_onRefusedKeys(shortcut: StoredShortcut) {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.toggleSidebar.rawValue] = shortcut
        let (normalized, _) = keyboard.normalizedForTest()
        #expect(normalized.overrides.isEmpty)
        #expect(normalized.retired[WeirShortcutAction.toggleSidebar.rawValue] == shortcut)
        #expect(normalized.shortcut(for: .toggleSidebar) == WeirShortcutAction.toggleSidebar.defaultShortcut)
    }

    /// A key with a line break in it can only come from a hand edit, and
    /// would start a config key of its own in the file libghostty reads. A
    /// load drops it outright: the notice would print it as it is.
    @Test(arguments: [
        "t=ignore\nclipboard-paste-protection = false",
        "t\r",
        " ",
        "",
        "\u{7}"
    ])
    func normalize_dropsAStoredKey_thatCannotBeWritten(key: String) {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.toggleSidebar.rawValue] = StoredShortcut(key: key, modifiers: [.command])
        let (normalized, _) = keyboard.normalizedForTest()
        #expect(normalized.overrides.isEmpty)
        #expect(normalized.retired.isEmpty)
    }

    /// A retired binding is shown in the update notice, so one with a key
    /// that cannot be written is dropped there too.
    @Test func normalize_dropsARetiredKey_thatCannotBeWritten() {
        var keyboard = KeyboardSettings()
        keyboard.retired[WeirShortcutAction.toggleSidebar.rawValue] = StoredShortcut(key: "a\nb", modifiers: [.command])
        let (normalized, _) = keyboard.normalizedForTest()
        #expect(normalized.retired.isEmpty)
    }

    @Test(arguments: ["t", "=", "+", ",", "é", "return", "enter", "page_up", "f12"])
    func hasWritableKey_takesOneCharacter_orANamedKey(key: String) {
        #expect(StoredShortcut(key: key, modifiers: [.command]).hasWritableKey)
    }

    /// Printable but not one libghostty reads in our trigger: two
    /// characters, a combining pair, a key name we do not know, or the
    /// sequence mark.
    @Test(arguments: ["tt", "e\u{301}", "numpad_add", ">"])
    func hasWritableKey_refusesPrintableKeys_libghosttyCannotRead(key: String) {
        let shortcut = StoredShortcut(key: key, modifiers: [.command])
        #expect(!shortcut.hasWritableKey)
        #expect(shortcut.hasPrintableKey)
    }
}
