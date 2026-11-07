// SettingsStoreMigrationTests.swift
// Weir — the settings store moving a file to schema 2: the copy it keeps first, what it writes, and when it holds off saving.

import CryptoKit
import Foundation
import Testing
@testable import Weir

@MainActor
struct SettingsStoreMigrationTests {
    private static let oldSettings = Data("""
    {
      "schemaVersion": 1,
      "appearance": {},
      "font": {"family": "Menlo"},
      "terminal": {"minPaneSize": 120},
      "advanced": {},
      "keyboard": {"overrides": {"find": {"key": "return", "modifiers": 1}}}
    }
    """.utf8)

    @Test func theStore_keepsACopy_andWritesSchemaTwo() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try Self.oldSettings.write(to: file)

            let store = SettingsStore(directory: dir)

            #expect(store.settings.schemaVersion == 2)
            #expect(store.settings.keyboard.retired["find"] == TestShortcuts.commandReturn)
            let ledger = try #require(MigrationBackup.readLedger(for: file))
            #expect(ledger.fromVersion == 1)
            #expect(ledger.toVersion == 2)
            #expect(ledger.stage == .written)
            #expect(try Data(contentsOf: dir.appendingPathComponent(ledger.backupFileName)) == Self.oldSettings)
            let onDisk = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: file))
            #expect(onDisk.schemaVersion == 2)
            #expect(onDisk.keyboard.overrides["find"] == nil)
            #expect(onDisk.keyboard.retired["find"] == TestShortcuts.commandReturn)
            #expect(onDisk.keyboard.shortcut(for: .find) == WeirShortcutAction.find.defaultShortcut)
            #expect(onDisk.font.family == "Menlo")
            #expect(onDisk.terminal.minPaneSize == 120)
        }
    }

    @Test func aRolledBackFile_isBroughtBackInLine_onLoad() throws {
        try withTempDir { dir in
            // An earlier build left ⌘⏎ on Find in a schema 2 file.
            try WeirSettings.testFileData(version: 2, overrides: ["find": TestShortcuts.commandReturn])
                .write(to: dir.appendingPathComponent("settings.json"))
            let store = SettingsStore(directory: dir)
            #expect(store.settings.keyboard.retired["find"] == TestShortcuts.commandReturn)
            #expect(store.settings.keyboard.shortcut(for: .find) == WeirShortcutAction.find.defaultShortcut)
        }
    }

    @Test func demoMode_migratesInMemory_andWritesNothing() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let v1 = try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn])
            try v1.write(to: file)

            let store = SettingsStore(directory: dir, writesFiles: false)
            #expect(store.settings.schemaVersion == 2)
            #expect(store.settings.keyboard.retired["find"] == TestShortcuts.commandReturn)
            #expect(store.settings.keyboard.shortcut(for: .find) == WeirShortcutAction.find.defaultShortcut)
            store.settings.terminal.minPaneSize = 160
            #expect(!store.saveNow())
            #expect(!store.hasFailedToSave)
            #expect(try Data(contentsOf: file) == v1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
        }
    }

    @Test func changesMadeInTheStore_keepTheKeysInLine() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            let custom = StoredShortcut(key: "k", modifiers: [.control, .option])
            store.settings.keyboard.setOverride(custom, for: .newWorktree)
            try #require(store.settings.keyboard.shortcut(for: .newWorktree) == custom)
            store.settings.keyboard.setOverride(TestShortcuts.commandN, for: .newTab)
            #expect(store.settings.keyboard.shortcut(for: .newTab) == TestShortcuts.commandN)
            store.settings.keyboard.resetOverride(for: .newWorktree)
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == nil)

            store.settings.keyboard.resetOverride(for: .newTab)
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == TestShortcuts.commandN)

            // Restore leaves the hotkey where it is, so its keys stay taken.
            store.settings.quickTerminal.hotKey = TestShortcuts.commandN
            store.settings.keyboard.restoreDefaults()
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == nil)
            store.settings.quickTerminal.hotKey = nil
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == TestShortcuts.commandN)
        }
    }

    @Test func aMoveWhoseWriteFailed_isRecordedOnceALaterSaveWrites() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let old = Self.oldSettings
            try old.write(to: file)
            // The copy and the ledger can be written; the file itself cannot
            // be replaced.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            try #require(throws: (any Error).self) { try SecureFileWrite.writeAtomic(Data([1]), to: file) }
            try #require(try Data(contentsOf: file) == old)

            let store = SettingsStore(directory: dir)
            #expect(store.settings.schemaVersion == 2)
            let backedUp = try #require(MigrationBackup.readLedger(for: file))
            #expect(backedUp.stage == .backedUp)
            #expect(try Data(contentsOf: dir.appendingPathComponent(backedUp.backupFileName)) == old)
            #expect(try Data(contentsOf: file) == old)
            #expect(store.hasFailedToSave)

            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            store.settings.terminal.minPaneSize = 140
            try #require(store.saveNow())
            let saved = try Data(contentsOf: file)
            let reopened = SettingsStore(directory: dir)
            #expect(reopened.settings.terminal.minPaneSize == 140)
            let ledger = try #require(MigrationBackup.readLedger(for: file))
            let digest = SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined()
            #expect(ledger.migratedSHA256 == digest)
            #expect(ledger.stage == .written)
            #expect(ledger.backupFileName == backedUp.backupFileName)
            #expect(!store.hasFailedToSave)
        }
    }

    /// A failed backup suspends writes until a later load can keep a copy.
    @Test(.enabled(if: geteuid() != 0))
    func withoutACopy_inAWritableFolder_aSaveLeavesTheFileAsItWas() throws {
        try withTempDir { dir in
            let manager = FileManager.default
            let file = dir.appendingPathComponent("settings.json")
            let v1 = try WeirSettings.testFileData(version: 1, overrides: ["newTab": TestShortcuts.commandN])
            try v1.write(to: file)
            let probe = dir.appendingPathComponent("write-probe")
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            try #require(throws: (any Error).self) { try SecureFileWrite.writeAtomic(Data([1]), to: probe) }

            let store = SettingsStore(directory: dir)
            #expect(store.settings.schemaVersion == 1)
            #expect(MigrationBackup.readLedger(for: file) == nil)
            #expect(store.savingSuspension == .notMoved)
            #expect(store.settings.keyboard.shortcut(for: .newWorktree) == nil)
            #expect(try Data(contentsOf: file) == v1)
            #expect(try manager.contentsOfDirectory(atPath: dir.path) == ["settings.json"])

            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try SecureFileWrite.writeAtomic(Data([1]), to: probe)
            #expect(try Data(contentsOf: probe) == Data([1]))
            store.settings.terminal.minPaneSize = 160
            #expect(!store.saveNow())
            store.flushSynchronously()
            #expect(!store.hasFailedToSave)
            #expect(try Data(contentsOf: file) == v1)

            let reopened = SettingsStore(directory: dir)
            #expect(reopened.settings.schemaVersion == 2)
            #expect(reopened.savingSuspension == nil)
            let ledger = try #require(MigrationBackup.readLedger(for: file))
            #expect(ledger.stage == .written)
            #expect(try Data(contentsOf: dir.appendingPathComponent(ledger.backupFileName)) == v1)
        }
    }

    /// The reload's move writes the file again, and the watcher reports
    /// that write too: by then the person may have changed a setting that
    /// is not saved yet, which the migrated file must not replace.
    @Test func aReloadOfTheMigratedBytes_keepsAChangeMadeSince() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let store = SettingsStore(directory: dir)
            try WeirSettings.testFileData(version: 1, overrides: ["find": TestShortcuts.commandReturn]).write(to: file)
            store.reloadFromDisk()
            #expect(store.settings.schemaVersion == 2)
            let migrated = try Data(contentsOf: file)
            let disk = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: migrated)
            try #require(disk.schemaVersion == 2)
            let ledger = try #require(MigrationBackup.readLedger(for: file))
            try #require(ledger.fromVersion == 1 && ledger.stage == .written)

            store.settings.terminal.minPaneSize = 120
            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 120)
            #expect(try Data(contentsOf: file) == migrated, "nothing else was written meanwhile")
            store.flushSynchronously()
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func aFileThatDoesNotDecode_andCannotBeMovedAside_isNeverSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let garbled = Data(#"{ "garbled": true, "#.utf8)
            try garbled.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = SettingsStore(directory: dir)
            #expect(store.settings == .default)
            #expect(store.savingSuspension == .unreadable)
            // Restored permissions let an incorrect save overwrite the file.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            store.settings.terminal.minPaneSize = 120
            store.saveNow()
            #expect(try Data(contentsOf: file) == garbled)

            // Fixed by hand, the file is read again and saving resumes.
            try WeirSettings.testFileData(version: 2, overrides: [:]).write(to: file)
            store.reloadFromDisk()
            #expect(store.savingSuspension == nil)
            store.settings.terminal.minPaneSize = 140
            store.saveNow()
            let saved = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: file))
            #expect(saved.terminal.minPaneSize == 140)
        }
    }

    /// A run that writes nothing (demo mode) tells no suspension, even for
    /// an older file it can neither move nor read: it saves nothing anyway,
    /// and the file belongs to the build the person runs, untouched.
    @Test func aStoreThatMayNotWrite_tellsNoSuspension() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try Self.versionlessMistyped.write(to: file)

            let store = SettingsStore(directory: dir, writesFiles: false)
            #expect(store.settings == .default)
            #expect(store.savingSuspension == nil)
            let edited = Data(#"{"appearance":{},"font":{},"terminal":"tall","advanced":{}}"#.utf8)
            try edited.write(to: file)
            store.reloadFromDisk()
            #expect(store.savingSuspension == nil)
            store.settings.terminal.minPaneSize = 160
            #expect(!store.saveNow())
            #expect(try Data(contentsOf: file) == edited)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
        }
    }

    /// No `schemaVersion`, and `terminal` is not an object.
    private static let versionlessMistyped = Data(#"{"appearance":{},"font":{},"terminal":"wide","advanced":{}}"#.utf8)
}
