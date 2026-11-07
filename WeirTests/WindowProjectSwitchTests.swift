// WindowProjectSwitchTests.swift
// Weir — a window switching project in place, the window showing it brought forward, a removed project's windows moved on.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A window shows one project at a time and a project is shown in one
/// window at a time. The person's choice of another project's
/// session switches the window in place, keeping what it showed of the
/// project it left for when a window shows that project again, or brings
/// forward the window that shows it. Nothing else switches a window or
/// brings one forward, except a removed project's windows, which move on.
@MainActor
struct WindowProjectSwitchTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - Switching in place

    @Test func choosingAnotherProjectsTab_switchesThisWindow_andOpensNone() throws {
        let fixture = Fixture()
        let session = fixture.session
        let window = fixture.primary.id
        let requested = session.openTab(container: .project(fixture.b.id), in: window, intent: .person, selects: false)
        session.rememberLastActive(tabID: fixture.bTab.id, container: .project(fixture.b.id))
        let tabs = session.tabs
        let before = try #require(session.currentNavTarget(in: window))
        try #require(before == .init(container: .project(fixture.a.id), tabID: fixture.aTab.id))

        fixture.choose(requested, in: fixture.primary)

        #expect(session.currentNavTarget(in: window) == .init(container: .project(fixture.b.id), tabID: requested.id))
        #expect(fixture.registry.windows.map(\.id) == [window])
        #expect(session.windowIDs == [window])
        #expect(fixture.presenter.shown.isEmpty)
        #expect(session.tabs == tabs)
        #expect(session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)

        fixture.choose(fixture.cTab, in: fixture.primary)
        #expect(session.currentNavTarget(in: window) == .init(container: .project(fixture.c.id), tabID: fixture.cTab.id))
        #expect(fixture.registry.windows.map(\.id) == [window])
        #expect(session.tabs == tabs)
        #expect(fixture.presenter.shown.isEmpty)
        fixture.expectInvariants()
    }

    @Test func aNewTabOpenedInAnotherProject_switchesThisWindow() {
        let fixture = Fixture()
        let session = fixture.session
        let window = fixture.primary.id
        let destination = ContainerID.project(fixture.b.id)
        let tabs = Set(session.tabs.map(\.id))

        let opened = session.openTab(container: destination, in: window, intent: .person, selects: true)

        #expect(session.currentNavTarget(in: window) == .init(container: destination, tabID: opened.id))
        #expect(session.tabs.count == tabs.count + 1)
        #expect(Set(session.tabs.map(\.id)) == tabs.union([opened.id]))
        #expect(fixture.registry.windows.map(\.id) == [window])
        #expect(session.windowIDs == [window])
        #expect(fixture.presenter.shown.isEmpty)
        fixture.expectInvariants()
    }

    /// The palette's project rows, run in turn from the primary: a row of
    /// another project switches this window, and the next row reads the
    /// project it switched to as this window's.
    @Test func thePalettesProjectRows_switchThisWindowOnlyToAnotherProject() throws {
        let fixture = Fixture()
        let worktree = try #require(fixture.session.attachGitWorktree(
            projectID: fixture.c.id,
            label: "feat",
            workingDirectory: WorkspaceSessionFixture.projectRootURL("c-feat"),
            branchName: "feat"
        ))
        let cWorktree = ContainerID.worktree(projectID: fixture.c.id, worktreeID: worktree.id)
        // swiftlint:disable:next large_tuple
        let rows: [(row: CommandPaletteAction, handling: PaletteRowHandling, shown: ContainerID)] = [
            // This window's project, as project ▾ does: nothing changes, and
            // the terminal gets the keyboard back as after any row.
            (.activateProject(fixture.a.id), .handledReturningKeyboard, .project(fixture.a.id)),
            // A tab of this window's project is the shared dispatch's.
            (.jumpToTab(fixture.aTab.id), .notHandled, .project(fixture.a.id)),
            // A project gone: nothing to show, and the keyboard goes back.
            (.activateProject(UUID()), .handledReturningKeyboard, .project(fixture.a.id)),
            (.openSettings, .notHandled, .project(fixture.a.id)),
            // Another project's rows switch this window, whose next terminal
            // takes the keyboard as it is drawn.
            (.jumpToTab(fixture.bTab.id), .handled, .project(fixture.b.id)),
            (.activateWorktree(projectID: fixture.c.id, worktreeID: worktree.id), .handled, cWorktree),
            (.activateProject(fixture.a.id), .handled, .project(fixture.a.id))
        ]

        for (row, handling, shown) in rows {
            let ran = SupervisionWindowActions.runProjectRow(
                row,
                in: fixture.primary,
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil
            )
            #expect(ran == handling, "\(row)")
            #expect(fixture.primary.selection.activeContainerID == shown, "\(row)")
            #expect(fixture.registry.windows.count == 1, "\(row)")
            if case let .jumpToTab(tab) = row, handling == .handled {
                #expect(fixture.primary.selection.activeTabID == tab)
            }
        }
        fixture.expectInvariants()
    }

    @Test func switchingBack_bringsBackItsSessionTabAndPanelAgent() {
        let fixture = Fixture()
        let selection = fixture.primary.selection
        let agent = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
        fixture.choose(fixture.aOther, in: fixture.primary)
        selection.changesPanelFilter = agent

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(selection.changesPanelFilter == nil)
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        #expect(selection.shownProjectID == fixture.a.id)
        #expect(selection.activeTabID == fixture.aOther.id)
        #expect(selection.changesPanelFilter == agent)
        // `b` keeps its own.
        #expect(fixture.session.projectViews[fixture.b.id]?.activeTabID == fixture.bTab.id)
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        fixture.expectInvariants()
    }

    @Test func switchingProject_keepsTheWindowsSidebarAndChangesPanel() {
        let fixture = Fixture()
        let selection = fixture.primary.selection
        let frame = CGRect(x: 10, y: 20, width: 900, height: 700)
        let filter = ConversationKey(provider: .claude, conversationID: "c1", isFallback: false)
        selection.frame = frame
        selection.sidebarWidth = 333
        selection.sidebarHidden = true
        selection.isChangesPanelPresented = true
        selection.changesPanelWidth = 444
        selection.changesPanelGrouping = .byConversation
        selection.changesPanelFilter = filter

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(selection.shownProjectID == fixture.b.id)
        #expect(selection.frame == frame)
        #expect(selection.sidebarWidth == 333)
        #expect(selection.sidebarHidden)
        #expect(selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 444)
        #expect(selection.changesPanelGrouping == .byConversation)
        #expect(selection.changesPanelFilter == nil)

        // The parked project restores its filter while the window keeps
        // the chrome last used in the other project.
        selection.sidebarWidth = 280
        selection.sidebarHidden = false
        selection.isChangesPanelPresented = false
        selection.changesPanelWidth = 360
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        #expect(selection.shownProjectID == fixture.a.id)
        #expect(selection.frame == frame)
        #expect(selection.sidebarWidth == 280)
        #expect(!selection.sidebarHidden)
        #expect(!selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 360)
        #expect(selection.changesPanelGrouping == .byConversation)
        #expect(selection.changesPanelFilter == filter)
        fixture.expectInvariants()
    }

    @Test func aSwitch_isDrawnAsOneChange_withTheAppLayerToldInsideIt() {
        let fixture = Fixture()
        let session = fixture.session
        let window = fixture.primary.id
        let row = ContainerID.project(fixture.b.id)
        let requested = session.openTab(container: row, in: window, intent: .person, selects: false)
        session.rememberLastActive(tabID: fixture.bTab.id, container: row)
        var events: [String] = []
        fixture.registry.drawsSwitch = { switching in
            events.append("begin")
            switching()
            events.append("end")
        }
        fixture.registry.onWillSwitchProject = { leaving, from, reason in
            events.append("will")
            #expect(leaving.id == window)
            #expect(from == fixture.a.id)
            #expect(reason == .person)
            #expect(leaving.selection.shownProjectID == fixture.a.id)
            #expect(leaving.selection.activeTabID == fixture.aTab.id)
        }
        fixture.registry.onDidSwitchProject = { arrived in
            events.append("did")
            #expect(arrived.id == window)
            #expect(arrived.selection.shownProjectID == fixture.b.id)
            #expect(arrived.selection.activeTabID == fixture.bTab.id)
        }

        fixture.choose(requested, in: fixture.primary)

        #expect(events == ["begin", "will", "did", "end"])
        #expect(session.currentNavTarget(in: window) == .init(container: row, tabID: requested.id))
    }

    @Test func aBackgroundWriteInAProjectNeverShown_keepsTheFirstShowInheritingTheSidebar() throws {
        let fixture = Fixture()
        let session = fixture.session
        let window = fixture.primary.id
        let row = ContainerID.project(fixture.b.id)
        let before = try #require(session.currentNavTarget(in: window))
        fixture.primary.selection.sidebarWidth = 333
        let decoy = session.openTab(container: row, in: window, intent: .person, selects: false)
        let behind = session.openTab(container: row, in: window, intent: .behind, selects: true)

        #expect(session.projectViews[fixture.b.id] == nil)
        #expect(session.currentNavTarget(in: window) == before)
        #expect(session.lastActiveTabID(for: row) == behind.id)
        session.setActiveTab(decoy.id, in: window, intent: .repair)
        #expect(session.projectViews[fixture.b.id] == nil)
        #expect(session.currentNavTarget(in: window) == before)
        #expect(session.lastActiveTabID(for: row) == decoy.id)
        session.setActiveTab(behind.id, in: window, intent: .behind)
        #expect(session.projectViews[fixture.b.id] == nil)
        #expect(session.currentNavTarget(in: window) == before)
        #expect(session.lastActiveTabID(for: row) == behind.id)
        session.closeTab(fixture.bTab.id)
        #expect(session.projectViews[fixture.b.id] == nil)
        #expect(session.currentNavTarget(in: window) == before)
        #expect(session.tabs(in: row).map(\.id) == [decoy.id, behind.id])

        #expect(session.chooseProject(fixture.b.id, in: window) == window)

        #expect(session.currentNavTarget(in: window) == .init(container: row, tabID: behind.id))
        #expect(fixture.primary.selection.sidebarWidth == 333)
    }

    // MARK: - The window that shows the project

    @Test func aProjectAnotherShownWindowShows_raisesThatWindow_andLeavesThisOne() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let later = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)

        fixture.choose(later, in: fixture.primary)

        #expect(fixture.presenter.shown == [other.id])
        #expect(other.selection.activeTabID == later.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.registry.windows.count == 2)
        fixture.expectInvariants()
    }

    @Test func withOnlyAHiddenWindow_aPersonsSelectionShowsItAndSwitchesIt() throws {
        let fixture = Fixture()
        let id = fixture.primary.id
        fixture.registry.hide(id)
        try #require(fixture.primary.isHidden && fixture.session.hiddenWindowIDs == [id])
        try #require(fixture.presenter.onScreen.isEmpty)

        // As a notification does: the window commands act on, then the tab.
        let window = try #require(fixture.registry.present(project: fixture.b.id, in: fixture.session, from: nil))
        fixture.choose(fixture.bTab, in: window)

        #expect(window === fixture.primary)
        #expect(!window.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(window.selection.shownProjectID == fixture.b.id)
        #expect(window.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.windows.map(\.id) == [id])
        #expect(fixture.presenter.shown == [id])
        #expect(fixture.presenter.onScreen == [id])
    }

    @Test func aRepairInAProjectAnotherWindowShows_writesThereWithoutRaisingIt() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let later = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)
        fixture.registry.hide(other.id)
        fixture.presenter.shown = []

        // Asked of the window that shows the project: written there.
        fixture.session.setActiveTab(later.id, in: other.id, intent: .repair)
        // Asked of another window: that one neither switches nor comes
        // forward.
        fixture.session.setActiveTab(fixture.bTab.id, in: fixture.primary.id, intent: .repair)

        #expect(other.selection.activeTabID == later.id)
        #expect(other.isHidden)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        fixture.expectInvariants()
    }

    @Test func aBehindWriteInAProjectAnotherWindowShows_changesNothingThere() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let later = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)

        let primaryBefore = try #require(fixture.session.currentNavTarget(in: fixture.primary.id))
        let otherBefore = try #require(fixture.session.currentNavTarget(in: other.id))
        let views = fixture.session.projectViews

        for window in [fixture.primary, other] {
            fixture.session.setActiveTab(later.id, in: window.id, intent: .behind)
            #expect(fixture.session.currentNavTarget(in: fixture.primary.id) == primaryBefore)
            #expect(fixture.session.currentNavTarget(in: other.id) == otherBefore)
            #expect(fixture.session.projectViews == views)
            #expect(fixture.presenter.shown.isEmpty)
        }
        fixture.expectInvariants()
    }

    @Test func closingATabAnotherWindowShows_movesThatWindowToTheNeighbor() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let neighbor = fixture.session.openTab(container: .project(fixture.b.id), in: other.id, intent: .person, selects: false)

        // Closed from the primary's palette, say.
        fixture.session.closeTab(fixture.bTab.id)

        #expect(other.selection.activeTabID == neighbor.id)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
    }

    @Test func backAcrossProjects_switchesThisWindow() {
        let fixture = Fixture()
        let window = fixture.primary.id
        let before = WorkspaceSession.NavTarget(container: .project(fixture.a.id), tabID: fixture.aTab.id)
        fixture.choose(fixture.bTab, in: fixture.primary)
        // As the app's observer records the move.
        fixture.session.recordNavigation(from: before, in: window)

        fixture.session.navigateBack(in: window, intent: .person)

        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        #expect(fixture.registry.windows.count == 1)

        fixture.session.navigateForward(in: window, intent: .person)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeTabID == fixture.bTab.id)
        fixture.expectInvariants()
    }

    // MARK: - Removing a project

    @Test func removingTheShownProject_movesOnlyThatWindow_toTheMostRecentProjectNoOtherWindowShows() throws {
        let fixture = Fixture()
        let session = fixture.session
        let preferred = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("preferred"))
        let preferredTab = session.openTab(container: .project(preferred.id), in: fixture.primary.id, intent: .person, selects: false)
        let other = try fixture.window(showing: fixture.c)
        let otherBefore = try #require(session.currentNavTarget(in: other.id))
        // The primary showed the preferred project and went back to `a`; the sidebar's
        // width, the window's own, is 333 throughout.
        fixture.choose(preferredTab, in: fixture.primary)
        fixture.primary.selection.sidebarWidth = 333
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)
        #expect(fixture.primary.selection.sidebarWidth == 333)
        session.noteProjectUsed(fixture.c.id)
        try #require(session.recentProjectPaths.prefix(4) == [fixture.c.rootURL, preferred.rootURL, fixture.b.rootURL, fixture.a.rootURL])
        var switched: [WindowID] = []
        fixture.registry.onWillSwitchProject = { window, from, reason in
            switched.append(window.id)
            #expect(from == fixture.a.id)
            #expect(reason == .projectRemoved)
        }

        fixture.session.removeProject(fixture.a.id)

        // The occupied project ranks first. The preferred free project
        // ranks above the earlier-listed free project.
        #expect(fixture.primary.selection.shownProjectID == preferred.id)
        #expect(fixture.primary.selection.activeTabID == preferredTab.id)
        #expect(fixture.primary.selection.sidebarWidth == 333)
        #expect(session.currentNavTarget(in: other.id) == otherBefore)
        #expect(switched == [fixture.primary.id])
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.session.projectViews.isEmpty)
        fixture.expectInvariants()
    }

    @Test func removingTheShownProjectWithAnOpenReview_leavesNoParkedReviewOrView() throws {
        let fixture = Fixture()
        fixture.tidiesAsTheAppDoes()
        let pane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let tab = try Fixture.windowWritingAComment(fixture.primary, agentPaneID: pane)
        try #require(fixture.primary.review?.opening == tab.opening)
        try #require(fixture.primary.reviewHasUnsavedComment)

        fixture.session.removeProject(fixture.a.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        // The comment does not keep it: nothing of a removed project stays.
        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.primary.reviewSession == nil)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        #expect(fixture.primary.selection.shownProjectID == fixture.c.id)
        fixture.expectInvariants()
    }

    @Test func removingAProjectAHiddenWindowShows_movesThatWindowToo() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.hide(other.id)
        fixture.presenter.shown = []

        fixture.session.removeProject(fixture.c.id)

        #expect(other.selection.shownProjectID == fixture.b.id)
        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(other.isHidden)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    @Test func removingTheProjectAWindowOnScratchKeeps_movesThatWindowOn() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let other = try fixture.window(showing: fixture.c)
        fixture.choose(scratch, in: other)
        #expect(other.selection.shownProjectID == fixture.c.id)
        #expect(fixture.session.scratchOwnerWindowID == other.id)

        fixture.session.removeProject(fixture.c.id)

        // It names no removed project any more: it went on to `b`, and gave
        // up the scratch tabs it left.
        #expect(other.selection.projectID == fixture.b.id)
        #expect(other.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.session.scratchOwnerWindowID == nil)
        // Closing the primary later moves nothing of it.
        fixture.registry.close(fixture.primary.id, in: fixture.session)
        #expect(other.selection.projectID == fixture.b.id)
        fixture.expectInvariants()
    }

    @Test func removingTheShownProjectOnAScratchTab_keepsThatTabAndItsTerminalDrawnAndSeen() throws {
        let fixture = Fixture()
        _ = fixture.scratchTab()
        // The second scratch tab, so that staying on the first one would
        // not pass for staying on the one the window was on.
        let scratch = fixture.scratchTab()
        fixture.choose(scratch, in: fixture.primary)
        _ = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        fixture.registry.didReportDisplay(window: fixture.primary.id, rendered: [pane], attended: [pane])

        // No project is left for the window: it stays on its scratch tab,
        // which its view has no reason to report again.
        fixture.session.removeProject(fixture.a.id)

        #expect(fixture.primary.selection.shownProjectID == nil)
        #expect(fixture.primary.selection.activeContainerID == .loose)
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.registry.visibility.union.contains(pane))
        #expect(fixture.registry.attention.attendedPanes.contains(pane))
    }

    @Test(arguments: [false, true])
    func removingTheLastProjectAWindowCouldTake_leavesItShowingNothing(hasOtherProjects: Bool) throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let target: ProjectWindowState
        if hasOtherProjects {
            let second = try fixture.window(showing: fixture.b)
            let secondBefore = try #require(fixture.session.currentNavTarget(in: second.id))
            target = try fixture.window(showing: fixture.c)
            fixture.session.removeProject(fixture.c.id)
            #expect(fixture.session.currentNavTarget(in: second.id) == secondBefore)
        } else {
            fixture.session.removeProject(fixture.b.id)
            fixture.session.removeProject(fixture.c.id)
            try #require(fixture.session.projects.map(\.id) == [fixture.a.id])
            target = fixture.primary
            fixture.session.removeProject(fixture.a.id)
            #expect(fixture.session.projects.isEmpty)
        }

        // "Open a Project": on the scratch row, drawing none of
        // its tabs until the person chooses them.
        #expect(target.selection.shownProjectID == nil)
        #expect(target.selection.isChoosingProject)
        #expect(target.selection.activeContainerID == .loose)
        #expect(target.selection.activeTabID == nil)
        #expect(!fixture.session.windows(showing: scratch.id).contains(target.id))
        fixture.expectInvariants()
    }
}

