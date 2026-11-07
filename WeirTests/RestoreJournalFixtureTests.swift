// RestoreJournalFixtureTests.swift
// Weir — the journal fixture leaves out each optional key it is not given, so suites can still write an older build's journal.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct RestoreJournalFixtureTests {
    @Test func defaultFields_decodeLikeALegacyJournalWithoutOptionalKeys() throws {
        let legacyJSON = """
        {
          "opId": "OP",
          "root": "/repo",
          "turnId": "T",
          "paneId": "P",
          "plannedPaths": [],
          "stage": {"kind":"applied"},
          "at": "2026-10-13T00:00:00Z"
        }
        """
        let legacy = try JSONDecoder().decode(RestoreJournal.self, from: Data(legacyJSON.utf8))
        #expect(legacy.operation == .restore)
        #expect(legacy.turnNumber == nil)
        #expect(legacy.undoes == nil)
        #expect(legacy.ranAt == "2026-10-13T00:00:00Z")

        let journal = try RestoreJournalFixture.make(stageJSON: #"{"kind":"applied"}"#)
        #expect(journal == legacy)
    }

    @Test(arguments: [("discard", RestoreJournal.Operation.discard), ("someday", .unknown)])
    func fixtureFields_areDecodedWithTheGivenStageAndOperation(operation: String, expected: RestoreJournal.Operation) throws {
        let journal = try RestoreJournalFixture.make(
            stageJSON: #"{"kind":"undone","by":"undo-2"}"#,
            fields: .init(
                opID: "U", operation: operation, root: #"/a "quoted" root"#, turnID: "s1-T3", turnNumber: 3,
                paneID: "Q", undoes: "R", at: "2026-10-13T00:00:01Z", ranAt: "2026-10-13T00:00:00Z"
            )
        )

        #expect(journal.opID == "U")
        #expect(journal.operation == expected)
        #expect(journal.root == #"/a "quoted" root"#)
        #expect(journal.turnID == TurnID("s1-T3"))
        #expect(journal.turnNumber == 3)
        #expect(journal.paneID == "Q")
        #expect(journal.undoes == "R")
        #expect(journal.at == "2026-10-13T00:00:01Z")
        #expect(journal.ranAt == "2026-10-13T00:00:00Z")
        #expect(journal.stage == .undone(by: "undo-2"))
        #expect(journal.plannedPaths.isEmpty)
    }

    /// The journal the restore suites start from is a restore of turn 5 of
    /// `s1`, run when it was written; each field a test passes replaces its default.
    @Test func theTurnsRestore_isTurnFiveOfS1_untilAFieldIsGiven() throws {
        let journal = try RestoreJournalFixture.restore(#"{"kind":"applied"}"#)
        #expect(journal.opID == "OP")
        #expect(journal.operation == .restore)
        #expect(journal.turnID == TurnID("s1-T5"))
        #expect(journal.turnNumber == 5)
        #expect(journal.at == "2026-10-12T00:07:30Z")
        #expect(journal.ranAt == journal.at)

        let given = try RestoreJournalFixture.restore(
            #"{"kind":"applied"}"#,
            opID: "U", turnID: "s1-T1", number: nil, at: "2026-10-12T00:20:00Z", ranAt: "2026-10-12T00:07:30Z"
        )
        #expect(given.opID == "U")
        #expect(given.turnID == TurnID("s1-T1"))
        #expect(given.turnNumber == nil)
        #expect(given.at == "2026-10-12T00:20:00Z")
        #expect(given.ranAt == "2026-10-12T00:07:30Z")
    }
}
