// TurnReadStoreTests.swift
// Weir — the turns read, kept across launches in turn-reads.json.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Turn read store")
struct TurnReadStoreTests {
    private static func mark(_ id: String, tree: String? = nil) -> TurnReadStore.Mark {
        TurnReadStore.Mark(turnID: TurnID(id), endTree: tree)
    }

    private func file(in dir: URL) -> URL {
        dir.appendingPathComponent("turn-reads.json")
    }

    @Test func readTurns_stayReadAcrossALaunch() throws {
        try withTempDir { dir in
            let store = TurnReadStore(directory: dir)
            store.markRead([Self.mark("a"), Self.mark("b")])
            store.flushSynchronously()

            let relaunched = TurnReadStore(directory: dir)

            #expect(relaunched.isRead(Self.mark("a")))
            #expect(relaunched.isRead(Self.mark("b")))
            #expect(!relaunched.isRead(Self.mark("c")))
            #expect(!relaunched.isRead(Self.mark("a", tree: "tree-1")), "a saved nil end is not a legacy wildcard")
        }
    }

    @Test func aMark_isSavedWithoutAFlush() async throws {
        // The debounced save, as the app relies on between launches.
        try await withTempDir { dir in
            let store = TurnReadStore(directory: dir)
            store.markRead([Self.mark("a")])

            // The save waits on the main queue, which a parallel run can stall
            // past a short deadline, so only a save that never comes should
            // reach this one.
            await pollUntil(timeout: .seconds(30), interval: .milliseconds(20)) {
                TurnReadStore(directory: dir).isRead(Self.mark("a"))
            }

            #expect(TurnReadStore(directory: dir).isRead(Self.mark("a")))
        }
    }

    @Test func aMark_lastsUntilItsTurnIsForgotten() throws {
        try withTempDir { dir in
            // However old: a kept record (the newest of a conversation) stays
            // read for as long as it is shown.
            let store = TurnReadStore(directory: dir, now: { Date(timeIntervalSince1970: 0) })
            store.markRead([Self.mark("old"), Self.mark("gone", tree: "gone-tree")])
            store.flushSynchronously()
            let saved = TurnReadStore(directory: dir)
            try #require(saved.isRead(Self.mark("old")))
            try #require(saved.isRead(Self.mark("gone", tree: "gone-tree")))
            store.forget([TurnID("gone")])
            store.flushSynchronously()

            let relaunched = TurnReadStore(directory: dir)

            #expect(relaunched.isRead(Self.mark("old")))
            #expect(!relaunched.isRead(Self.mark("gone", tree: "gone-tree")))
            #expect(relaunched.ends["gone"] == nil)
        }
    }

    @Test func readingATurnAgain_keepsWhenItWasFirstRead() throws {
        try withTempDir { dir in
            var clock = Date(timeIntervalSince1970: 100)
            let store = TurnReadStore(directory: dir, now: { clock })
            store.markRead([Self.mark("a")])
            clock = Date(timeIntervalSince1970: 200)
            store.markRead([Self.mark("a")])

            #expect(store.reads["a"] == Date(timeIntervalSince1970: 100))
        }
    }

