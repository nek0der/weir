// WindowCloseTests.swift
// Weir — closing a window ends it while another is shown, and hides the last one.

import Combine
import CoreGraphics
import Foundation
import Testing
@testable import Weir

/// A window closed beside another ends: its project keeps what it showed,
/// its agents run on, the primary's role moves to a window left, and
/// nothing it held is counted or told in it again. The last window shown
/// is hidden for the Dock, and at most one is ever hidden.
@MainActor
struct WindowCloseTests {
    /// Two windows: the primary on `first`, at `firstTab`, and `other` on
    /// `second`, at `secondTab`, the one the person was in last. Both are
    /// shown, and the registry tells the session what it hides.
    /// Shared with the extension in WindowCloseReviewTests.swift and with
    /// `ParkedReviewArrivalTests`.
    @MainActor
    struct Fixture {
        let session: WorkspaceSession
        let registry: WindowRegistry
        let presenter: RecordingWindowPresenter
        let first: Project
        let firstTab: Tab
        let second: Project
        let secondTab: Tab
        let other: ProjectWindowState

        init() throws {
            let (session, first) = WorkspaceSessionFixture.withProject(name: "first")
            firstTab = session.openTab(container: .project(first.id))
            second = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("second"), suggestedName: "second")
            session.setActiveTab(firstTab.id)
            session.primarySelection.projectID = first.id
            registry = WindowRegistry(primary: session.primarySelection)
            presenter = RecordingWindowPresenter()
            registry.presenter = presenter
            registry.onVisibilityChange = { session.setWindow($0, isHidden: $1) }
            registry.show(registry.primary.id)
            other = try #require(registry.openInNewWindow(project: second.id, in: session, from: registry.primary))
            secondTab = session.openTab(container: .project(second.id), in: other.id)
            registry.windowBecameKey(other.id)
            self.session = session
            self.first = first
        }

        var primary: ProjectWindowState {
            registry.primary
        }

        var secondPane: UUID {
            secondTab.splitTree.allLeafIDs()[0]
        }

        /// A window on `project` listed and shown beside `hidden`, laid out
        /// like it (`WorkspaceSession.addWindow(showing:layoutFrom:)`): a state
        /// no entry point leaves, for the close's own guard.
        func windowBeside(_ hidden: ProjectWindowState, showing project: Project) -> ProjectWindowState {
            let window = registry.addWindow(session.addWindow(showing: project.id, layoutFrom: hidden.id))
            registry.show(window.id)
            return window
        }

        /// Closes `window` as its close button would.
        func close(_ window: ProjectWindowState) {
            registry.close(window.id, in: session)
        }

        /// The person chooses `second` in `window` (project ▾, a card, a
        /// notification): it switches in place unless another window shows
        /// the project, which comes forward instead. The registry switches
        /// the session's windows from here on, as the app's always does.
        func chooseSecond(in window: ProjectWindowState) throws -> ProjectWindowState {
            registry.connectProjectSwitching(of: session)
            return try #require(registry.show(project: second.id, in: session, from: window, intent: .person))
        }

        /// Tidies a window as it closes, telling its toasts in `toasts`, as
        /// the app does (`WindowClosing.tidy`).
        func tidiesOnClose(into toasts: ToastCenter) {
            registry.onClose = { [session, weak registry] window in
                guard let registry else { return }
                WindowClosing.tidy(window, session: session, registry: registry, toasts: toasts)
            }
        }

        /// A window beside the others with no project, on the scratch tabs.
        func addEmptyWindow() throws -> ProjectWindowState {
            let id = WorkspaceSessionFixture.addWindow(to: session)
            let window = try registry.addWindow(#require(session.selection(id)))
            registry.show(id)
            return window
        }

    }

    private static let english = Locale(identifier: "en")

    // MARK: - Closing, hiding, and the primary

