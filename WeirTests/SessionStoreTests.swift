// SessionStoreTests.swift
// Weir — `SessionStore` loading state.json (moving an older one forward, or aside) and saving it.

import CryptoKit
import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.tags(.persistence))
struct SessionStoreTests {
    /// A migrator whose one step turns the previous version into an empty
    /// current snapshot: what the store does around a step, apart from what
    /// the real step (`SessionSnapshotV5.step`) makes of the file.
    private static func oneStep(_ migrate: @escaping @Sendable (Data) throws -> Data) -> VersionedDocumentMigrator {
        VersionedDocumentMigrator(
            versionKey: "version",
            currentVersion: SessionSnapshot.currentVersion,
            versionWhenAbsent: nil,
            steps: [DocumentMigrationStep(fromVersion: SessionSnapshot.currentVersion - 1, migrate: migrate)]
        )
    }

    private static let upgrade: @Sendable (Data) throws -> Data = { _ in
        try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
    }

    private static func previousVersionFile(in dir: URL) throws -> Data {
        let data = Data("{\"version\":\(SessionSnapshot.currentVersion - 1)}".utf8)
        try data.write(to: dir.appendingPathComponent("state.json"))
        return data
    }

    private static func sessionFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("state.json") }
            .sorted()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func expectWrittenMigration(in dir: URL, original: Data, written: Data) throws -> MigrationBackupRecord {
        let document = dir.appendingPathComponent("state.json")
        let backup = "state.json.pre-v\(SessionSnapshot.currentVersion)"
        let ledger = try #require(MigrationBackup.readLedger(for: document))
        #expect(ledger.stage == .written)
        #expect(ledger.fromVersion == SessionSnapshot.currentVersion - 1)
        #expect(ledger.toVersion == SessionSnapshot.currentVersion)
        #expect(ledger.backupFileName == backup)
        #expect(ledger.sourceSHA256 == digest(original))
        #expect(ledger.migratedSHA256 == digest(written))
        #expect(try Data(contentsOf: dir.appendingPathComponent(backup)) == original)
        #expect(try sessionFiles(in: dir) == ["state.json", "state.json.migration.json", backup])
        return ledger
    }

    @Test func migratedFile_isWrittenAtOnceWithOneBackup_andReloadLeavesItAlone() throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let original = try Self.previousVersionFile(in: dir)
            let migrator = Self.oneStep(Self.upgrade)

            guard case .loaded = SessionStore(directory: dir, migrator: migrator).load() else {
                Issue.record("expected the migrated session to load")
                return
            }
            let written = try Data(contentsOf: document)
            let decoded = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: written)
            #expect(decoded.version == SessionSnapshot.currentVersion)
            let ledger = try Self.expectWrittenMigration(in: dir, original: original, written: written)
            let ledgerURL = MigrationBackup.ledgerURL(for: document)
            let ledgerBytes = try Data(contentsOf: ledgerURL)
            let manager = FileManager.default
            let preserved = [document, ledgerURL, dir.appendingPathComponent(ledger.backupFileName)]
            let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
            for file in preserved {
                try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
                try #require(manager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == oldDate)
            }

            let second = SessionStore(directory: dir, migrator: migrator)
            guard case let .loaded(reopened) = second.load() else {
                Issue.record("expected the current file to load")
                return
            }
            #expect(reopened.version == SessionSnapshot.currentVersion)
            #expect(try Data(contentsOf: document) == written)
            #expect(try Data(contentsOf: ledgerURL) == ledgerBytes)
            #expect(try Self.expectWrittenMigration(in: dir, original: original, written: written) == ledger)
            for file in preserved {
                #expect(try manager.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == oldDate)
            }
        }
    }

    /// How far a first launch got with the migration before it ended.
    enum InterruptedMigration: CaseIterable, Sendable {
        /// The copy is on disk; the ledger is not.
        case copied
        /// The copy and the ledger are on disk; the migrated file is not.
        case backedUp
        /// The migrated file is on disk; the ledger still says `backedUp`.
        case written
    }

    /// A relaunch after any of those points keeps the one copy and finishes
    /// the ledger. Each rule it rests on is `MigrationBackupTests`'s: a copy
    /// found by its bytes, a backup reused for the same source, and a ledger
    /// finished once the migrated bytes are on disk.
    @Test(arguments: InterruptedMigration.allCases)
    func aRelaunchAfterAnInterruptedMigration_keepsOneCopy_andFinishesTheLedger(
        _ interrupted: InterruptedMigration
    ) throws {
        try withTempDir { dir in
            let document = dir.appendingPathComponent("state.json")
            let original = try Self.previousVersionFile(in: dir)
            let migrated = try Self.upgrade(original)
            switch interrupted {
            case .copied:
                try original.write(to: dir.appendingPathComponent("state.json.pre-v\(SessionSnapshot.currentVersion)"))
            case .backedUp, .written:
                _ = try MigrationBackup.keep(
                    document,
                    source: original,
                    migrated: migrated,
                    from: SessionSnapshot.currentVersion - 1,
                    to: SessionSnapshot.currentVersion
                )
                if interrupted == .written {
                    try migrated.write(to: document)
                }
            }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))

            guard case .loaded = store.load() else {
                Issue.record("expected the session to load")
                return
            }
            let written = try Data(contentsOf: document)
            #expect(written == migrated)
            _ = try Self.expectWrittenMigration(in: dir, original: original, written: written)
        }
    }

    @Test(.enabled(if: geteuid() != 0))
    func backupFailure_leavesTheFileUnchanged() throws {
        try withTempDir { dir in
            let original = try Self.previousVersionFile(in: dir)
            let manager = FileManager.default
            // The same read-only directory prevents both backup and quarantine.
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))
            let outcome = store.load()

            guard case let .decodeFailed(error) = outcome else {
                Issue.record("expected a backup failure, got \(outcome)")
                return
            }
            #expect(error as? MigrationBackup.BackupError == .copyFailed)
            #expect(try Data(contentsOf: store.fileURL) == original)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
            #expect(store.isSavingSuspended)

            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let changed = SessionSnapshot(projects: [], tabs: [], recentProjectPaths: [dir])
            try #require(PersistenceCoders.makeEncoder().encode(changed) != original)
            store.saveSynchronously(changed)
            #expect(try Data(contentsOf: store.fileURL) == original)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
        }
    }

    private static func quarantine(in dir: URL, reason: String) throws -> URL {
        let files = try sessionFiles(in: dir)
        try #require(files.count == 1)
        let name = try #require(files.first)
        try #require(name.hasPrefix("state.json.bak-\(reason)-"))
        return dir.appendingPathComponent(name)
    }

    @Test func stepThatDoesNotDecode_leavesNoCopy() throws {
        try withTempDir { dir in
            let original = try Self.previousVersionFile(in: dir)
            let migrator = Self.oneStep { _ in Data("{\"version\":\(SessionSnapshot.currentVersion)}".utf8) }
            let outcome = SessionStore(directory: dir, migrator: migrator).load()

            guard case .decodeFailed = outcome else {
                Issue.record("expected a decode failure, got \(outcome)")
                return
            }
            #expect(try Data(contentsOf: Self.quarantine(in: dir, reason: "decode-failed")) == original)
        }
    }

    @Test func aMigrationWhoseWriteFailed_isRecordedOnceALaterSaveWrites() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = try Self.previousVersionFile(in: dir)
            let manager = FileManager.default
            // The backup and ledger can be written, but the original cannot
            // be replaced until the retry below.
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))

            guard case .loaded = store.load() else {
                Issue.record("expected the migrated session to load from memory")
                return
            }
            let pending = try #require(MigrationBackup.readLedger(for: file))
            try #require(pending.stage == .backedUp)
            try #require(store.hasFailedToSave)
            try #require(Data(contentsOf: file) == original)
            let backup = dir.appendingPathComponent(pending.backupFileName)
            try #require(Data(contentsOf: backup) == original)

            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            let changed = SessionSnapshot(projects: [], tabs: [], recentProjectPaths: [dir.appendingPathComponent("saved-after-migration")])
            store.saveSynchronously(changed)

            let written = try Data(contentsOf: file)
            let ledger = try #require(MigrationBackup.readLedger(for: file))
            #expect(ledger.stage == .written)
            #expect(ledger.migratedSHA256 == SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined())
            #expect(ledger.backupFileName == pending.backupFileName)
            #expect(try Data(contentsOf: backup) == original)
            #expect(!store.hasFailedToSave)
            let relaunched = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))
            guard case let .loaded(restored) = relaunched.load() else {
                Issue.record("expected the saved session to reload")
                return
            }
            #expect(restored.recentProjectPaths == changed.recentProjectPaths)
            #expect(try Data(contentsOf: file) == written)
            #expect(MigrationBackup.readLedger(for: file) == ledger)
        }
    }

    @Test func aDebouncedSave_finishesTheMigrationToo() async throws {
        try await withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = try Self.previousVersionFile(in: dir)
            let manager = FileManager.default
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir, migrator: Self.oneStep(Self.upgrade))
            guard case .loaded = store.load() else {
                Issue.record("expected the migrated session to load from memory")
                return
            }
            let pending = try #require(MigrationBackup.readLedger(for: file))
            try #require(pending.stage == .backedUp)
            try #require(store.hasFailedToSave)
            try #require(Data(contentsOf: file) == original)
            let backup = dir.appendingPathComponent(pending.backupFileName)
            try #require(Data(contentsOf: backup) == original)

            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            let changed = SessionSnapshot(projects: [], tabs: [], recentProjectPaths: [dir.appendingPathComponent("saved-after-debounce")])
            store.scheduleSave(changed)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                MigrationBackup.readLedger(for: file)?.stage == .written && !store.hasFailedToSave
            }

            let written = try Data(contentsOf: file)
            let restored = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: written)
            let ledger = try #require(MigrationBackup.readLedger(for: file))
            #expect(restored.recentProjectPaths == changed.recentProjectPaths)
            #expect(ledger.stage == .written, "finished on the queue")
            #expect(ledger.migratedSHA256 == SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined())
            #expect(ledger.backupFileName == pending.backupFileName)
            #expect(try Data(contentsOf: backup) == original)
            #expect(!store.hasFailedToSave)
        }
    }

    @Test func aStoreThatMayNotWrite_skipsItsSynchronousSave() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = Data("{}".utf8)
            try original.write(to: file)
            let store = SessionStore(directory: dir, writesFiles: false)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func aFileThatCannotBeSetAside_stopsSaving() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = Data("not json".utf8)
            try original.write(to: file)
            let manager = FileManager.default
            // An immutable file cannot be renamed, so it cannot be set aside.
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the malformed file to fail decoding")
                return
            }
            #expect(store.isSavingSuspended)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
            // Writable again, so only the suspension can keep the save off it.
            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))

            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func aFileSetAside_leavesSavingOn() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = Data("not json".utf8)
            try original.write(to: file)
            let store = SessionStore(directory: dir)
            guard case .decodeFailed = store.load() else {
                Issue.record("expected the malformed session to fail decoding")
                return
            }
            let backups = try Self.sessionFiles(in: dir).filter { $0.hasPrefix("state.json.bak-decode-failed-") }
            try #require(backups.count == 1)
            let backup = dir.appendingPathComponent(backups[0])
            try #require(Data(contentsOf: backup) == original)
            try #require(!FileManager.default.fileExists(atPath: file.path))
            #expect(!store.isSavingSuspended)

            let changed = SessionSnapshot(
                projects: [],
                tabs: [],
                recentProjectPaths: [dir.appendingPathComponent("saved-after-quarantine")]
            )
            store.saveSynchronously(changed)

            let relaunched = SessionStore(directory: dir)
            guard case let .loaded(restored) = relaunched.load() else {
                Issue.record("expected the new session to reload after the malformed file was set aside")
                return
            }
            #expect(restored.recentProjectPaths == changed.recentProjectPaths)
            #expect(!store.hasFailedToSave)
            #expect(try Data(contentsOf: backup) == original)
            #expect(try Self.sessionFiles(in: dir).filter { $0.hasPrefix("state.json.bak-decode-failed-") } == backups)
        }
    }

}

