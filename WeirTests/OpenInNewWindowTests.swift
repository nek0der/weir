// OpenInNewWindowTests.swift
// Weir — a project opened in a new window on request, and a window that shows nothing until the person chooses.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A new window opens only when the person asks for one:
/// ⌘-click or ⌘Return on another project's row opens the project in a new
/// window, on what it showed last; New Window always opens a new window
/// that shows nothing until the person chooses a project or the scratch
/// tabs, and lists every project. A project another window shows brings
/// that window forward instead, and a window that shows nothing is saved
/// and comes back showing nothing.
@MainActor
struct OpenInNewWindowTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - A project in a new window

    @Test func aCommandClick_opensTheProjectInANewWindow_onWhatItShowedLast() throws {
        let fixture = Fixture()
        let (review, _) = try ProjectWindowsFixture.reviewAndHunk()
        fixture.primary.review = review
        fixture.session.setActiveTab(fixture.aOther.id, in: fixture.primary.id, intent: .person)
        fixture.primary.selection.sidebarWidth = 311
        fixture.primary.selection.isChangesPanelPresented = true
        fixture.primary.scrollPlace.changesTurn = TurnID("t1")
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(
            projectOrder: [fixture.c.id, fixture.b.id, fixture.a.id],
            collapsedProjects: [fixture.c.id]
        )
        // The window leaves `a`, which keeps its view, its review tab, and
        // where its list was.
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.primary.selection.sidebarWidth = 250
        #expect(fixture.session.projectViews[fixture.a.id] != nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id] != nil)
        #expect(fixture.registry.scrollMemories[fixture.a.id] != nil)

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.a.id, in: fixture.session, from: fixture.primary))

        #expect(opened !== fixture.primary)
        #expect(fixture.registry.windows.count == 2)
        #expect(fixture.presenter.shown == [opened.id])
        #expect(opened.selection.shownProjectID == fixture.a.id)
        #expect(opened.selection.activeTabID == fixture.aOther.id)
        // The chrome is the window's it was opened from, as it is now, not
        // the one `a` was left with.
        #expect(opened.selection.sidebarWidth == 250)
        #expect(opened.selection.isChangesPanelPresented)
        #expect(!opened.selection.isChoosingProject)
        // What `a` kept now belongs to the new window: it is kept only for a
        // project no window shows.
        #expect(opened.review?.opening == review.opening)
        #expect(opened.scrollRestore?.projectID == fixture.a.id)
        #expect(opened.scrollRestore?.memory.changes?.place.row == TurnID("t1"))
        // The sidebar's order and folds are the window's it was opened from
        // too, `a`'s header opened as the window takes it, and `b`, which
        // the window it came from shows, folded as another window's.
        #expect(opened.selection.sidebarArrangement.projectOrder == [fixture.c.id, fixture.b.id, fixture.a.id])
        #expect(opened.selection.sidebarArrangement.collapsedProjects == [fixture.c.id, fixture.b.id])
        #expect(fixture.session.projectViews[fixture.a.id] == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id] == nil)
        #expect(fixture.registry.scrollMemories[fixture.a.id] == nil)
        // The window asked stays on its own project.
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        fixture.expectInvariants()
    }

    @Test func aProjectShownForTheFirstTime_inANewWindow_takesTheChromeOfTheWindowAsked_butNotItsFrame() throws {
        let fixture = Fixture()
        fixture.primary.selection.sidebarWidth = 290
        fixture.primary.selection.sidebarHidden = true
        fixture.primary.selection.isChangesPanelPresented = true
        fixture.primary.selection.changesPanelWidth = 360
        fixture.primary.selection.frame = CGRect(x: 10, y: 20, width: 900, height: 700)
        fixture.primary.selection.isFullScreen = true

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: fixture.primary))

        #expect(opened.selection.activeTabID == fixture.bTab.id)
        #expect(opened.selection.sidebarWidth == 290)
        #expect(opened.selection.sidebarHidden)
        #expect(opened.selection.isChangesPanelPresented)
        #expect(opened.selection.changesPanelWidth == 360)
        // Placed by the presenter on the asking window's screen, and never
        // in full screen of its own.
        #expect(opened.selection.frame == nil)
        #expect(!opened.selection.isFullScreen)
        // Used by the person: it is the most recent project.
        #expect(fixture.session.recentProjectPaths.first?.standardizedFileURL == fixture.b.rootURL.standardizedFileURL)
    }

    @Test(arguments: [false, true])
    func aProjectAnotherWindowShows_bringsThatWindowForward_hiddenOrNot(isHidden: Bool) throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        if isHidden {
            fixture.registry.hide(other.id)
        }
        #expect(other.isHidden == isHidden)
        #expect(fixture.presenter.isOnScreen(other.id) != isHidden)

        let shown = fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: fixture.primary)

        #expect(shown === other)
        #expect(!other.isHidden)
        #expect(fixture.presenter.shown == [other.id])
        #expect(fixture.presenter.closed.isEmpty)
        #expect(fixture.registry.windows.map(\.id) == [fixture.primary.id, other.id])
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    @Test func theProjectOfTheWindowAsked_doesNothing() {
        let fixture = Fixture()

        let shown = fixture.registry.openInNewWindow(project: fixture.a.id, in: fixture.session, from: fixture.primary)

        #expect(shown === fixture.primary)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.presenter.shown.isEmpty)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
    }

    @Test func aProjectGone_orAWindowClosed_opensNothing() throws {
        let fixture = Fixture()
        let closing = try fixture.window(showing: fixture.c)
        fixture.registry.close(closing.id, in: fixture.session)

        #expect(fixture.registry.openInNewWindow(project: UUID(), in: fixture.session, from: fixture.primary) == nil)
        #expect(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: closing) == nil)
        #expect(fixture.registry.windows.count == 1)
    }

    @Test func theNewWindow_isPlacedFromTheWindowAsked() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: other))
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: other)

        // Cascaded from it, on its screen (`ProjectWindowPresenter`).
        #expect(fixture.presenter.openedFrom[opened.id] == other.id)
        #expect(fixture.presenter.openedFrom[empty.id] == other.id)
    }

    @Test func askedOfAHiddenWindow_aNewWindowOpens_andTheHiddenOneClosesKeepingItsProject() throws {
        let fixture = Fixture()
        let hidden = fixture.primary
        fixture.registry.close(hidden.id, in: fixture.session)
        #expect(hidden.isHidden)

        let opened = try #require(fixture.registry.openInNewWindow(project: fixture.b.id, in: fixture.session, from: hidden))

        // The hidden window's project is not replaced: it closes, and `a`
        // keeps what it showed. No window stands hidden beside the new one.
        #expect(opened !== hidden)
        #expect(opened.selection.shownProjectID == fixture.b.id)
        #expect(fixture.registry.windows.map(\.id) == [opened.id])
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)
        #expect(fixture.presenter.closed == [hidden.id])
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        fixture.expectInvariants()
    }

    @Test func aRowOpenedInANewWindow_isChosenThere_andThisWindowStays() throws {
        let fixture = Fixture()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session)
        let row = ContainerID.worktree(projectID: fixture.b.id, worktreeID: worktree.id)
        let checkout = fixture.session.openTab(container: row, in: fixture.primary.id, intent: .person, selects: false)
        fixture.session.projectViews[fixture.b.id] = ProjectView(
            projectID: fixture.b.id, activeContainerID: fixture.bTab.container, activeTabID: fixture.bTab.id
        )

        let opened = try #require(fixture.registry.openInNewWindow(row: row, in: fixture.session, from: fixture.primary))

        #expect(opened !== fixture.primary)
        #expect(opened.selection.shownProjectID == fixture.b.id)
        #expect(opened.selection.activeContainerID == row)
        #expect(opened.selection.activeTabID == checkout.id)
        #expect(fixture.session.projectViews[fixture.b.id] == nil)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(fixture.primary.selection.activeTabID == fixture.aTab.id)
        // The scratch tabs are no project's row, and open in no new window.
        #expect(fixture.registry.openInNewWindow(row: .loose, in: fixture.session, from: fixture.primary) == nil)
        #expect(fixture.registry.windows.count == 2)
        fixture.expectInvariants()
    }

    // MARK: - New Window

    @Test func newWindow_showsNothing_andOffersEveryProject_sayingWhichAnotherWindowShows() throws {
        let fixture = Fixture()
        let forC = try fixture.window(showing: fixture.c)
        fixture.presenter.shown = []

        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        #expect(fixture.registry.windows.count == 3)
        #expect(fixture.presenter.shown == [empty.id])
        #expect(empty.selection.isChoosingProject)
        #expect(empty.selection.shownProjectID == nil)
        #expect(empty.selection.activeTabID == nil)
        let rows = EmptyWindowModel(session: fixture.session, window: empty.selection).rows
        #expect(rows.map(\.id) == [fixture.a.id, fixture.b.id, fixture.c.id])
        #expect(rows.map(\.isInOtherWindow) == [true, false, true])
        #expect(rows.map(\.opensInNewWindow) == [false, true, false])
        fixture.expectInvariants()

        // A project another window shows brings that window forward; the
        // empty window stays as it is.
        let shown = fixture.registry.show(project: fixture.c.id, in: fixture.session, from: empty, intent: .person)
        #expect(shown === forC)
        #expect(empty.selection.isChoosingProject)
    }

    @Test func aRemovedProjectsHeir_isTheMostRecentNoWindowShows_whileAnEmptyWindowListsThemInItsSidebarsOrder() throws {
        let fixture = Fixture()
        let d = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("d"), suggestedName: "d")
        fixture.session.recentProjectPaths = [d.rootURL, fixture.a.rootURL]

        let free = fixture.session.projectsNoWindowShows(besides: nil).map(\.id)
        #expect(free == [d.id, fixture.b.id, fixture.c.id])
        // An empty window lists every project in its sidebar's order instead.
        let chooser = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        #expect(chooser.selection.isChoosingProject)
        chooser.selection.sidebarArrangement = SidebarArrangement(projectOrder: [d.id, fixture.c.id])
        #expect(EmptyWindowModel(session: fixture.session, window: chooser.selection).rows.map(\.id) == [
            d.id, fixture.c.id, fixture.a.id, fixture.b.id
        ])

        // A window whose project is removed takes the first of them.
        let other = try fixture.window(showing: fixture.c)
        fixture.session.removeProject(fixture.c.id)
        #expect(other.selection.shownProjectID == d.id)
    }

    @Test func newWindow_withEveryWindowHidden_opensANewOne_andTheHiddenOneCloses() {
        let fixture = Fixture()
        let hidden = fixture.primary
        hidden.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.a.id, fixture.b.id, fixture.c.id])
        fixture.registry.close(hidden.id, in: fixture.session)
        #expect(hidden.isHidden)

        let opened = fixture.registry.openEmptyWindow(in: fixture.session, from: nil)

        #expect(opened !== hidden)
        #expect(opened.selection.isChoosingProject)
        #expect(!opened.isHidden)
        // No hidden window beside a shown one: it closed, and its project
        // keeps what it showed.
        #expect(fixture.registry.windows.map(\.id) == [opened.id])
        #expect(fixture.registry.primary === opened)
        #expect(fixture.session.projectViews[fixture.a.id]?.activeTabID == fixture.aTab.id)
        #expect(fixture.presenter.closed == [hidden.id])
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        // The project the hidden window showed is no window's now, so the
        // new window's sidebar does not fold it as another window's.
        #expect(!opened.selection.sidebarArrangement.collapsedProjects.contains(fixture.a.id))
        let rows = EmptyWindowModel(session: fixture.session, window: opened.selection).rows
        #expect(rows.map(\.id) == [fixture.a.id, fixture.b.id, fixture.c.id])
        #expect(rows.map(\.isInOtherWindow) == [false, false, false])
        #expect(rows.map(\.mark) == [nil, nil, nil])
    }

    @Test func newWindow_besideAShownWindow_foldsThatWindowsProject() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.a.id, fixture.b.id])

        let opened = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        #expect(opened.selection.sidebarArrangement.collapsedProjects.contains(fixture.a.id))
    }

    @Test func newWindow_besideAnotherThatShowsNothing_isANewOneEachTime() {
        let fixture = Fixture()
        let first = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        let second = fixture.registry.openEmptyWindow(in: fixture.session, from: first)

        #expect(first !== second)
        #expect(fixture.registry.windows.count == 3)
        #expect(second.selection.isChoosingProject)
    }

    @Test func anEmptyWindowsRow_saysOneThingAtItsEnd_itsWindowFirst() {
        let fixture = Fixture()
        let d = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("d"), suggestedName: "d")
        let store = AttentionQueueStore()
        store.apply(.init(runtimes: [
            RuntimeFact.stopped("a", in: fixture.aTab, of: fixture.a),
            RuntimeFact.stopped("b", in: fixture.bTab, of: fixture.b)
        ]), announces: false)
        let projects = [fixture.a, fixture.b, fixture.c, d]
        let rows = EmptyWindowModel(
            projects: projects,
            shownElsewhere: [fixture.a.id],
            attentionQueue: store.queue,
            running: { $0 == d.id ? 0 : 2 }
        ).rows

        #expect(rows.map(\.id) == projects.map(\.id))
        #expect(rows.map(\.attention.count) == [1, 1, 0, 0])
        #expect(rows.map(\.attention.style) == [.blocking, .blocking, .empty, .empty])
        #expect(rows.map(\.running) == [2, 2, 2, 0])
        #expect(rows.map(\.mark) == [.otherWindow, .attention, .running, nil])
        #expect(rows.map(\.folder) == projects.map(\.rootURL.path))
    }

    @Test func anEmptyWindow_drawsNoChangesPanel_andKeepsThePersonsChoiceForTheProjectChosen() {
        let fixture = Fixture()
        fixture.primary.selection.isChangesPanelPresented = true
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        #expect(empty.selection.isChangesPanelPresented)
        #expect(!empty.selection.showsChangesPanel)

        // ⌥⌘I and the menu leave the choice as it is while nothing shows.
        ChangesPanelActions.toggle(empty, session: fixture.session)
        #expect(empty.selection.isChangesPanelPresented)

        fixture.registry.show(project: fixture.b.id, in: fixture.session, from: empty, intent: .person)
        #expect(empty.selection.showsChangesPanel)
    }

    @Test func aWindowThatShowsNothing_drawsNoScratchTab_untilTheScratchIsChosen() {
        let fixture = Fixture()
        let scratch = fixture.scratchTab()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        #expect(!fixture.session.showsScratch(in: empty.id))
        #expect(fixture.session.scratchDrawingWindowID == nil)
        #expect(!fixture.session.shownTabIDs.contains(scratch.id))
        #expect(!fixture.session.shownContainerIDs.contains(.loose))
        #expect(fixture.session.windows(showing: scratch.id).isEmpty)

        // The sidebar's scratch row.
        fixture.session.setActiveContainer(.loose, in: empty.id, intent: .person)

        #expect(!empty.selection.isChoosingProject)
        #expect(empty.selection.activeTabID == scratch.id)
        #expect(fixture.session.scratchDrawingWindowID == empty.id)
        #expect(fixture.session.shownTabIDs.contains(scratch.id))
    }

    @Test func choosingAProject_inAWindowThatShowsNothing_showsItThere() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        fixture.presenter.shown = []

        let shown = fixture.registry.show(project: fixture.b.id, in: fixture.session, from: empty, intent: .person)

        #expect(shown === empty)
        #expect(!empty.selection.isChoosingProject)
        #expect(empty.selection.activeTabID == fixture.bTab.id)
        #expect(fixture.registry.windows.count == 2)
        fixture.expectInvariants()
    }

    @Test func aScratchTabOpenedBehind_whileAWindowShowsNothing_isTheOneChoosingTheRowOpens() {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)

        // A window that shows nothing holds no row, so nothing keeps the
        // scratch row on a tab it shows.
        #expect(!fixture.session.holdsSelection(of: .loose))
        let opened = fixture.scratchTab()
        #expect(fixture.session.tabOpened(choosing: .loose) == opened.id)

        // The sidebar's scratch row.
        fixture.session.setActiveContainer(.loose, in: empty.id, intent: .person)

        #expect(empty.selection.activeTabID == opened.id)
        #expect(fixture.session.holdsSelection(of: .loose))
    }

    @Test func aWindowThatShowsNothing_isSaved_andComesBackShowingNothing() throws {
        let fixture = Fixture()
        let empty = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        empty.selection.sidebarWidth = 277

        let saved = fixture.session.makeSnapshot()
        let data = try JSONEncoder().encode(saved)
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(snapshot.windows.map(\.isChoosingProject) == [false, true])
        #expect(snapshot.windows.first?.projectID == fixture.a.id)
        #expect(fixture.session.savedWindowIDs.contains(empty.id))

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)
        let ids = restored.windowIDs
        #expect(ids.count == 2)
        let later = try #require(ids.last.flatMap { restored.selection($0) })
        #expect(later.isChoosingProject)
        #expect(later.shownProjectID == nil)
        #expect(later.activeTabID == nil)
        #expect(later.sidebarWidth == 277)
        #expect(restored.primarySelection.shownProjectID == fixture.a.id)
    }

    /// A session of one project with a tab of its own, which the primary
    /// shows, and the windows connected to it as the app does.
    private struct OneProject {
        let session: WorkspaceSession
        let project: Project
        let projectTab: Tab
        let registry: WindowRegistry
    }

    /// The project is named `name`; `connecting` adds to the session before
    /// the windows are connected.
    private static func oneProject(
        _ name: String,
        before connecting: (WorkspaceSession, Project) -> Void = { _, _ in }
    ) -> OneProject {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL(name), suggestedName: name)
        let projectTab = session.openTab(container: .project(project.id))
        connecting(session, project)
        session.primarySelection.projectID = project.id
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        registry.connectProjectSwitching(of: session)
        return OneProject(session: session, project: project, projectTab: projectTab, registry: registry)
    }

    @Test func aRemovedProjectWithNowhereToGo_leavesItsWindowShowingNothing() {
        let scene = Self.oneProject("only")
        let session = scene.session

        session.removeProject(scene.project.id)
        withExtendedLifetime(scene.registry) {}

        #expect(session.primarySelection.isChoosingProject)
        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.primarySelection.activeTabID == nil)
        #expect(EmptyWindowModel(session: session, window: session.primarySelection).rows.isEmpty)
    }

    // MARK: - Launch

    @Test func aLaunchWithNoTab_makesAScratchTab_asBefore() throws {
        let session = WorkspaceSession()
        session.restore(from: SessionSnapshot(projects: [], tabs: []))

        let made = try #require(session.openLaunchTabIfNone())

        #expect(session.activeTab(in: session.primaryWindowID)?.id == made.id)
        #expect(made.container == .loose)
        #expect(!session.primarySelection.isChoosingProject)
        #expect(session.scratchDrawingWindowID == session.primaryWindowID)
        // Any tab at all, and the launch makes none.
        #expect(session.openLaunchTabIfNone() == nil)
        #expect(session.tabs.count == 1)
    }

    @Test func aPrimaryThatShowedNothing_comesBackShowingNothing() throws {
        var scratchTab: Tab?
        let scene = Self.oneProject("only") { session, only in
            scratchTab = session.openTab(container: .loose, in: session.primaryWindowID, intent: .person, selects: false)
            session.setActiveContainer(.project(only.id))
        }
        let (session, scratch) = try (scene.session, #require(scratchTab))
        session.removeProject(scene.project.id)
        withExtendedLifetime(scene.registry) {}
        #expect(session.primarySelection.isChoosingProject)

        let snapshot = session.makeSnapshot()
        // A build that reads past the flag finds the scratch tab.
        #expect(snapshot.windows.first?.activeTabID == scratch.id)
        let restored = WorkspaceSession()
        restored.restore(from: snapshot)

        #expect(restored.primarySelection.isChoosingProject)
        #expect(restored.primarySelection.activeContainerID == .loose)
        #expect(restored.primarySelection.activeTabID == nil)
        #expect(restored.scratchDrawingWindowID == nil)
        #expect(restored.openLaunchTabIfNone() == nil)
    }

    @Test func twoWindowsThatShowedNothing_bothComeBack() {
        let fixture = Fixture()
        let first = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        let second = fixture.registry.openEmptyWindow(in: fixture.session, from: fixture.primary)
        first.selection.sidebarWidth = 277
        first.selection.sidebarHidden = true
        second.selection.sidebarWidth = 399
        second.selection.isChangesPanelPresented = true

        let restored = WorkspaceSession()
        restored.restore(from: fixture.session.makeSnapshot())

        let selections = restored.windowIDs.compactMap { restored.selection($0) }
        #expect(selections.count == 3)
        #expect(selections.map(\.isChoosingProject) == [false, true, true])
        #expect(selections.map(\.shownProjectID) == [fixture.a.id, nil, nil])
        #expect(selections.map(\.activeTabID) == [fixture.aTab.id, nil, nil])
        // Restored secondary window IDs are new, so their enumeration is
        // by those IDs rather than by the order the windows were opened.
        let choosers = selections.dropFirst().sorted { $0.sidebarWidth < $1.sidebarWidth }
        #expect(choosers.map(\.sidebarWidth) == [277, 399])
        #expect(choosers.map(\.sidebarHidden) == [true, false])
        #expect(choosers.map(\.isChangesPanelPresented) == [false, true])
    }

    @Test func theLastWindow_closedWhileItShowedNothing_comesBackHiddenAndShowingNothing() {
        let fixture = Fixture()
        let (session, registry) = (fixture.session, fixture.registry)
        let empty = registry.openEmptyWindow(in: session, from: registry.primary)
        registry.close(registry.primary.id, in: session)
        registry.close(empty.id, in: session)
        #expect(empty.isHidden)

        let snapshot = session.makeSnapshot()
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.isHidden == true)
        #expect(snapshot.windows.first?.isChoosingProject == true)

        let restored = WorkspaceSession()
        restored.restore(from: snapshot)
        #expect(restored.windowIDs == [restored.primaryWindowID])
        #expect(restored.primarySelection.isChoosingProject)
        #expect(restored.hiddenWindowIDs.contains(restored.primaryWindowID))
    }

    @Test func aPrimaryThatShowedNothing_withNoTabAtAll_comesBackOnTheScratchTabs_whereTheLaunchOpensOne() throws {
        var record = WindowRecord()
        record.isChoosingProject = true
        let restored = WorkspaceSession()
        restored.restore(from: SessionSnapshot(projects: [], tabs: [], windows: [record]))

        #expect(!restored.primarySelection.isChoosingProject)
        let made = try #require(restored.openLaunchTabIfNone())
        #expect(made.container == .loose)
        #expect(restored.activeTab(in: restored.primaryWindowID)?.id == made.id)
    }

    @Test func onlyAWindowThatShowedNothing_withNoScratchTab_comesBackShowingNothing() throws {
        let scene = Self.oneProject("kept")
        let session = scene.session
        let registry = scene.registry
        let empty = registry.openEmptyWindow(in: session, from: registry.primary)
        // The window on `kept` closes; the one that shows nothing is left.
        registry.close(registry.primary.id, in: session)
        #expect(registry.windows.map(\.id) == [empty.id])

        let snapshot = session.makeSnapshot()
        let record = try #require(snapshot.windows.first)
        #expect(snapshot.windows.count == 1)
        #expect(record.isChoosingProject)
        #expect(record.activeContainerID == .loose)
        #expect(record.activeTabID == nil)

        let restored = WorkspaceSession()
        let issue = restored.restore(from: snapshot)

        // Showing nothing, and not another project's tab with a repair to
        // report; the launch makes no tab, as there are some.
        #expect(issue == nil)
        #expect(restored.primarySelection.isChoosingProject)
        #expect(restored.primarySelection.shownProjectID == nil)
        #expect(restored.primarySelection.activeContainerID == .loose)
        #expect(restored.primarySelection.activeTabID == nil)
        #expect(restored.openLaunchTabIfNone() == nil)
        #expect(restored.tabs.map(\.id) == [scene.projectTab.id])
    }

}

