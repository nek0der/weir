// CloseConfirmationFlowTests.swift
// Weir — a tab or pane closes only once its confirmation says yes, on what is still there then, and not when the confirmation's
// window closed first.

import AppKit
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Each test sets `CloseConfirmer.gate` and puts it back before it returns.
/// The tests are synchronous on the main actor, so no other test that
/// closes a tab runs while the gate is ours.
@MainActor
@Suite("Close confirmation flow")
struct CloseConfirmationFlowTests {
    /// Holds the question the gate was asked and the way to answer it.
    @MainActor
    private final class PendingGate {
        var requests: [CloseConfirmer.Request] = []
        var answer: (@MainActor (Bool) -> Void)?

        func install() {
            CloseConfirmer.gate = { [self] request, answer in
                requests.append(request)
                self.answer = answer
            }
        }
    }

    private func withGate(_ body: (PendingGate) throws -> Void) rethrows {
        let previous = CloseConfirmer.gate
        defer { CloseConfirmer.gate = previous }
        let gate = PendingGate()
        gate.install()
        try body(gate)
    }

    @Test func aTab_closesOnlyOnceTheAnswerIsYes() throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
            // Asked, and still open while the question is up.
            #expect(gate.requests.map(\.paneIDs) == [[pane]])
            #expect(session.tab(tab.id) != nil)
            let answer = try #require(gate.answer)
            answer(true)
            #expect(session.tab(tab.id) == nil)
            #expect(session.closedTabStack.count == 1)
        }
    }

    @Test func aTab_staysWhenTheAnswerIsNo() throws {
        try withGate { gate in
            let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
            TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
            let answer = try #require(gate.answer)
            answer(false)
            #expect(session.tab(tab.id) != nil)
            #expect(session.closedTabStack.isEmpty)
        }
    }

    @Test func aTabGoneBeforeTheAnswer_isNotClosedAgain() throws {
        try withGate { gate in
            let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
            TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
            // Closed some other way (its shell exited) while the question was up.
            session.closeTab(tab.id)
            let answer = try #require(gate.answer)
            answer(true)
            // No second close: nothing was snapshotted for reopening.
            #expect(session.closedTabStack.isEmpty)
        }
    }

    @Test func aPane_closesOnlyOnceTheAnswerIsYes_andOnlyThatPane() throws {
        try withGate { gate in
            let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
            CloseConfirmer.gate = nil
            PaneActions.split(session, direction: .horizontal)
            gate.install()
            let focused = try #require(session.tab(tab.id)?.splitTree.effectiveFocusedLeafID)
            #expect(focused != first)
            PaneActions.closeActivePane(session, registry: NoopSurfaceRegistry())
            #expect(session.tab(tab.id)?.splitTree.allLeafIDs().count == 2)
            // The window moves its focus to the other pane while the
            // question is up; the answer still closes the pane it was about.
            session.update(tab.id) { $0.splitTree.focusedLeafID = first }
            let answer = try #require(gate.answer)
            answer(true)
            #expect(session.tab(tab.id)?.splitTree.allLeafIDs() == [first])
        }
    }

    @Test func aPaneGoneBeforeTheAnswer_leavesTheTabAsItIs() throws {
        try withGate { gate in
            let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
            CloseConfirmer.gate = nil
            PaneActions.split(session, direction: .horizontal)
            gate.install()
            let focused = try #require(session.tab(tab.id)?.splitTree.effectiveFocusedLeafID)
            PaneActions.closeActivePane(session, registry: NoopSurfaceRegistry())
            // Its shell exited while the question was up.
            session.update(tab.id) { $0.splitTree = $0.splitTree.remove(focused).tree }
            let answer = try #require(gate.answer)
            answer(true)
            #expect(session.tab(tab.id)?.splitTree.allLeafIDs() == [first])
        }
    }

    @Test func aSheetAnswerCancelledByItsWindow_closesNothing() throws {
        try withGate { gate in
            let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
            TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
            let answer = try #require(gate.answer)
            // The sheet's answer, as `WindowAlert.begin` gives it.
            let sheet = SheetAnswer { answer($0 == .alertFirstButtonReturn) }
            sheet.parentClosed()
            // A late click on the sheet's Close is dropped.
            sheet.give(.alertFirstButtonReturn)
            #expect(session.tab(tab.id) != nil)
            #expect(session.closedTabStack.isEmpty)
        }
    }

    @Test func aTabThatSplitWhileAsked_stays() throws {
        try withGate { gate in
            let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
            TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
            // A pane no one was asked about appears while the question is up.
            CloseConfirmer.gate = nil
            PaneActions.split(session, direction: .horizontal)
            let answer = try #require(gate.answer)
            answer(true)
            #expect(session.tab(tab.id)?.splitTree.allLeafIDs().count == 2)
        }
    }

    @Test func closeAllTabs_closesOnlyTheTabsItAskedAbout() throws {
        try withGate { gate in
            let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
            TabActions.closeAllTabs(session, registry: NoopSurfaceRegistry(), in: .loose, from: session.primaryWindowID)
            #expect(gate.requests.first?.window == session.primaryWindowID)
            let opened = session.openTab(container: .loose)
            let answer = try #require(gate.answer)
            answer(true)
            #expect(session.tab(tabA.id) == nil)
            #expect(session.tab(tabB.id) == nil)
            #expect(session.tab(opened.id) != nil)
        }
    }

    @Test func aPaneLeftAloneWhileAsked_closesAsItsTab_underTheCascade() throws {
        try withGate { gate in
            let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
            CloseConfirmer.gate = nil
            PaneActions.split(session, direction: .horizontal)
            gate.install()
            let focused = try #require(session.tab(tab.id)?.splitTree.effectiveFocusedLeafID)
            PaneActions.closeActivePaneOrTab(session, registry: NoopSurfaceRegistry(), in: session.primaryWindowID)
            // The sibling's shell exits while the question is up.
            session.update(tab.id) { $0.splitTree = $0.splitTree.remove(first).tree }
            #expect(session.tab(tab.id)?.splitTree.allLeafIDs() == [focused])
            let answer = try #require(gate.answer)
            answer(true)
            // Closed as a tab, so it can be reopened.
            #expect(session.tab(tab.id) == nil)
            #expect(session.closedTabStack.count == 1)
        }
    }

    @Test func closeAllTabs_leavesATabThatSplitWhileAsked() throws {
        try withGate { gate in
            let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
            TabActions.closeAllTabs(session, registry: NoopSurfaceRegistry(), in: .loose)
            // The active tab, A, splits while the question is up.
            CloseConfirmer.gate = nil
            PaneActions.split(session, direction: .horizontal)
            let answer = try #require(gate.answer)
            answer(true)
            #expect(session.tab(tabA.id)?.splitTree.allLeafIDs().count == 2)
            #expect(session.tab(tabB.id) == nil)
        }
    }

    @Test func aSheet_answersOnce() {
        let record = SheetRecord()
        let sheet = SheetAnswer { record.responses.append($0) }
        sheet.onFinish = { record.finishes += 1 }
        sheet.give(.alertSecondButtonReturn)
        sheet.parentClosed()
        sheet.give(.alertFirstButtonReturn)
        #expect(record.responses == [.alertSecondButtonReturn])
        #expect(record.finishes == 1)
    }

    /// What a sheet answered, for `aSheet_answersOnce`.
    @MainActor
    private final class SheetRecord {
        var responses: [NSApplication.ModalResponse] = []
        var finishes = 0
    }

    /// Asks to close the tab's one pane, and says whether the question
    /// the gate got is about a pane that carries an agent, as
    /// `AppState.confirmClose` reads it for the `onlyWhenAgent` policy.
    private func asksAboutAnAgent(closing tab: Tab, in session: WorkspaceSession, gate: PendingGate) throws -> Bool {
        TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
        let request = try #require(gate.requests.last)
        return session.hasLiveAgent(inAnyOf: request.paneIDs)
    }

    @Test func aCodexJustTypedIntoAShell_isAskedAbout_beforeItHasARecord() throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            // Codex writes its record at its first prompt; until then only
            // its terminal's job in front says it is there.
            PaneAgentInFrontFollower(session: session).apply(.agent(.codex), at: .titleChanged, inPane: pane)
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(isAsked)
        }
    }

    @Test(arguments: AgentKind.allCases)
    func anAgentOpenedByTheStripsPlus_isAskedAbout_beforeItIsInFront(kind: AgentKind) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.update(tab.id) { $0.agentsInFront[pane] = PaneAgentInFront(kind: kind, isStaged: true) }
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(isAsked)
        }
    }

    @Test(arguments: AgentKind.allCases)
    func anAgentStartedWithoutHooks_isAskedAbout_thoughItNeverWritesARecord(kind: AgentKind) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let follower = PaneAgentInFrontFollower(session: session)
            follower.apply(.agent(kind), at: .titleChanged, inPane: pane)
            // A command it runs finishes under it; the agent is still in
            // front, and no hook ever places a run in the pane.
            follower.apply(.agent(kind), at: .commandFinished, inPane: pane)
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(isAsked)
        }
    }

    @Test(arguments: AgentKind.allCases)
    func aRunRestoredAtLaunch_isAskedAbout_whileItsStateIsUnknown(kind: AgentKind) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            session.update(tab.id) { $0.agentBadges[kind] = [pane: AgentBadge(state: .unknown, updatedAt: Date())] }
            // Its resume is typed into the restored pane and waits at the
            // agent's prompt, which reports nothing until the person types.
            PaneAgentInFrontFollower(session: session).apply(.agent(kind), at: .titleChanged, inPane: pane)
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(isAsked)
        }
    }

    @Test(arguments: AgentKind.allCases)
    func aRunRestoredInWeirsTmux_isAskedAbout_withNothingReadInFront(kind: AgentKind) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            var badge = AgentBadge(state: .unknown, updatedAt: Date())
            badge.isTmuxHosted = true
            session.update(tab.id) { $0.agentBadges[kind] = [pane: badge] }
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(isAsked)
        }
    }

    @Test func aRunWhoseAgentEnded_isNotAskedAbout_whileItsBadgeWaitsForTheSweep() throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let follower = PaneAgentInFrontFollower(session: session)
            follower.apply(.agent(.claude), at: .titleChanged, inPane: pane)
            // `/exit`: SessionEnd leaves the record unknown, and the shell's
            // prompt comes back.
            session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .unknown, updatedAt: Date())] }
            follower.apply(.none, at: .commandFinished, inPane: pane)
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(!isAsked)
        }
    }

    @Test func aPaneWhoseAgentLeftForTheShell_isNotAskedAbout() throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let follower = PaneAgentInFrontFollower(session: session)
            follower.apply(.agent(.codex), at: .titleChanged, inPane: pane)
            follower.apply(.none, at: .commandFinished, inPane: pane)
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(!isAsked)
        }
    }

    @Test func aPlainShell_isNotAskedAbout() throws {
        try withGate { gate in
            let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
            let isAsked = try asksAboutAnAgent(closing: tab, in: session, gate: gate)
            #expect(!isAsked)
        }
    }

    @Test func withNoGate_theCloseHappensAtOnce() {
        let previous = CloseConfirmer.gate
        defer { CloseConfirmer.gate = previous }
        CloseConfirmer.gate = nil
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
        #expect(session.tab(tab.id) == nil)
    }
}
