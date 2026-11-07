// ReviewTabActionsTests.swift
// Weir — the review tab among a window's tabs: opening it through the window's stores, stepping to it and past it,
// putting it behind a terminal tab, and closing it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Review tab actions")
struct ReviewTabActionsTests {
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let window: ProjectWindowState
        let first: Tab
        let second: Tab

        init() {
            let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
            let container = ContainerID.project(project.id)
            first = session.openTab(container: container)
            second = session.openTab(container: container)
            self.session = session
            window = ProjectWindowState(selection: session.primarySelection)
        }

        var tabs: [Tab] {
            session.tabs(in: session.primarySelection.activeContainerID)
        }

        /// A review opened from `agent`, in front unless said otherwise.
        func openReview(from agent: UUID?, isShown: Bool = true) {
            window.review = ReviewTabState(
                root: "/repo",
                selection: .uncommitted(includesChangesOutsideTurns: false),
                fixedPoint: ReviewTabFixedPoint(),
                agentPaneID: agent,
                destinationPaneID: agent,
                isShown: isShown,
                opening: UUID()
            )
            window.reviewPresentation.open(URL(fileURLWithPath: "/repo"), originPaneID: agent, initialScope: .uncommitted)
        }

        func cycle(forward: Bool) {
            ReviewTabActions.cycleTab(
                forward: forward,
                window: window,
                session: session,
                registry: RecordingSurfaceRegistry(),
                paneVisibility: PaneVisibilityReporter()
            )
        }
    }

    /// Close and Close Tab, run from a palette row or the channel in a
    /// window that is not the key one, close the review in front of that
    /// window and leave the key window as it is.
    @Test func closeIfInFront_closesTheReviewOfTheWindowAsked_notTheKeyWindows() async throws {
        let fixture = ActionStoresFixture(opensTab: false)
        let key = fixture.window
        let selection = WindowSelection()
        fixture.session.addSelection(selection)
        let other = fixture.windows.addWindow(selection)
        fixture.windows.windowBecameKey(key.id)
        #expect(fixture.windows.commandTarget === key)
        #expect(fixture.session.activeTab(in: other.id) == nil)
        other.review = ReviewTabState(
            root: fixture.root,
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: key, stores: fixture.review)
        let keyOpening = try #require(key.review?.opening)
        let keySession = try #require(key.reviewSession)
        try #require(key.review?.isShown == true)

        #expect(ReviewTabActions.closeIfInFront(in: other, stores: fixture.review))

        #expect(other.review == nil)
        #expect(key.review?.opening == keyOpening)
        #expect(key.review?.isShown == true)
        #expect(key.reviewSession === keySession)
        key.review?.isShown = false
        #expect(!ReviewTabActions.closeIfInFront(in: key, stores: fixture.review))
        #expect(!ReviewTabActions.closeIfInFront(in: nil, stores: fixture.review))
    }

    /// An open that finds no repository, or whose person moved on, leaves
    /// no request behind: while one stands, the window is taken to be
    /// opening a review and is passed over for one another window parks.
    /// A later open's request is that one's to clear.
    @Test func anOpen_clearsItsRequest_howeverItEnds() async throws {
        let window = ProjectWindowState(id: WindowID())
        let request = ReviewOpenRequest(containerID: .loose, tabID: nil)
        let found: URL? = await window.openingReview(request) {
            #expect(window.reviewOpenRequest == request)
            return nil
        }
        #expect(found == nil)
        #expect(window.reviewOpenRequest == nil)

        let root = URL(fileURLWithPath: "/tmp/review")
        let success = await window.openingReview(request) { root }
        #expect(success == root)
        #expect(window.reviewOpenRequest == nil)

        let olderGate = Gate<URL>()
        let newerGate = Gate<URL>()
        defer {
            olderGate.open(with: root)
            newerGate.open(with: root)
        }
        let older = Task { @MainActor in await window.openingReview(request) { await olderGate.wait() } }
        try await olderGate.waitUntilRequested()
        let later = ReviewOpenRequest(containerID: .loose, tabID: nil)
        let newer = Task { @MainActor in await window.openingReview(later) { await newerGate.wait() } }
        try await newerGate.waitUntilRequested()
        try #require(window.reviewOpenRequest == later)

        olderGate.open(with: root)
        _ = await older.value
        #expect(window.reviewOpenRequest == later)
        newerGate.open(with: root)
        #expect(await newer.value == root)
        #expect(window.reviewOpenRequest == nil)
    }

    @Test(arguments: [true, false])
    func cyclingThroughTheReview_wrapsInEitherDirection(forward: Bool) {
        let fixture = Fixture()
        let current = forward ? fixture.second : fixture.first
        let next = forward ? fixture.first : fixture.second
        fixture.session.setActiveTab(current.id)
        fixture.openReview(from: nil, isShown: false)

        fixture.cycle(forward: forward)
        #expect(fixture.window.review?.isShown == true)
        #expect(fixture.session.primarySelection.activeTabID == current.id, "the terminal tab stays behind it")

        fixture.cycle(forward: forward)
        #expect(fixture.window.review?.isShown == false)
        #expect(fixture.session.primarySelection.activeTabID == next.id)
    }

    @Test func withoutAReview_theTerminalTabsStepAsBefore() throws {
        let fixture = Fixture()
        let tabs = fixture.tabs
        let last = try #require(tabs.last)
        fixture.session.setActiveTab(last.id)

        fixture.cycle(forward: true)

        #expect(fixture.session.primarySelection.activeTabID == tabs.first?.id)
        #expect(fixture.window.review == nil)
    }

    @Test func goingToTheTabBehindTheReview_bringsItInFront_andDropsAnOpenStillOnItsWay() async throws {
        let stores = ActionStoresFixture()
        let active = try #require(stores.session.primarySelection.activeTabID)
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: stores.window, stores: stores.review)
        let original = try #require(stores.window.review)
        let reviewSession = try #require(stores.window.reviewSession)
        let root = stores.project.rootURL
        let gate = Gate<URL>()
        defer { gate.open(with: root) }
        stores.gitRoot = { _ in await gate.wait() }
        let pending = Task { @MainActor in
            await ReviewTabActions.open(.worktreeUnviewedTurns, agentPaneID: nil, window: stores.window, stores: stores.review)
        }
        try await gate.waitUntilRequested()
        try #require(stores.window.reviewOpenRequest != nil)

        // ⌘1 on the tab already behind the review, or ⌘J to one of its panes.
        ReviewTabActions.putBehind(
            window: stores.window,
            session: stores.session,
            registry: stores.registry,
            paneVisibility: Self.paneVisibility(stores)
        )

        #expect(stores.window.reviewOpenRequest == nil)
        gate.open(with: root)
        await pending.value
        #expect(stores.window.review?.isShown == false)
        #expect(stores.window.review?.opening == original.opening)
        #expect(stores.window.review?.selection == original.selection)
        #expect(stores.window.reviewSession === reviewSession)
        #expect(stores.session.primarySelection.activeTabID == active)
    }

    @Test func anOpen_landsOnlyWhereThePersonAskedForIt() async throws {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        let request = ReviewOpenRequest(
            containerID: fixture.session.primarySelection.activeContainerID,
            tabID: fixture.session.primarySelection.activeTabID
        )
        fixture.window.reviewOpenRequest = request

        #expect(ReviewTabActions.isCurrent(request, window: fixture.window, session: fixture.session))
        // ⌘T, a session's row, or a notification while Git answers.
        fixture.session.setActiveTab(fixture.second.id)
        #expect(!ReviewTabActions.isCurrent(request, window: fixture.window, session: fixture.session))
        fixture.session.setActiveTab(fixture.first.id)
        fixture.window.reviewOpenRequest = ReviewOpenRequest(
            containerID: fixture.session.primarySelection.activeContainerID,
            tabID: fixture.session.primarySelection.activeTabID
        )
        #expect(!ReviewTabActions.isCurrent(request, window: fixture.window, session: fixture.session), "a newer open replaced it")

        let stores = ActionStoresFixture()
        let next = stores.session.openTab(container: .project(stores.project.id))
        stores.session.setActiveTab(nil)
        let gate = Gate<URL>()
        let root = stores.project.rootURL
        defer { gate.open(with: root) }
        stores.gitRoot = { _ in await gate.wait() }
        let opening = Task { @MainActor in
            await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: stores.window, stores: stores.review)
        }
        try await gate.waitUntilRequested()
        try #require(stores.window.reviewOpenRequest != nil)
        stores.session.setActiveTab(next.id)
        gate.open(with: root)
        await opening.value
        #expect(stores.window.reviewOpenRequest == nil)
        #expect(stores.window.review == nil)
        #expect(stores.window.reviewSession == nil)
        #expect(stores.session.primarySelection.activeTabID == next.id)

        let oldGate = Gate<URL>()
        let newGate = Gate<URL>()
        defer {
            oldGate.open(with: root)
            newGate.open(with: root)
        }
        stores.gitRoot = { _ in await oldGate.wait() }
        let older = Task { @MainActor in
            await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: stores.window, stores: stores.review)
        }
        try await oldGate.waitUntilRequested()
        let oldRequest = try #require(stores.window.reviewOpenRequest)
        stores.gitRoot = { _ in await newGate.wait() }
        let newer = Task { @MainActor in
            await ReviewTabActions.open(.worktreeUnviewedTurns, agentPaneID: nil, window: stores.window, stores: stores.review)
        }
        try await newGate.waitUntilRequested()
        let newRequest = try #require(stores.window.reviewOpenRequest)
        try #require(oldRequest != newRequest)

        oldGate.open(with: root)
        await older.value
        #expect(stores.window.reviewOpenRequest == newRequest)
        #expect(stores.window.review == nil)

        newGate.open(with: root)
        await newer.value
        #expect(stores.window.reviewOpenRequest == nil)
        #expect(stores.window.review?.selection == .worktreeUnviewedTurns(.none))
    }

    @Test func closingTheOldSessionsReview_leavesAnOpenAskedForInTheNewOne() throws {
        let fixture = Fixture()
        let origin = try #require(fixture.first.splitTree.allLeafIDs().first)
        fixture.openReview(from: origin)
        let scratch = fixture.session.openTab(container: .loose)
        fixture.session.setActiveTab(scratch.id)
        // ⌘J to another session's turn asked for its review there.
        let request = ReviewOpenRequest(containerID: .loose, tabID: scratch.id)
        fixture.window.reviewOpenRequest = request

        ReviewTabActions.close(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(),
            returnsToAgent: false
        )

        #expect(fixture.window.reviewOpenRequest == request)
        #expect(fixture.window.review == nil)
        #expect(fixture.session.primarySelection.activeContainerID == .loose)
        #expect(fixture.session.primarySelection.activeTabID == scratch.id)
    }

    @Test func aTerminalTabComingInFront_putsTheReviewBehind_butATabClosedUnderItDoesNot() {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        fixture.openReview(from: nil)

        fixture.session.setActiveTab(fixture.second.id)
        #expect(fixture.session.primarySelection.activeTabID == fixture.second.id)
        #expect(ReviewTabActions.activeTabChangePutsReviewBehind(from: fixture.first.id, window: fixture.window, session: fixture.session))
        fixture.session.closeTab(fixture.first.id)
        #expect(!ReviewTabActions.activeTabChangePutsReviewBehind(
            from: fixture.first.id,
            window: fixture.window,
            session: fixture.session
        ), "the person did not move")
        fixture.window.review?.isShown = false
        #expect(!ReviewTabActions.activeTabChangePutsReviewBehind(
            from: fixture.second.id,
            window: fixture.window,
            session: fixture.session
        ))
    }

    @Test func theRowsLastTerminalTabClosingInFrontOfTheReview_bringsTheReviewForward() {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        fixture.openReview(from: nil, isShown: false)
        let bringsForward = { (closed: UUID) in
            ReviewTabActions.activeTabChangeBringsReviewForward(from: closed, window: fixture.window, session: fixture.session)
        }

        fixture.session.setActiveTab(fixture.second.id)
        #expect(!bringsForward(fixture.first.id), "the tab left is still open")
        fixture.session.setActiveTab(fixture.first.id)
        fixture.session.closeTab(fixture.first.id)
        #expect(!bringsForward(fixture.first.id), "another terminal tab is left to show")
        fixture.session.closeTab(fixture.second.id)
        #expect(bringsForward(fixture.second.id), "the review is the only tab left")

        fixture.window.review?.isShown = true
        #expect(!bringsForward(fixture.second.id), "the review is already in front")
    }

    @Test func aTabPickedFromThePalette_comesInFrontOfTheReview_onlyWhileTheReviewIsInFront() {
        let fixture = Fixture()
        fixture.session.setActiveTab(fixture.first.id)
        fixture.openReview(from: nil)
        let comesInFront = { (tab: UUID) in
            ReviewTabActions.pickedTabComesInFrontOfReview(tab, window: fixture.window, session: fixture.session)
        }

        #expect(comesInFront(fixture.first.id), "the tab under the review, already the active one")
        #expect(comesInFront(fixture.second.id))
        // Opened without selecting it, so the window stays on the project.
        let scratch = fixture.session.openTab(
            container: .loose,
            in: fixture.session.primaryWindowID,
            intent: .person,
            selects: false
        )
        #expect(!comesInFront(scratch.id), "a tab of another row switches rows, which settles the review itself")

        fixture.window.review?.isShown = false
        #expect(!comesInFront(fixture.first.id), "with the review behind, picking the tab is an ordinary switch")
    }

    @Test(arguments: [true, false])
    func closing_releasesTheReviewAndSelectsTheRequestedTerminal(returnsToAgent: Bool) throws {
        let fixture = Fixture()
        let agent = try #require(fixture.first.splitTree.allLeafIDs().first)
        fixture.session.setActiveTab(fixture.second.id)
        fixture.openReview(from: agent)
        fixture.window.reviewSession = ProjectWindowState.reviewSession(root: "/repo")
        try #require(fixture.window.reviewSession != nil && fixture.window.reviewPresentation.isPresented)
        let registry = RecordingSurfaceRegistry()
        let visibility = PaneVisibilityReporter()

        if returnsToAgent {
            ReviewTabActions.close(window: fixture.window, session: fixture.session, registry: registry, paneVisibility: visibility)
        } else {
            ReviewTabActions.close(
                window: fixture.window, session: fixture.session, registry: registry, paneVisibility: visibility, returnsToAgent: false
            )
        }

        #expect(fixture.window.review == nil)
        #expect(fixture.window.reviewSession == nil)
        #expect(!fixture.window.reviewPresentation.isPresented)
        #expect(fixture.session.primarySelection.activeTabID == (returnsToAgent ? fixture.first.id : fixture.second.id))
    }

    @Test func hidingTheWindow_closesItsReview_unlessACommentIsBeingWritten() {
        let fixture = Fixture()
        fixture.openReview(from: nil)
        fixture.window.reviewOpenRequest = ReviewOpenRequest(containerID: fixture.session.primarySelection.activeContainerID, tabID: nil)
        let editing = fixture.window.writeComment()
        let opening = fixture.window.review?.opening
        let composer = editing.composer
        editing.unplacedComment = "Set aside text"

        ReviewTabActions.windowHidden(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )
        #expect(fixture.window.review?.opening == opening, "kept for when the window comes back")
        #expect(fixture.window.reviewSession === editing)
        #expect(fixture.window.reviewSession?.composer == composer)
        #expect(fixture.window.reviewSession?.unplacedComment == "Set aside text")
        #expect(fixture.window.reviewOpenRequest == nil, "an open on its way would open it again")

        fixture.window.letGoOfComment()
        ReviewTabActions.windowHidden(
            window: fixture.window,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter()
        )
        #expect(fixture.window.review == nil)
        #expect(!fixture.window.reviewPresentation.isPresented)
    }

    @Test func theReviewTab_isInItsOwnSessionsStripOnly() throws {
        let fixture = Fixture()
        let agent = try #require(fixture.first.splitTree.allLeafIDs().first)
        let container = try #require(fixture.session.tab(containing: agent)?.container)
        fixture.openReview(from: agent)
        let elsewhere = ContainerID.loose
        let scratch = fixture.session.openTab(container: elsewhere, in: fixture.window.id, intent: .person, selects: false)
        #expect(fixture.session.tab(scratch.id)?.container == elsewhere)

        #expect(fixture.window.reviewStripTab(in: container, session: fixture.session) == .inFront)
        #expect(fixture.window.reviewStripTab(in: elsewhere, session: fixture.session) == .none)
        fixture.window.review?.isShown = false
        #expect(fixture.window.reviewStripTab(in: container, session: fixture.session) == .behind)
        #expect(fixture.window.reviewStripTab(in: elsewhere, session: fixture.session) == .none)

        fixture.session.setActiveTab(scratch.id)
        fixture.openReview(from: nil)
        #expect(fixture.window.reviewStripTab(in: elsewhere, session: fixture.session) == .inFront, "no agent's pane to place it by")
    }

    // MARK: - Opening through the window's stores

    private static func paneVisibility(_ fixture: ActionStoresFixture) -> PaneVisibilityReporter {
        PaneVisibilityReporter(windowID: fixture.window.id, registry: fixture.windows)
    }

    @Test func showCurrentDiff_opensTheTabOnTheWorktreesTopLevel() async throws {
        let fixture = ActionStoresFixture()
        let ancestor = fixture.project.rootURL.deletingLastPathComponent()
        var lookedUp: [URL] = []
        fixture.gitRoot = { directory in
            lookedUp.append(directory)
            return ancestor
        }

        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)

        let tab = try #require(fixture.window.review)
        let active = try #require(fixture.window.reviewSession)
        #expect(lookedUp == [fixture.project.rootURL])
        #expect(tab.root == ancestor.path)
        #expect(tab.selection == .uncommitted(includesChangesOutsideTurns: false))
        #expect(tab.isShown)
        #expect(active.root == ancestor.resolvingSymlinksInPath())
        #expect(fixture.window.reviewPresentation.isPresented)
        #expect(fixture.window.reviewStripTab(in: .project(fixture.project.id), session: fixture.session) == .inFront)
        #expect(fixture.toasts.current(in: fixture.window.id) == nil)
    }

    @Test func outsideARepository_noTabOpens_andAToastSaysWhy() async {
        let fixture = ActionStoresFixture()
        fixture.gitRoot = { _ in throw ReviewError.gitFailed }

        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)

        #expect(fixture.window.review == nil)
        #expect(fixture.window.reviewOpenRequest == nil)
        #expect(fixture.toasts.current(in: fixture.window.id)?.message.resolved(in: Locale(identifier: "en"))
            == "Git couldn’t load the changes. Try again.")

        fixture.gitRoot = { $0 }
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        let before = fixture.window.review
        let reviewSession = fixture.window.reviewSession
        #expect(before != nil && reviewSession != nil)
        fixture.gitRoot = { _ in throw ReviewError.gitFailed }
        await ReviewTabActions.open(.worktreeUnviewedTurns, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        #expect(fixture.window.review == before)
        #expect(fixture.window.reviewSession === reviewSession)
        #expect(fixture.window.reviewOpenRequest == nil)
    }

    @Test func askingForARunningTurn_keepsTheOpenReviewAndSaysWhy() async throws {
        let fixture = ActionStoresFixture()
        let turn = try TurnSummaryFixture.turn(
            "running", phase: "started", number: 1,
            extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", 1), root: fixture.root))
        )
        fixture.turnHistory.replace(with: [ConversationTurns(key: turn.conversation, turns: [turn])])
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        let opened = try #require(fixture.window.review)
        let reviewSession = try #require(fixture.window.reviewSession)
        let selected = fixture.session.primarySelection.activeTabID

        await ReviewTabActions.open(
            .turn(turn.turnID), agentPaneID: nil, conversation: turn.conversation, window: fixture.window, stores: fixture.review
        )

        #expect(fixture.window.review == opened)
        #expect(fixture.window.reviewSession === reviewSession)
        #expect(fixture.session.primarySelection.activeTabID == selected)
        #expect(fixture.toasts.current(in: fixture.window.id)?.message.resolved(in: Locale(identifier: "en"))
            == "This turn is still running.")
    }

    @Test func reviewUnviewedWithNothingUnviewed_opensTheTabSayingSo() async {
        let fixture = ActionStoresFixture()

        await ReviewTabActions.open(.worktreeUnviewedTurns, agentPaneID: nil, window: fixture.window, stores: fixture.review)

        #expect(fixture.window.review?.selection == .worktreeUnviewedTurns(.none))
        #expect(fixture.toasts.current(in: fixture.window.id) == nil)
    }

    @Test func theShortcut_closesTheTabInFront() async throws {
        let fixture = ActionStoresFixture()
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        try #require(fixture.window.review?.isShown == true)
        try #require(fixture.window.reviewSession != nil)
        fixture.gitRoot = { _ in
            Issue.record("Closing the visible review should not resolve Git again")
            throw ReviewError.gitFailed
        }

        await ReviewTabActions.toggle(window: fixture.window, stores: fixture.review, paneVisibility: Self.paneVisibility(fixture))

        #expect(fixture.window.review == nil)
        #expect(fixture.window.reviewSession == nil)
        #expect(!fixture.window.reviewPresentation.isPresented)
    }

    @Test func aTabPutBehind_comesBackToFrontWithItsScope() async throws {
        let fixture = ActionStoresFixture()
        let current = try #require(fixture.session.primarySelection.activeTabID)
        let next = fixture.session.openTab(container: .project(fixture.project.id))
        fixture.session.setActiveTab(current)
        await ReviewTabActions.open(.worktreeUnviewedTurns, agentPaneID: nil, window: fixture.window, stores: fixture.review)
        let before = try #require(fixture.window.review)
        let session = try #require(fixture.window.reviewSession)

        ReviewTabActions.hide(
            window: fixture.window,
            showing: next.id,
            session: fixture.session,
            registry: fixture.registry,
            paneVisibility: Self.paneVisibility(fixture)
        )
        #expect(fixture.window.review?.isShown == false)
        #expect(fixture.session.primarySelection.activeTabID == next.id)
        ReviewTabActions.show(window: fixture.window)

        #expect(fixture.window.review?.isShown == true)
        #expect(fixture.window.review?.opening == before.opening)
        #expect(fixture.window.review?.selection == before.selection)
        #expect(fixture.window.reviewSession === session)
    }
}
