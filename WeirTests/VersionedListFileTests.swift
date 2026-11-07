// VersionedListFileTests.swift
// Weir — the small versioned list files: what they read, and how they leave the disk.

import Foundation
import OSLog
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("VersionedListFile")
struct VersionedListFileTests {
    private let file = VersionedListFile<NamesDocument>(
        schemaVersion: 2,
        label: "test names",
        log: Logger.weir("test.versioned-list")
    )

    @Test("a list written reads back, under the key its document names")
    func write_readsBackUnderDocumentKey() throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("nested/names.json")
            try #require(file.write(["a", "b"], to: url))
            let read = file.read(url)
            #expect(read.elements == ["a", "b"])
            #expect(read.isWritable)
            #expect(!read.isKeptUnread)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 2)
            #expect(object["names"] as? [String] == ["a", "b"])
        }
    }

    @Test("an empty list removes the file")
    func write_emptyRemovesFile() throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("names.json")
            try #require(file.write(["a"], to: url))
            try #require(FileManager.default.fileExists(atPath: url.path))
            #expect(file.write([], to: url))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(file.write([], to: url), "nothing to remove is not a failure")
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("a missing file holds nothing and may be written")
    func read_missingFileIsEmptyAndWritable() throws {
        try withTempDir { root in
            let read = file.read(root.appendingPathComponent("names.json"))
            #expect(read.elements.isEmpty)
            #expect(read.isWritable)
            #expect(!read.isKeptUnread)
        }
    }

    @Test("a file that does not decode is moved aside, and the list starts empty")
    func read_undecodableFileIsSetAside() throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("names.json")
            try Data("not json".utf8).write(to: url)
            let read = file.read(url)
            #expect(read.elements.isEmpty)
            #expect(read.isWritable)
            #expect(!read.isKeptUnread)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(names.count == 1)
            let aside = try #require(names.first { $0.hasPrefix("names.json.bak-decode-failed-") })
            #expect(try Data(contentsOf: root.appendingPathComponent(aside)) == Data("not json".utf8))
        }
    }

    @Test("a newer build's file is kept as it is and not written", arguments: [
        #"{"schemaVersion": 3, "names": ["a"]}"#,
        #"{"schemaVersion": 3, "names": {"changedShape": true}}"#
    ])
    func read_newerFileIsKeptAndNotWritable(document: String) throws {
        try withTempDir { root in
            let url = root.appendingPathComponent("names.json")
            let newer = Data(document.utf8)
            try newer.write(to: url)
            let read = file.read(url)
            #expect(read.elements.isEmpty)
            #expect(!read.isWritable)
            #expect(!read.isKeptUnread, "a newer build's file is not a trouble to report")
            #expect(try Data(contentsOf: url) == newer)
        }
    }

    /// A folder that cannot be searched hides the file in it, which is not
    /// a missing file: it is kept, not written, and reported.
    @Test("a file in a folder that cannot be searched is kept and not written", .enabled(if: geteuid() != 0))
    func read_fileInUnsearchableFolderIsKept() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let url = dir.appendingPathComponent("names.json")
            try #require(file.write(["a"], to: url))
            let original = try Data(contentsOf: url)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            try Self.requireReadDenied(url)
            let read = file.read(url)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

            #expect(read.elements.isEmpty)
            #expect(!read.isWritable)
            #expect(read.isKeptUnread)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    /// The queues that read these files write nothing over one kept: the
    /// turns on their way and the ended sessions' hints.
    @Test("the queues leave a kept file as it is", .enabled(if: geteuid() != 0))
    func queues_leaveAKeptFile() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let hints = dir.appendingPathComponent(AgentForgottenHintFile.fileName)
            let turns = dir.appendingPathComponent(TurnDeletionFile.fileName)
            let hintBytes = Data(#"{"schemaVersion": 1, "hints": []}"#.utf8)
            let turnBytes = Data(#"{"schemaVersion": 1, "turns": [{"turnId": "t1", "directory": "/d"}]}"#.utf8)
            try hintBytes.write(to: hints)
            try turnBytes.write(to: turns)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            try Self.requireReadDenied(hints)
            try Self.requireReadDenied(turns)
            var hintQueue = AgentForgottenHintQueue(url: hints)
            var turnQueue = TurnDeletionQueue(url: turns)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let hint = AgentForgottenHint(provider: "claude", pane: UUID(), sessionID: "S")
            hintQueue.add(hint)
            #expect(hintQueue.hints == [hint])
            let protection = TurnProtection(protectedTurnIDs: [], shownConversations: [])
            turnQueue.queue(["new-turn"], in: root, sweptWith: protection)
            let batch = try #require(turnQueue.nextBatch(protection: protection).batch)
            #expect(batch.turnIDs == ["new-turn"])

            let controlHints = root.appendingPathComponent("control-hints.json")
            let controlTurns = root.appendingPathComponent("control-turns.json")
            try hintBytes.write(to: controlHints)
            try turnBytes.write(to: controlTurns)
            var writableHints = AgentForgottenHintQueue(url: controlHints)
            var writableTurns = TurnDeletionQueue(url: controlTurns)
            writableHints.add(hint)
            writableTurns.queue(["new-turn"], in: root, sweptWith: protection)
            _ = try #require(writableTurns.nextBatch(protection: protection).batch)
            #expect(AgentForgottenHintFile.read(controlHints).elements == [hint])
            #expect(Set(TurnDeletionFile.read(controlTurns).elements.map(\.turnID)) == ["t1", "new-turn"])
            #expect(try Data(contentsOf: controlHints) != hintBytes)
            #expect(try Data(contentsOf: controlTurns) != turnBytes)

            #expect(hintQueue.suspendedFile == hints)
            #expect(turnQueue.suspendedFile == turns)
            #expect(try Data(contentsOf: hints) == hintBytes)
            #expect(try Data(contentsOf: turns) == turnBytes)
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

    /// The two files already on people's disks: a renamed key would read
    /// every one of them as empty.
    @Test("the hint and deletion files keep the keys they were written with")
    func files_keepTheirKeys() throws {
        try withTempDir { root in
            let hints = root.appendingPathComponent(AgentForgottenHintFile.fileName)
            let pane = UUID()
            try Data(#"""
            {"schemaVersion": 1, "hints": [{"provider": "claude", "pane": "\#(pane.uuidString)", "sessionID": "S"}]}
            """#.utf8).write(to: hints)
            #expect(AgentForgottenHintFile.read(hints).elements == [AgentForgottenHint(provider: "claude", pane: pane, sessionID: "S")])

            let turns = root.appendingPathComponent(TurnDeletionFile.fileName)
            try Data(#"""
            {"schemaVersion": 1, "turns": [{"turnId": "t1", "directory": "/d"}]}
            """#.utf8).write(to: turns)
            #expect(TurnDeletionFile.read(turns).elements == [
                TurnDeletionEntry(turnID: "t1", directory: "/d", conversation: nil, span: nil)
            ])
        }
    }
}

/// A list file of the tests' own, under a key of its own.
private struct NamesDocument: VersionedListDocument {
    var schemaVersion: Int
    var elements: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case elements = "names"
    }
}