extension SessionStoreTests {
    /// A state.json that is there but cannot be read is not a first launch:
    /// it is set aside as it is, so the save that follows once it could be
    /// written lands on a fresh name instead of replacing it.
    @Test(.enabled(if: geteuid() != 0))
    func aFileThatCannotBeRead_isSetAside_notTakenForAFirstLaunch() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
            try original.write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            try #require(throws: (any Error).self) { try Data(contentsOf: file) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the unreadable file to be reported")
                return
            }
            #expect(!store.isSavingSuspended)
            let aside = try Self.quarantine(in: dir, reason: "read-failed")
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aside.path)
            let changed = SessionSnapshot(projects: [], tabs: [], recentProjectPaths: [dir])
            store.saveSynchronously(changed)

            guard case let .loaded(reopened) = SessionStore(directory: dir).load() else {
                Issue.record("expected the replacement to load")
                return
            }
            #expect(reopened.recentProjectPaths == changed.recentProjectPaths)
            #expect(try Data(contentsOf: aside) == original)
            #expect(try Self.sessionFiles(in: dir) == ["state.json", aside.lastPathComponent])
        }
    }

    /// One that can be neither read nor moved stops saving, so a save once
    /// it is readable and writable again cannot replace it.
    @Test(.enabled(if: geteuid() != 0))
    func aFileThatCannotBeReadOrSetAside_stopsSaving() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            let original = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
            try original.write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            try #require(throws: (any Error).self) { try Data(contentsOf: file) }
            try manager.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: file.path) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the unreadable file to be reported")
                return
            }
            #expect(store.isSavingSuspended)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
            try manager.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let changed = SessionSnapshot(projects: [Project(name: "new", rootURL: dir)], tabs: [])
            try #require(PersistenceCoders.makeEncoder().encode(changed) != original)
            store.saveSynchronously(changed)

            #expect(try Data(contentsOf: file) == original)
        }
    }

    /// Keys a later build added to a tab, a project, or a worktree are
    /// written back as they were, through a restore and a save, so going
    /// back a build and forward again keeps them. The keys this build reads
    /// and no longer writes stay gone.
    @Test func keysALaterBuildAdded_toATabProjectOrWorktree_surviveARestoreAndASave() throws {
        try withTempDir { dir in
            let root = WorkspaceSessionFixture.projectRootURL("unknown-keys")
            let worktree = Worktree(label: "w", workingDirectory: root.appendingPathComponent("w"), origin: .userPinned)
            let project = Project(name: "repo", rootURL: root, worktrees: [worktree])
            let tab = Tab.newWithSinglePane(title: "t", container: .project(project.id)).tab
            let encoded = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [project], tabs: [tab]))
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var tabs = try #require(object["tabs"] as? [String: Any])
            var tabObject = try #require(tabs[tab.id.uuidString] as? [String: Any])
            tabObject["futureTabField"] = ["nested": [1, 2]]
            tabObject["claudeSessions"] = [String: Any]()
            tabs[tab.id.uuidString] = tabObject
            object["tabs"] = tabs
            var containers = try #require(object["containers"] as? [[String: Any]])
            var projectObject = try #require(containers[0]["project"] as? [String: Any])
            projectObject["futureProjectField"] = "kept"
            projectObject["isExpanded"] = true
            var worktreeObjects = try #require(projectObject["worktrees"] as? [[String: Any]])
            worktreeObjects[0]["futureWorktreeField"] = 7
            projectObject["worktrees"] = worktreeObjects
            containers[0]["project"] = projectObject
            object["containers"] = containers
            let file = dir.appendingPathComponent("state.json")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let store = SessionStore(directory: dir)

            guard case let .loaded(snapshot) = store.load() else {
                Issue.record("expected the file to load")
                return
            }
            let session = WorkspaceSession()
            session.restore(from: snapshot)
            store.saveSynchronously(session.makeSnapshot())

            let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let writtenTab = try #require((written["tabs"] as? [String: Any])?[tab.id.uuidString] as? [String: Any])
            #expect((writtenTab["futureTabField"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
            #expect(writtenTab["claudeSessions"] == nil)
            let writtenProject = try #require((written["containers"] as? [[String: Any]])?.first?["project"] as? [String: Any])
            #expect(writtenProject["futureProjectField"] as? String == "kept")
            #expect(writtenProject["isExpanded"] == nil)
            let writtenWorktree = try #require((writtenProject["worktrees"] as? [[String: Any]])?.first)
            #expect(writtenWorktree["futureWorktreeField"] as? Int == 7)
        }
    }

    /// A folder that cannot be searched hides the file in it, even from the
    /// check that it was moved aside: saving stops, so a save once the
    /// folder opens up again cannot replace the file.
    @Test(.enabled(if: geteuid() != 0))
    func aFileInAFolderThatCannotBeSearched_stopsSaving() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("state.json")
            let original = try PersistenceCoders.makeEncoder().encode(SessionSnapshot(projects: [], tabs: []))
            try original.write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
            try #require(throws: (any Error).self) { try Data(contentsOf: file) }
            let store = SessionStore(directory: dir)

            guard case .decodeFailed = store.load() else {
                Issue.record("expected the hidden file to be reported")
                return
            }
            #expect(store.isSavingSuspended)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let changed = SessionSnapshot(projects: [Project(name: "new", rootURL: dir)], tabs: [])
            try #require(PersistenceCoders.makeEncoder().encode(changed) != original)
            store.saveSynchronously(changed)

            #expect(try Data(contentsOf: file) == original)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
        }
    }

    @Test func noFile_isAFirstLaunch() throws {
        try withTempDir { dir in
            let store = SessionStore(directory: dir)
            guard case .absent = store.load() else {
                Issue.record("expected no file to read as a first launch")
                return
            }
            #expect(!store.isSavingSuspended)
        }
    }

    @Test func throwingStep_movesTheFileAsideUnchanged() throws {
        try withTempDir { dir in
            struct Boom: Error {}
            let original = try Self.previousVersionFile(in: dir)
            let outcome = SessionStore(directory: dir, migrator: Self.oneStep { _ in throw Boom() }).load()

            guard case .decodeFailed = outcome else {
                Issue.record("expected a failure, got \(outcome)")
                return
            }
            #expect(try Data(contentsOf: Self.quarantine(in: dir, reason: "migration-failed")) == original)
        }
    }

    @Test(arguments: [4, SessionSnapshot.currentVersion + 1])
    func unsupportedVersion_isSetAsideUnchanged(version: Int) throws {
        try withTempDir { dir in
            let original = Data("{\"version\":\(version)}".utf8)
            let store = SessionStore(directory: dir)
            try original.write(to: store.fileURL)
            let outcome = store.load()

            guard case let .versionMismatch(found, expected) = outcome else {
                Issue.record("expected a version mismatch, got \(outcome)")
                return
            }
            #expect(found == version)
            #expect(expected == SessionSnapshot.currentVersion)
            #expect(try Data(contentsOf: Self.quarantine(in: dir, reason: "version-mismatch")) == original)
        }
    }

    @Test func currentFile_loadsWithoutABackup() throws {
        try withTempDir { dir in
            let store = SessionStore(directory: dir)
            let snapshot = SessionSnapshot(projects: [], tabs: [], recentProjectPaths: [dir])
            store.saveSynchronously(snapshot)
            let bytes = try Data(contentsOf: store.fileURL)

            guard case let .loaded(reopened) = SessionStore(directory: dir).load() else {
                Issue.record("expected the saved session to load")
                return
            }
            #expect(reopened.recentProjectPaths == snapshot.recentProjectPaths)
            #expect(try Data(contentsOf: store.fileURL) == bytes)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
        }
    }

    /// A newer build may add a run state; going back a build must not
    /// cost every project, tab, and window for it.
    @Test func aRunStateThisBuildDoesNotKnow_readsAsUnknown_andTheSessionLoads() throws {
        try withTempDir { dir in
            let session = WorkspaceSession()
            let tab = session.openTab(container: .loose)
            let pane = try #require(tab.splitTree.allLeafIDs().first)
            let neighbor = session.openTab(container: .loose)
            let neighborPane = try #require(neighbor.splitTree.allLeafIDs().first)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            _ = session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: now)] }
            _ = session.update(neighbor.id) {
                $0.agentBadges[.claude] = [neighborPane: AgentBadge(state: .finished, updatedAt: now)]
            }
            let encoded = try PersistenceCoders.makeEncoder().encode(session.makeSnapshot())
            let text = try #require(String(data: encoded, encoding: .utf8))
            let future = text
                .replacingOccurrences(of: #""state":"running""#, with: #""state":"waiting""#)
                .replacingOccurrences(of: #""state" : "running""#, with: #""state" : "waiting""#)
            try #require(future != text)
            try Data(future.utf8).write(to: dir.appendingPathComponent("state.json"))

            let store = SessionStore(directory: dir)
            guard case let .loaded(snapshot) = store.load() else {
                Issue.record("expected the session to load")
                return
            }

            #expect(Set(snapshot.tabs.map(\.id)) == [tab.id, neighbor.id])
            #expect(snapshot.tabs.first { $0.id == tab.id }?.agentBadges[.claude]?[pane]?.state == .unknown)
            #expect(snapshot.tabs.first { $0.id == neighbor.id }?.agentBadges[.claude]?[neighborPane]?.state == .finished)
            #expect(try Self.sessionFiles(in: dir) == ["state.json"])
        }
    }

    /// A save that does not reach disk is reported, for the notice that
    /// tells the person, and the next save that lands takes it back. Only
    /// whether the file was written decides it.
    @Test(.enabled(if: geteuid() != 0))
    func aSaveThatFails_isReported_untilASaveLands() throws {
        try withTempDir { dir in
            let manager = FileManager.default
            let store = SessionStore(directory: dir)
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            store.saveSynchronously(SessionSnapshot(projects: [], tabs: []))
            #expect(store.hasFailedToSave)
            #expect(!store.isSavingSuspended)
            #expect(try Self.sessionFiles(in: dir).isEmpty)

            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let changed = SessionSnapshot(projects: [], tabs: [], recentProjectPaths: [dir])
            store.saveSynchronously(changed)
            #expect(!store.hasFailedToSave)
            let written = try Data(contentsOf: store.fileURL)
            let reopened = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: written)
            #expect(reopened.recentProjectPaths == changed.recentProjectPaths)
        }
    }

    /// The debounced save reports a failure too, once its write is back on
    /// the main actor.
    @Test(.enabled(if: geteuid() != 0))
    func aDebouncedSaveThatFails_isReported() async throws {
        try await withTempDir { dir in
            let manager = FileManager.default
            let store = SessionStore(directory: dir)
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            store.scheduleSave(SessionSnapshot(projects: [], tabs: []))
            await pollUntil(timeout: .seconds(5)) { store.hasFailedToSave }
            #expect(store.hasFailedToSave)
            #expect(!store.isSavingSuspended)
            #expect(try Self.sessionFiles(in: dir).isEmpty)
        }
    }
}
