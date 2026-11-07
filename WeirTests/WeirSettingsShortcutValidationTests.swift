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
        StoredShortcut(key: "return", modifiers: [.option]),
        StoredShortcut(key: "delete", modifiers: [.shift]),
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

    /// Input includes keys such as ⌥⌫ and ⇧⎋ that type no characters.
    @Test(arguments: [
        (ShortcutValidation.typesText, "With only ⇧ or ⌥, this key is input to the terminal. Add ⌃ or ⌘"),
        (.standardMenuItem, "A standard macOS menu item uses these keys"),
        (.unwritableKey, "This key can’t be used in a shortcut"),
        (.keptBySidebar, "The sidebar uses these keys while it has keyboard focus"),
        (.reserved, "Reserved by Weir (⌘⏎, ⌘1–9, ⌃⌘1–9)"),
        (.missingModifier, "Shortcut must include ⌃, ⌥, ⇧, or ⌘"),
        (.quickTerminalConflict, "Already used by the Quick Terminal hotkey"),
        (.ok, nil)
    ] as [(ShortcutValidation, String?)])
    func nonActionSpecificValidation_hasExpectedMessage(result: ShortcutValidation, english: String?) {
        #expect(result.message?.resolved(in: Locale(identifier: "en")) == english)
    }

    @Test(arguments: [">", "e\u{301}", "numpad_add", "x\ny"])
    func validate_reportsUnwritableKeys(key: String) {
        let shortcut = StoredShortcut(key: key, modifiers: [.command])
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
        #expect(normalized.retired == ["toggleSidebar": shortcut])
        #expect(normalized.shortcut(for: .toggleSidebar) == StoredShortcut(key: "b", modifiers: [.command]))
    }

    /// A key with a line break or a control character could inject a config
    /// line or be printed in the update notice. A load drops just that entry.
    @Test(arguments: [
        "t=ignore\nclipboard-paste-protection = false",
        "t\r",
        " ",
        "",
        "\u{7}",
        "a\nb"
    ])
    func normalize_dropsNonPrintableKeysAndKeepsOtherStoredBindings(key: String) {
        let invalid = StoredShortcut(key: key, modifiers: [.command])
        let binding = StoredShortcut(key: "f12", modifiers: [.control])
        let retired = StoredShortcut(key: "c", modifiers: [.command])
        var keyboard = KeyboardSettings()
        keyboard.overrides = ["toggleSidebar": invalid, "newTab": binding]
        keyboard.retired = ["newWorktree": invalid, "find": retired]

        let normalized = keyboard.normalizedForTest().keyboard
        #expect(normalized.overrides == ["newTab": binding])
        #expect(normalized.retired == ["find": retired])
        #expect(normalized.shortcut(for: .newTab) == binding)
        #expect(normalized.shortcut(for: .toggleSidebar) == StoredShortcut(key: "b", modifiers: [.command]))
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