/// The scratch tabs across a switch, and what the window lets go of and
/// keeps as it switches.
extension WindowProjectSwitchTests {

    // MARK: - The scratch tabs

    @Test func aScratchTabChosenInAProject_isRememberedForIt() {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        fixture.choose(scratch, in: fixture.primary)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeContainerID == .loose)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == scratch.id)
        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeContainerID == .loose)
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.session.showsScratch(in: fixture.primary.id))
    }

    @Test func switchingBackToAProjectLeftOnScratch_doesNotTakeTheScratchFromAnotherWindow() throws {
        let fixture = Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let other = try fixture.window(showing: fixture.c)
        // The primary chooses the scratch tab, then goes to `b`, leaving
        // the scratch tabs.
        fixture.choose(scratch, in: fixture.primary)
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.session.scratchOwnerWindowID == nil)
        // The other window comes to the scratch tab without choosing it.
        fixture.session.setActiveTab(scratch.id, in: other.id, intent: .repair)
        #expect(fixture.session.scratchDrawingWindowID == other.id)

        fixture.session.showProject(fixture.a.id, in: fixture.primary.id, intent: .person, reason: .person)

        // The primary is back on the scratch tab it left, but coming back is
        // not choosing it: the window drawing the scratch tabs is kept as
        // their keeper, so it goes on drawing them, and the primary says
        // they are open there.
        #expect(fixture.primary.selection.activeTabID == scratch.id)
        #expect(fixture.session.scratchOwnerWindowID == other.id)
        #expect(fixture.session.scratchDrawingWindowID == other.id)
        #expect(!fixture.session.showsScratch(in: fixture.primary.id))
        // "Show Here" still takes them.
        fixture.session.claimScratch(for: fixture.primary.id)
        #expect(fixture.session.scratchDrawingWindowID == fixture.primary.id)
    }

    // MARK: - What the window holds

    @Test func switching_clearsThisWindowsReportedPanesFirst() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        let aPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let cPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        fixture.registry.didReportDisplay(window: fixture.primary.id, rendered: [aPane], attended: [aPane])
        fixture.registry.didReportDisplay(window: other.id, rendered: [cPane], attended: [cPane])
        var phases: [String] = []
        fixture.registry.onWillSwitchProject = { leaving, from, _ in
            phases.append("will")
            #expect(leaving.id == fixture.primary.id)
            #expect(from == fixture.a.id)
            #expect(fixture.registry.visibility.union == [aPane, cPane])
            #expect(fixture.registry.attention.attendedPanes == [aPane, cPane])
        }
        fixture.registry.onDidSwitchProject = { arriving in
            phases.append("did")
            #expect(arriving.id == fixture.primary.id)
            #expect(fixture.registry.visibility.union == [cPane])
            #expect(fixture.registry.attention.attendedPanes == [cPane])
        }

        fixture.choose(fixture.bTab, in: fixture.primary)

        // Told while the project it leaves was still its own; then its panes
        // stop counting, until it reports what it shows of the next one.
        #expect(phases == ["will", "did"])
        #expect(fixture.registry.visibility.union == [cPane])
        #expect(fixture.registry.attention.attendedPanes == [cPane])
    }

    @Test func switching_closesTheRowsCardAndTheFloatingSurfaces_butKeepsTheHistoryAndTheSheet() async throws {
        let fixture = Fixture()
        let approvals = ApprovalPresentationStore()
        fixture.tidiesAsTheAppDoes()
        let window = fixture.primary
        let other = try fixture.window(showing: fixture.c)
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        approvals.receive([request])
        window.approvalCard.updateRowAnchor(CGRect(x: 0, y: 40, width: 200, height: 20), for: request, in: approvals)
        window.approvalCard.present(key: request.key, from: approvals)
        // The other window's card stood beside the Needs Attention button.
        other.approvalCard.present(key: request.key, from: approvals, openedFrom: CGRect(x: 0, y: 0, width: 40, height: 20))
        try #require(window.approvalCard.presentedApproval(in: approvals)?.id == request.id)
        try #require(other.approvalCard.presentedApproval(in: approvals)?.id == request.id)
        let aPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        let cPane = try #require(fixture.cTab.splitTree.allLeafIDs().first)
        let sheet = NewSessionSheetRequest(projectID: fixture.a.id)
        try #require(window.openNewWorktreeSheet(sheet) == .opened)
        window.titleBarMenu = TitleBarMenuRequest(menu: .project, anchor: .zero)
        window.isAllProjectsPresented = true
        fixture.session.commandPaletteState = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window.id)
        window.paneRename.open(paneID: aPane, name: "pane", anchor: .zero)
        window.containerColor.open(projectID: fixture.a.id, anchor: .zero)
        window.restoreFocusRequest = UUID()
        window.sidebarFocusRequest = UUID()
        window.reviewOpenRequest = ReviewOpenRequest(containerID: .project(fixture.a.id), tabID: fixture.aTab.id)
        window.isSidebarKeptOverPanel = true
        window.notificationHistory.isPresented = true
        window.keyboardShortcuts.isPresented = true
        window.planUsage.isPresented = true
        let item = AttentionItemID.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))
        window.decisionBarSelection[aPane] = item
        window.decisionBarDone[aPane] = .answeredInTerminal
        window.pendingDecisionBarDone[aPane] = .answeredInTerminal
        window.pendingDecisionBarDone[cPane] = .answeredInTerminal
        window.restoreStrips[aPane] = RestoreStrip(turnID: TurnID("t"))
        window.decisionBarSelection[cPane] = item
        let scratch = fixture.scratchTab()
        let scratchPane = try #require(scratch.splitTree.allLeafIDs().first)
        window.decisionBarSelection[scratchPane] = item
        window.restoreStrips[scratchPane] = RestoreStrip(turnID: TurnID("s"))
        window.promptCachePanel.open(
            target: PromptCacheTarget(runtimeID: "a", paneID: aPane),
            place: .paneHeader(paneID: aPane),
            clock: .init(instance: UUID(), frame: .zero),
            trigger: .pointer
        )
        window.prHover.rowEntered(
            rowID: PRHoverSource(container: .project(fixture.a.id)),
            info: PRInfoFixture.make(),
            anchor: .zero,
            delay: .zero
        )
        await pollUntil { window.prHover.visible != nil }
        try #require(window.prHover.visible != nil)
        try #require(window.titleBarMenu != nil)
        try #require(window.promptCachePanel.request != nil)

        fixture.choose(fixture.bTab, in: window)

        #expect(window.approvalCard.presentedApproval(in: approvals) == nil)
        // The sidebar lists every project, so the row is still where it
        // was, and opening its card again stands beside it.
        #expect(window.approvalCard.rowAnchor(for: request) == CGRect(x: 0, y: 40, width: 200, height: 20))
        #expect(approvals.pending.map(\.id) == [request.id])
        #expect(window.titleBarMenu == nil)
        #expect(!window.isAllProjectsPresented)
        #expect(!window.keyboardShortcuts.isPresented, "it holds the keyboard the next project's pane is handed")
        #expect(fixture.session.commandPaletteState == nil)
        #expect(window.paneRename.request == nil)
        #expect(window.containerColor.request == nil)
        #expect(window.restoreFocusRequest == nil)
        #expect(window.sidebarFocusRequest == nil)
        #expect(window.reviewOpenRequest == nil)
        // The sidebar kept over the panel is the window's chrome, as the
        // panel is: it stays.
        #expect(window.isSidebarKeptOverPanel)
        #expect(window.promptCachePanel.request == nil)
        #expect(window.prHover.visible == nil)
        // The bars and strips of `a`'s panes go; another project's stay.
        #expect(window.decisionBarSelection[aPane] == nil)
        #expect(window.decisionBarDone[aPane] == nil)
        #expect(window.pendingDecisionBarDone[aPane] == nil)
        #expect(window.pendingDecisionBarDone[cPane] == .answeredInTerminal)
        #expect(window.restoreStrips[aPane] == nil)
        #expect(window.decisionBarSelection[cPane] == item)
        // A scratch tab's are no project's: the window can still show it.
        #expect(window.decisionBarSelection[scratchPane] == item)
        #expect(window.restoreStrips[scratchPane] == RestoreStrip(turnID: TurnID("s")))
        // The window's own: the history and the new session sheet, which
        // makes its session in `a` still.
        #expect(window.notificationHistory.isPresented)
        #expect(window.planUsage.isPresented)
        #expect(window.newSession == sheet)
        // Another window's card is its own.
        #expect(other.approvalCard.presentedApproval(in: approvals)?.id == request.id)
    }

    @Test func theNewSessionSheetsOfARemovedProject_closeInEveryWindow() throws {
        let fixture = Fixture()
        fixture.tidiesAsTheAppDoes()
        let other = try fixture.window(showing: fixture.c)
        let surviving = try fixture.window(showing: fixture.b)
        let removed = NewSessionSheetRequest(projectID: fixture.a.id)
        let kept = NewSessionSheetRequest(projectID: fixture.c.id)
        try #require(fixture.primary.openNewWorktreeSheet(removed) == .opened)
        try #require(other.openNewWorktreeSheet(removed) == .opened)
        try #require(surviving.openNewWorktreeSheet(kept) == .opened)

        fixture.session.removeProject(fixture.a.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.primary.newSession == nil)
        #expect(other.newSession == nil)
        #expect(surviving.newSession == kept)
    }

    @Test(arguments: [false, true])
    func switchingProject_keepsOnlyTheWindowControlsApprovalCard(fromDecisionBar: Bool) throws {
        let fixture = Fixture()
        let approvals = ApprovalPresentationStore()
        fixture.tidiesAsTheAppDoes()
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        approvals.receive([request])
        let window = fixture.primary
        if fromDecisionBar {
            let pane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
            window.approvalCard.present(key: request.key, from: approvals, openedFromPane: pane, focusesClose: true)
        } else {
            window.approvalCard.present(key: request.key, from: approvals, openedFrom: CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        try #require(window.approvalCard.presentedApproval(in: approvals)?.id == request.id)

        fixture.choose(fixture.bTab, in: window)

        #expect(window.approvalCard.presentedApproval(in: approvals)?.id == (fromDecisionBar ? nil : request.id))
        #expect(approvals.pending.map(\.id) == [request.id])
    }

    @Test func theProjectViewsInvariant_holdsAfterEverySwitch() throws {
        let fixture = Fixture()
        let session = fixture.session
        let primary = fixture.primary.id
        let scratch = fixture.scratchTab()
        func check(_ owners: [WindowID: UUID], parked: Set<UUID>) {
            fixture.expectInvariants()
            #expect(Set(fixture.registry.windows.map(\.id)) == Set(owners.keys))
            #expect(Set(session.windowIDs) == Set(owners.keys))
            for (window, project) in owners {
                #expect(session.selection(window)?.shownProjectID == project)
            }
            #expect(Set(session.projectViews.keys) == parked)
            for (project, view) in session.projectViews {
                #expect(view.projectID == project)
                #expect(session.project(project) != nil)
            }
        }

        check([primary: fixture.a.id], parked: [])
        fixture.choose(fixture.bTab, in: fixture.primary)
        check([primary: fixture.b.id], parked: [fixture.a.id])
        let other = try fixture.window(showing: fixture.c)
        check([primary: fixture.b.id, other.id: fixture.c.id], parked: [fixture.a.id])
        fixture.choose(fixture.aOther, in: fixture.primary)
        check([primary: fixture.a.id, other.id: fixture.c.id], parked: [fixture.b.id])
        fixture.choose(fixture.bTab, in: other)
        check([primary: fixture.a.id, other.id: fixture.b.id], parked: [fixture.c.id])
        fixture.choose(scratch, in: other)
        check([primary: fixture.a.id, other.id: fixture.b.id], parked: [fixture.c.id])
        fixture.choose(fixture.cTab, in: fixture.primary)
        check([primary: fixture.c.id, other.id: fixture.b.id], parked: [fixture.a.id])
        fixture.registry.close(other.id, in: session)
        check([primary: fixture.c.id], parked: [fixture.a.id, fixture.b.id])
        fixture.choose(fixture.bTab, in: fixture.primary)
        check([primary: fixture.b.id], parked: [fixture.a.id, fixture.c.id])
        session.removeProject(fixture.b.id)
        check([primary: fixture.c.id], parked: [fixture.a.id])
        #expect(session.currentNavTarget(in: primary) == .init(container: .project(fixture.c.id), tabID: fixture.cTab.id))
    }
}
