// KeyboardMigrationRowsTests.swift
// Weir — the rows Settings → Keyboard lists for what the update did to a person's shortcuts.

import Foundation
import Testing
@testable import Weir

struct KeyboardMigrationRowsTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// A binding kept aside comes before a default left unassigned.
    @Test func keptAsideThenUnassigned_areListedInThatOrder() throws {
        var keyboard = KeyboardSettings()
        keyboard.retired = ["oldAction": StoredShortcut(key: "x", modifiers: [.command, .option])]
        keyboard.setOverride(StoredShortcut(key: "j", modifiers: [.command, .option]), for: .newTab)
        keyboard = keyboard.normalizedForTest().keyboard
        let rows = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: nil, locale: Self.japanese)
        try #require(rows.map(\.id) == ["retired.oldAction", "unassigned.showNeedsAttention"])
        #expect(rows[0].detail == "割り当てを外しました：⌥⌘X")
        #expect(rows[1].detail == "デフォルトの ⌥⌘J は 新規タブ で使われています")
    }

    /// A default the quick terminal's hotkey holds names the hotkey.
    @Test func aDefaultTheHotkeyHolds_namesTheHotkey() throws {
        let (keyboard, hotKey) = KeyboardSettings().normalizedForTest(hotKey: StoredShortcut(key: "j", modifiers: [.command, .option]))
        #expect(hotKey == StoredShortcut(key: "j", modifiers: [.command, .option]))
        #expect(keyboard.shortcut(for: .showNeedsAttention) == nil)
        let english = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: hotKey, locale: Self.english)
        #expect(english.map(\.id) == ["unassigned.showNeedsAttention"])
        let row = try #require(english.first)
        #expect(row.kind == .unassigned(.showNeedsAttention))
        #expect(row.title == "Show Needs Attention")
        #expect(row.detail == "Default ⌥⌘J is used by Quick Terminal hotkey")
        let japanese = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: hotKey, locale: Self.japanese)
        #expect(japanese.map(\.title) == ["要対応の一覧を表示"])
        #expect(japanese.map(\.detail) == ["デフォルトの ⌥⌘J は クイックターミナルのホットキー で使われています"])
    }
}
