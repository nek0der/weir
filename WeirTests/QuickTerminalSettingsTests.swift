// QuickTerminalSettingsTests.swift
// Weir — the quick terminal settings: which hotkeys the recorder accepts, which it warns about, and how the section decodes.

import Foundation
import Testing
@testable import Weir

@Suite("QuickTerminal settings")
@MainActor
struct QuickTerminalSettingsTests {

    // MARK: - Recorder validation

    private static let noSystemHotKeys: (StoredShortcut) -> Bool = { _ in false }

    @Test func validateHotKey_requiresCommandOrControl() {
        let settings = QuickTerminalSettings()
        let keyboard = KeyboardSettings()
        #expect(settings.validateHotKey(.init(key: "k", modifiers: [.option]), keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.shift, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        )
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(.init(key: "k", modifiers: []), keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .missingPrimaryModifier)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.control, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
        #expect(settings.validateHotKey(
            .init(key: "k", modifiers: [.command, .option]),
            keyboard: keyboard,
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
    }

    @Test(arguments: [
        (WeirShortcutAction.newTab, StoredShortcut(key: "t", modifiers: [.command])),
        (.toggleSidebar, StoredShortcut(key: "k", modifiers: [.control, .option]))
    ])
    func validateHotKey_rejectsEffectiveMenuShortcuts(action: WeirShortcutAction, chord: StoredShortcut) {
        var keyboard = KeyboardSettings()
        if action == .toggleSidebar {
            keyboard.setOverride(chord, for: action)
        }
        let settings = QuickTerminalSettings()
        #expect(settings.validateHotKey(chord, keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys)
            == .conflictsWithMenu(action))
        let nearMiss = StoredShortcut(key: chord.key, modifiers: [.command, .control, .option])
        #expect(settings.validateHotKey(nearMiss, keyboard: keyboard, isTakenBySystem: Self.noSystemHotKeys) == .ok)
    }

    @Test(arguments: ["q", "3"], [false, true])
    func validateHotKey_reservedChordWinsEvenWhenTakenByTheSystem(key: String, isSystemChord: Bool) {
        let chord = StoredShortcut(key: key, modifiers: [.command])
        let result = QuickTerminalSettings().validateHotKey(chord, keyboard: .init()) { isSystemChord && $0 == chord }
        #expect(result == .reserved)
    }

    @Test func validateHotKey_takenBySystem_isRejected() {
        let spotlight = StoredShortcut(key: "space", modifiers: [.command])
        let result = QuickTerminalSettings().validateHotKey(spotlight, keyboard: .init()) { $0 == spotlight }
        #expect(result == .takenBySystem)
    }

    /// Ordinary app commands are warned about in the pane, not rejected.
    @Test func validateHotKey_appCommandNotTakenBySystem_isAccepted() {
        let settings = QuickTerminalSettings()
        #expect(settings.validateHotKey(
            .init(key: "s", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
        #expect(settings.validateHotKey(
            .init(key: "c", modifiers: [.command]),
            keyboard: .init(),
            isTakenBySystem: Self.noSystemHotKeys
        ) == .ok)
    }

    // MARK: - App command warning

    @Test(arguments: [
        (StoredShortcut(key: "s", modifiers: [.command]), true),
        (StoredShortcut(key: "space", modifiers: [.command]), true),
        (StoredShortcut(key: "k", modifiers: [.control]), true),
        (StoredShortcut(key: "k", modifiers: [.command, .control]), false),
        (StoredShortcut(key: "`", modifiers: [.control]), false),
        (StoredShortcut(key: "k", modifiers: [.command, .option]), false),
        (StoredShortcut(key: "k", modifiers: [.control, .shift]), false)
    ])
    func mayOverlapAppCommands(_ shortcut: StoredShortcut, expected: Bool) {
        #expect(QuickTerminalSettings.mayOverlapAppCommands(shortcut) == expected, "\(shortcut.displayString)")
    }

    // MARK: - Settings decoding

    @Test(arguments: [
        #"{"schemaVersion":1,"appearance":{},"font":{},"terminal":{},"advanced":{}}"#,
        #"{"schemaVersion":1,"appearance":{},"font":{},"terminal":{},"advanced":{},"quickTerminal":{}}"#
    ])
    func decode_legacySettingsUseDefaultsForMissingQuickTerminalValues(json: String) throws {
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: Data(json.utf8))
        #expect(decoded.quickTerminal.hotKey == nil)
        #expect(decoded.quickTerminal.position == .top)
        #expect(decoded.quickTerminal.sizePercent == 50)
        #expect(decoded.quickTerminal.hidesOnFocusLoss)
        #expect(decoded.quickTerminal.unknownFields.isEmpty)
    }

    @Test func decode_partialSection_keepsPresentKeys() throws {
        let json = #"{"position":"left","hotKey":{"key":"`","modifiers":8}}"#
        let decoded = try JSONDecoder().decode(QuickTerminalSettings.self, from: Data(json.utf8))
        #expect(decoded.position == .left)
        #expect(decoded.hotKey == StoredShortcut(key: "`", modifiers: [.control]))
        #expect(decoded.sizePercent == 50)
        #expect(decoded.hidesOnFocusLoss)
    }

    @Test func decode_unknownPosition_fallsBackToTop() throws {
        let decoded = try JSONDecoder().decode(
            QuickTerminalSettings.self,
            from: Data(#"{"position":"diagonal"}"#.utf8)
        )
        #expect(decoded.position == .top)
    }

    @Test func decode_outOfRangeSize_isClampedAndSnapped() throws {
        for (raw, expected) in [(5, 30), (30, 30), (44, 40), (45, 50), (46, 50), (70, 70), (90, 90), (95, 90)] {
            let decoded = try JSONDecoder().decode(
                QuickTerminalSettings.self,
                from: Data(#"{"sizePercent":\#(raw)}"#.utf8)
            )
            #expect(decoded.sizePercent == expected, "\(raw)")
        }
    }

    @Test func codable_roundTrip_preservesEveryField() throws {
        let json = """
        {
          "hotKey": {"key": "space", "modifiers": 3},
          "position": "center",
          "sizePercent": 70,
          "hidesOnFocusLoss": false,
          "future": {"style": "sheet"}
        }
        """
        let fixture = Data(json.utf8)
        let settings = try JSONDecoder().decode(QuickTerminalSettings.self, from: fixture)
        #expect(settings.hotKey == StoredShortcut(key: "space", modifiers: [.command, .shift]))
        #expect(settings.position == .center)
        #expect(settings.sizePercent == 70)
        #expect(!settings.hidesOnFocusLoss)

        let expected = try #require(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let encoded = try JSONEncoder().encode(settings)
        let actual = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(actual == expected)
        #expect(try JSONDecoder().decode(QuickTerminalSettings.self, from: encoded) == settings)
    }

    @Test func encode_unboundHotKey_omitsTheKey() throws {
        let data = try JSONEncoder().encode(QuickTerminalSettings())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["hotKey"] == nil)
    }
}
