// FrecencyStoreTests.swift
// Weir — the palette's frecency: how often and how lately a row was used, kept on disk for a month.

import Foundation
import Testing
@testable import Weir

@Suite("FrecencyStore")
@MainActor
struct FrecencyStoreTests {
    /// Writes `entries` where the store in `dir` reads them.
    private static func write(_ entries: [String: FrecencyStore.Entry], to dir: URL) throws {
        let data = try PersistenceCoders.makeEncoder().encode(entries)
        try data.write(to: dir.appendingPathComponent("frecency.json"))
    }

    @Test("demo mode ranks in memory and neither reads nor writes the file")
    func demoMode_touchesNoFile() throws {
        try withTempDir { dir in
            let real = FrecencyStore(directory: dir)
            real.record("mine")
            real.flushSynchronously()
            let file = dir.appendingPathComponent("frecency.json")
            let onDisk = try Data(contentsOf: file)

            let demo = FrecencyStore(directory: dir, writesFiles: false)
            #expect(demo.score(for: "mine") == 0, "the person's ranking stays out of a demo")
            demo.record("demo")
            demo.flushSynchronously()
            #expect(demo.score(for: "demo") > 0)
            #expect(try Data(contentsOf: file) == onDisk)
        }
    }

    @Test("an item used lately scores higher than one used as often, longer ago")
    func recentItem_scoresHigher() throws {
        try withTempDir { dir in
            try Self.write([
                "recent": FrecencyStore.Entry(count: 1, lastUsed: Date().addingTimeInterval(-60 * 60)),
                "old": FrecencyStore.Entry(count: 1, lastUsed: Date().addingTimeInterval(-7 * 24 * 60 * 60))
            ], to: dir)

            let store = FrecencyStore(directory: dir)

            #expect(store.score(for: "old") > 0)
            #expect(store.score(for: "recent") > store.score(for: "old"))
        }
    }

    @Test("frequently used item scores higher")
    func frequentItem_scoresHigher() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            for _ in 0..<10 {
                store.record("frequent")
            }
            store.record("rare")
            #expect(store.score(for: "frequent") > store.score(for: "rare"))
        }
    }

    @Test("recording updates count")
    func record_updatesEntry() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            store.record("test")
            #expect(store.entries["test"]?.count == 1)
            store.record("test")
            #expect(store.entries["test"]?.count == 2)
        }
    }

    @Test("persistence round-trip survives")
    func persistence_roundTrip() throws {
        try withTempDir { dir in
            let store1 = FrecencyStore(directory: dir)
            store1.record("x")
            store1.record("x")
            store1.flushSynchronously()

            let store2 = FrecencyStore(directory: dir)
            #expect(store2.entries["x"]?.count == 2)
        }
    }

    @Test("entries unused for a month are dropped on load")
    func load_evictsStaleEntries() throws {
        try withTempDir { dir in
            // Keys are per-object identities that nothing removes when the
            // object goes away, so the store's own age bound is what keeps
            // frecency.json from growing for the life of the install.
            try Self.write([
                "tab.gone": FrecencyStore.Entry(count: 9, lastUsed: Date().addingTimeInterval(-40 * 24 * 60 * 60)),
                "tab.live": FrecencyStore.Entry(count: 1, lastUsed: Date().addingTimeInterval(-24 * 60 * 60))
            ], to: dir)

            let store = FrecencyStore(directory: dir)

            #expect(store.entries["tab.gone"] == nil)
            #expect(store.entries["tab.live"]?.count == 1)
        }
    }

    // MARK: - A file that cannot be read

    @Test func aRankingThatDoesNotDecode_isMovedAside_notSavedOver() throws {
        try withTempDir { dir in
            let garbled = Data(#"{ "broken": "#.utf8)
            try garbled.write(to: dir.appendingPathComponent("frecency.json"))

            let store = FrecencyStore(directory: dir)
            store.record("new")
            store.flushSynchronously()

            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let kept = try #require(names.first { $0.hasPrefix("frecency.json.bak-decode-failed-") })
            #expect(try Data(contentsOf: dir.appendingPathComponent(kept)) == garbled)
            #expect(FrecencyStore(directory: dir).score(for: "new") > 0)
        }
    }

    @Test func anUnreadableRanking_thatCannotBeMovedAside_isNeverSavedOver() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("frecency.json")
            let garbled = Data(#"{ "broken": "#.utf8)
            try garbled.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = FrecencyStore(directory: dir)
            store.record("new")
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == garbled)
        }
    }

    @Test func flush_withNothingRecorded_leavesTheFileAsItWas() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("frecency.json")
            let written = Data(#"{"tab.a":{"count":1,"lastUsed":"2026-11-01T00:00:00Z"}}"#.utf8)
            try written.write(to: file)

            FrecencyStore(directory: dir).flushSynchronously()

            #expect(try Data(contentsOf: file) == written)
        }
    }

    /// A folder that cannot be searched hides the file in it, which is not
    /// a first launch: the check that a file exists answers no there too.
    /// Saving stops, and says so, so a save once the folder opens up again
    /// cannot replace the file with what this launch recorded.
    @Test func aRankingInAFolderThatCannotBeSearched_isNeverSavedOver() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("frecency.json")
            let original = Data(#"{"tab.a":{"count":1,"lastUsed":"2026-11-01T00:00:00Z"}}"#.utf8)
            try original.write(to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            let store = FrecencyStore(directory: dir)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            store.record("new")
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == original)
            #expect(store.suspendedFile == file)
        }
    }

    /// A demo run neither reads nor moves the person's ranking, even one
    /// that does not decode.
    @Test func aRunThatWritesNoFiles_leavesAnUndecodableRankingInPlace() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("frecency.json")
            let garbled = Data(#"{ "broken": "#.utf8)
            try garbled.write(to: file)

            let store = FrecencyStore(directory: dir, writesFiles: false)
            store.record("new")
            store.flushSynchronously()

            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["frecency.json"])
            #expect(try Data(contentsOf: file) == garbled)
        }
    }
}
