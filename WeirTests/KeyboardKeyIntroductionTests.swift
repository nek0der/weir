// KeyboardKeyIntroductionTests.swift
// Weir — scheduling, persisting, and requesting the shortcut introduction after a schema 1 update.

import Foundation
import Testing
@testable import Weir

@MainActor
struct KeyboardKeyIntroductionTests {
    private static let optionCommandN = TestShortcuts.optionCommandN
    private static let commandF = TestShortcuts.commandF

    /// The keyboard as a schema 1 file leaves the move: its bindings moved,
    /// then the keys whose meaning changed noted.
    private static func moved(_ schema1: KeyboardSettings) -> KeyboardSettings {
        var keyboard = schema1.normalizedForTest().keyboard
        keyboard.noteChangedKeys(since: schema1)
        return keyboard
    }

    // MARK: - Who is told

    /// The previous release's ⌥⌘N was the sheet, and is Create Worktree Now
    /// now: the person is told on their first ⌥⌘N.
    @Test func migratingSchema1Defaults_schedulesTheIntroduction() {
        let keyboard = Self.moved(KeyboardSettings())

        #expect(keyboard.shortcut(for: .newWorktree) == TestShortcuts.commandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == Self.optionCommandN)
        #expect(keyboard.keysToIntroduce == ["newWorktreeNow"])
        #expect(keyboard.isIntroductionDue(for: .newWorktreeNow))
        #expect(KeyboardSettings.schema1NewWorktreeDefault == Self.optionCommandN)
    }