    @Test func closingOneOfTwoWindows_closesIt_andKeepsItsProjectsViewAndAgents() throws {
        let fixture = try Fixture()
        let pane = fixture.secondPane
        let badge = AgentBadge(state: .running, updatedAt: Date(timeIntervalSince1970: 100))
        fixture.session.update(fixture.secondTab.id) { $0.agentBadges[.claude] = [pane: badge] }

        fixture.close(fixture.other)

        #expect(fixture.registry.window(fixture.other.id) == nil)
        #expect(fixture.session.selection(fixture.other.id) == nil)
        #expect(fixture.presenter.closed == [fixture.other.id])
        #expect(!fixture.primary.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        // The project keeps what the window showed, and its session runs on.
        let view = try #require(fixture.session.projectViews[fixture.second.id])
        #expect(view.activeTabID == fixture.secondTab.id)
        #expect(view.activeContainerID == fixture.secondTab.container)
        #expect(fixture.registry.windows.map(\.id) == [fixture.primary.id])
        #expect(fixture.presenter.isOnScreen(fixture.primary.id))
        let tab = try #require(fixture.session.tab(fixture.secondTab.id))
        #expect(tab.splitTree.allLeafIDs() == [pane])
        #expect(tab.agentBadges[.claude] == [pane: badge])
        #expect(fixture.session.hasLiveAgent(inProject: fixture.second.id))
        let reopened = try #require(fixture.registry.openInNewWindow(
            project: fixture.second.id,
            in: fixture.session,
            from: fixture.primary
        ))
        #expect(reopened.selection.activeTabID == tab.id)
        #expect(reopened.selection.activeContainerID == tab.container)
        #expect(fixture.session.projectViews[fixture.second.id] == nil)
    }

    @Test func closingTheLastWindow_hidesIt_andTheDockBringsItBack() throws {
        let fixture = try Fixture()
        fixture.close(fixture.other)
        let primary = fixture.primary
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)
        defer { fixture.registry.onClose = nil }
        fixture.presenter.shown = []
        #expect(fixture.presenter.isOnScreen(primary.id))

        fixture.close(primary)

        #expect(primary.isHidden)
        #expect(!fixture.presenter.isOnScreen(primary.id))
        #expect(fixture.registry.windows.map(\.id) == [primary.id])
        #expect(fixture.presenter.closed == [fixture.other.id])
        #expect(fixture.session.hiddenWindowIDs == [primary.id])
        #expect(fixture.session.selection(primary.id) === primary.selection)
        #expect(primary.selection.shownProjectID == fixture.first.id)
        #expect(primary.selection.activeTabID == fixture.firstTab.id)
        #expect(fixture.session.projectViews[fixture.first.id] == nil)
        #expect(toasts.items.isEmpty)

        fixture.registry.showLastWindow()

        #expect(fixture.presenter.shown == [primary.id])
        #expect(fixture.presenter.isOnScreen(primary.id))
        #expect(!primary.isHidden)
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(fixture.session.selection(primary.id) === primary.selection)
        #expect(primary.selection.activeTabID == fixture.firstTab.id)
    }

    @Test(arguments: [false, true])
    func closingThePrimaryPromotesTheOtherWindowEvenWhenMinimized(isMinimized: Bool) throws {
        let fixture = try Fixture()
        let closing = fixture.primary
        fixture.registry.windowBecameKey(closing.id)
        if isMinimized {
            fixture.registry.windowScreenPresenceChanged(fixture.other.id, isOnScreen: false)
            fixture.presenter.onScreen.remove(fixture.other.id)
        }
        #expect(!fixture.other.isHidden)
        #expect(fixture.presenter.isOnScreen(fixture.other.id) != isMinimized)

        fixture.close(closing)

        #expect(fixture.presenter.closed == [closing.id])
        #expect(fixture.registry.window(closing.id) == nil)
        #expect(fixture.session.selection(closing.id) == nil)
        #expect(fixture.registry.primary === fixture.other)
        #expect(fixture.registry.windows.map(\.id) == [fixture.other.id])
        #expect(fixture.session.primaryWindowID == fixture.other.id)
        #expect(fixture.session.primarySelection === fixture.other.selection)
        #expect(fixture.session.windowIDs == [fixture.other.id])
        #expect(fixture.session.hiddenWindowIDs.isEmpty)
        #expect(fixture.session.primarySelection.activeTabID == fixture.secondTab.id)
        #expect(fixture.registry.backgroundCommandTarget === fixture.other)
        #expect(fixture.registry.noticeWindow === fixture.other)
        let view = try #require(fixture.session.projectViews[fixture.first.id])
        #expect(view.activeTabID == fixture.firstTab.id)
        #expect(view.activeContainerID == fixture.firstTab.container)
    }

    @Test func aClosedKeyWindow_leavesNoCommandTarget() throws {
        let fixture = try Fixture()
        fixture.registry.windowBecameKey(fixture.other.id)

        fixture.close(fixture.other)

        // Closed, it has no keyboard; AppKit makes another window key and
        // that one reports in turn.
        #expect(fixture.registry.commandTarget == nil)
        fixture.registry.windowBecameKey(fixture.primary.id)
        #expect(fixture.registry.commandTarget === fixture.primary)
    }

    @Test func closingAWindowNeverLeavesTwoHidden() throws {
        let fixture = try Fixture()
        fixture.close(fixture.other)
        fixture.close(fixture.primary)
        let hidden = fixture.primary
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)
        defer { fixture.registry.onClose = nil }
        let opened = fixture.windowBeside(hidden, showing: fixture.second)
        #expect(fixture.session.hiddenWindowIDs == [hidden.id])
        #expect(fixture.presenter.isOnScreen(opened.id))

        fixture.close(opened)

        #expect(fixture.registry.windows.map(\.id) == [opened.id])
        #expect(opened.isHidden)
        #expect(!fixture.presenter.isOnScreen(opened.id))
        #expect(fixture.registry.primary === opened)
        #expect(fixture.session.primarySelection === opened.selection)
        #expect(fixture.session.windowIDs == [opened.id])
        #expect(fixture.session.hiddenWindowIDs == [opened.id])
        #expect(fixture.presenter.closed == [fixture.other.id, hidden.id])
        #expect(fixture.session.selection(hidden.id) == nil)
        let view = try #require(fixture.session.projectViews[fixture.first.id])
        #expect(view.activeTabID == fixture.firstTab.id)
        #expect(view.activeContainerID == fixture.firstTab.container)
        #expect(toasts.items.isEmpty)
    }

    // MARK: - What the closed window held

    @Test func aClosedWindowsPanes_stopCountingAsDrawnOrSeen() throws {
        let fixture = try Fixture()
        let closedPane = fixture.secondPane
        let survivingPane = try #require(fixture.firstTab.splitTree.allLeafIDs().first)
        fixture.registry.didReportDisplay(window: fixture.primary.id, rendered: [survivingPane], attended: [survivingPane])
        fixture.registry.didReportDisplay(window: fixture.other.id, rendered: [closedPane], attended: [closedPane])
        #expect(fixture.registry.visibility.union == [survivingPane, closedPane])
        #expect(fixture.registry.attention.attendedPanes == [survivingPane, closedPane])

        fixture.close(fixture.other)
        #expect(fixture.registry.visibility.union == [survivingPane])
        #expect(fixture.registry.attention.attendedPanes == [survivingPane])
        fixture.registry.didReportDisplay(window: fixture.other.id, rendered: [closedPane], attended: [closedPane])
        #expect(fixture.registry.visibility.union == [survivingPane])
        #expect(fixture.registry.attention.attendedPanes == [survivingPane])
    }

    @Test func aClosedWindowsToastsCardsAndAnchors_go() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        let approvals = ApprovalPresentationStore()
        let closingCard = fixture.other.approvalCard
        let survivingCard = fixture.primary.approvalCard
        fixture.tidiesOnClose(into: toasts)
        defer {
            fixture.registry.onClose = nil
            toasts.dismiss(in: fixture.other.id)
            toasts.dismiss(in: fixture.primary.id)
        }
        let request = ApprovalPresentation.test()
        let survivor = ApprovalPresentation.test(epoch: request.epoch)
        approvals.receive([request, survivor])
        let closed = fixture.other.id
        let anchor = CGRect(x: 0, y: 40, width: 200, height: 20)
        let otherAnchor = CGRect(x: 20, y: 100, width: 200, height: 20)
        closingCard.updateRowAnchor(anchor, for: request, in: approvals)
        survivingCard.updateRowAnchor(otherAnchor, for: survivor, in: approvals)
        #expect(closingCard.present(key: request.key, from: approvals))
        #expect(survivingCard.present(key: survivor.key, from: approvals))
        let closingToast = ToastItem(message: .verbatim("Done"), undo: nil)
        let survivingToast = ToastItem(message: .verbatim("Undo this change"), undo: {})
        toasts.show(closingToast, in: closed)
        toasts.show(survivingToast, in: fixture.primary.id)
        #expect(closingCard.rowAnchor(for: request) == anchor)
        #expect(closingCard.presentedApproval(in: approvals) == request)
        #expect(toasts.current(in: closed)?.id == closingToast.id)

        fixture.close(fixture.other)

        #expect(toasts.current(in: closed) == nil)
        #expect(closingCard.state == ApprovalCardState())
        #expect(closingCard.presentedApproval(in: approvals) == nil)
        #expect(closingCard.rowAnchor(for: request) == nil)
        #expect(survivingCard.presentedApproval(in: approvals) == survivor)
        #expect(survivingCard.rowAnchor(for: survivor) == otherAnchor)
        #expect(toasts.current(in: fixture.primary.id)?.id == survivingToast.id)
        #expect(approvals.pending.map(\.id) == [request.id, survivor.id])
    }

    @Test func aNoticeFixedToAClosedWindow_movesToAShownOne() throws {
        let fixture = try Fixture()
        let placed = fixture.other.id

        fixture.close(fixture.other)

        #expect(fixture.registry.placeNotice(keeping: placed) { fixture.registry.noticeWindow } == fixture.primary.id)
    }

    @Test func theScratchOfAClosedWindow_goesToAnotherThatHasItSelected() throws {
        let fixture = try Fixture()
        let scratch = fixture.session.openTab(container: .loose, in: fixture.other.id)
        // The primary has it selected too, without having chosen it.
        fixture.session.setActiveTab(scratch.id, in: fixture.primary.id, intent: .repair)
        #expect(fixture.session.scratchDrawingWindowID == fixture.other.id)

        fixture.close(fixture.other)

        #expect(fixture.session.scratchDrawingWindowID == fixture.primary.id)
        #expect(fixture.session.windows(showing: scratch.id) == [fixture.primary.id])
        // The closed window's project comes back to the scratch tab it was on.
        let view = try #require(fixture.session.projectViews[fixture.second.id])
        #expect(view.activeContainerID == .loose)
        #expect(view.activeTabID == scratch.id)
    }

    @Test func theViewAClosedWindowLeaves_movesNoWindowOnScratchWithNoProject() throws {
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("only"), suggestedName: "only")
        let projectTab = session.openTab(container: .project(project.id))
        let scratch = session.openTab(container: .loose)
        session.setActiveTab(scratch.id)
        // The primary has shown no project: the only one is another window's.
        session.primarySelection.projectID = nil
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let id = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(projectTab.id, in: id)
        let selection = try #require(session.selection(id))
        selection.projectID = project.id
        let window = registry.addWindow(selection)
        registry.show(session.primaryWindowID)
        registry.show(id)
        #expect(session.primarySelection.shownProjectID == nil)

        registry.close(window.id, in: session)

        #expect(session.primarySelection.activeTabID == scratch.id)
        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.primarySelection.projectID == nil)
        #expect(session.projectViews[project.id]?.activeTabID == projectTab.id)
    }

    // MARK: - Work that ends after its window closed

    @Test(.timeLimit(.minutes(1)))
    func aSetupFinishingAfterItsWindowClosed_movesNoOtherWindow() async throws {
        try await withTempDir { dir in
            let started = dir.appendingPathComponent("started")
            let release = dir.appendingPathComponent("release")
            let command = "touch '\(started.path)'; while [ ! -f '\(release.path)' ]; do sleep 0.02; done"
            let fixture = try await SessionLaunchFixture.make(in: dir, bootstrap: [.shorthand(command)])
            defer { fixture.store.cancelAll() }
            let session = fixture.session
            let row = ContainerID.worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            // The primary shows another project, on its empty row.
            let elsewhere = session.addOrActivateProject(rootURL: dir.appendingPathComponent("elsewhere"), suggestedName: "elsewhere")
            session.setActiveContainer(.project(elsewhere.id))
            session.primarySelection.projectID = elsewhere.id
            let registry = WindowRegistry(primary: session.primarySelection)
            registry.presenter = RecordingWindowPresenter()
            // The session is asked for in a second window, on its empty row,
            // where the tab would come to front.
            let launching = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(row, in: launching)
            try registry.addWindow(#require(session.selection(launching)))
            registry.show(session.primaryWindowID)
            registry.show(launching)
            fixture.store.begin(
                projectID: fixture.project.id,
                worktreeID: fixture.worktree.id,
                request: SessionLaunchRequest(open: .shell),
                in: session,
                window: launching
            )

            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                FileManager.default.fileExists(atPath: started.path)
            }
            try #require(FileManager.default.fileExists(atPath: started.path))
            try #require(fixture.store.launch(in: row)?.phase == .settingUp(stepIndex: 0, stepCount: 1, command: command))
            #expect(fixture.tabs.isEmpty)

            registry.close(launching, in: session)
            #expect(registry.window(launching) == nil)
            #expect(session.selection(launching) == nil)
            try Data().write(to: release)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                !fixture.tabs.isEmpty
            }

            let tab = try #require(fixture.tabs.first)
            #expect(session.windowIDs == [session.primaryWindowID])
            #expect(session.primarySelection.activeContainerID == .project(elsewhere.id))
            #expect(session.primarySelection.activeTabID == nil)
            // The row the window left shows the new tab when the project is
            // shown again: the tab would have come to front there.
            #expect(session.projectViews[fixture.project.id]?.activeContainerID == row)
            #expect(session.projectViews[fixture.project.id]?.activeTabID == tab.id)
            let reopened = try #require(registry.openInNewWindow(project: fixture.project.id, in: session, from: registry.primary))
            #expect(reopened.selection.activeContainerID == row)
            #expect(reopened.selection.activeTabID == tab.id)
            #expect(session.projectViews[fixture.project.id] == nil)
            #expect(session.primarySelection.activeContainerID == .project(elsewhere.id))
        }
    }

    @Test func anAwaitedOpenFromAClosedWindow_writesNoPrimarySelection() async throws {
        let fixture = try Fixture()
        let before = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))
        let folder = URL(fileURLWithPath: "/weir-opened-\(UUID().uuidString)")

        let project = await fixture.session.openProject(at: folder, in: fixture.other.id, intent: .person) { url in
            // The window closes while the folder is resolved.
            fixture.close(fixture.other)
            return url
        }

        #expect(fixture.session.windowIDs == [fixture.primary.id])
        #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == before)
        #expect(fixture.session.projectViews[project.id] == nil)
        let tab = try #require(fixture.session.tabs(in: .project(project.id)).first)
        #expect(fixture.session.project(project.id)?.lastActiveTabID == tab.id)
    }

    @Test func aPaletteRunAddressedToAClosedWindow_doesNothing() throws {
        let fixture = try Fixture()
        let closed = fixture.other.id
        fixture.close(fixture.other)
        let before = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))

        try CommandPaletteActions.runRowForTest(
            .activateProject(fixture.second.id),
            session: fixture.session,
            window: closed,
            commands: fixture.registry
        )

        #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == before)
        #expect(fixture.session.windowIDs == [fixture.primary.id])
        // The row a window's chrome would run is for that window alone: a
        // closed window runs nothing, and no other window runs it for it.
        let ranInPrimary = Recorded(false)
        let token = fixture.primary.commands.requests.sink { _ in ranInPrimary.value = true }
        defer { token.cancel() }
        let execution = CommandPaletteExecution(action: .activateProject(fixture.second.id), windowID: closed)
        #expect(!fixture.registry.perform(.runPaletteRow(execution), in: closed))
        #expect(!ranInPrimary.value)
    }

    @Test func restoreCompletionRoutingFollowsTheOriginThenItsSurvivorOrReopenedPane() throws {
        let fixture = try Fixture()
        let pane = fixture.secondPane
        let closed = fixture.other
        // Open, it is told where it began.
        let open = RestoreActions.places(forEndOf: closed, paneID: pane, registry: fixture.registry, session: fixture.session)
        #expect(open.toast === closed)
        #expect(open.bar === closed)

        fixture.close(closed)

        // No window shows the pane. The remaining window takes the toast
        // route, and there is no decision bar destination.
        let gone = RestoreActions.places(forEndOf: closed, paneID: pane, registry: fixture.registry, session: fixture.session)
        #expect(gone.toast === fixture.primary)
        #expect(gone.bar == nil)

        // Shown again in a window of its own, the project's window tells it,
        // and the bar of the window that draws the pane takes the line.
        let reopened = try #require(fixture.registry.openInNewWindow(project: fixture.second.id, in: fixture.session, from: nil))
        let again = RestoreActions.places(forEndOf: closed, paneID: pane, registry: fixture.registry, session: fixture.session)
        #expect(again.toast === reopened)
        #expect(again.bar === reopened)
    }

    // MARK: - The toast

    @Test func theToast_isToldInTheWindowLeft_withTheProjectsName() throws {
        let fixture = try Fixture()
        let toasts = ToastCenter()
        fixture.tidiesOnClose(into: toasts)

        fixture.close(fixture.other)

        let toast = try #require(toasts.current(in: fixture.primary.id))
        guard case let .localized(message) = toast.message else {
            Issue.record("the toast is localized")
            return
        }
        #expect(message.resolved(in: Self.english) == "Closed the window. second’s agents and terminals keep running.")
        #expect(toast.undo == nil)
    }

    @Test func closingAnEmptyWindow_showsNoToast_andTheFixtureReleasesItsRegistry() throws {
        weak var registry: WindowRegistry?
        do {
            let fixture = try Fixture()
            registry = fixture.registry
            let empty = try fixture.addEmptyWindow()
            let toasts = ToastCenter()
            fixture.tidiesOnClose(into: toasts)

            fixture.close(empty)

            #expect(fixture.registry.window(empty.id) == nil)
            #expect(toasts.items.isEmpty)
        }
        #expect(registry == nil)
    }

}
