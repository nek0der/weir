// RestoreOutcomeDecodingTests.swift
// Weir — reading what Rust says became of a restore or a discard, including words a newer bridge adds.
//
// The journals and codes come from `rust/fixtures/restore`, which the Rust
// model's tests check are what it writes, so the two sides read one copy.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite(.disabled(if: !RepoFixture.hasLocalRepo, "the shared fixtures are in the source tree"))
struct RestoreOutcomeDecodingTests {
    private static let expectedStageReasons: [String: RestoreStageReason] = [
        "agentStarted": .agentStarted,
        "writeFailed": .writeFailed,
        "externalChangeDetected": .externalChangeDetected,
        "interrupted": .interrupted,
        "keptAside": .keptAside
    ]

    /// The codes a stage reason is written as (`stage-reasons.json`).
    struct StageCodes: Decodable {
        let written: [String]
        let later: String
    }

    private static func fixture(_ name: String) throws -> Data {
        let root = try #require(RepoFixture.weirRoot)
        return try Data(contentsOf: root.appendingPathComponent("rust/fixtures/restore/\(name)"))
    }

    /// The restore journal Rust writes, at `stage`, as a finished outcome.
    /// It also carries what a newer build may add: a field this build does
    /// not model and a path of a kind it does not name.
    private static func finished(stage: String, undoes: String? = nil) throws -> RestoreOutcome {
        var journal = try JSONObjectFixture.object(fixture("journal-without-operation.json"))
        journal["stage"] = try JSONSerialization.jsonObject(with: Data(stage.utf8))
        if let undoes {
            journal["undoes"] = undoes
        }
        journal["laterField"] = 1
        var planned = try #require(journal["plannedPaths"] as? [Any])
        planned.append(["path": "b", "kind": "renamed"])
        journal["plannedPaths"] = planned
        let outcome = try JSONSerialization.data(withJSONObject: ["outcome": "finished", "journal": journal])
        return try JSONDecoder().decode(RestoreOutcome.self, from: outcome)
    }

    private static func journal(stage: String, undoes: String? = nil) throws -> RestoreJournal? {
        let outcome = try finished(stage: stage, undoes: undoes)
        guard case let .finished(journal) = outcome else {
            Issue.record("not finished: \(outcome)")
            return nil
        }
        return journal
    }