    /// Their own keys for New Worktree… meant ⌥⌘N was never the sheet.
    @Test func aCustomSheetKey_doesNotScheduleTheIntroduction() {
        var schema1 = KeyboardSettings()
        schema1.overrides["newWorktree"] = Self.commandF

        let keyboard = Self.moved(schema1)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandF)
        #expect(keyboard.keysToIntroduce.isEmpty)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// New Worktree… bound to ⌥⌘N in the file, the default written out,
    /// keeps those keys: the sheet stays on them, Create Worktree Now has
    /// none, and nothing changed under the person's hands.
    @Test func anExplicitOldSheetKey_doesNotScheduleTheIntroduction() {
        var schema1 = KeyboardSettings()
        schema1.overrides["newWorktree"] = Self.optionCommandN
        let keyboard = Self.moved(schema1)

        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.keysToIntroduce.isEmpty)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Bound to other keys since, Create Worktree Now has nothing to say:
    /// the person chose them knowing what they do.
    @Test func rebindingInstantWorktree_makesThePendingIntroductionNotDue() {
        var keyboard = Self.moved(KeyboardSettings())
        let rebound = StoredShortcut(key: "f12", modifiers: [.control])
        #expect(keyboard.isIntroductionDue(for: .newWorktreeNow))
        #expect(keyboard.validate(rebound, for: .newWorktreeNow) == .ok)
        keyboard.setOverride(rebound, for: .newWorktreeNow)
        let normalized = keyboard.normalizedForTest().keyboard

        #expect(normalized.shortcut(for: .newWorktreeNow) == rebound)
        #expect(normalized.keysToIntroduce == ["newWorktreeNow"])
        #expect(!normalized.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Their own binding on ⌥⌘N keeps it theirs: Create Worktree Now starts
    /// with no keys, and nothing changed under their hands.
    @Test func anotherActionKeepingOptionCommandN_preventsTheIntroduction() {
        var schema1 = KeyboardSettings()
        schema1.overrides["newWorktree"] = Self.commandF
        schema1.overrides["newTab"] = Self.optionCommandN
        let keyboard = Self.moved(schema1)

        #expect(keyboard.shortcut(for: .newTab) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandF)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.keysToIntroduce.isEmpty)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// A hotkey on ⌥⌘N displaces the new built-in shortcut.
    @Test func keepingTheQuickTerminalHotkey_preventsTheIntroduction() {
        let schema1 = KeyboardSettings()
        let result = schema1.normalizedForTest(hotKey: Self.optionCommandN)
        var keyboard = result.keyboard
        keyboard.noteChangedKeys(since: schema1)

        #expect(result.hotKey == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.keysToIntroduce.isEmpty)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Noting twice lists it once.
    @Test func notingTwice_listsItOnce() {
        var keyboard = Self.moved(KeyboardSettings())
        keyboard.noteChangedKeys(since: KeyboardSettings())

        #expect(keyboard.keysToIntroduce == ["newWorktreeNow"])
    }

    // MARK: - Said, then kept

    @Test func normalization_keepsAConsumedIntroductionAbsent() {
        var keyboard = Self.moved(KeyboardSettings())
        #expect(keyboard.isIntroductionDue(for: .newWorktreeNow))
        keyboard.markIntroduced(.newWorktreeNow)
        var hotKey: StoredShortcut?
        keyboard.normalize(quickTerminalHotKey: &hotKey)

        #expect(keyboard.shortcut(for: .newWorktreeNow) == Self.optionCommandN)
        #expect(keyboard.keysToIntroduce.isEmpty)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Kept through the file, and written only while there is something to
    /// say, so a file that never needed it reads as it did.
    @Test func theList_roundTripsThroughTheFile_andIsLeftOutWhenEmpty() throws {
        var settings = WeirSettings()
        settings.keyboard = Self.moved(KeyboardSettings())
        let data = try WeirSettings.makeFileEncoder().encode(settings)
        let saved = try Self.settingsObject(data)
        let pending = try #require(saved["keyboard"] as? [String: Any])
        #expect(pending["keysToIntroduce"] as? [String] == ["newWorktreeNow"])
        let decoded = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: data)
        #expect(decoded.keyboard.isIntroductionDue(for: .newWorktreeNow))

        settings.keyboard.markIntroduced(.newWorktreeNow)
        let emptied = try Self.settingsObject(WeirSettings.makeFileEncoder().encode(settings))
        let keyboard = try #require(emptied["keyboard"] as? [String: Any])
        #expect(!keyboard.keys.contains("keysToIntroduce"))
    }

    private static func settingsObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Through the store

    @Test func theStore_schedulesAnIntroductionOnMigration_andPersistsItsConsumption() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("settings.json")
            let schema1 = Data(#"""
            {
              "schemaVersion": 1,
              "appearance": {},
              "font": {},
              "terminal": {"scrollbackLines": 27000},
              "advanced": {},
              "keyboard": {"overrides": {}}
            }
            """#.utf8)
            try schema1.write(to: url)
            let store = SettingsStore(directory: dir)
            #expect(store.settings.terminal.scrollbackLines == 27000)
            #expect(store.settings.keyboard.keysToIntroduce == ["newWorktreeNow"])
            #expect(store.settings.keyboard.isIntroductionDue(for: .newWorktreeNow))

            store.settings.keyboard.markIntroduced(.newWorktreeNow)
            try #require(store.saveNow())

            let saved = try Self.settingsObject(Data(contentsOf: url))
            #expect(saved["schemaVersion"] as? Int == 2)
            let keyboard = try #require(saved["keyboard"] as? [String: Any])
            #expect(!keyboard.keys.contains("keysToIntroduce"))

            let reloaded = SettingsStore(directory: dir)
            #expect(reloaded.settings.terminal.scrollbackLines == 27000)
            #expect(reloaded.settings.keyboard.shortcut(for: .newWorktreeNow) == Self.optionCommandN)
            #expect(!reloaded.settings.keyboard.isIntroductionDue(for: .newWorktreeNow))
        }
    }

    @Test func newSettingsAndSchema2WithoutPendingKeys_doNotScheduleAnIntroduction() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            #expect(store.settings.keyboard.keysToIntroduce.isEmpty)
            #expect(!store.settings.keyboard.isIntroductionDue(for: .newWorktreeNow))
        }
        try withTempDir { dir in
            let file = Data(#"""
            {
              "schemaVersion": 2,
              "appearance": {},
              "font": {},
              "terminal": {},
              "advanced": {},
              "keyboard": {"overrides": {}, "showsHeldKeyHints": false}
            }
            """#.utf8)
            try file.write(to: dir.appendingPathComponent("settings.json"))
            let store = SettingsStore(directory: dir)
            #expect(!store.settings.keyboard.showsHeldKeyHints)
            #expect(store.settings.keyboard.keysToIntroduce.isEmpty)
            #expect(!store.settings.keyboard.isIntroductionDue(for: .newWorktreeNow))
        }
    }

    // MARK: - ⌥⌘N in the window

    @Test func dueIntroduction_requestsTheWorktreeSheetWithTheNote() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        session.setActiveContainer(.project(project.id))
        let window = ProjectWindowState(selection: session.primarySelection)
        let keyboard = Self.moved(KeyboardSettings())

        #expect(SupervisionWindowActions.introduceInstantWorktree(in: window, keyboard: keyboard))

        #expect(window.newSession?.projectID == project.id)
        #expect(window.newWorktreeSheet.introducesInstantKey)
    }

    @Test func introductionWithoutAPendingKeyOrProject_doesNotRequestTheSheet() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        session.setActiveContainer(.project(project.id))
        let window = ProjectWindowState(selection: session.primarySelection)
        var consumed = Self.moved(KeyboardSettings())
        #expect(consumed.isIntroductionDue(for: .newWorktreeNow))
        consumed.markIntroduced(.newWorktreeNow)
        for keyboard in [KeyboardSettings(), consumed] {
            #expect(!SupervisionWindowActions.introduceInstantWorktree(in: window, keyboard: keyboard))
            #expect(window.newSession == nil)
            #expect(!window.newWorktreeSheet.introducesInstantKey)
        }

        let empty = ProjectWindowState(selection: WindowSelection())
        #expect(!SupervisionWindowActions.introduceInstantWorktree(in: empty, keyboard: Self.moved(KeyboardSettings())))
        #expect(empty.newSession == nil)
        #expect(!empty.newWorktreeSheet.introducesInstantKey)
    }

    // MARK: - The note

    @Test func theNote_namesTheKeysAsBoundNow() {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let commandN = TestShortcuts.commandN
        let both = InstantWorktreeKeyText.note(now: Self.optionCommandN, sheet: commandN)
        #expect(both.resolved(in: en)
            == "⌥⌘N now creates a worktree without showing this sheet. This sheet now opens with ⌘N.")
        #expect(both.resolved(in: ja)
            == "⌥⌘N は、このシートを表示せずにワークツリーを作成するようになりました。このシートは ⌘N で開きます。")

        let withoutSheet = InstantWorktreeKeyText.note(now: Self.optionCommandN, sheet: nil)
        #expect(withoutSheet.resolved(in: en)
            == "⌥⌘N now creates a worktree without showing this sheet. To open this sheet, choose New Worktree… in the File menu.")
        #expect(withoutSheet.resolved(in: ja)
            == "⌥⌘N は、このシートを表示せずにワークツリーを作成するようになりました。このシートは、ファイルメニューの「新規ワークツリー…」で開きます。")

        for sheet in [commandN, nil] {
            let withoutNow = InstantWorktreeKeyText.note(now: nil, sheet: sheet)
            #expect(withoutNow.resolved(in: en)
                == "Create Worktree Now creates a worktree without showing this sheet. This is the New Worktree… sheet.")
            #expect(withoutNow.resolved(in: ja)
                == "「今すぐワークツリーを作成」は、このシートを表示せずにワークツリーを作成します。このシートは「新規ワークツリー…」です。")
        }
    }
}