extension OpenInNewWindowTests {

    // MARK: - The palette and the lists

    @Test func paletteNewWindowRoutingSelectsTheRequestedProjectsTab() throws {
        let fixture = Fixture()
        func run(_ action: CommandPaletteAction) -> PaletteRowHandling {
            SupervisionWindowActions.runProjectRow(
                action,
                in: fixture.primary,
                session: fixture.session,
                registry: fixture.registry,
                frecency: nil,
                opensInNewWindow: true
            )
        }

        // "#": a project.
        #expect(run(.activateProject(fixture.b.id)) == .handled)
        let forB = try #require(fixture.registry.window(showingProject: fixture.b.id, in: fixture.session))
        #expect(forB !== fixture.primary)
        // The requested tab is different from the one C remembers.
        let alternate = fixture.session.openTab(
            container: .project(fixture.c.id), in: fixture.primary.id, intent: .person, selects: false
        )
        fixture.session.projectViews[fixture.c.id] = ProjectView(
            projectID: fixture.c.id, activeContainerID: fixture.cTab.container, activeTabID: fixture.cTab.id
        )
        #expect(run(.jumpToTab(alternate.id)) == .handled)
        let forC = try #require(fixture.registry.window(showingProject: fixture.c.id, in: fixture.session))
        #expect(forC.selection.activeTabID == alternate.id)
        #expect(fixture.session.projectViews[fixture.c.id] == nil)
        // This window's own: as without ⌘.
        #expect(run(.activateProject(fixture.a.id)) == .handledReturningKeyboard)
        #expect(run(.jumpToTab(fixture.aOther.id)) == .notHandled)
        #expect(fixture.registry.windows.count == 3)
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        fixture.expectInvariants()
    }

