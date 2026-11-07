// AgentResumeIntentStoreTests.swift
// Weir — the migration that keeps a restore working across the move of the
// intent directory.
//
// An intent is the only evidence that Weir killed a run rather than losing
// it, so an intent left behind in the old location is a restore the user was
// promised and silently does not get.

import Foundation
import Testing
@testable import Weir

@Suite("AgentResumeIntentStore")
struct AgentResumeIntentStoreTests {
    private static let runID = "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2"
    private static let otherRunID = "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3"

    private func intent(runID: String, pid: String) -> AgentResumeIntent {
        AgentResumeIntent(
            runID: runID,
            paneID: UUID(),
            sessionID: "session-\(pid)",
            ownerRunID: nil,
            pid: pid,
            createdAt: Date(timeIntervalSince1970: 1_757_000_000)
        )
    }

    @Test("demo mode saves no intent and moves none an earlier build left")
    func demoMode_writesNothing() throws {
        try withTempDir { root in
            let legacyStore = AgentResumeIntentStore(directory: root.appendingPathComponent("legacy", isDirectory: true))
            try legacyStore.save(intent(runID: Self.runID, pid: "4242"))
            let legacyURL = legacyStore.url(Self.runID)
            let original = try Data(contentsOf: legacyURL)
            try #require(legacyStore.record(runID: Self.runID)?.pid == "4242")
            let demoDirectory = root.appendingPathComponent("resume-intents", isDirectory: true)
            let demo = AgentResumeIntentStore(directory: demoDirectory, writesFiles: false)

            try demo.save(intent(runID: Self.otherRunID, pid: "1"))
            demo.adoptLegacyIntents(from: legacyStore.directory)

            #expect(!FileManager.default.fileExists(atPath: demoDirectory.path))
            #expect(try Data(contentsOf: legacyURL) == original)
            #expect(legacyStore.allIntents().map(\.runID) == [Self.runID])
        }
    }

    @Test("an intent the previous build left behind is adopted")
    func adoptLegacyIntents_movesTheIntentAndMakesItReadable() throws {
        try withTempDir { root in
            let legacyStore = AgentResumeIntentStore(
                directory: root.appendingPathComponent("legacy", isDirectory: true)
            )
            // The legacy file is independent of this build's encoder.
            let legacyBytes = Data("""
            {
              "runID": "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2",
              "paneID": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
              "sessionID": "legacy-session",
              "ownerRunID": "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3",
              "pid": "4242",
              "createdAt": "2025-09-04T00:00:00Z"
            }
            """.utf8)
            try legacyBytes.write(to: legacyStore.directory.appendingPathComponent(Self.runID + ".json"))
            let store = AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            )

            store.adoptLegacyIntents(from: legacyStore.directory)

            let adopted = try #require(store.record(runID: Self.runID))
            #expect(adopted.runID == Self.runID)
            #expect(adopted.paneID.uuidString == "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1")
            #expect(adopted.sessionID == "legacy-session")
            #expect(adopted.ownerRunID == Self.otherRunID)
            #expect(adopted.pid == "4242")
            #expect(adopted.createdAt == Date(timeIntervalSince1970: 1_756_944_000))
            #expect(store.allIntents().map(\.runID) == [Self.runID])
            #expect(try Data(contentsOf: store.url(Self.runID)) == legacyBytes)
            #expect(!FileManager.default.fileExists(atPath: legacyStore.directory.path))
        }
    }

    @Test("an intent this build already wrote is not replaced by the old one")
    func adoptLegacyIntents_keepsTheCurrentIntent() throws {
        try withTempDir { root in
            let legacyStore = AgentResumeIntentStore(
                directory: root.appendingPathComponent("legacy", isDirectory: true)
            )
            try legacyStore.save(intent(runID: Self.runID, pid: "1111"))
            try legacyStore.save(intent(runID: Self.otherRunID, pid: "3333"))
            let legacyBytes = try Data(contentsOf: legacyStore.url(Self.runID))
            let otherBytes = try Data(contentsOf: legacyStore.url(Self.otherRunID))
            let store = AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            )
            try store.save(intent(runID: Self.runID, pid: "2222"))
            let currentBytes = try Data(contentsOf: store.url(Self.runID))

            store.adoptLegacyIntents(from: legacyStore.directory)

            #expect(store.record(runID: Self.runID)?.pid == "2222")
            #expect(try Data(contentsOf: store.url(Self.runID)) == currentBytes)
            #expect(try Data(contentsOf: legacyStore.url(Self.runID)) == legacyBytes)
            #expect(store.allIntents().map(\.runID) == [Self.runID, Self.otherRunID])
            #expect(try Data(contentsOf: store.url(Self.otherRunID)) == otherBytes)
            #expect(!FileManager.default.fileExists(atPath: legacyStore.url(Self.otherRunID).path))
        }
    }

    @Test("a legacy directory that was never used is nothing to migrate")
    func adoptLegacyIntents_missingDirectory_isANoOp() throws {
        try withTempDir { root in
            let store = AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            )

            try store.save(intent(runID: Self.runID, pid: "4242"))
            let bytes = try Data(contentsOf: store.url(Self.runID))
            let missing = root.appendingPathComponent("never-there", isDirectory: true)
            try #require(!FileManager.default.fileExists(atPath: missing.path))

            store.adoptLegacyIntents(from: missing)

            #expect(try Data(contentsOf: store.url(Self.runID)) == bytes)
            #expect(store.allIntents().map(\.runID) == [Self.runID])
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }
}
