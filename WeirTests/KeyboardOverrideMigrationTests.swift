// KeyboardOverrideMigrationTests.swift
// Weir — moving keyboard settings to schema 2: renamed actions, new defaults, reserved ⌘⏎, and rollback.

import Foundation
import Testing
@testable import Weir

@MainActor
struct KeyboardOverrideMigrationTests {
    private static let commandN = TestShortcuts.commandN
    private static let commandF = TestShortcuts.commandF
    private static let commandReturn = TestShortcuts.commandReturn
    private static let optionCommandN = TestShortcuts.optionCommandN

    private static func normalized(_ keyboard: KeyboardSettings, hotKey: StoredShortcut? = nil) -> (KeyboardSettings, StoredShortcut?) {
        keyboard.normalizedForTest(hotKey: hotKey)
    }

    @Test func renamedCases_keepRawValues() {
        // Settings store overrides under these names; a rename must not move them.
        #expect(WeirShortcutAction.nextSession.rawValue == "nextSection")
        #expect(WeirShortcutAction.previousSession.rawValue == "previousSection")
        #expect(WeirShortcutAction.review.rawValue == "reviewChanges")
        #expect(WeirShortcutAction.reviewLatestTurn.rawValue == "reviewTurn")

        var keyboard = KeyboardSettings()
        keyboard.overrides["nextSection"] = Self.commandN
        #expect(keyboard.shortcut(for: .nextSession) == Self.commandN)
    }

    /// Toggle Tab Layout went with the tab column. A binding a person
    /// saved for it still reads, binds nothing, and holds no keys: here on
    /// ⌘B, Toggle Sidebar's default, which stays Toggle Sidebar's. It is
    /// written back as it was, for a build that still has the action.
    @Test func aBindingForTheRemovedToggleTabLayout_reads_holdsNoKeys_andIsKept() throws {
        let commandB = StoredShortcut(key: "b", modifiers: [.command])
        #expect(WeirShortcutAction(rawValue: "toggleTabLayout") == nil)
        let data = try WeirSettings.testFileData(version: 2, overrides: ["toggleTabLayout": commandB])

        var settings = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: data)
        settings.normalizeKeyboard()

