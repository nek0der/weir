// WorkspaceSessionTabsTests.swift
// Weir — covers the tab-level mutation surface that lives in
// `WorkspaceSession+Tabs.swift` (open, find, close, move, reorder). Pure
// in-memory mutations; no filesystem or libghostty involvement.

import Foundation
import Testing
@testable import Weir

@Suite("WorkspaceSession +Tabs")
@MainActor
struct WorkspaceSessionTabsTests {

    // MARK: - Helpers

    /// Three-piece test setup; struct rather than tuple so swiftlint's
    /// `large_tuple` rule stays happy.
    private struct Fixture {
        let session: WorkspaceSession
        let sourceID: UUID
        let tabs: [Tab]
    }

    /// Build a session with a source project containing `count` tabs.
    /// Tabs are returned in insertion order; the last one is active
    /// because `openTab` activates whatever it creates.
    private func makeSession(sourceTabCount: Int) -> Fixture {
        let session = WorkspaceSession()
        let source = Self.addProject(to: session, name: "Source")
        var madeTabs: [Tab] = []
        for _ in 0..<sourceTabCount {
            madeTabs.append(session.openTab(container: .project(source.id)))
        }
        return Fixture(session: session, sourceID: source.id, tabs: madeTabs)
    }

    /// A project at a path of its own, never touched on disk.
    private static func addProject(to session: WorkspaceSession, name: String) -> Project {
        session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL(name), suggestedName: name)
    }

    // MARK: - openTab / tab(containing:)

    @Test(arguments: [false, true])
    func openTab_addsOneFocusedPaneInTheRequestedRow(isProjectRoot: Bool) throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let scratchFolder = WorkspaceSessionFixture.projectRootURL("scratch")
        session.quickTabDefaultsProvider = { (mode: .fixed, path: scratchFolder) }
        let container: ContainerID = isProjectRoot ? .project(project.id) : .loose
        let other: ContainerID = isProjectRoot ? .loose : .project(project.id)
        let existing = session.openTab(container: other)

        let opened = session.openTab(container: container)

        let pane = try #require(opened.splitTree.allLeafIDs().first)
        #expect(opened.splitTree.allLeafIDs() == [pane])
        #expect(opened.splitTree.focusedLeafID == pane)
        #expect(opened.container == container)
        #expect(opened.projectID == (isProjectRoot ? project.id : nil))
        #expect(opened.worktreeID == nil)
        #expect(opened.workingDirectory == (isProjectRoot ? project.rootURL.path : scratchFolder.path))
        #expect(session.primarySelection.activeContainerID == container)
        #expect(session.primarySelection.activeTabID == opened.id)
        #expect(session.focusedPaneID(in: session.primaryWindowID) == pane)
        #expect(session.tabs == [existing, opened])
    }

    @Test("tab(containing:) follows a pane merged into another tab when the totals stay the same")
    func tabContaining_afterMergeKeepingCounts_returnsNewTab() throws {
        let session = WorkspaceSession()
        let source = session.openTab(container: .loose)
        let target = session.openTab(container: .loose)
        let stationary = try #require(source.splitTree.allLeafIDs().first)
        let pivot = try #require(target.splitTree.allLeafIDs().first)
        let unknown = UUID()
        session.setActiveTab(source.id)
        PaneActions.split(session, direction: .horizontal)
        let moved = try #require(session.tab(source.id)?.splitTree.allLeafIDs().last)
        try #require(session.tab(source.id)?.splitTree.allLeafIDs() == [stationary, moved])
        try #require(stationary != moved)

        // Prime the index while both tabs already have their pre-move counts.
        #expect(session.tab(containing: unknown) == nil)
        #expect(session.tab(containing: moved)?.id == source.id)
        #expect(session.tab(containing: stationary)?.id == source.id)
        #expect(session.tab(containing: pivot)?.id == target.id)

        TabActions.mergePaneIntoTab(session, paneID: moved, into: target.id)

        #expect(session.tabs.map(\.id) == [source.id, target.id])
        #expect(session.tab(source.id)?.splitTree.allLeafIDs() == [stationary])
        #expect(session.tab(target.id)?.splitTree.allLeafIDs() == [pivot, moved])
        #expect(session.tab(containing: moved)?.id == target.id)
        #expect(session.tab(containing: stationary)?.id == source.id)
        #expect(session.tab(containing: pivot)?.id == target.id)
        #expect(session.tab(containing: unknown) == nil)

        session.closeTab(target.id)
        #expect(session.tab(containing: moved) == nil)
        #expect(session.tab(containing: pivot) == nil)
        #expect(session.tab(containing: stationary)?.id == source.id)
    }

    // MARK: - closeTab

    @Test func closeTab_removesOnlyTheClosedTabsState() throws {
        let fixture = makeSession(sourceTabCount: 3)
        let session = fixture.session
        let closing = fixture.tabs[0]
        let survivor = fixture.tabs[2]
        let closedPane = try #require(closing.splitTree.allLeafIDs().first)
        let survivingPane = try #require(survivor.splitTree.allLeafIDs().first)
        let survivingSearch = PaneSearchState()
        survivingSearch.needle = "kept"
        session.setWorkingDirectory(paneID: closedPane, path: "/tmp/weir-closed-tab")
        session.setWorkingDirectory(paneID: survivingPane, path: "/tmp/weir-surviving-tab")
        session.paneSearchStates[closedPane] = PaneSearchState()
        session.paneSearchStates[survivingPane] = survivingSearch

        session.closeTab(closing.id)

        let row = ContainerID.project(fixture.sourceID)
        #expect(session.tabs == Array(fixture.tabs.dropFirst()))
        #expect(session.primarySelection.activeContainerID == row)
        #expect(session.primarySelection.activeTabID == survivor.id)
        #expect(session.lastActiveTabID(for: row) == survivor.id)
        #expect(session.workingDirectory(paneID: closedPane) == nil)
        #expect(session.paneSearchStates[closedPane] == nil)
        #expect(session.workingDirectory(paneID: survivingPane) == "/tmp/weir-surviving-tab")
        #expect(session.paneSearchStates[survivingPane] === survivingSearch)
        #expect(survivingSearch.needle == "kept")
    }

    @Test(arguments: [false, true])
    func closeTab_activeChoosesItsRightNeighbor_orThePredecessorAtTheEnd(closesTail: Bool) {
        let fixture = makeSession(sourceTabCount: 4)
        let session = fixture.session
        let foreignProject = Self.addProject(to: session, name: "Foreign")
        let foreign = session.openTab(container: .project(foreignProject.id))
        let closed = fixture.tabs[closesTail ? 3 : 1]
        let expected = fixture.tabs[2]
        // A neighboring tab in another row must not be chosen.
        if closesTail {
            session.reorderTab(foreign.id, before: closed.id)
        } else {
            session.reorderTab(foreign.id, after: closed.id)
        }
        session.setActiveTab(closed.id)
        let remaining = session.tabs.filter { $0.id != closed.id }
        let row = ContainerID.project(fixture.sourceID)

        session.closeTab(closed.id)

        #expect(session.tabs == remaining)
        #expect(session.primarySelection.activeContainerID == row)
        #expect(session.primarySelection.activeTabID == expected.id)
        #expect(session.lastActiveTabID(for: row) == expected.id)
        #expect(session.projectViews[foreignProject.id]?.activeTabID == foreign.id)
    }

    // MARK: - moveTab

    @Test("non-active tab drag leaves activeContainerID and activeTabID untouched")
    func moveTab_nonActiveDrag_leavesViewUnchanged() {
        let fx = makeSession(sourceTabCount: 2)
        let target = Self.addProject(to: fx.session, name: "Target")
        // openTab activates each newly-created tab, so we rewind to
        // the first one so the second one is the *non-active* one we
        // want to drag.
        fx.session.setActiveTab(fx.tabs[0].id)
        let nonActive = fx.tabs[1]

        fx.session.moveTab(nonActive.id, to: .project(target.id))

        #expect(fx.session.primarySelection.activeContainerID == .project(fx.sourceID))
        #expect(fx.session.primarySelection.activeTabID == fx.tabs[0].id)
        #expect(fx.session.tab(nonActive.id)?.container == .project(target.id))
    }

    enum SourcePosition: Sendable {
        case middle
        case tail
        case only
    }

    @Test(arguments: [SourcePosition.middle, .tail, .only])
    func moveTab_activeRepairsTheSource_andPlacesTheTabAtTheDestination(_ position: SourcePosition) {
        let fixture = makeSession(sourceTabCount: position == .only ? 1 : 4)
        let session = fixture.session
        let source = ContainerID.project(fixture.sourceID)
        let target = Self.addProject(to: session, name: "Target")
        let destination = ContainerID.project(target.id)
        let foreign = Self.addProject(to: session, name: "Foreign")
        let foreignTab = session.openTab(container: .project(foreign.id))
        let moved = fixture.tabs[position == .middle ? 1 : fixture.tabs.count - 1]
        session.reorderTab(foreignTab.id, after: moved.id)
        let destinationBefore: [Tab]
        if position == .only {
            destinationBefore = []
            session.projectViews[target.id] = ProjectView(projectID: target.id, activeContainerID: destination)
        } else {
            destinationBefore = [session.openTab(container: destination)]
        }
        session.setActiveTab(moved.id)
        let remaining = session.tabs.filter { $0.id != moved.id }
        let neighbor = position == .only ? nil : fixture.tabs[2].id

        session.moveTab(moved.id, to: destination)

        var movedTab = moved
        movedTab.container = destination
        movedTab.workingDirectory = target.rootURL.path
        #expect(session.tabs == remaining + [movedTab])
        #expect(session.tabs(in: destination) == destinationBefore + [movedTab])
        #expect(session.primarySelection.activeContainerID == source)
        #expect(session.primarySelection.activeTabID == neighbor)
        #expect(session.lastActiveTabID(for: source) == neighbor)
        #expect(session.projectViews[target.id]?.activeTabID == (destinationBefore.first?.id ?? moved.id))
    }

    @Test("moving a middle tab to its own container preserves its state and order")
    func moveTab_sameContainer_isNoOp() {
        let fixture = makeSession(sourceTabCount: 3)
        let session = fixture.session
        let middle = fixture.tabs[1]
        let row = ContainerID.project(fixture.sourceID)
        session.setActiveTab(middle.id)
        session.update(middle.id) {
            $0.titleOverride = "Pinned tab"
            $0.paletteIndex = 3
        }
        let before = session.tabs

        session.moveTab(middle.id, to: row)

        #expect(session.tabs == before)
        #expect(session.primarySelection.activeContainerID == row)
        #expect(session.primarySelection.activeTabID == middle.id)
        #expect(session.lastActiveTabID(for: row) == middle.id)
    }

    // MARK: - reorderTab

    // `performDrop` fires `onDrop` for a same-list reorder again once the
    // dragged row has slid under the cursor, calling
    // `reorderTab(src, before/after: src)`: a tab placed against itself
    // stays where it is, and a drag to the top lands at the top.

    @Test(arguments: [false, true])
    func reorderTab_againstItself_preservesOrderAndSelection(placesAfter: Bool) {
        let fixture = makeSession(sourceTabCount: 3)
        let session = fixture.session
        let middle = fixture.tabs[1]
        let row = ContainerID.project(fixture.sourceID)
        session.setActiveTab(middle.id)
        let before = session.tabs

        if placesAfter {
            session.reorderTab(middle.id, after: middle.id)
        } else {
            session.reorderTab(middle.id, before: middle.id)
        }

        #expect(session.tabs == before)
        #expect(session.primarySelection.activeTabID == middle.id)
        #expect(session.primarySelection.activeContainerID == row)
        #expect(session.lastActiveTabID(for: row) == middle.id)
    }

    @Test("dragging the bottom tab to the top lands it at the front, not the end")
    func reorderTab_bottomToTop_movesToFront() {
        let fx = makeSession(sourceTabCount: 3)
        // [0, 1, 2] — drop 2 before 0 — expect [2, 0, 1], not [0, 1, 2].
        fx.session.reorderTab(fx.tabs[2].id, before: fx.tabs[0].id)

        #expect(fx.session.tabs.map(\.id) == [fx.tabs[2].id, fx.tabs[0].id, fx.tabs[1].id])
    }

    @Test(arguments: [false, true])
    func moveTab_intoAProjectRow_replacesOnlyTheFolderDefault(isWorktree: Bool) throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let destination: ContainerID = isWorktree ? .worktree(projectID: project.id, worktreeID: worktree.id) : .project(project.id)
        let destinationFolder = isWorktree ? worktree.workingDirectory.path : project.rootURL.path
        let scratchFolder = WorkspaceSessionFixture.projectRootURL("scratch")
        session.quickTabDefaultsProvider = { (mode: .fixed, path: scratchFolder) }
        let tab = session.openTab(container: .loose)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        try #require(tab.workingDirectory == scratchFolder.path)
        session.update(tab.id) {
            $0.namePrefix = "prod"
            $0.paletteIndex = 2
            $0.cwdMode = .fixed
            $0.cwdPath = scratchFolder
            $0.pwd = "/tmp/weir-live-pane"
        }
        session.setWorkingDirectory(paneID: pane, path: "/tmp/weir-live-pane")

        session.moveTab(tab.id, to: destination)

        let moved = try #require(session.tab(tab.id))
        #expect(moved.container == destination)
        #expect(moved.splitTree == tab.splitTree)
        #expect(moved.namePrefix == "prod")
        #expect(moved.paletteIndex == 2)
        #expect(moved.cwdMode == nil)
        #expect(moved.cwdPath == nil)
        #expect(moved.workingDirectory == destinationFolder)
        #expect(moved.pwd == "/tmp/weir-live-pane")
        #expect(session.workingDirectory(paneID: pane) == "/tmp/weir-live-pane")
    }
}