    @Test func aJournal_isReadWithItsStage() throws {
        let applied = try #require(try Self.journal(stage: #"{"kind":"applied"}"#))
        #expect(applied.stage == .applied)
        #expect(applied.turnID == TurnID("T"))
        #expect(applied.turnNumber == 7)
        #expect(applied.plannedPaths == [
            RestorePathChange(path: "a.txt", kind: .modify),
            RestorePathChange(path: "b", kind: .unknown)
        ])
        #expect(applied.isUndoable)

        let partial = #"{"kind":"partiallyApplied","reason":"interrupted","currentTree":"c","kept":["a.txt"],"#
            + #""failed":[{"path":"b","reason":"x"}]}"#
        let stopped = try #require(try Self.journal(stage: partial))
        #expect(stopped.stage == .partiallyApplied(reason: .interrupted, kept: ["a.txt"], failed: ["b"]))
        #expect(stopped.stage.isInterrupted)
        #expect(stopped.isUndoable)
    }

    /// A save kept aside is not a path that could not be written: it is
    /// read apart, with where it went, from its own field or, as earlier
    /// journals wrote it, from the reason. A diagnostic an earlier build put
    /// in the reason is a path not written.
    @Test func aSaveKeptAside_isReadApartFromThePathsNotWritten() throws {
        let paths = try JSONObjectFixture.object(Self.fixture("kept-aside.json"))
        let failed = try ["writeFailed", "written", "earlier", "earlierDiagnostic"].map { try #require(paths[$0]) }
        let stage: [String: Any] = ["kind": "partiallyApplied", "reason": "writeFailed", "currentTree": "c", "failed": failed]
        let data = try JSONSerialization.data(withJSONObject: stage)
        let json = try #require(String(bytes: data, encoding: .utf8))
        let kept = try #require(try Self.journal(stage: json))
        #expect(kept.stage == .partiallyApplied(
            reason: .writeFailed,
            kept: [],
            failed: ["b", "d.txt"],
            keptAside: [
                RestoreKeptAside(path: "a.txt", location: ".weir-OP/target/ready-1/a.txt"),
                RestoreKeptAside(path: "c.txt", location: ".weir-OP/target/ready-1/c.txt")
            ]
        ))
    }

    @Test func aStageReasonRustWrites_isReadAsItself() throws {
        let codes = try JSONDecoder().decode(StageCodes.self, from: Self.fixture("stage-reasons.json"))
        #expect(Set(codes.written) == Set(Self.expectedStageReasons.keys))
        #expect(codes.written.count == Self.expectedStageReasons.count)
        for code in codes.written {
            let reason = try #require(Self.expectedStageReasons[code], "no expected reason for \(code)")
            let journal = try #require(try Self.journal(stage: #"{"kind":"aborted","reason":"\#(code)"}"#))
            #expect(journal.stage == .aborted(reason: reason), "wire code \(code)")
        }
    }

    @Test func aStageReasonANewerBridgeAdded_isUnknown() throws {
        let codes = try JSONDecoder().decode(StageCodes.self, from: Self.fixture("stage-reasons.json"))
        let journal = try #require(try Self.journal(stage: #"{"kind":"aborted","reason":"\#(codes.later)"}"#))
        #expect(journal.stage == .aborted(reason: .unknown))
    }

    /// A journal's stage, and the restore it undoes, if it is an undo.
    struct Undoable: Sendable, CustomTestStringConvertible {
        let stage: String
        var undoes: String?
        let expectedStage: RestoreStage
        let isUndoable: Bool

        var testDescription: String {
            undoes.map { "\(stage), undoing \($0)" } ?? stage
        }
    }

    /// Only applied and partly applied restores can be undone. An undo cannot itself be undone here.
    @Test(arguments: [
        Undoable(stage: #"{"kind":"applied"}"#, expectedStage: .applied, isUndoable: true),
        Undoable(
            stage: #"{"kind":"partiallyApplied","reason":"writeFailed","kept":["a.txt"]}"#,
            expectedStage: .partiallyApplied(reason: .writeFailed, kept: ["a.txt"], failed: []), isUndoable: true
        ),
        Undoable(stage: #"{"kind":"undone","by":"OP2"}"#, expectedStage: .undone(by: "OP2"), isUndoable: false),
        Undoable(
            stage: #"{"kind":"aborted","reason":"externalChangeDetected"}"#,
            expectedStage: .aborted(reason: .externalChangeDetected), isUndoable: false
        ),
        Undoable(stage: #"{"kind":"writing","done":[]}"#, expectedStage: .writing, isUndoable: false),
        Undoable(stage: #"{"kind":"squashed"}"#, expectedStage: .unknown, isUndoable: false),
        Undoable(stage: #"{"kind":"applied"}"#, undoes: "OP0", expectedStage: .applied, isUndoable: false)
    ])
    func onlyARestoreWhoseWorkStays_isUndoable(_ journal: Undoable) throws {
        let read = try #require(try Self.journal(stage: journal.stage, undoes: journal.undoes))
        #expect(read.stage == journal.expectedStage)
        #expect(read.undoes == journal.undoes)
        #expect(read.isUndoable == journal.isUndoable)
    }

    @Test func aDiscardOutcome_keepsItsJournalAndHunks() throws {
        let journal = try JSONObjectFixture.object(Self.fixture("journal-discard.json"))
        let data = try JSONSerialization.data(withJSONObject: [
            "outcome": "finished",
            "journal": journal,
            "hunks": [["path": "a.txt", "header": "@@ -1 +1 @@", "result": "discarded"]]
        ])
        let outcome = try JSONDecoder().decode(DiscardOutcome.self, from: data)
        guard case let .finished(maybeJournal, hunks) = outcome else {
            Issue.record("expected a finished discard")
            return
        }
        let kept = try #require(maybeJournal)
        #expect(kept.opID == "OP")
        #expect(kept.operation == .discard)
        #expect(kept.stage == .applied)
        #expect(hunks == [DiscardHunkResult(path: "a.txt", header: "@@ -1 +1 @@", result: .discarded)])
    }

    @Test func aJournalWithoutAnOperationIsARestore() throws {
        let restore = try JSONDecoder().decode(RestoreJournal.self, from: Self.fixture("journal-without-operation.json"))
        #expect(restore.operation == .restore)
        // When it ran is its own field, which recovery does not rewrite.
        #expect(restore.at == "2026-10-13T00:00:00Z")
        #expect(restore.ranAt == "2026-10-12T23:59:00Z")
    }
}

struct RestoreOutcomeInlineDecodingTests {
    private static func decodeRefusal(_ payload: String) throws -> RestoreOutcome {
        let json = #"{"outcome":"refused","refusal":\#(payload)}"#
        return try JSONDecoder().decode(RestoreOutcome.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        (#"{"kind":"agentActive","provider":"codex"}"#, RestoreRefusal.agentActive(.codex)),
        (#"{"kind":"changedSinceRestore","paths":["a.txt"]}"#, .changedSinceRestore(paths: ["a.txt"])),
        (#"{"kind":"mergeInProgress"}"#, .mergeInProgress),
        (#"{"kind":"journalUnwritable","cause":"refs file: denied"}"#, .journalUnwritable(cause: "refs file: denied")),
        (#"{"kind":"somethingNew"}"#, .unknown),
        (#"{"kind":"unsupportedVolume"}"#, .unsupportedVolume),
        (#"{"kind":"converted","paths":["f.txt"]}"#, .converted(["f.txt"])),
        (#"{"kind":"renamedInPlace","paths":["Name.txt"]}"#, .renamedInPlace(["Name.txt"])),
        (#"{"kind":"journalUnreadable","cause":"EACCES"}"#, .journalUnreadable(cause: "EACCES")),
        (#"{"kind":"restoreNotFound"}"#, .restoreNotFound)
    ])
    func refusals_areReadByKind_andAnUnknownOneIsUnknown(payload: String, expected: RestoreRefusal) throws {
        #expect(try Self.decodeRefusal(payload) == .refused(expected))
    }

    @Test func aDiscardOutcomeWithoutAJournal_keepsItsHunkResults() throws {
        let json = """
        {"outcome":"finished","journal":null,"hunks":[{"path":"f.txt","header":"@@ -1 +1 @@","result":"notFound"},
         {"path":"g.txt","header":"@@ -2 +2 @@","result":"somethingNew"}]}
        """
        let outcome = try JSONDecoder().decode(DiscardOutcome.self, from: Data(json.utf8))
        #expect(outcome == .finished(nil, [
            DiscardHunkResult(path: "f.txt", header: "@@ -1 +1 @@", result: .notFound),
            DiscardHunkResult(path: "g.txt", header: "@@ -2 +2 @@", result: .unknown)
        ]))
    }

    @Test func aRefusedDiscard_keepsTheReason() throws {
        let json = #"{"outcome":"refused","refusal":{"kind":"mergeInProgress"}}"#
        #expect(try JSONDecoder().decode(DiscardOutcome.self, from: Data(json.utf8)) == .refused(.mergeInProgress))
    }

    @Test(arguments: [
        (#"{"kind":"journalUnreadable","cause":"EACCES"}"#, true),
        (#"{"kind":"restoreNotFound"}"#, false)
    ])
    func aDecodedUndoRefusal_canBeRetriedOnlyWhenItMayChange(payload: String, mayChange: Bool) throws {
        let result = try #require(try RestoreCoordinator.UndoResult(Self.decodeRefusal(payload)))
        #expect(result.mayChange == mayChange)
    }
}