        #expect(settings.keyboard.overrides["toggleTabLayout"] == commandB)
        #expect(settings.keyboard.unbound.isEmpty)
        #expect(settings.keyboard.retired.isEmpty)
        #expect(settings.keyboard.shortcut(for: .toggleSidebar) == commandB)
        let controlCommandT = StoredShortcut(key: "t", modifiers: [.command, .control])
        #expect(settings.keyboard.validate(controlCommandT, for: .newTab) == .ok)
        let saved = try PersistenceCoders.makeDecoder().decode(
            WeirSettings.self,
            from: WeirSettings.makeFileEncoder().encode(settings)
        )
        #expect(saved.keyboard.overrides["toggleTabLayout"] == commandB)
    }

    @Test func newDefaults_takeNoKeysAnotherDefaultOrAReservedOneHas() {
        let defaults = WeirShortcutAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } }
        for (index, (action, shortcut)) in defaults.enumerated() {
            #expect(!ReservedShortcuts.triggers.contains(shortcut.ghosttyTrigger), "\(action) uses a reserved key")
            // Only the pair that answers in different places may share
            // (`WeirShortcutAction.sharesKeys`).
            for (other, otherShortcut) in defaults.dropFirst(index + 1) where !action.sharesKeys(with: other) {
                #expect(shortcut.ghosttyTrigger != otherShortcut.ghosttyTrigger, "\(action) and \(other) share a default")
            }
        }
        #expect(WeirShortcutAction.newWorktree.defaultShortcut == Self.commandN)
        #expect(WeirShortcutAction.goBack.defaultShortcut == StoredShortcut(key: "[", modifiers: [.command, .option]))
        #expect(WeirShortcutAction.showNeedsAttention.defaultShortcut == StoredShortcut(key: "j", modifiers: [.command, .option]))
        #expect(WeirShortcutAction.showOpenTabs.defaultShortcut == StoredShortcut(key: "a", modifiers: [.command, .shift]))
    }

    @Test func unbound_removesDefault() {
        var keyboard = KeyboardSettings()
        keyboard.unbound = [WeirShortcutAction.newWorktree.rawValue]
        #expect(keyboard.shortcut(for: .newWorktree) == nil)

        // Binding it by hand brings it back for good.
        keyboard.setOverride(Self.optionCommandN, for: .newWorktree)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.unbound.isEmpty)
    }

    /// ⌥⌘N makes a worktree at once by default. A person who had
    /// put ⌥⌘N on another action keeps it, and the new default gives way.
    @Test func optionCommandN_isCreateWorktreeNow_unlessThePersonBoundIt() {
        #expect(KeyboardSettings().shortcut(for: .newWorktreeNow) == Self.optionCommandN)
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newWindow.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWindow) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.unbound == [WeirShortcutAction.newWorktreeNow.rawValue])
        #expect(WeirShortcutAction.newWorktreeNow.category == .file)
        #expect(WeirShortcutAction.newWorktreeNow.localizedTitle.resolved(in: Locale(identifier: "ja")) == "今すぐワークツリーを作成")
    }

    @Test func conflictWithNewDefault_unbindsNewAction() throws {
        var keyboard = KeyboardSettings()
        // A person had put ⌘N on New Tab before ⌘N meant New Worktree….
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = Self.commandN

        (keyboard, _) = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newTab) == Self.commandN, "the person's binding wins")
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        // A default held by another binding has no ↺: restoring it would
        // leave it given up.
        #expect(!keyboard.canRestoreDefault(.newWorktree))
        let notice = try #require(keyboard.migrationNotice)
        #expect(notice.conflicts == [.newWorktree])

        // Resetting New Worktree… does not take ⌘N back from New Tab.
        keyboard.resetOverride(for: .newWorktree)
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        // Freeing ⌘N brings the default back, and the notice goes with it.
        keyboard.resetOverride(for: .newTab)
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
        #expect(keyboard.migrationNotice == nil)
    }

    @Test func aGivenUpDefault_namesWhatHoldsItsKeys() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = Self.commandN
        #expect(keyboard.holderOfDefault(for: .newWorktree, quickTerminalHotKey: nil) == .action(.newTab))
        keyboard.overrides.removeAll()
        #expect(keyboard.holderOfDefault(for: .newWorktree, quickTerminalHotKey: Self.commandN) == .quickTerminalHotKey)
        #expect(keyboard.holderOfDefault(for: .newWorktree, quickTerminalHotKey: nil) == nil)
        #expect(keyboard.holderOfDefault(for: .newWindow, quickTerminalHotKey: nil) == nil, "its keys are free")
    }

    @Test func aStaleUnboundEntry_isDroppedOnceItsKeysAreFree() {
        // An earlier load gave New Worktree… up; the binding that held ⌘N
        // is gone since (a hand edit, or a rollback that reset it).
        var keyboard = KeyboardSettings()
        keyboard.unbound = [WeirShortcutAction.newWorktree.rawValue, "anActionFromANewerBuild"]
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.unbound.isEmpty)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
    }

    @Test func aNewWorktreeBinding_keepsWorking() {
        // The action stays and keeps the person's keys. ⌥⌘N is
        // now Create Worktree Now's default, which gives way, and the
        // notice says so.
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.migrationNotice?.conflicts == [.newWorktreeNow])
    }

    // MARK: New Workspace… folded into New Worktree…

    /// An earlier build's "New Workspace…" saved its binding under
    /// `newSession`. With New Worktree… free of a choice of its own, the
    /// binding moves to it and ⌘N comes free.
    @Test func aNewWorkspaceBinding_movesToNewWorktree() {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newSession"] = Self.commandF
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.overrides["newSession"] == nil)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandF)
        #expect(keyboard.retired.isEmpty)
        // The moved binding holds its keys as before: Find's ⌘F gives way,
        // as it did to New Workspace….
        #expect(keyboard.shortcut(for: .find) == nil)
        #expect(keyboard.migrationNotice?.conflicts == [.find])
    }

    /// Both had a binding: New Worktree…'s own stays, and New Workspace…'s
    /// is kept aside, listed under the action that took it over.
    @Test func bothBound_keepsNewWorktrees_andKeepsNewWorkspacesAside() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newSession"] = Self.commandF
        keyboard.overrides[WeirShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.retired == ["newSession": Self.commandF])
        let notice = try #require(keyboard.migrationNotice)
        #expect(notice.retired == [.init(rawValue: "newSession", shortcut: Self.commandF)])
        let rows = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: nil, locale: Locale(identifier: "ja"))
        #expect(rows.first?.title == "新規ワークツリー…")
        // ⌘F binds nothing while it is kept aside: Find keeps its default.
        #expect(keyboard.shortcut(for: .find) == Self.commandF)
    }

    /// A binding kept aside under the old name already (from an earlier
    /// run that a rollback undid) gives way to the one moved aside now.
    @Test func aNewerNewWorkspaceBinding_replacesTheOneKeptAside() {
        var keyboard = KeyboardSettings()
        keyboard.retired["newSession"] = Self.commandReturn
        keyboard.overrides["newSession"] = Self.commandF
        keyboard.overrides[WeirShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.retired["newSession"] == Self.commandF)
    }

    /// New Workspace… unassigned: New Worktree… is left without keys too,
    /// unless the person had chosen something for it.
    @Test func anUnassignedNewWorkspace_unassignsNewWorktree_unlessItHasAChoice() {
        var keyboard = KeyboardSettings()
        keyboard.unassigned = ["newSession"]
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.unassigned == [WeirShortcutAction.newWorktree.rawValue])
        #expect(keyboard.shortcut(for: .newWorktree) == nil)

        var bound = KeyboardSettings()
        bound.unassigned = ["newSession"]
        bound.overrides[WeirShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (bound, _) = Self.normalized(bound)
        #expect(bound.unassigned.isEmpty)
        #expect(bound.shortcut(for: .newWorktree) == Self.optionCommandN)
    }

    /// A given-up New Workspace… leaves no trace; New Worktree… gives way
    /// on its own when the keys are taken.
    @Test func aGivenUpNewWorkspace_isForgotten() {
        var keyboard = KeyboardSettings()
        keyboard.unbound = ["newSession"]
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = Self.commandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.unbound == [WeirShortcutAction.newWorktree.rawValue])
    }

    /// The fold leaves nothing under the old name, so a second run, and a
    /// file read back, change nothing more.
    @Test func folding_changesNothingMoreTheSecondTime() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newSession"] = Self.commandF
        keyboard.overrides[WeirShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        let once = Self.normalized(keyboard)
        let twice = Self.normalized(once.0)
        #expect(twice.0 == once.0)
        let read = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(once.0))
        #expect(Self.normalized(read).0 == once.0)
    }

    /// The old keyboard object stored only overrides. The unrelated
    /// settings sections are required by both decoders.
    private static func legacySettings(overrides: String, includesVersion: Bool = true) -> Data {
        let version = includesVersion ? #""schemaVersion": 1,"# : ""
        return Data("""
        {
          \(version)
          "appearance": {},
          "font": {},
          "terminal": {"scrollbackLines": 27000},
          "advanced": {},
          "keyboard": {"overrides": \(overrides)}
        }
        """.utf8)
    }

    @Test(arguments: [
        (#"{"newWorktree":{"key":"f","modifiers":1}}"#, TestShortcuts.commandF),
        ("{}", TestShortcuts.commandN)
    ])
    func aSchema1File_keepsItsNewWorktreeBinding_orGetsCommandN(overrides: String, expected: StoredShortcut) throws {
        let legacy = Self.legacySettings(overrides: overrides)
        guard case let .migrated(from, data) = try VersionedDocumentMigrator.settings.migrate(legacy) else {
            Issue.record("Expected a schema 1 migration")
            return
        }
        #expect(from == 1)
        let migrated = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: data)
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.terminal.scrollbackLines == 27000)
        #expect(migrated.keyboard.shortcut(for: .newWorktree) == expected)
        #expect(migrated.keyboard.retired.isEmpty)
    }

    @Test func commandReturn_isReservedAndExistingOverrideRetired() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.find.rawValue] = Self.commandReturn

        (keyboard, _) = Self.normalized(keyboard)

        #expect(keyboard.retired[WeirShortcutAction.find.rawValue] == Self.commandReturn)
        #expect(keyboard.shortcut(for: .find) == WeirShortcutAction.find.defaultShortcut)
        #expect(keyboard.validate(Self.commandReturn, for: .find) == .reserved)
        let notice = try #require(keyboard.migrationNotice)
        #expect(notice.retired == [.init(rawValue: "find", shortcut: Self.commandReturn)])
        keyboard.discardRetired("find")
        #expect(keyboard.migrationNotice == nil)
    }

    @Test func aRetiredBinding_whoseDefaultAnotherHolds_leavesTheActionUnbound() {
        // Find's default ⌘F comes back once its ⌘⏎ binding is retired, but
        // the person had put ⌘F on New Tab.
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.find.rawValue] = Self.commandReturn
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = Self.commandF

        (keyboard, _) = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .find) == nil)
        #expect(keyboard.shortcut(for: .newTab) == Self.commandF)
    }

    @Test func theQuickTerminalHotkey_holdsItsKeys_unlessTheyAreReserved() {
        let (unbound, hotKey) = Self.normalized(KeyboardSettings(), hotKey: Self.commandN)
        #expect(hotKey == Self.commandN)
        #expect(unbound.shortcut(for: .newWorktree) == nil, "Carbon takes the hotkey before the menu")

        let (retired, cleared) = Self.normalized(KeyboardSettings(), hotKey: Self.commandReturn)
        #expect(cleared == nil)
        #expect(retired.retired[KeyboardSettings.quickTerminalHotKeyID] == Self.commandReturn)
    }

    @Test func normalizing_changesNothingMoreTheSecondTime() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = Self.commandN
        keyboard.overrides[WeirShortcutAction.find.rawValue] = Self.commandReturn
        let once = Self.normalized(keyboard, hotKey: Self.commandReturn)
        let twice = Self.normalized(once.0, hotKey: once.1)
        #expect(twice.0 == once.0)
        #expect(twice.1 == once.1)
    }

    @Test func configEmitsAnActiveOverrideAndOmitsUnboundAndRetiredKeys() {
        var settings = WeirSettings()
        settings.keyboard.unbound = ["newWorktree"]
        settings.keyboard.retired = ["find": Self.commandReturn]
        settings.keyboard.overrides["increaseFontSize"] = StoredShortcut(key: "f12", modifiers: [.control])
        let config = GhosttyConfigBridge.makeConfigString(settings: settings, resourcesDir: nil)
        let lines = config.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("keybind = ctrl+f12=") } == ["keybind = ctrl+f12=increase_font_size:1"])
        #expect(!lines.contains { $0.hasPrefix("keybind = super+n=") })
        #expect(!lines.contains { $0.hasPrefix("keybind = super+enter=") })
    }

    @Test(arguments: [true, false])
    func migrationTreatsExplicitAndUnversionedV1AsSchema2Once(includesVersion: Bool) throws {
        let v1 = Self.legacySettings(overrides: #"{"find":{"key":"return","modifiers":1}}"#, includesVersion: includesVersion)
        guard case let .migrated(from, data) = try VersionedDocumentMigrator.settings.migrate(v1) else {
            Issue.record("Expected a schema 1 migration")
            return
        }
        #expect(from == 1)
        let migrated = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: data)
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.terminal.scrollbackLines == 27000)
        #expect(migrated.keyboard.retired == ["find": Self.commandReturn])
        #expect(migrated.keyboard.shortcut(for: .find) == Self.commandF)
        #expect(try VersionedDocumentMigrator.settings.migrate(data) == .current)
    }

    @Test func theSchema1KeyboardModel_preservesSchema2FieldsInItsSidecar() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newTab"] = Self.commandN
        keyboard.unbound = ["newWorktree"]
        keyboard.retired = ["find": Self.commandReturn]
        let data = try JSONEncoder().encode(keyboard)

        let old = try JSONDecoder().decode(KeyboardSettingsV1.self, from: data)
        #expect(old.overrides == ["newTab": Self.commandN])
        #expect(old.unknownFields["unbound"] == .array([.string("newWorktree")]))
        #expect(old.unknownFields["retired"] == .object([
            "find": .object(["key": .string("return"), "modifiers": .int(1)])
        ]))

        let roundTripped = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(old))
        #expect(roundTripped == keyboard)
    }
}
