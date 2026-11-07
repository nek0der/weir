// WindowRoutingTests.swift
// Weir — what each window's selection follows: the actions run in it, and the changes every window shares.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A second window beside the primary moves on its own: an action
/// run in it writes its selection and its history, never the primary's,
/// and a tab or container that goes away moves every window that showed
/// it. The palette's rows are `PaletteExecuteRoutingTests`'.
@MainActor
struct WindowRoutingTests {

    // MARK: - Actions in a window

    @Test func navigationHistory_isEachWindowsOwn() throws {
        let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tabB.id, in: other)
        let before = try #require(session.currentNavTarget(in: other))
        session.setActiveTab(tabA.id, in: other)
        session.recordNavigation(from: before, in: other)

        #expect(session.canNavigateBack(in: other))
        #expect(!session.canNavigateBack(in: session.primaryWindowID))

        session.navigateBack(in: other)
        #expect(session.selection(other)?.activeTabID == tabB.id)
        #expect(session.canNavigateForward(in: other))
        // The primary stays where it was, with no history of its own.
        #expect(session.primarySelection.activeTabID == tabA.id)
        #expect(!session.canNavigateForward(in: session.primaryWindowID))
    }

    @Test func aShortcutRunInASecondWindow_movesThatWindow() {
        let session = WorkspaceSession()
        let first = session.openTab(container: .loose)
        let middle = session.openTab(container: .loose)
        let last = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(first.id)
        session.setActiveTab(middle.id, in: other)

        let steps: [(WeirShortcutAction, UUID)] = [
            (.nextTab, last.id), (.nextTab, first.id), (.previousTab, last.id), (.previousTab, middle.id)
        ]
        for (action, expected) in steps {
            dispatch(action, session: session, window: other)
            #expect(session.selection(other)?.activeTabID == expected)
            #expect(session.primarySelection.activeTabID == first.id)
        }
    }

    @Test func everyWindowShortcutOfTheDispatch_asksTheWindowForItsCommand() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let table: [(WeirShortcutAction, WindowCommand)] = [
            (.newWorktree, .newWorktree), (.newWorktreeNow, .newWorktreeNow), (.openFolder, .openFolder), (.closeWindow, .closeWindow),
            (.newWindow, .newWindow), (.toggleSidebar, .toggleSidebar),
            (.notificationHistory, .toggleNotificationHistory), (.review, .review),
            (.reviewLatestTurn, .reviewLatestTurn), (.toggleChangesPanel, .toggleChangesPanel), (.showScratch, .showScratch),
            (.allProjects, .toggleAllProjects), (.keyboardShortcuts, .toggleKeyboardShortcuts),
            (.showNeedsAttention, .showNeedsAttention), (.showOpenTabs, .showOpenTabs),
            (.showProjectMenu, .showProjectMenu), (.showWorktreeMenu, .showWorktreeMenu), (.showDecisionBarMenu, .showDecisionBarMenu),
            (.planUsage, .togglePlanUsage),
            (.focusSidebar, .focusSidebar)
        ]
        for (action, command) in table {
            let commands = RecordingWindowCommands()
            dispatch(action, session: session, window: other, commands: commands)
            #expect(commands.commands(in: other) == [command], "\(action)")
            #expect(commands.commands(in: session.primaryWindowID).isEmpty, "\(action)")
        }
    }

    /// From the palette the sidebar has no keyboard, so Move Project Up and
    /// Down move the project the window shows, in that window's order.
    @Test func theProjectMoves_fromThePalette_moveTheShownProject() throws {
        let fixture = ProjectWindowsFixture()
        let session = fixture.session
        let other = try fixture.window(showing: fixture.b)
        let original = [fixture.a.id, fixture.b.id, fixture.c.id]
        let steps: [(WeirShortcutAction, [UUID])] = [
            (.moveProjectDown, [fixture.a.id, fixture.c.id, fixture.b.id]),
            (.moveProjectDown, [fixture.a.id, fixture.c.id, fixture.b.id]),
            (.moveProjectUp, original),
            (.moveProjectUp, [fixture.b.id, fixture.a.id, fixture.c.id]),
            (.moveProjectUp, [fixture.b.id, fixture.a.id, fixture.c.id])
        ]
        try #require(other.selection.shownProjectID == fixture.b.id)
        for (action, expected) in steps {
            dispatch(action, session: session, window: other.id)
            #expect(other.selection.sidebarArrangement.ordered(original) == expected)
            #expect(session.primarySelection.sidebarArrangement.ordered(original) == original)
            #expect(session.projects.map(\.id) == original)
        }
    }

    /// ⌘J and ⇧⌘J from a window's palette, or the channel naming a
    /// window, walk from that window's place in the list, as its menu does,
    /// not from the window the person was last in.
    @Test func theAttentionShortcuts_walkTheList_fromTheWindowTheyRanIn() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let attention = AttentionState()
        var walked: [(forward: Bool, window: WindowID)] = []
        attention.walkAttention = { walked.append(($0, $1)) }

        for action in [WeirShortcutAction.nextAttention, .previousAttention] {
            dispatch(action, session: session, window: other, attention: attention)
        }

        #expect(walked.map(\.forward) == [true, false])
        #expect(walked.map(\.window) == [other, other])
    }

    /// Go Back and Go Forward are the window's to run, closing its dropdown
    /// first (`SupervisionWindowActions.runHistoryRow`): the shared
    /// dispatch leaves the history alone, so a row never steps twice.
    @Test func theHistoryShortcuts_areLeftToTheWindow_byTheSharedDispatch() throws {
        let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tabB.id, in: other)
        let before = try #require(session.currentNavTarget(in: other))
        session.setActiveTab(tabA.id, in: other)
        session.recordNavigation(from: before, in: other)
        try #require(session.canNavigateBack(in: other))

        dispatch(.goBack, session: session, window: other)

        #expect(session.selection(other)?.activeTabID == tabA.id)
        #expect(session.canNavigateBack(in: other))
        session.navigateBack(in: other)
        try #require(session.selection(other)?.activeTabID == tabB.id)
        try #require(session.canNavigateForward(in: other))

        dispatch(.goForward, session: session, window: other)

        #expect(session.selection(other)?.activeTabID == tabB.id)
        #expect(session.canNavigateForward(in: other))
        #expect(session.primarySelection.activeTabID == tabA.id)
    }

    @Test(arguments: [false, true])
    func aNewTabInASecondWindow_startsInThatWindowsFolder(hasLiveDirectory: Bool) throws {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (mode: .inheritPrevious, path: nil) }
        let launch = "/tmp/weir-window-b"
        let live = "/tmp/weir-window-b/live"
        let shown = session.openTab(container: .loose, workingDirectory: URL(fileURLWithPath: launch))
        let primary = session.openTab(container: .loose, workingDirectory: URL(fileURLWithPath: "/tmp/weir-primary"))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(shown.id, in: other)
        if hasLiveDirectory {
            session.update(shown.id) { $0.pwd = live }
        }

        dispatch(.newTab, session: session, window: other)

        let opened = try #require(session.activeTab(in: other))
        #expect(opened.workingDirectory == (hasLiveDirectory ? live : launch))
        #expect(opened.container == .loose)
        #expect(session.tabs.map(\.id) == [shown.id, primary.id, opened.id])
        #expect(session.primarySelection.activeTabID == primary.id)
    }

    // MARK: - Changes every window shares

    @Test(arguments: [false, true])
    func closingATab_movesItsSelectingWindowsToTheSameNeighbor(includesPrimary: Bool) throws {
        let session = WorkspaceSession()
        let untouched = session.openTab(container: .loose)
        let closing = session.openTab(container: .loose)
        let neighbor = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let third = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(includesPrimary ? closing.id : untouched.id)
        session.setActiveTab(closing.id, in: other)
        session.setActiveTab(untouched.id, in: third)
        let primary = session.primaryWindowID
        let selecting: Set<WindowID> = includesPrimary ? [primary, other] : [other]
        try #require(Set(session.windows(selecting: closing.id)) == selecting)

        session.closeTab(closing.id)

        #expect(session.tabs.map(\.id) == [untouched.id, neighbor.id])
        #expect(session.selection(other)?.activeTabID == neighbor.id)
        #expect(session.primarySelection.activeTabID == (includesPrimary ? neighbor.id : untouched.id))
        #expect(session.selection(third)?.activeTabID == untouched.id)
        for window in [primary, other, third] {
            #expect(session.selection(window)?.activeContainerID == .loose)
        }
    }

    @Test(arguments: [false, true])
    func leavingAHiddenOrRemovedWorktree_selectsTheProjectTab(isHiding: Bool) throws {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let primaryTab = try #require(session.primarySelection.activeTabID)
        let primaryContainer = session.primarySelection.activeContainerID
        let fallback = session.openTab(container: .project(project.id), in: other)
        let worktree = try #require(session.attachGitWorktree(
            projectID: project.id,
            label: "feature",
            workingDirectory: project.rootURL.appendingPathComponent("feature"),
            branchName: "feature"
        ))
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        let tab = session.openTab(container: container, in: other)
        try #require(session.selection(other)?.activeTabID == tab.id)
        try #require(session.selection(other)?.activeContainerID == container)
        let panes = tab.splitTree.allLeafIDs()
        try #require(panes.count == 1)

        if isHiding {
            session.hideWorktree(projectID: project.id, worktreeID: worktree.id)
            #expect(session.worktree(projectID: project.id, worktreeID: worktree.id)?.isHidden == true)
            #expect(session.tab(tab.id)?.container == .project(project.id))
            #expect(session.tab(tab.id)?.splitTree == tab.splitTree)
            #expect(session.tabs.map(\.id) == [primaryTab, fallback.id, tab.id])
        } else {
            let freed = session.removeWorktree(projectID: project.id, worktreeID: worktree.id)
            #expect(freed == panes)
            #expect(session.worktree(projectID: project.id, worktreeID: worktree.id) == nil)
            #expect(session.tabs.map(\.id) == [primaryTab, fallback.id])
        }

        #expect(session.selection(other)?.activeContainerID == .project(project.id))
        #expect(session.selection(other)?.activeTabID == fallback.id)
        #expect(session.primarySelection.activeTabID == primaryTab)
        #expect(session.primarySelection.activeContainerID == primaryContainer)
    }

    @Test func movingATab_leavesTheSecondWindowThatShowedItOnTheSource() {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let primaryTab = session.primarySelection.activeTabID
        let sibling = session.openTab(container: .project(project.id), in: other)
        let tab = session.openTab(container: .project(project.id), in: other)

        session.moveTab(tab.id, to: .loose)

        #expect(session.selection(other)?.activeTabID == sibling.id)
        #expect(session.selection(other)?.activeContainerID == .project(project.id))
        #expect(session.tab(tab.id)?.container == .loose)
        #expect(session.tab(tab.id)?.splitTree == tab.splitTree)
        #expect(session.primarySelection.activeTabID == primaryTab)
    }

    @Test func anUnknownWindow_movesNoWindow() throws {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let first = session.openTab(container: .project(project.id), in: other)
        let unselected = session.openTab(container: .project(project.id), in: other, intent: .person, selects: false)
        let primary = try #require(session.primarySelection.activeTabID)
        let primaryContainer = session.primarySelection.activeContainerID
        let unknown = WindowID()
        let windows = session.windowIDs
        try #require(!windows.contains(unknown))
        try #require(session.selection(other)?.activeTabID == first.id)
        try #require(session.lastActiveTabID(for: .project(project.id)) == first.id)

        session.setActiveTab(unselected.id, in: unknown)

        #expect(session.windowIDs == windows)
        #expect(session.primarySelection.activeTabID == primary)
        #expect(session.primarySelection.activeContainerID == primaryContainer)
        #expect(session.selection(other)?.activeContainerID == .project(project.id))
        #expect(session.selection(other)?.activeTabID == first.id)
        #expect(session.lastActiveTabID(for: .project(project.id)) == first.id)
    }

    // MARK: - Helpers

    // A tuple keeps the call sites' destructuring, as the fixtures' do.
    // swiftlint:disable large_tuple
    /// A primary on one project's tab, and a second window on `project`,
    /// which no other window shows: a change to `project` reaches
    /// the second window, and the primary is the one to stay as it was.
    private static func secondWindowShowingAProject() -> (session: WorkspaceSession, project: Project, other: WindowID) {
        let (session, home) = WorkspaceSessionFixture.withProject(name: "home")
        session.openTab(container: .project(home.id))
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("second"), suggestedName: "second")
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(.project(project.id), in: other)
        return (session, project, other)
    }

    // swiftlint:enable large_tuple

    private func dispatch(
        _ action: WeirShortcutAction,
        session: WorkspaceSession,
        window: WindowID,
        commands: RecordingWindowCommands = RecordingWindowCommands(),
        attention: AttentionState = AttentionState()
    ) {
        TabActions.dispatchShortcutAction(
            action,
            session: session,
            attention: attention,
            registry: RecordingSurfaceRegistry(),
            commands: commands,
            trackers: TabActions.SessionTrackers(projection: nil),
            toastCenter: ToastCenter(),
            minPaneSize: 0,
            window: window
        )
    }

    @Test func thePaneOfASecondWindowsTab_namesThatWindow() throws {
        let (session, project, other) = Self.secondWindowShowingAProject()
        let primaryTab = try #require(session.primarySelection.activeTabID.flatMap { session.tab($0) })
        let primaryPane = try #require(primaryTab.splitTree.allLeafIDs().first)
        let shown = session.openTab(container: .project(project.id), in: other)
        let behind = session.openTab(container: .project(project.id), in: other, intent: .person, selects: false)
        let shownPane = try #require(shown.splitTree.allLeafIDs().first)
        let behindPane = try #require(behind.splitTree.allLeafIDs().first)

        #expect(session.window(showingPane: primaryPane) == session.primaryWindowID)
        #expect(session.window(showingPane: shownPane) == other)
        // A tab no window shows, and a pane no tab holds, name no window.
        #expect(session.window(showingPane: behindPane) == nil)
        #expect(session.window(showingPane: UUID()) == nil)
    }

    @Test func theSessionsInFront_includeOnlyVisibleWindowsShowingASession() throws {
        let fixture = ProjectWindowsFixture()
        let session = fixture.session
        let other = try fixture.window(showing: fixture.b)
        #expect(session.shownContainerIDs == [.project(fixture.a.id), .project(fixture.b.id)])

        session.setWindow(other.id, isHidden: true)
        let chooser = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID)
        try #require(session.hiddenWindowIDs == [other.id])
        try #require(chooser.isChoosingProject)
        #expect(session.shownContainerIDs == [.project(fixture.a.id)])

        session.setWindow(other.id, isHidden: false)
        #expect(session.shownContainerIDs == [.project(fixture.a.id), .project(fixture.b.id)])
    }
}

/// A request addressed to one window.
@MainActor
extension WindowRoutingTests {
    @Test func renaming_asksOnlyTheWindowItWasAskedIn() {
        let (session, primary, _, tab, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tab.id, in: other)
        let commands = RecordingWindowCommands()

        dispatch(.renameTab, session: session, window: other, commands: commands)

        #expect(commands.commands(in: other) == [.renameTab(tab.id)])
        #expect(session.primarySelection.activeTabID == primary.id)
        #expect(commands.commands(in: session.primaryWindowID).isEmpty)
    }
}
