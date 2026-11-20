// ChangesPanelTotalsComparisonTests.swift
// Weir — the comparison the changes panel's list holds for its totals, the one the panel asks Git to count.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// The panel refreshes its counts by the comparison its list holds, so the
/// list must hold the one the totals read (`ChangesPanelModel.totalsComparison`)
/// for every reading: an unviewed range, nothing unviewed, and a list
/// narrowed to one conversation, whose totals stay the worktree's.
struct ChangesPanelTotalsComparisonTests {
    typealias Panel = ChangesPanelFixture

    @Test func theList_holdsTheComparisonTheTotalsRead() throws {
        let old = try TurnSummaryFixture.timed(1, start: 0, end: 10)
        let recent = try TurnSummaryFixture.timed(2, start: 1000, end: 1100)
        let other = try TurnSummaryFixture.timed(1, conversation: "s2", start: 2000, end: 2100)
        let agents = Panel.agents([old, recent, other])
        let viewedOld = Panel.line(through: old).line
        let unviewed = Panel.input(agents, lines: [viewedOld])
        let expected = try WorktreeChanges.Comparison(begin: #require(recent.beginTree).tree, end: #require(other.endTree).tree)
        #expect(ChangesPanelModel.totalsComparison(unviewed) == expected)
        #expect(try Panel.list(ChangesPanelModel.make(unviewed)).totalsComparison == expected)

        let narrowed = Panel.input(agents, lines: [viewedOld], chosen: TurnSummaryFixture.conversation("s2", provider: .claude))
        #expect(try Panel.list(ChangesPanelModel.make(narrowed)).totalsComparison == expected, "the worktree's range, whatever the filter")

        let allViewed = Panel.input(agents, lines: [Panel.line(through: recent).line, Panel.line(through: other).line])
        #expect(ChangesPanelModel.totalsComparison(allViewed) == nil)
        #expect(try Panel.list(ChangesPanelModel.make(allViewed)).totalsComparison == nil)
    }
}