    @Test func attentionRowNavigationUsesItsExplicitNewWindowFlag() throws {
        let fixture = Fixture()
        let store = AttentionQueueStore()
        let navigator = SessionAttentionNavigator(session: fixture.session, registry: fixture.registry)
        store.navigator = navigator
        defer { withExtendedLifetime(navigator) {} }
        store.apply(
            .init(runtimes: [
                RuntimeFact.stopped("b", in: fixture.bTab, of: fixture.b),
                RuntimeFact.stopped("c", in: fixture.cTab, of: fixture.c)
            ]),
            announces: false
        )
        let itemB = try #require(store.queue.items.first { $0.subject.projectID == fixture.b.id })
        let itemC = try #require(store.queue.items.first { $0.subject.projectID == fixture.c.id })

        // The default route keeps navigation in the requesting window.
        store.focus(itemB, from: fixture.primary)
        #expect(fixture.registry.windows.count == 1)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)

        // The explicit new-window route puts the item in its project's window.
        store.focus(itemC, from: fixture.primary, opensInNewWindow: true)
        let forC = try #require(fixture.registry.window(showingProject: fixture.c.id, in: fixture.session))
        #expect(forC !== fixture.primary)
        #expect(forC.selection.activeTabID == fixture.cTab.id)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(forC.cursor.current == itemC.id)
    }

