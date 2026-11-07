// KeyboardUnassignTests.swift
// Weir — explicit shortcut removal survives persistence, and recorder keys preserve modified bindings.

import Foundation
import Testing
@testable import Weir

@MainActor
struct KeyboardUnassignTests {
    private static let commandN = TestShortcuts.commandN
    private static let optionCommandN = TestShortcuts.optionCommandN

    private static func normalized(_ keyboard: KeyboardSettings, hotKey: StoredShortcut? = nil) -> KeyboardSettings {
        keyboard.normalizedForTest(hotKey: hotKey).keyboard
    }

    @Test func unassigningADefault_survivesNormalizingAndASave_andRestoringBringsItBack() throws {
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        #expect(keyboard.canRestoreDefault(.newWorktree))
        let saved = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(keyboard))
        keyboard = Self.normalized(saved)
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        #expect(keyboard.unassigned == [WeirShortcutAction.newWorktree.rawValue])

        keyboard.restoreDefault(for: .newWorktree)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
        #expect(!keyboard.canRestoreDefault(.newWorktree))
    }

    @Test(arguments: [
        (WeirShortcutAction.newWorktree, StoredShortcut(key: "n", modifiers: [.command])),
        (.newWindow, StoredShortcut(key: "n", modifiers: [.command, .control]))
    ])
    func unassigningAnOverride_dropsItAndTheDefault(action: WeirShortcutAction, defaultShortcut: StoredShortcut) {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(Self.optionCommandN, for: action)
        #expect(keyboard.shortcut(for: action) == Self.optionCommandN)
        keyboard.unassign(action)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.overrides.isEmpty)
        #expect(keyboard.shortcut(for: action) == nil)
        #expect(keyboard.unassigned == [action.rawValue])
        #expect(keyboard.unbound.isEmpty)
        #expect(keyboard.canRestoreDefault(action))
        keyboard.restoreDefault(for: action)
        #expect(keyboard.shortcut(for: action) == defaultShortcut)
        #expect(keyboard.unassigned.isEmpty)
        #expect(!keyboard.canRestoreDefault(action))
    }

    @Test func anUnassignedDefault_staysOff_whenItsKeysAreTakenAndFreedAgain() {
        // Unassign New Worktree…, put ⌘N on New Tab, then give New Tab its
        // default back: ⌘N is free, and still New Worktree… stays off.
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        keyboard.setOverride(Self.commandN, for: .newTab)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newTab) == Self.commandN)
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        keyboard.restoreDefault(for: .newTab)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        #expect(keyboard.shortcut(for: .newTab) == WeirShortcutAction.newTab.defaultShortcut)
        #expect(keyboard.unassigned == [WeirShortcutAction.newWorktree.rawValue])
    }

    @Test func anUnassignedDefaultWhoseKeysAreTakenLater_isNoUpdateNotice() {
        // Unassigned, then its ⌘N given to another action or to the hotkey:
        // the person's own choices, not something the update changed.
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        keyboard.setOverride(Self.commandN, for: .newTab)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.unbound.isEmpty)
        #expect(keyboard.migrationNotice == nil)
        #expect(keyboard.shortcut(for: .newTab) == Self.commandN)
        #expect(keyboard.shortcut(for: .newWorktree) == nil)

        var withHotKey = KeyboardSettings()
        withHotKey.unassign(.newWorktree)
        withHotKey = Self.normalized(withHotKey, hotKey: Self.commandN)
        #expect(withHotKey.migrationNotice == nil)
        #expect(withHotKey.unbound.isEmpty)
        #expect(withHotKey.unassigned == [WeirShortcutAction.newWorktree.rawValue])
        #expect(withHotKey.shortcut(for: .newWorktree) == nil)
    }

    @Test func freeingTheKeys_bringsBackOnlyTheDefaultThatGaveWay() throws {
        let unassignedAction = try #require(WeirShortcutAction.allCases.first {
            $0 != .newWorktree && $0 != .newTab && $0.defaultShortcut != nil
        })
        var keyboard = KeyboardSettings()
        keyboard.unassign(unassignedAction)
        keyboard.setOverride(Self.commandN, for: .newTab)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.unbound == [WeirShortcutAction.newWorktree.rawValue])

        keyboard.resetOverride(for: .newTab)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
        #expect(keyboard.shortcut(for: unassignedAction) == nil)
    }

    @Test func aFileWithoutUnassigned_readsAsNone_andAnEmptyListIsNotWritten() throws {
        let old = try JSONDecoder().decode(KeyboardSettings.self, from: Data(#"{"overrides":{}}"#.utf8))
        #expect(old.unassigned.isEmpty)

        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(KeyboardSettings())) as? [String: Any])
        #expect(written["unassigned"] == nil)
        let recorded = try JSONDecoder().decode(KeyboardSettings.self, from: Data(#"{"unassigned":["newWorktree"],"overrides":{}}"#.utf8))
        #expect(recorded.unassigned == ["newWorktree"])
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        let roundTripped = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(keyboard))
        #expect(roundTripped.unassigned == [WeirShortcutAction.newWorktree.rawValue])
    }

    @Test(arguments: [
        (NamedKey?.some(.backspace), ShortcutModifiers(), ShortcutRecorderKey.restoreDefault),
        (.escape, ShortcutModifiers(), .cancel),
        (.return, ShortcutModifiers(), .record),
        (nil, ShortcutModifiers(), .record),
        (.backspace, .command, .record),
        (.backspace, .shift, .record),
        (.escape, .command, .record),
        (.escape, .shift, .record)
    ])
    func recorderKeys_distinguishBareControlsFromModifiedBindings(
        key: NamedKey?, modifiers: ShortcutModifiers, expected: ShortcutRecorderKey
    ) {
        #expect(ShortcutRecorderKey.meaning(of: key, modifiers: modifiers) == expected)
    }
}
