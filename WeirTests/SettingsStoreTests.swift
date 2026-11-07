// SettingsStoreTests.swift
// Weir — guards the on-disk lifecycle of `settings.json`. The Codable
// round-trip is covered by `WeirSettingsTests`; this suite pins the
// quarantine-on-decode-failure behavior that protects the user's bytes
// from a default-save clobber after a hand-edit typo.

import Foundation
import Testing
@testable import Weir

@MainActor
struct SettingsStoreTests {

    /// A garbled `settings.json` is renamed aside on init and the
    /// subsequent `saveNow()` lands on a fresh file, preserving the
    /// user's original bytes.
    @Test("decode failure quarantines settings.json before defaults take over", arguments: [
        #"{ "garbled": true, "#,
        #"{"appearance":{},"font":{},"terminal":"wide","advanced":{}}"#
    ])
    func decodeFailureQuarantinesFile(json: String) throws {
        try withTempDir { dir in
            let originalBytes = Data(json.utf8)
            let live = dir.appendingPathComponent("settings.json")
            try originalBytes.write(to: live)

            let store = SettingsStore(directory: dir)

            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let backup = try #require(entries.first { $0.hasPrefix("settings.json.bak-decode-failed-") })
            let quarantined = dir.appendingPathComponent(backup)
            #expect(entries == [backup])
            #expect(!FileManager.default.fileExists(atPath: live.path))
            #expect(try Data(contentsOf: quarantined) == originalBytes)
            #expect(store.settings == .default)
            #expect(store.savingSuspension == nil)
            #expect(MigrationBackup.readLedger(for: live) == nil)
            #expect(SavingSuspendedNotice.alert(
                launchSettings: store.savingSuspension,
                failedSessionFile: nil,
                isSettingsSaveFailing: store.hasFailedToSave,
                settingsFile: live,
                locale: Locale(identifier: "en")
            ) == nil)