    @Test func aRowSaysItOpensInANewWindow_onlyWhereItWould() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.c)
        let store = AttentionQueueStore()
        store.apply(.init(runtimes: [
            RuntimeFact.stopped("a", in: fixture.aTab, of: fixture.a),
            RuntimeFact.stopped("b", in: fixture.bTab, of: fixture.b),
            RuntimeFact.stopped("c", in: fixture.cTab, of: fixture.c)
        ]), announces: false)

        let model = NeedsAttentionListModel(
            queue: store.queue,
            session: fixture.session,
            approvals: ApprovalPresentationStore(),
            projectsInOtherWindows: fixture.registry.projectsShown(besides: fixture.primary.id, in: fixture.session),
            windowProjectID: .some(fixture.primary.selection.shownProjectID),
            locale: Locale(identifier: "en")
        )
        let opens = { (project: Project) in
            model.rows.first { row in store.queue.items.first { $0.id == row.id }?.subject.projectID == project.id }?.opensInNewWindow
        }

        #expect(opens(fixture.a) == false)
        #expect(opens(fixture.b) == true)
        #expect(opens(fixture.c) == false)
        #expect(other.selection.shownProjectID == fixture.c.id)

        // Outside a window (the menu bar), no row opens one.
        let outside = NeedsAttentionListModel(
            queue: store.queue,
            session: fixture.session,
            approvals: ApprovalPresentationStore(),
            windowProjectID: nil,
            locale: Locale(identifier: "en")
        )
        let ids = Set(store.queue.items.map(\.id))
        #expect(ids.count == 3)
        #expect(outside.rows.count == 3)
        #expect(Set(outside.rows.map(\.id)) == ids)
        #expect(outside.rows.map(\.opensInNewWindow) == [false, false, false])

        // The menu bar, told which projects the windows show, says it of an
        // item of a project none shows.
        let menuBar = NeedsAttentionListModel(
            queue: store.queue,
            session: fixture.session,
            approvals: ApprovalPresentationStore(),
            windowProjectID: nil,
            projectsInWindows: fixture.registry.projectsShown(besides: nil, in: fixture.session),
            locale: Locale(identifier: "en")
        )
        let opensFromMenuBar = { (project: Project) in
            menuBar.rows.first { row in store.queue.items.first { $0.id == row.id }?.subject.projectID == project.id }?.opensInNewWindow
        }
        #expect(opensFromMenuBar(fixture.a) == false)
        #expect(opensFromMenuBar(fixture.b) == true)
        #expect(opensFromMenuBar(fixture.c) == false)
        #expect(menuBar.rows.map(\.id) == outside.rows.map(\.id))
        #expect(menuBar.rows.map(\.placeLead) == outside.rows.map(\.placeLead))
    }

    @Test func onlyACommandClick_orItsVoiceOverAction_opensARowInANewWindow() {
        #expect(!NeedsAttentionListOpening.returnKey.opensInNewWindow)
        #expect(!NeedsAttentionListOpening.click(holdsCommand: false).opensInNewWindow)
        #expect(NeedsAttentionListOpening.click(holdsCommand: true).opensInNewWindow)
        #expect(NeedsAttentionListOpening.newWindowAction.opensInNewWindow)
    }

    @Test func thePalettesCommand_reachesTheWindowWithTheRow() {
        let window = WindowID()
        let state = CommandPaletteState(locale: Locale(identifier: "en"), windowID: window)
        let commands = RecordingWindowCommands()
        let project = UUID()

        CommandPaletteActions.postExecution(of: .activateProject(project), from: state, opensInNewWindow: true, commands: commands)
        CommandPaletteActions.postExecution(of: .activateProject(project), from: state, commands: commands)

        #expect(commands.commands(in: window) == [
            .runPaletteRow(CommandPaletteExecution(action: .activateProject(project), windowID: window, opensInNewWindow: true)),
            .runPaletteRow(CommandPaletteExecution(action: .activateProject(project), windowID: window, opensInNewWindow: false))
        ])
        #expect(commands.performed.count == 2)
    }

}
