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

    @Test(arguments: [false, true])
    func aTabClosesOnlyAfterApproval(approves: Bool) throws {
        try withGate { gate in
            let (session, target, first, unrelated, _) = WorkspaceSessionFixture.withTwoLooseTabs()
            let registry = NoopSurfaceRegistry()
            PaneActions.split(session, direction: .horizontal)
            let leaves = try #require(session.tab(target.id)?.splitTree.allLeafIDs())
            try #require(leaves.count == 2 && leaves.contains(first))
            let window = session.primaryWindowID

            TabActions.closeTab(session, registry: registry, tabID: target.id, in: window)

            try checkRequest(gate, kind: .tab, source: .keyboard, panes: leaves, window: window)
            #expect(session.tab(target.id)?.splitTree.allLeafIDs() == leaves)
            #expect(session.primarySelection.activeTabID == target.id)
            #expect(session.closedTabStack.isEmpty)
            if !approves {
                session.setActiveTab(unrelated.id, in: window, intent: .person)
            }
            let answer = try #require(gate.answer)
            answer(approves)

            #expect(session.tabs(in: .loose).map(\.id) == (approves ? [unrelated.id] : [unrelated.id, target.id]))
            #expect(session.primarySelection.activeTabID == unrelated.id)
            #expect(session.closedTabStack.map(\.tab.id) == (approves ? [target.id] : []))
            if approves {
                #expect(session.closedTabStack.first?.tab.splitTree.allLeafIDs() == leaves)
            } else {
                #expect(session.tab(target.id)?.splitTree.allLeafIDs() == leaves)
            }
            #expect(gate.requests.count == 1)
        }
    }

    private func checkRequest(
        _ gate: PendingGate,
        kind: CloseConfirmer.Kind,
        source: CloseConfirmer.Source,
        panes: [UUID],
        window: WindowID?
    ) throws {
        #expect(gate.requests.count == 1)
        let request = try #require(gate.requests.first)
        #expect(request.kind == kind)
        #expect(request.source == source)
        #expect(request.paneIDs == panes)
        #expect(request.window == window)
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

    enum PaneChange: CaseIterable {
        case focusMoved
        case requestedPaneExited
    }

    @Test(arguments: PaneChange.allCases)
    func anApprovedPaneCloseRespectsTheOriginalLeaf(_ change: PaneChange) throws {
        try withGate { gate in
            let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
            let registry = NoopSurfaceRegistry()
            PaneActions.split(session, direction: .horizontal)
            let split = try #require(session.tab(tab.id)?.splitTree)
            let requested = try #require(split.effectiveFocusedLeafID)
            try #require(requested != first)
            try #require(split.allLeafIDs().count == 2)
            let window = session.primaryWindowID

            PaneActions.closeActivePane(session, registry: registry, in: window)

            try checkRequest(gate, kind: .pane, source: .keyboard, panes: [requested], window: window)
            #expect(session.tab(tab.id)?.splitTree == split)
            #expect(session.closedTabStack.isEmpty)
            switch change {
            case .focusMoved:
                session.update(tab.id) { $0.splitTree.focusedLeafID = first }
                #expect(session.tab(tab.id)?.splitTree.effectiveFocusedLeafID == first)
            case .requestedPaneExited:
                PaneActions.removeClosedLeaf(
                    requested, fromTab: tab.id, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
                )
                #expect(session.tab(tab.id)?.splitTree.allLeafIDs() == [first])
            }
            let answer = try #require(gate.answer)
            answer(true)

            #expect(session.tabs.map(\.id) == [tab.id])
            #expect(session.tab(tab.id)?.splitTree.allLeafIDs() == [first])
            #expect(session.closedTabStack.isEmpty)
            #expect(gate.requests.count == 1)
        }
    }

    enum FirstSheetEvent: CaseIterable {
        case parentClosed
        case cancelButton
        case closeButton
    }

    @Test(arguments: FirstSheetEvent.allCases)
    func aCloseSheetUsesOnlyItsFirstResponse(_ event: FirstSheetEvent) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let window = session.primaryWindowID
            TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id, in: window)
            try checkRequest(gate, kind: .tab, source: .keyboard, panes: [pane], window: window)
            let answer = try #require(gate.answer)
            let record = SheetRecord()
            let sheet = SheetAnswer {
                record.responses.append($0)
                answer($0 == .alertFirstButtonReturn)
            }
            sheet.onFinish = { record.finishes += 1 }
            let expected: NSApplication.ModalResponse
            switch event {
            case .parentClosed:
                expected = .cancel
                sheet.parentClosed()
            case .cancelButton:
                expected = .alertSecondButtonReturn
                sheet.give(expected)
            case .closeButton:
                expected = .alertFirstButtonReturn
                sheet.give(expected)
            }
            sheet.parentClosed()
            sheet.give(.alertFirstButtonReturn)
            #expect(record.responses == [expected])
            #expect(record.finishes == 1)
            #expect((session.tab(tab.id) == nil) == (event == .closeButton))
            #expect(session.closedTabStack.map(\.tab.id) == (event == .closeButton ? [tab.id] : []))
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

    enum BulkChange: CaseIterable {
        case tabOpened
        case tabSplit
        case tabMoved
    }

    @Test(arguments: BulkChange.allCases)
    func closeAllTabsClosesOnlyTheOriginalUnchangedTabs(_ change: BulkChange) throws {
        try withGate { gate in
            let (session, tabA, paneA, tabB, paneB) = WorkspaceSessionFixture.withTwoLooseTabs()
            let window = session.primaryWindowID
            TabActions.closeAllTabs(session, registry: NoopSurfaceRegistry(), in: .loose, from: window)
            try checkRequest(gate, kind: .allTabs, source: .mouse, panes: [paneB, paneA], window: window)
            #expect(session.tabs(in: .loose).map(\.id) == [tabB.id, tabA.id])
            #expect(session.closedTabStack.isEmpty)

            let kept: Tab
            switch change {
            case .tabOpened:
                kept = session.openTab(container: .loose)
            case .tabSplit:
                PaneActions.split(session, direction: .horizontal)
                kept = try #require(session.tab(tabA.id))
                try #require(kept.splitTree.allLeafIDs().count == 2)
            case .tabMoved:
                let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("move"), suggestedName: "move")
                session.moveTab(tabA.id, to: .project(project.id))
                kept = try #require(session.tab(tabA.id))
                try #require(kept.container == .project(project.id))
            }
            let answer = try #require(gate.answer)
            answer(true)

            #expect(session.tabs.map(\.id) == [kept.id])
            #expect(session.tab(kept.id)?.splitTree.allLeafIDs() == kept.splitTree.allLeafIDs())
            #expect(session.tab(kept.id)?.container == kept.container)
            #expect(session.closedTabStack.map(\.tab.id) == (change == .tabOpened ? [tabB.id, tabA.id] : [tabB.id]))
            #expect(gate.requests.count == 1)
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

    @MainActor
    private final class SheetRecord {
        var responses: [NSApplication.ModalResponse] = []
        var finishes = 0
    }

    /// The model input to the app's only-when-agent policy.
    private func asksAboutAnAgent(closing tab: Tab, in session: WorkspaceSession, gate: PendingGate) throws -> Bool {
        let count = gate.requests.count
        let window = session.primaryWindowID
        TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id, in: window)
        #expect(gate.requests.count == count + 1)
        let request = try #require(gate.requests.last)
        #expect(request.kind == .tab)
        #expect(request.source == .keyboard)
        #expect(request.window == window)
        #expect(request.paneIDs == tab.splitTree.allLeafIDs())
        #expect(session.tab(tab.id) != nil)
        #expect(session.closedTabStack.isEmpty)
        return session.hasLiveAgent(inAnyOf: request.paneIDs)
    }

    @Test(arguments: AgentKind.allCases)
    func aStagedAgentFromTheStripProtectsTheNewPane(kind: AgentKind) throws {
        try withGate { gate in
            let session = WorkspaceSession()
            let pane = try #require(TabActions.newTab(session, in: .loose, running: kind))
            let tab = try #require(session.tab(containing: pane))
            #expect(tab.initialCommands == [pane: kind.launchCommand])
            #expect(tab.agentsInFront == [pane: PaneAgentInFront(kind: kind, isStaged: true)])
            #expect(tab.agentBadges.isEmpty)
            #expect(try asksAboutAnAgent(closing: tab, in: session, gate: gate))
        }
    }

    @Test(arguments: AgentKind.allCases)
    func aHooklessAgentProtectsItsPaneBeforeAndAfterAnInnerCommand(kind: AgentKind) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            PaneActions.split(session, direction: .horizontal)
            let split = try #require(session.tab(tab.id))
            let sibling = try #require(split.splitTree.allLeafIDs().first { $0 != pane })
            let follower = PaneAgentInFrontFollower(session: session)
            follower.apply(.agent(kind), at: .titleChanged, inPane: pane)
            let seen = try #require(session.tab(tab.id))
            #expect(seen.agentsInFront == [pane: PaneAgentInFront(kind: kind, isStaged: false)])
            #expect(seen.agentBadges.isEmpty)
            #expect(try asksAboutAnAgent(closing: seen, in: session, gate: gate))

            follower.apply(.agent(kind), at: .commandFinished, inPane: pane)
            let afterCommand = try #require(session.tab(tab.id))
            #expect(afterCommand.agentsInFront == seen.agentsInFront)
            #expect(afterCommand.agentBadges.isEmpty)
            #expect(try asksAboutAnAgent(closing: afterCommand, in: session, gate: gate))

            session.update(tab.id) { $0.splitTree.focusedLeafID = sibling }
            let count = gate.requests.count
            PaneActions.closeActivePane(session, registry: NoopSurfaceRegistry(), in: session.primaryWindowID)
            #expect(gate.requests.count == count + 1)
            let request = try #require(gate.requests.last)
            #expect(request.kind == .pane)
            #expect(request.paneIDs == [sibling])
            #expect(!session.hasLiveAgent(inAnyOf: request.paneIDs))
        }
    }

    @Test(arguments: AgentKind.allCases)
    func aRestoredUnknownRunIsProtectedAfterItsFirstForegroundReading(kind: AgentKind) throws {
        try withGate { gate in
            let (original, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            original.update(tab.id) {
                $0.agentBadges[kind] = [pane: AgentBadge(state: .unknown, updatedAt: Date())]
                $0.agentsInFront[pane] = PaneAgentInFront(kind: kind, isStaged: false)
            }
            let data = try JSONEncoder().encode(original.makeSnapshot())
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            let session = WorkspaceSession()
            #expect(session.restore(from: snapshot) == nil)
            let restored = try #require(session.tab(tab.id))
            #expect(restored.splitTree.allLeafIDs() == [pane])
            #expect(restored.agentBadges[kind]?[pane]?.state == .unknown)
            #expect(restored.agentBadges[kind]?[pane]?.isTmuxHosted != true)
            #expect(restored.agentsInFront.isEmpty)
            #expect(!session.hasLiveAgent(inAnyOf: [pane]))

            PaneAgentInFrontFollower(session: session).apply(.agent(kind), at: .titleChanged, inPane: pane)

            let observed = try #require(session.tab(tab.id))
            #expect(observed.agentsInFront == [pane: PaneAgentInFront(kind: kind, isStaged: false)])
            #expect(observed.agentBadges[kind]?[pane]?.state == .unknown)
            #expect(try asksAboutAnAgent(closing: observed, in: session, gate: gate))
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

    enum ShellHistory: CaseIterable {
        case neverHadAgent
        case agentReturnedToShell
        case endedRunBadgeRemains
    }

    @Test(arguments: ShellHistory.allCases)
    func aShellPaneDoesNotProtectTheClose(_ history: ShellHistory) throws {
        try withGate { gate in
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let follower = PaneAgentInFrontFollower(session: session)
            if history != .neverHadAgent {
                let kind: AgentKind = history == .endedRunBadgeRemains ? .claude : .codex
                follower.apply(.agent(kind), at: .titleChanged, inPane: pane)
                #expect(session.tab(tab.id)?.agentsInFront == [pane: PaneAgentInFront(kind: kind, isStaged: false)])
                #expect(session.hasLiveAgent(inAnyOf: [pane]))
                if history == .endedRunBadgeRemains {
                    session.update(tab.id) { $0.agentBadges[kind] = [pane: AgentBadge(state: .unknown, updatedAt: Date())] }
                }
                follower.apply(.none, at: .commandFinished, inPane: pane)
            }
            let shell = try #require(session.tab(tab.id))
            #expect(shell.agentsInFront.isEmpty)
            if history == .endedRunBadgeRemains {
                #expect(shell.agentBadges[.claude]?[pane]?.state == .unknown)
            } else {
                #expect(shell.agentBadges.isEmpty)
            }
            let carriesAgent = try asksAboutAnAgent(closing: shell, in: session, gate: gate)
            #expect(!carriesAgent)
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
