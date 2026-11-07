// TurnHistoryTests.swift
// Weir — when the turns are known: work that needs them waits for the first pass that
// reports them, and what a pass could not read is said once.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct TurnHistoryTests {
    @Test func whenLoaded_runsAtOnce_onceTheTurnsAreKnown() {
        let history = TurnHistory()
        history.replace(with: [])
        var runs = 0

        history.whenLoaded { runs += 1 }

        #expect(runs == 1)
    }

    @Test func whenLoaded_waitsForTheFirstPass_andRunsOnce() async throws {
        let history = TurnHistory()
        let conversation = TurnSummaryFixture.conversation
        let firstTurn = try TurnSummaryFixture.turn("first")
        var reports: [[TurnID]] = []
        history.whenLoaded { reports.append(history.turns(of: conversation).map(\.turnID)) }
        #expect(reports.isEmpty)

        history.replace(with: [ConversationTurns(key: conversation, turns: [firstTurn])])
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(5)) { !reports.isEmpty }
        try #require(reports == [[firstTurn.turnID]])

        history.replace(with: [])
        #expect(history.turns(of: conversation).isEmpty)
        // Give any newly scheduled observation callback a chance to run.
        await Task { @MainActor in }.value
        #expect(reports == [[firstTurn.turnID]])
    }

    @Test func theHistory_isLoadedOnceAPassReportsIt() {
        let history = TurnHistory()
        #expect(!history.hasLoaded)
        history.replace(with: [])
        #expect(history.hasLoaded, "an empty report is still a report")
    }

    @Test func skippedEntries_areSaidOnlyWhenTheCountChanges() {
        var report = SkippedEntriesReport()
        // Each value is one pass that reports the list; a pass that leaves it
        // out never asks.
        let said = [1, 1, 2, 0, 0, 1].map { report.newCount($0) }

        #expect(said == [1, nil, 2, nil, nil, 1])
    }
}