    @Test(arguments: [false, true])
    func aRunThatMayNotWrite_keepsReadsInMemoryOnly(hasExistingFile: Bool) throws {
        try withTempDir { dir in
            let original = Data(#"{"schemaVersion":1,"reads":{"saved":"2026-10-12T00:00:00Z"}}"#.utf8)
            if hasExistingFile {
                try original.write(to: file(in: dir))
                #expect(TurnReadStore(directory: dir).isRead(Self.mark("saved")), "the fixture can be loaded")
            }
            let store = TurnReadStore(directory: dir, writesFiles: false)
            #expect(!store.isRead(Self.mark("saved")))
            store.markRead([Self.mark("a")])
            store.flushSynchronously()

            #expect(store.isRead(Self.mark("a")))
            if hasExistingFile {
                #expect(try Data(contentsOf: file(in: dir)) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: file(in: dir).path))
            }
        }
    }

    @Test func aNewerBuildsFile_isReadButNotRewritten() throws {
        try withTempDir { dir in
            let newer = Data(#"{"schemaVersion":2,"reads":{"a":"2026-10-12T00:00:00Z"},"more":true}"#.utf8)
            try newer.write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            store.markRead([Self.mark("b")])
            store.flushSynchronously()

            #expect(store.isRead(Self.mark("a")))
            #expect(store.isRead(Self.mark("b")), "marked in memory")
            #expect(try Data(contentsOf: file(in: dir)) == newer)
        }
    }

    @Test func aNewerBuildsFileOfAnotherShape_isLeftAsItIs() throws {
        try withTempDir { dir in
            let newer = Data(#"{"schemaVersion":3,"reads":[{"turn":"a"}]}"#.utf8)
            try newer.write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            store.markRead([Self.mark("b")])
            store.flushSynchronously()

            #expect(store.isRead(Self.mark("b")), "marked in memory")
            #expect(try Data(contentsOf: file(in: dir)) == newer)
        }
    }

    @Test(arguments: [
        "{",
        #"{"schemaVersion":1,"reads":{"untrusted":"2026-10-12T00:00:00Z"},"ends":[]}"#
    ])
    func aDamagedFile_costsItsMarksOnly(contents: String) throws {
        try withTempDir { dir in
            let original = Data(contents.utf8)
            try original.write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)
            #expect(!store.isRead(Self.mark("untrusted")))
            #expect(try Data(contentsOf: file(in: dir)) == original)

            store.markRead([Self.mark("a")])
            store.flushSynchronously()

            #expect(TurnReadStore(directory: dir).isRead(Self.mark("a")), "written afresh")
        }
    }

    @Test func aTurnEndedAgainAtAnotherTree_isNoLongerRead() throws {
        // Work after the stop is folded into the turn under the same ID:
        // what it changed has not been seen.
        try withTempDir { dir in
            let store = TurnReadStore(directory: dir)
            store.markRead([Self.mark("a", tree: "tree-1")])

            #expect(store.isRead(Self.mark("a", tree: "tree-1")))
            #expect(!store.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!store.isRead(Self.mark("a", tree: nil)), "nor at an end not taken")
            store.flushSynchronously()
            let restored = TurnReadStore(directory: dir)
            #expect(restored.isRead(Self.mark("a", tree: "tree-1")))
            #expect(!restored.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!restored.isRead(Self.mark("a", tree: nil)))
        }
    }

    @Test func aTurnReadAgainAtItsNewEnd_isReadAnew() throws {
        try withTempDir { dir in
            var clock = Date(timeIntervalSince1970: 100)
            let store = TurnReadStore(directory: dir, now: { clock })
            store.markRead([Self.mark("a", tree: "tree-1")])
            store.flushSynchronously()
            try #require(TurnReadStore(directory: dir).isRead(Self.mark("a", tree: "tree-1")))
            clock = Date(timeIntervalSince1970: 200)
            store.markRead([Self.mark("a", tree: "tree-2")])

            #expect(store.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!store.isRead(Self.mark("a", tree: "tree-1")))
            #expect(store.reads["a"] == Date(timeIntervalSince1970: 200))
            store.flushSynchronously()
            let restored = TurnReadStore(directory: dir)
            #expect(restored.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!restored.isRead(Self.mark("a", tree: "tree-1")))
            #expect(restored.reads["a"] == Date(timeIntervalSince1970: 200))
        }
    }

    @Test func aMarkFromAFileWithoutEnds_standsForAnyEnd_untilReadAgain() throws {
        try withTempDir { dir in
            try Data(#"{"schemaVersion":1,"reads":{"a":"2026-10-12T00:00:00Z"}}"#.utf8).write(to: file(in: dir))
            let store = TurnReadStore(directory: dir)

            #expect(store.isRead(Self.mark("a", tree: "tree-1")))
            #expect(store.isRead(Self.mark("a", tree: "tree-2")))
            #expect(store.isRead(Self.mark("a")))
            store.markRead([Self.mark("a", tree: "tree-1")])

            #expect(store.reads["a"] == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"), "keeps when it was read")
            #expect(!store.isRead(Self.mark("a", tree: "tree-2")), "held to the end it was read at from now on")
            store.flushSynchronously()
            let restored = TurnReadStore(directory: dir)
            #expect(restored.isRead(Self.mark("a", tree: "tree-1")))
            #expect(!restored.isRead(Self.mark("a", tree: "tree-2")))
            #expect(!restored.isRead(Self.mark("a")))
            #expect(restored.reads["a"] == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root reads files without read permission"))
    func unreadableMarks_arePreservedBeforeNewMarksAreSaved() throws {
        try withTempDir { dir in
            let original = Data(#"{"schemaVersion":1,"reads":{"old":"2026-10-12T00:00:00Z"}}"#.utf8)
            let url = file(in: dir)
            try original.write(to: url)
            try #require(TurnReadStore(directory: dir).isRead(Self.mark("old")))
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            let store = TurnReadStore(directory: dir)
            #expect(!store.isRead(Self.mark("old")))
            #expect(store.suspendedFile == nil)
            let names = try manager.contentsOfDirectory(atPath: dir.path)
            let backup = try dir.appendingPathComponent(#require(names.first {
                $0.hasPrefix("turn-reads.json.bak-read-failed-")
            }))
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            #expect(try Data(contentsOf: backup) == original)

            store.markRead([Self.mark("new")])
            store.flushSynchronously()
            let restored = TurnReadStore(directory: dir)
            #expect(restored.isRead(Self.mark("new")))
            #expect(!restored.isRead(Self.mark("old")))
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    /// A folder that cannot be searched hides turn-reads.json, which is not
    /// a first launch: the marks it holds are kept, not written over.
    @Test(.disabled(if: geteuid() == 0, "root can search folders without search permission"))
    func marksInAFolderThatCannotBeSearched_areNeverSavedOver() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let earlier = TurnReadStore(directory: dir)
            earlier.markRead([Self.mark("a")])
            earlier.flushSynchronously()
            let original = try Data(contentsOf: file(in: dir))
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = TurnReadStore(directory: dir)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            store.markRead([Self.mark("b")])
            store.flushSynchronously()

            #expect(try Data(contentsOf: file(in: dir)) == original)
            #expect(store.suspendedFile == file(in: dir))
        }
    }
}
