// DecisionBarLifetimeTests.swift
// Weir — a pane's decision bar keeps its chosen item until the person moves on, and its "Done" line until the run does.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct DecisionBarLifetimeTests {
    private static let item = AttentionItemID.prompt(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))

    private static func prompt(in pane: UUID) -> AttentionItem {
        AttentionItem(
            id: item,
            kind: .prompt(.unclassified(detail: nil)),
            subject: .runtime(id: "a", provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivalSequence: 1,
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func window(choosing panes: UUID...) -> ProjectWindowState {
        let window = ProjectWindowState(id: WindowID())
        for pane in panes {
            window.decisionBarSelection[pane] = item
            window.decisionBarDone[pane] = .answeredInTerminal
        }
        return window
    }

    @Test func movingOnFromAPane_endsOnlyItsChoiceAndLines() {
        let (left, arrived) = (UUID(), UUID())
        let window = Self.window(choosing: left, arrived)
        window.pendingDecisionBarDone = [left: .insertedReview(agent: .claude), arrived: .resumed]

        window.keyboardMoved(from: left, livePanes: [left, arrived])

        #expect(window.decisionBarSelection == [arrived: Self.item])
        #expect(window.decisionBarDone == [arrived: .answeredInTerminal])
        #expect(window.pendingDecisionBarDone == [arrived: .resumed])
    }

    @Test func panesTheSessionNoLongerHas_loseChoicesAndBothKindsOfLine() {
        let (selectionOnly, shownOnly, pendingOnly, kept) = (UUID(), UUID(), UUID(), UUID())
        let window = Self.window(choosing: kept)
        window.decisionBarSelection[selectionOnly] = Self.item
        window.decisionBarDone[shownOnly] = .insertedReview(agent: .claude)
        window.pendingDecisionBarDone = [pendingOnly: .resumed, kept: .answeredInTerminal]

        window.keyboardMoved(from: nil, livePanes: [kept])

        #expect(window.decisionBarSelection == [kept: Self.item])
        #expect(window.decisionBarDone == [kept: .answeredInTerminal])
        #expect(window.pendingDecisionBarDone == [kept: .answeredInTerminal])
    }

    // MARK: - The "Done" line as items and runs change

    private static func itemsGone(
        from shown: ProjectWindowState.ShownItem,
        pane: UUID,
        epoch: Int?,
        in window: ProjectWindowState,
        isSelectedPane: Bool = true
    ) {
        window.itemsChanged(
            .init(paneID: pane, items: [], lastShown: shown, epoch: epoch),
            isSelectedPane: isSelectedPane,
            isCurrent: { _ in true }
        )
    }

    @Test(arguments: [
        (Optional(3), Optional(3), true),
        (3, 4, false),
        (3, nil, false),
        (nil, 3, false),
        (nil, nil, false)
    ])
    func removingAPrompt_setsTheDoneLineOnlyWithinTheSameEpoch(shownEpoch: Int?, epoch: Int?, showsAnswer: Bool) {
        let window = ProjectWindowState(id: WindowID())
        let pane = UUID()
        let item = Self.prompt(in: pane)
        Self.itemsGone(from: .init(item: item, epoch: shownEpoch), pane: pane, epoch: epoch, in: window)
        #expect(window.decisionBarDone == (showsAnswer ? [pane: .answeredInTerminal] : [:]))
    }

    @Test func aLine_isSetOnlyInThePaneWithTheKeyboard() {
        let window = ProjectWindowState(id: WindowID())
        let pane = UUID()
        let shown = ProjectWindowState.ShownItem(item: Self.prompt(in: pane), epoch: 1)
        Self.itemsGone(from: shown, pane: pane, epoch: 1, in: window, isSelectedPane: false)
        #expect(window.decisionBarDone.isEmpty)
    }
}

// MARK: - The "Done" line and the runs

/// A bar's "Done" line, set or pending, lasts until its pane's run moves on
/// to its next turn (`WindowRegistry.noteRuns`).
extension DecisionBarLifetimeTests {
    private static func run(_ id: String, in pane: UUID, turn: String?, state: AgentState = .finished) -> PaneRunLedger.Run {
        PaneRunLedger.Run.test(id, in: [pane], turn: turn, state: state)
    }

    /// One pass as the app makes it: the runs are noted, then the bar sees
    /// its items change, as `AppState.refreshAttentionQueue` and the bar's
    /// change handler do.
    private static func pass(
        _ runs: [PaneRunLedger.Run],
        itemsNow items: [AttentionItem],
        shown: ProjectWindowState.ShownItem?,
        pane: UUID,
        registry: WindowRegistry
    ) {
        registry.noteRuns(runs)
        registry.primary.itemsChanged(
            .init(paneID: pane, items: items, lastShown: shown, epoch: registry.epoch(inPane: pane)),
            isSelectedPane: true,
            isCurrent: { _ in true }
        )
    }

    @Test func aPromptAnsweredInTheTurn_setsTheLine_untilTheNextTurn() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        let item = Self.prompt(in: pane)
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .needsInput)])
        let shown = ProjectWindowState.ShownItem(item: item, epoch: registry.epoch(inPane: pane))

        Self.pass([Self.run("a", in: pane, turn: "t1", state: .running)], itemsNow: [], shown: shown, pane: pane, registry: registry)
        #expect(registry.primary.decisionBarDone[pane] == .answeredInTerminal)
        registry.primary.pendingDecisionBarDone[pane] = .insertedReview(agent: .claude)

        registry.noteRuns([Self.run("a", in: pane, turn: "t2", state: .running)])
        #expect(registry.primary.decisionBarDone[pane] == nil)
        #expect(registry.primary.pendingDecisionBarDone[pane] == nil)
    }

    @Test(arguments: [false, true])
    func removingAPromptAlongsideAnExitOrNewTurn_setsNoDoneLine(exits: Bool) throws {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .needsInput)])
        let initialEpoch = try #require(registry.epoch(inPane: pane))
        let item = Self.prompt(in: pane)
        let shown = ProjectWindowState.ShownItem(item: item, epoch: initialEpoch)
        let updated = exits ? Self.run("a", in: pane, turn: "t1", state: .unknown) : Self.run("a", in: pane, turn: "t2", state: .running)

        Self.pass([updated], itemsNow: [], shown: shown, pane: pane, registry: registry)

        let next = registry.epoch(inPane: pane)
        if exits {
            #expect(next == nil)
        } else {
            #expect(try #require(next) != initialEpoch)
        }
        #expect(registry.primary.decisionBarDone.isEmpty)
    }

    @Test func aResumedLine_setInThePassThatBringsItsRunBack_staysAsTheOldRunGoes() throws {
        let registry = WindowRegistry(primary: WindowSelection())
        let primary = registry.primary
        let requesting = registry.addWindow(WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("old", in: pane, turn: "t1", state: .error)])
        let before = try #require(registry.epoch(inPane: pane))
        primary.decisionBarDone[pane] = .answeredInTerminal
        primary.pendingDecisionBarDone[pane] = .insertedReview(agent: .claude)
        requesting.decisionBarDone[pane] = .answeredInTerminal
        requesting.pendingDecisionBarDone[pane] = .insertedReview(agent: .claude)

        // A new turn on the old run invalidates its lines in the same pass
        // that a resumed run is recorded for the requesting window.
        let new = Self.run("resumed", in: pane, turn: nil, state: .idle)
        registry.noteRuns(
            [Self.run("old", in: pane, turn: "t2", state: .error), new],
            endedStops: StopLedger.Ended(resumed: [StopLedger.Resumed(paneID: pane, window: requesting.id)])
        )
        let after = try #require(registry.epoch(inPane: pane))
        #expect(after != before)
        #expect(primary.decisionBarDone.isEmpty)
        #expect(primary.pendingDecisionBarDone.isEmpty)
        #expect(requesting.decisionBarDone.isEmpty)
        #expect(requesting.pendingDecisionBarDone == [pane: .resumed])

        registry.noteRuns([new])

        #expect(registry.epoch(inPane: pane) == after)
        #expect(requesting.pendingDecisionBarDone == [pane: .resumed])
    }

    @Test func aResumedLine_isNotSet_forARunThatBeganATurn_orWithNoWindow() {
        let registry = WindowRegistry(primary: WindowSelection())
        let window = registry.primary
        let typedOn = UUID()
        let unasked = UUID()
        registry.noteRuns(
            [Self.run("a", in: typedOn, turn: "t1", state: .running), Self.run("b", in: unasked, turn: nil, state: .idle)],
            endedStops: StopLedger.Ended(resumed: [
                StopLedger.Resumed(paneID: typedOn, window: window.id, hasBegunATurn: true),
                StopLedger.Resumed(paneID: unasked, window: nil)
            ])
        )
        #expect(window.pendingDecisionBarDone.isEmpty)
    }

    @Test(arguments: [false, true])
    func aStoppedRunsLinesRemainUntilItsPaneMovesToAnotherConversation(reportsExit: Bool) throws {
        let registry = WindowRegistry(primary: WindowSelection())
        let window = registry.primary
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: .error)])
        window.decisionBarDone[pane] = .answeredInTerminal
        window.pendingDecisionBarDone[pane] = .resumed

        registry.noteRuns(reportsExit ? [Self.run("a", in: pane, turn: "t1", state: .unknown)] : [])
        #expect(registry.epoch(inPane: pane) == nil)
        #expect(window.decisionBarDone == [pane: .answeredInTerminal])
        #expect(window.pendingDecisionBarDone == [pane: .resumed])

        let next = Self.run("b", in: pane, turn: nil, state: .idle)
        registry.noteRuns([next])
        #expect(window.decisionBarDone == [pane: .answeredInTerminal])
        #expect(window.pendingDecisionBarDone == [pane: .resumed])
        let before = try #require(registry.epoch(inPane: pane))

        registry.noteRuns([next], endedStops: StopLedger.Ended(movedOn: [pane]))

        #expect(window.decisionBarDone.isEmpty)
        #expect(window.pendingDecisionBarDone.isEmpty)
        #expect(try #require(registry.epoch(inPane: pane)) != before)
    }

    @Test(arguments: [AgentState.finished, .error])
    func everyWindow_endsTheLinesOfThePanesThatMovedOn(previousState: AgentState) {
        let registry = WindowRegistry(primary: WindowSelection())
        let second = registry.addWindow(WindowSelection())
        let pane = UUID()
        let other = UUID()
        let unchanged = Self.run("b", in: other, turn: "t1")
        registry.noteRuns([Self.run("a", in: pane, turn: "t1", state: previousState), unchanged])
        for window in [registry.primary, second] {
            window.decisionBarSelection[pane] = Self.item
            window.decisionBarDone[pane] = .insertedReview(agent: .claude)
            window.pendingDecisionBarDone[pane] = .resumed
        }
        second.decisionBarDone[other] = .answeredInTerminal
        second.pendingDecisionBarDone[other] = .insertedReview(agent: .codex)

        registry.noteRuns([Self.run("a", in: pane, turn: "t2", state: .running), unchanged])

        #expect(registry.primary.decisionBarDone.isEmpty)
        #expect(registry.primary.pendingDecisionBarDone.isEmpty)
        #expect(second.decisionBarDone == [other: .answeredInTerminal])
        #expect(second.pendingDecisionBarDone == [other: .insertedReview(agent: .codex)])
        #expect(registry.primary.decisionBarSelection == [pane: Self.item])
        #expect(second.decisionBarSelection == [pane: Self.item])
    }

    @Test func afterAProjectSwitchInPlace_theNewProjectsLineEndsWithItsTurn() throws {
        let fixture = ProjectWindowsFixture()
        let window = fixture.primary
        let firstPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let pane = try #require(fixture.bTab.splitTree.allLeafIDs().first)
        let left = Self.run("left", in: firstPane, turn: "t1")
        fixture.registry.noteRuns([left, Self.run("right", in: pane, turn: "t1")])
        let leftEpoch = try #require(fixture.registry.epoch(inPane: firstPane))
        let rightEpoch = try #require(fixture.registry.epoch(inPane: pane))

        fixture.choose(fixture.bTab, in: window)
        #expect(fixture.registry.primary === window)
        #expect(window.selection.shownProjectID == fixture.b.id)
        #expect(fixture.registry.epoch(inPane: firstPane) == leftEpoch)
        #expect(fixture.registry.epoch(inPane: pane) == rightEpoch)
        window.decisionBarDone[pane] = .insertedReview(agent: .claude)
        window.pendingDecisionBarDone[pane] = .resumed

        fixture.registry.noteRuns([left, Self.run("right", in: pane, turn: "t2", state: .running)])

        #expect(window.decisionBarDone.isEmpty)
        #expect(window.pendingDecisionBarDone.isEmpty)
        #expect(fixture.registry.epoch(inPane: firstPane) == leftEpoch)
        #expect(try #require(fixture.registry.epoch(inPane: pane)) != rightEpoch)
    }

    @Test func aRunBetweenTmuxAttachments_keepsItsLine() {
        let registry = WindowRegistry(primary: WindowSelection())
        let pane = UUID()
        registry.noteRuns([Self.run("a", in: pane, turn: "t1")])
        registry.primary.decisionBarDone[pane] = .insertedReview(agent: .claude)

        // The run names no pane for a moment, then the same one again.
        registry.noteRuns([PaneRunLedger.Run.test("a", in: [], turn: "t1")])
        registry.noteRuns([Self.run("a", in: pane, turn: "t1")])
        #expect(registry.primary.decisionBarDone[pane] == .insertedReview(agent: .claude))
    }
}