            try #require(store.saveNow())
            #expect(try Self.read(live) == .default)
            store.settings.terminal.minPaneSize = 140
            try #require(store.saveNow())
            #expect(try Self.read(live).terminal.minPaneSize == 140)
            #expect(try Data(contentsOf: quarantined) == originalBytes)
        }
    }

    private static func read(_ url: URL) throws -> WeirSettings {
        try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: url))
    }

    /// The file name is what users edit by hand and what older builds
    /// read, so we pin it here rather than through the store's helper.
    @Test("the store saves to and loads from settings.json in its directory")
    func saveAndLoad_useSettingsJSONInDirectory() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let store = SettingsStore(directory: dir)
            #expect(store.settingsFileURL == file)

            store.settings.terminal.minPaneSize = 120
            try #require(store.saveNow())
            #expect(try Self.read(file).terminal.minPaneSize == 120)

            let reloaded = SettingsStore(directory: dir)
            #expect(reloaded.settings.terminal.minPaneSize == 120)
        }
    }

    /// A file a newer build wrote is read but never written back: this
    /// build would write its own schema under the newer version number, and
    /// the newer build would then skip the step that moves it forward.
    @Test func aNewerSchemaFile_isReadButNotWrittenBack() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            var newer = WeirSettings.default
            newer.schemaVersion = 99
            newer.terminal.minPaneSize = 140
            let bytes = try WeirSettings.makeFileEncoder().encode(newer)
            try bytes.write(to: file)

            let store = SettingsStore(directory: dir)
            #expect(store.settings.terminal.minPaneSize == 140)
            #expect(store.savingSuspension == .newerVersion)
            store.settings.terminal.minPaneSize = 160
            #expect(!store.saveNow())
            #expect(!store.hasFailedToSave)
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    /// A newer build may change the type of a key this build knows. Its file
    /// then does not decode here, and it is still that build's: it stays
    /// where it is, unread and unwritten, and this launch runs on the
    /// defaults without saving them over it.
    @Test func aNewerSchemaFileThatDoesNotDecode_staysInPlace_andIsNotWritten() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let bytes = Data(#"{"schemaVersion":99,"appearance":{},"font":{},"terminal":"a newer shape","advanced":{}}"#.utf8)
            try bytes.write(to: file)

            let store = SettingsStore(directory: dir)
            #expect(store.savingSuspension == .newerVersionUnreadable)
            #expect(store.settings == .default)
            #expect(try Data(contentsOf: file) == bytes)
            store.settings.terminal.minPaneSize = 160
            #expect(!store.saveNow())
            store.flushSynchronously()
            #expect(try Data(contentsOf: file) == bytes)

            let handEdit = Data(#"{"schemaVersion":100,"appearance":{},"font":{},"terminal":"a different newer shape","advanced":{}}"#.utf8)
            try handEdit.write(to: file)
            store.reloadFromDisk()
            #expect(store.savingSuspension == .newerVersionUnreadable)
            #expect(store.settings == .default)
            store.flushSynchronously()
            #expect(try Data(contentsOf: file) == handEdit)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
        }
    }

    /// A settings.json that is there but cannot be read is set aside under a
    /// new name as it is, so the defaults saved later do not land on it.
    @Test(.enabled(if: geteuid() != 0))
    func aFileThatCannotBeRead_isSetAside() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let original = try WeirSettings.testFileData(version: 2, overrides: ["newTab": TestShortcuts.commandN])
            try original.write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            try Self.requireReadDenied(file)

            let store = SettingsStore(directory: dir)
            #expect(store.savingSuspension == nil)
            #expect(store.settings.keyboard.overrides.isEmpty, "the defaults, as nothing could be read")
            let aside = try #require(try manager.contentsOfDirectory(atPath: dir.path)
                .first { $0.hasPrefix("settings.json.bak-read-failed-") })
            let asideURL = dir.appendingPathComponent(aside)
            #expect(!manager.fileExists(atPath: file.path))
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asideURL.path) }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asideURL.path)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()

            #expect(try Data(contentsOf: asideURL) == original)
            #expect(SettingsStore(directory: dir).settings.terminal.minPaneSize == 160)
        }
    }

    private static func requireReadDenied(_ file: URL) throws {
        let descriptor = open(file.path, O_RDONLY)
        let error = errno
        if descriptor >= 0 {
            close(descriptor)
        }
        try #require(descriptor == -1 && error == EACCES)
    }

    /// A folder that cannot be searched hides the file in it: that is not a
    /// first launch either. Saving stops, so a save once the folder opens
    /// up again cannot replace the file with the defaults.
    @Test(.enabled(if: geteuid() != 0))
    func aFileInAFolderThatCannotBeSearched_stopsSaving() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("settings.json")
            let original = try WeirSettings.makeFileEncoder().encode(WeirSettings.default)
            try original.write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            try Self.requireReadDenied(file)

            let store = SettingsStore(directory: dir)
            #expect(store.savingSuspension == .unreadable)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == original)
        }
    }

    /// The file watcher sees our own save as a change on disk. Reading it
    /// back must not undo a change made after that save and not yet saved.
    @Test func reloadAfterOwnSave_keepsALaterChange() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            let saved = try Data(contentsOf: store.settingsFileURL)
            try #require(try Self.read(store.settingsFileURL).terminal.minPaneSize == 120)
            store.settings.terminal.minPaneSize = 140

            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 140)
            #expect(try Data(contentsOf: store.settingsFileURL) == saved)
        }
    }

    /// With no file yet, the folder's other files (the session's state) set
    /// the watcher off before the first save writes ours. That reload finds
    /// no file, which is nothing new, and must not undo the change waiting
    /// to be saved.
    @Test(arguments: [false, true])
    func aReloadBeforeTheFirstSave_keepsAChangeMadeSinceTheLaunch(hadQuarantinedFile: Bool) throws {
        try withTempDir { dir in
            let original = Data(#"{ "broken": "#.utf8)
            let file = dir.appendingPathComponent("settings.json")
            if hadQuarantinedFile {
                try original.write(to: file)
            }
            let store = SettingsStore(directory: dir)
            try #require(!FileManager.default.fileExists(atPath: file.path))
            if hadQuarantinedFile {
                let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                let backup = try #require(names.first { $0.hasPrefix("settings.json.bak-decode-failed-") })
                #expect(try Data(contentsOf: dir.appendingPathComponent(backup)) == original)
            }
            store.settings.font.family = "Menlo"

            store.reloadFromDisk()

            #expect(store.settings.font.family == "Menlo")
            store.flushSynchronously()
            let saved = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: store.settingsFileURL))
            #expect(saved.font.family == "Menlo")
        }
    }

    /// A file deleted after the launch read it is still a change on disk:
    /// the settings go back to their defaults, as before.
    @Test func aReloadAfterTheFileWasDeleted_readsTheDefaults() throws {
        try withTempDir { dir in
            var stored = WeirSettings.default
            stored.font.family = "Menlo"
            try WeirSettings.makeFileEncoder().encode(stored).write(to: dir.appendingPathComponent("settings.json"))
            let store = SettingsStore(directory: dir)
            #expect(store.settings.font.family == "Menlo")
            try FileManager.default.removeItem(at: store.settingsFileURL)

            store.reloadFromDisk()

            #expect(store.settings.font.family == nil)
        }
    }

    /// A file that stops decoding while the app runs may be a save still in
    /// progress: it stays, the settings stay, and nothing writes over it
    /// until a change makes it readable again.
    @Test func aReloadOfAFileThatDoesNotDecode_keepsTheFileAndTheSettings() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            let file = store.settingsFileURL
            var fixed = store.settings
            fixed.terminal.minPaneSize = 140
            let garbled = Data(#"{ "garbled": true, "#.utf8)
            try garbled.write(to: file)

            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 120)
            #expect(store.savingSuspension == .doesNotDecode)
            #expect(try Data(contentsOf: file) == garbled)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(!entries.contains { $0.contains(".bak-") })
            store.settings.terminal.minPaneSize = 130
            store.flushSynchronously()
            #expect(try Data(contentsOf: file) == garbled)

            try WeirSettings.makeFileEncoder().encode(fixed).write(to: file)
            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 140)
            #expect(store.savingSuspension == nil)
            store.settings.terminal.minPaneSize = 160
            store.flushSynchronously()
            let saved = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: Data(contentsOf: file))
            #expect(saved.terminal.minPaneSize == 160)
        }
    }

    /// A read that caught a save half done, of a file that has since come
    /// back: the next report finds other bytes than the ones judged, and
    /// takes saving back up.
    @Test func aFileBackFromAHalfDoneRead_takesSavingBackUp() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            let file = store.settingsFileURL
            var edited = store.settings
            edited.terminal.minPaneSize = 140
            try WeirSettings.makeFileEncoder().encode(edited).write(to: file)

            store.reload(from: .data(Data(#"{ "terminal": "#.utf8)))
            #expect(store.savingSuspension == .doesNotDecode)
            #expect(store.settings.terminal.minPaneSize == 120)

            store.reloadFromDisk()

            #expect(store.savingSuspension == nil)
            #expect(store.settings.terminal.minPaneSize == 140)
        }
    }

    /// An edit made by hand after our save is taken in, and so is a hand
    /// edit that puts the file back to what we last saved: an edit like any
    /// other, not our own save's echo.
    @Test func anEditByHandBackToOurSave_isTakenIn() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            store.flushSynchronously()
            let saved = try Data(contentsOf: store.settingsFileURL)
            var edited = store.settings
            edited.terminal.minPaneSize = 180
            try WeirSettings.makeFileEncoder().encode(edited).write(to: store.settingsFileURL)
            store.reloadFromDisk()
            #expect(store.settings.terminal.minPaneSize == 180)

            try saved.write(to: store.settingsFileURL)
            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 120)
        }
    }

    @Test func restoreDefaultsForRelaunch_keepsTheOldFile_andQuitWritesDefaults() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            var existing = WeirSettings.default
            existing.terminal.minPaneSize = 160
            let bytes = try WeirSettings.makeFileEncoder().encode(existing)
            try bytes.write(to: file)
            let store = SettingsStore(directory: dir)
            try #require(store.settings.terminal.minPaneSize == 160)

            store.restoreDefaultsForRelaunch()

            #expect(store.settings == .default)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let backup = try #require(names.first { $0.hasPrefix("settings.json.bak-init-failure-") })
            store.flushSynchronously()
            #expect(try Self.read(file) == .default)
            #expect(SettingsStore(directory: dir).settings == .default)
            #expect(try Data(contentsOf: dir.appendingPathComponent(backup)) == bytes)
        }
    }

    /// A save of the session's file sets the watcher off for the folder,
    /// and the reload finds settings.json as the launch read it. That is
    /// nothing new, and must not undo the first change made since the
    /// launch, before its save lands.
    @Test func aReloadOfTheFileTheLaunchRead_keepsAChangeNotSavedYet() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            try WeirSettings.makeFileEncoder().encode(WeirSettings.default).write(to: file)
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 140

            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 140)
        }
    }

    /// A hand edit after the launch is still read, as it is new.
    @Test func aReloadOfAFileEditedSinceTheLaunch_readsTheEdit() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("settings.json")
            let encoder = WeirSettings.makeFileEncoder()
            try encoder.encode(WeirSettings.default).write(to: file)
            let store = SettingsStore(directory: dir)
            var edited = WeirSettings.default
            edited.terminal.minPaneSize = 150
            try encoder.encode(edited).write(to: file)

            store.reloadFromDisk()

            #expect(store.settings.terminal.minPaneSize == 150)
        }
    }

    /// A save that does not reach disk is reported, for the notice that
    /// tells the person, and the next save that lands takes it back.
    @Test(.enabled(if: geteuid() != 0))
    func aSaveThatFails_isReported_untilASaveLands() throws {
        try withTempDir { dir in
            let manager = FileManager.default
            let store = SettingsStore(directory: dir)
            store.settings.terminal.minPaneSize = 120
            try #require(store.saveNow())
            let before = try Data(contentsOf: store.settingsFileURL)
            try #require(try Self.read(store.settingsFileURL).terminal.minPaneSize == 120)
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            let probe = dir.appendingPathComponent("write-probe")
            try #require(throws: (any Error).self) { try SecureFileWrite.writeAtomic(Data([1]), to: probe) }

            store.settings.terminal.minPaneSize = 140
            #expect(!store.saveNow())
            #expect(store.hasFailedToSave)
            #expect(store.savingSuspension == nil)
            #expect(try Data(contentsOf: store.settingsFileURL) == before)

            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try #require(store.saveNow())
            #expect(!store.hasFailedToSave)
            #expect(try Self.read(store.settingsFileURL).terminal.minPaneSize == 140)
        }
    }
}
