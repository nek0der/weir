// TabActionsTests.swift
// Weir — tab-level verbs that wrap WorkspaceSession mutations: close,
// reopen (closed-tab stack), the stack's cap, and a new tab that types a
// command. Pane-level verbs (zoom / split / focusPane / equalizeSplits /
// closeActivePane) live in `PaneActionsTests.swift` so the file/suite name
// tracks the namespace it covers.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("TabActions")
struct TabActionsTests {
    @Test func reopenClosedTab_toldOfThePanesNewIDs_beforeTheTabIsInTheSession() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.recordClosedTab(tab)
        session.closeTab(tab.id)
        var told: [UUID: UUID] = [:]
        var tabCountsWhenTold: [Int] = []
        session.onTabReopening = { [weak session] closed, paneIDs in
            #expect(closed.id == tab.id)
            told = paneIDs
            if let session {
                tabCountsWhenTold.append(session.tabs.count)
            }
        }
        let before = session.tabs.count
        TabActions.reopenClosedTab(session)
        #expect(tabCountsWhenTold == [before])
        let new = try #require(told[pane])
        #expect(told == [pane: new])
        #expect(new != pane)
        #expect(session.activeTab(in: session.primaryWindowID)?.splitTree.allLeafIDs() == [new])
    }

    // MARK: - Reopen closed tab

    @Test("closeTab pushes a ClosedTab snapshot of the full Tab")
    func closeTab_pushesClosedTabSnapshot() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        session.update(tab.id) { t in
            t.titleOverride = "build"
            t.workingDirectory = "/tmp/weir-test-cwd"
        }
        let before = try #require(session.tab(tab.id))

        TabActions.closeTab(session, registry: registry, tabID: tab.id)

        #expect(session.closedTabStack.count == 1)
        let closed = session.closedTabStack.last
        #expect(closed?.tab == before)
        #expect(session.tab(tab.id) == nil)
        #expect(closed?.tab.container == .loose)
        #expect(closed?.tab.displayTitle == "build")
        #expect(closed?.tab.workingDirectory == "/tmp/weir-test-cwd")
        // No SurfaceView in the noop registry, so no paths captured.
        #expect(closed?.tab.scrollbackPaths.isEmpty == true)
    }

    @Test("reopenClosedTab recreates the tab with a fresh id at the same container + cwd")
    func reopenClosedTab_popsAndRecreates() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        let originalID = tab.id
        session.update(tab.id) { t in
            t.titleOverride = "restore-me"
            t.workingDirectory = "/tmp/weir-test-cwd"
        }
        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        #expect(session.tab(originalID) == nil)
        #expect(session.closedTabStack.count == 1)

        TabActions.reopenClosedTab(session)

        #expect(session.closedTabStack.isEmpty)
        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        #expect(revived.id != originalID) // new identity, not the same Tab
        #expect(revived.displayTitle == "restore-me")
        #expect(revived.workingDirectory == "/tmp/weir-test-cwd")
        #expect(revived.container == .loose)
    }

    @Test("a reopened scratch tab keeps the prefix, color, and folder default it kept from its group")
    func reopenClosedTab_keepsPrefixColorCwd() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.namePrefix = "prod"
            t.paletteIndex = 3
            t.cwdMode = .fixed
            t.cwdPath = URL(fileURLWithPath: "/tmp/servers")
        }
        TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)

        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        #expect(revived.namePrefix == "prod")
        #expect(revived.paletteIndex == 3)
        #expect(revived.cwdMode == .fixed)
        #expect(revived.cwdPath == URL(fileURLWithPath: "/tmp/servers"))
    }

    @Test("reopenClosedTab rebuilds the split tree with remapped pane IDs")
    func reopenClosedTab_splitTab_restoresLayout() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.split(session, direction: .vertical)
        // Snapshot the original split-tree structure before close.
        let originalLeafIDs = try #require(session.tab(tab.id)?.splitTree.allLeafIDs())
        try #require(originalLeafIDs.count == 3)

        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        let ids = revived.splitTree.allLeafIDs()
        try #require(ids.count == 3)
        let right = PaneSplit(direction: .vertical, ratio: 0.5, first: .leaf(id: ids[1]), second: .leaf(id: ids[2]))
        let root = PaneSplit(direction: .horizontal, ratio: 0.5, first: .leaf(id: ids[0]), second: .split(right))
        #expect(revived.splitTree == SplitTree(root: .split(root), focusedLeafID: ids[2]))
        // None of the new leaf IDs should equal any of the originals —
        // remapping guarantees fresh UUIDs so the registry doesn't
        // collide with whatever the previous SurfaceViews held.
        let revivedLeafIDs = Set(ids)
        #expect(revivedLeafIDs.count == 3)
        #expect(revivedLeafIDs.isDisjoint(with: Set(originalLeafIDs)))
    }

    @Test("reopenClosedTab preserves the zoomed leaf and remaps it to the new id")
    func reopenClosedTab_zoomedTab_preservesZoomViaRemap() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.toggleZoom(session)
        let zoomedBefore = try #require(session.tab(tab.id)?.zoomedLeafID)
        let zoomedPosition = try #require(session.tab(tab.id)?.splitTree.allLeafIDs().firstIndex(of: zoomedBefore))

        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        let zoomedAfter = try #require(revived.zoomedLeafID)
        // Same logical position (zoomed leaf still present), fresh UUID.
        #expect(zoomedAfter != zoomedBefore)
        #expect(revived.splitTree.allLeafIDs().firstIndex(of: zoomedAfter) == zoomedPosition)
    }

    @Test("reopenClosedTab preserves paneStates with remapped pane IDs")
    func reopenClosedTab_paneStates_areRemapped() throws {
        let (session, tab, paneA) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        // Stamp paneA's PaneState with an unread count so we can spot
        // it after the round-trip.
        session.markUnread(paneID: paneA)
        #expect(session.tab(tab.id)?.paneStates[paneA]?.unreadCount == 1)

        TabActions.closeTab(session, registry: registry, tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        // PaneA's id should have been remapped to a fresh UUID, and
        // the PaneState should have moved to that new key intact.
        let newPaneID = try #require(revived.splitTree.allLeafIDs().first)
        #expect(newPaneID != paneA)
        #expect(revived.paneStates[newPaneID]?.unreadCount == 1)
        #expect(revived.paneStates[paneA] == nil) // old id is gone
    }

    /// Closed before its terminal was made, a pane comes back with its
    /// staged launch under its new id, the sheet's executable with it.
    @Test("reopenClosedTab remaps the staged executable with the pane")
    func reopenClosedTab_stagedExecutable_isRemapped() throws {
        let (session, tab, paneA) = WorkspaceSessionFixture.withLooseTab()
        let found = AgentInstallation(kind: .claude, executable: "/opt/tools/bin/claude")
        session.update(tab.id) { $0.initialCommands[paneA] = "claude" }
        session.stageAgentExecutable(found, paneID: paneA)

        TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        let newPaneID = try #require(revived.splitTree.allLeafIDs().first)
        #expect(newPaneID != paneA)
        #expect(revived.initialAgentExecutables == [newPaneID: found])
    }

    /// The conversation that named the row names it again, in the pane it
    /// ran in under that pane's new id.
    @Test("reopenClosedTab keeps the conversation name, in the remapped pane")
    func reopenClosedTab_conversationName_isRemapped() throws {
        let (session, tab, paneA) = WorkspaceSessionFixture.withLooseTab()
        let name = ConversationName(
            name: "Add tests",
            provider: .claude,
            paneID: paneA,
            conversationID: "c",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        session.update(tab.id) { $0.conversationName = name }

        TabActions.closeTab(session, registry: NoopSurfaceRegistry(), tabID: tab.id)
        TabActions.reopenClosedTab(session)

        let revived = try #require(session.activeTab(in: session.primaryWindowID))
        let newPaneID = try #require(revived.splitTree.allLeafIDs().first)
        #expect(newPaneID != paneA)
        #expect(revived.conversationName?.name == "Add tests")
        #expect(revived.conversationName?.paneID == newPaneID)
        #expect(revived.conversationName?.conversationID == "c")
        #expect(revived.conversationName?.startedAt == name.startedAt)
    }

    @Test("reopenClosedTab on an empty stack is a no-op")
    func reopenClosedTab_emptyStack_doesNothing() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let tabCountBefore = session.tabs.count
        TabActions.reopenClosedTab(session)
        #expect(session.tabs.count == tabCountBefore)
    }

    @Test("closedTabStack caps at closedTabStackLimit, oldest dropped")
    func closeTab_overLimit_dropsOldest() {
        let session = WorkspaceSession()
        let registry = NoopSurfaceRegistry()
        // Open + close enough tabs to overflow the stack by one.
        let extra = 3
        for i in 0..<(WorkspaceSession.closedTabStackLimit + extra) {
            let tab = session.openTab(container: .loose, title: "tab-\(i)")
            TabActions.closeTab(session, registry: registry, tabID: tab.id)
        }
        let expected = (extra..<(WorkspaceSession.closedTabStackLimit + extra)).map { "tab-\($0)" }
        #expect(session.closedTabStack.map(\.tab.displayTitle) == expected)
    }

    // MARK: - A tab that types a command

    @Test func aTabTypingACommand_opensInTheContainer_withTheCommandStagedOnce() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let container = ContainerID.project(project.id)
        TabActions.newTab(session, in: container, typing: CommitAndPRActions.createPullRequestCommand)
        let tab = try #require(session.activeTab(in: session.primaryWindowID))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        #expect(tab.container == container)
        #expect(tab.initialCommands == [pane: "gh pr create --fill"])
        #expect(session.stagedLaunch(paneID: pane)?.command == "gh pr create --fill")
        session.clearStagedLaunch(paneID: pane)
        #expect(session.stagedLaunch(paneID: pane) == nil)
        #expect(session.tab(tab.id)?.initialCommands.isEmpty == true)
    }
}
