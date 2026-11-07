// ReviewDiscardStoreTests.swift
// Weir — the one store of what became of the hunks discarded, which every window and every review of a worktree shares.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A worktree's discard records are the worktree's: every window and every
/// review of it reads and writes the same ones, whatever the review's
/// owner, wherever its tab is drawn or kept, and a discard or an undo still
/// running ends in them. A removed project's go with it, unless another
/// project or a kept review still reads that folder, and nothing else
/// lets any go.
@MainActor
struct ReviewDiscardStoreTests {
    typealias Fixture = ProjectWindowsFixture

    @Test func discardMarksSurviveProjectSwitches_ownerChanges_andWindowClosure() throws {
        let fixture = Fixture()
        let (tab, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        let other = try fixture.window(showing: fixture.c)
        let original = fixture.primary
        let scratchPane = try #require(fixture.scratchTab().splitTree.allLeafIDs().first)
        let projectPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        fixture.primary.review = tab
        fixture.primary.hunkDiscards[hunk] = ProjectWindowsFixture.discarded

        // A switch, and back.
        fixture.choose(fixture.bTab, in: original)
        #expect(original.selection.shownProjectID == fixture.b.id)
        #expect(original.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
        fixture.choose(fixture.aTab, in: original)
        #expect(original.selection.shownProjectID == fixture.a.id)
        #expect(original.review?.opening == tab.opening)
        #expect(fixture.primary.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)

        // The same tab opened again from a scratch pane, then a project's.
        var context = ReviewTabModel.Context(turns: [], isViewed: { _ in false }, branchBase: nil)
        context.isAgentPaneOfNoProject = true
        let scratchOwned = try ReviewTabModel.open(.uncommitted, context, root: tab.root, agentPaneID: scratchPane, current: tab).get()
        original.review = scratchOwned
        #expect(scratchOwned.agentPaneID == scratchPane)
        #expect(scratchOwned.isOfNoProjectNow(in: fixture.session))
        #expect(original.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
        context.isAgentPaneOfNoProject = false
        let projectOwned = try ReviewTabModel.open(.uncommitted, context, root: tab.root, agentPaneID: projectPane, current: scratchOwned)
            .get()
        original.review = projectOwned
        #expect(projectOwned.agentPaneID == projectPane)
        #expect(!projectOwned.isOfNoProjectNow(in: fixture.session))
        #expect(original.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)

        fixture.registry.close(original.id, in: fixture.session)
        #expect(fixture.registry.window(original.id) == nil)
        #expect(other.reviewDiscards === original.reviewDiscards)
        #expect(other.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
    }

    @Test func anUndoWithTheBridge_whenItsWindowCloses_clearsOnlyItsOperationsHunks() async throws {
        let fixture = Fixture()
        let (tab, hunk) = try Fixture.reviewAndHunk()
        let closing = try fixture.window(showing: fixture.c)
        closing.review = tab
        let journal = try RestoreJournalFixture.make(
            stageJSON: #"{"kind":"applied"}"#,
            fields: .init(opID: "discard", operation: "discard", root: hunk.root)
        )
        let undone = try RestoreJournalFixture.make(
            stageJSON: #"{"kind":"applied"}"#,
            fields: .init(opID: "undo", operation: "undo", root: hunk.root, undoes: journal.opID)
        )
        let sibling = ReviewHunkKey(
            scopeID: hunk.scopeID, root: hunk.root, fromTree: hunk.fromTree, toTree: hunk.toTree,
            path: hunk.path, header: "@@ -10 +10 @@"
        )
        let unrelated = Fixture.scratchHunk
        let discarded = ReviewHunkDiscardRecord.discarded(opID: journal.opID, root: journal.root, note: nil)
        closing.hunkDiscards[hunk] = discarded
        closing.hunkDiscards[sibling] = discarded
        closing.hunkDiscards[unrelated] = Fixture.discarded

        let request = Recorded<[String]?>(nil)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let bridge = RestoreCoordinator.Bridge(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { root, opID, _ in
                request.value = [root, opID]
                guard release.wait(timeout: .now() + 10) == .success else { return .refused(.unknown) }
                return .finished(undone)
            },
            recover: { _ in RestoreRecovery(journals: [journal], settled: []) }
        )
        let stores = try Self.stores(fixture, bridge: bridge)
        _ = await stores.restores.recover(roots: [journal.root])
        try #require(stores.restores.journal(journal.opID, in: journal.root) == journal)
        ReviewHunkDiscardActions.undo(Self.action(tab, hunk), window: closing, stores: stores, locale: Locale(identifier: "en"))
        await pollUntil(timeout: .seconds(5)) { request.value != nil }
        try #require(request.value == [journal.root, journal.opID])
        #expect(closing.hunkDiscards[hunk] == .running)
        #expect(closing.hunkDiscards[sibling] == discarded)
        fixture.registry.close(closing.id, in: fixture.session)
        #expect(fixture.registry.window(closing.id) == nil)
        release.signal()

        await pollUntil(timeout: .seconds(5)) { fixture.primary.hunkDiscards[hunk] != .running }
        #expect(fixture.primary.hunkDiscards[hunk] == nil)
        #expect(fixture.primary.hunkDiscards[sibling] == nil)
        #expect(fixture.primary.hunkDiscards[unrelated] == Fixture.discarded)
    }

    /// The bridge's result reaches the shared records after the initiating window closes.
    @Test(arguments: [true, false])
    func aDiscardWithTheBridge_whenItsWindowCloses_endsInTheStore(_ didWrite: Bool) async throws {
        let fixture = Fixture()
        let (tab, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        let closing = try fixture.window(showing: fixture.c)
        closing.review = tab
        let journal = try RestoreJournalFixture.make(
            stageJSON: #"{"kind":"applied"}"#,
            fields: .init(opID: "discard", operation: "discard", root: hunk.root)
        )
        let outcome: DiscardOutcome = didWrite
            ? .finished(journal, [DiscardHunkResult(path: hunk.path, header: hunk.header, result: .discarded)])
            : .refused(.unknown)
        let reached = Recorded(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let bridge = RestoreCoordinator.Bridge(
            restore: { _, _, _, _ in .refused(.unknown) },
            undo: { _, _, _ in .refused(.unknown) },
            recover: { _ in RestoreRecovery(journals: [], settled: []) },
            discard: { _, _ in
                reached.value = true
                // The wait is bounded, so a test that fails before letting
                // it go does not hold the bridge's queue for good.
                guard release.wait(timeout: .now() + 10) == .success else { return .refused(.unknown) }
                return outcome
            }
        )
        let stores = try Self.stores(fixture, bridge: bridge)
        let english = Locale(identifier: "en")
        let unrelated = Fixture.scratchHunk
        fixture.primary.hunkDiscards[unrelated] = Fixture.discarded
        ReviewHunkDiscardActions.discard(Self.action(tab, hunk), window: closing, stores: stores, locale: english)
        #expect(closing.hunkDiscards[hunk] == .running)
        await pollUntil(timeout: .seconds(5)) { reached.value }
        try #require(reached.value, "the discard is with the bridge")
        #expect(fixture.primary.hunkDiscards[hunk] == .running)

        fixture.registry.close(closing.id, in: fixture.session)
        #expect(fixture.registry.window(closing.id) == nil)
        release.signal()

        await pollUntil(timeout: .seconds(5)) { fixture.primary.hunkDiscards[hunk] != .running }
        let expected: ReviewHunkDiscardRecord = didWrite
            ? .discarded(opID: journal.opID, root: journal.root, note: nil)
            : .failed(ReviewHunkDiscardText.refused(.unknown, locale: english))
        #expect(fixture.primary.hunkDiscards[hunk] == expected)
        #expect(fixture.primary.hunkDiscards[unrelated] == Fixture.discarded)
    }

    private static func stores(_ fixture: Fixture, bridge: RestoreCoordinator.Bridge) throws -> ReviewHunkDiscardStores {
        let history = TurnHistory()
        let turn = try TurnSummaryFixture.recordedTurn(number: 7)
        history.replace(with: [ConversationTurns(key: turn.conversation, turns: [turn])])
        return ReviewHunkDiscardStores(
            session: fixture.session,
            windows: fixture.registry,
            toasts: ToastCenter(),
            turnHistory: history,
            worktreePaths: WorktreePathResolver(resolveLinks: { $0 }),
            restores: RestoreCoordinator(stateDirectories: [], bridge: bridge),
            restoreGateInput: { RestoreGate.Input(turn: $0, agents: [], isWaiting: false, isRestoring: false) },
            laterTurns: ReviewLaterTurns()
        )
    }

    private static func action(_ tab: ReviewTabState, _ hunk: ReviewHunkKey) -> ReviewHunkDiscardActions.Hunk {
        .init(tab: tab, file: ReviewFile(path: hunk.path, layer: .unstaged, status: .modified), header: hunk.header)
    }

    @Test func twoWindowsOnOneWorktree_seeTheSameMarks() throws {
        let fixture = Fixture()
        let (_, hunk) = try ProjectWindowsFixture.reviewAndHunk()
        let other = try fixture.window(showing: fixture.b)

        fixture.primary.hunkDiscards[hunk] = ProjectWindowsFixture.discarded

        #expect(other.reviewDiscards === fixture.primary.reviewDiscards)
        #expect(other.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
    }

    /// A record of the hunk discarded in the worktree at `root`, keyed as
    /// a discard keys it (`ReviewHunkDiscardActions.key`).
    private static func hunk(at root: String, scope: String = "s", resolvesLinks: Bool = true) -> ReviewHunkKey {
        ReviewHunkKey(
            scopeID: scope,
            root: resolvesLinks ? WorktreePathResolver().resolved(root) : root,
            fromTree: "f",
            toTree: "t",
            path: "a.swift",
            header: "@@ -1 +1 @@"
        )
    }

    /// What the app does as the session's projects change, which they do
    /// as a tab is chosen too (`AppState.presentSupervisionWindows`).
    private static func projectsChanged(_ fixture: Fixture) {
        fixture.registry.forgetProjectsGone(in: fixture.session)
    }

    @Test func removingAProject_dropsItsWorktreesRecords_andKeepsTheRest() throws {
        let fixture = Fixture()
        let ofA = Self.hunk(at: fixture.a.rootURL.path)
        let ofB = Self.hunk(at: fixture.b.rootURL.path)
        let running = Self.hunk(at: fixture.a.rootURL.path, scope: "r")
        let later = ReviewLaterPathsKey(root: WorktreePathResolver().resolved(fixture.a.rootURL.path), endTree: "e", laterTree: "l")
        let laterOfB = ReviewLaterPathsKey(root: WorktreePathResolver().resolved(fixture.b.rootURL.path), endTree: "e", laterTree: "l")
        fixture.primary.hunkDiscards[ofA] = ProjectWindowsFixture.discarded
        fixture.primary.hunkDiscards[ofB] = ProjectWindowsFixture.discarded
        fixture.primary.hunkDiscards[running] = .running
        fixture.primary.pathsChangedLater[later] = ["a.swift"]
        fixture.primary.pathsChangedLater[laterOfB] = ["a.swift"]
        fixture.primary.pathsChangedLaterFailed.insert(later)
        // A scratch pane's review, with a discard in a worktree no project
        // holds.
        try fixture.reviewAScratchPane(hasComment: false)

        fixture.session.removeProject(fixture.a.id)
        Self.projectsChanged(fixture)

        #expect(fixture.primary.hunkDiscards[ofA] == nil)
        #expect(fixture.primary.pathsChangedLater[later] == nil)
        #expect(!fixture.primary.pathsChangedLaterFailed.contains(later))
        #expect(fixture.primary.hunkDiscards[ofB] == ProjectWindowsFixture.discarded)
        #expect(fixture.primary.pathsChangedLater[laterOfB] == ["a.swift"])
        // Its end is on its way.
        #expect(fixture.primary.hunkDiscards[running] == .running)
        // No project held it: it stays while the app runs.
        #expect(fixture.primary.hunkDiscards[ProjectWindowsFixture.scratchHunk] == ProjectWindowsFixture.discarded)
    }

    @Test func choosingATab_orClosingAScratchReview_forgetsNoDiscard() throws {
        let fixture = Fixture()
        let inner = Self.hunk(at: fixture.a.rootURL.appendingPathComponent("repo").path)
        fixture.primary.hunkDiscards[inner] = ProjectWindowsFixture.discarded
        try fixture.reviewAScratchPane(hasComment: false)
        ReviewTabActions.close(
            window: fixture.primary,
            session: fixture.session,
            registry: RecordingSurfaceRegistry(),
            paneVisibility: PaneVisibilityReporter(windowID: fixture.primary.id, registry: fixture.registry),
            returnsToAgent: false
        )
        #expect(fixture.primary.review == nil)

        // The tab chosen changes the projects (`rememberLastActive`).
        let before = fixture.session.projects
        fixture.choose(fixture.aOther, in: fixture.primary)
        #expect(fixture.session.projects != before)
        Self.projectsChanged(fixture)

        #expect(fixture.primary.hunkDiscards[ProjectWindowsFixture.scratchHunk] == ProjectWindowsFixture.discarded)
        #expect(fixture.primary.hunkDiscards[inner] == ProjectWindowsFixture.discarded)
    }

    @Test func removingAProject_keepsWhatAProjectLeftHolds_eitherWay() {
        let fixture = Fixture()
        // `d` is a folder inside `a`; `e` is inside a repository.
        let insideA = fixture.a.rootURL.appendingPathComponent("d")
        let d = fixture.session.addOrActivateProject(rootURL: insideA, suggestedName: "d")
        let repository = WorkspaceSessionFixture.projectRootURL("r")
        let e = fixture.session.addOrActivateProject(rootURL: repository.appendingPathComponent("e"), suggestedName: "e")
        Self.projectsChanged(fixture)
        let ofD = Self.hunk(at: insideA.appendingPathComponent("x").path)
        let ofAOnly = Self.hunk(at: fixture.a.rootURL.appendingPathComponent("y").path)
        let holdingE = Self.hunk(at: repository.path)
        // The folder every project of the fixture is in.
        let holdingAll = Self.hunk(at: fixture.a.rootURL.deletingLastPathComponent().path)
        for key in [ofD, ofAOnly, holdingE, holdingAll] {
            fixture.primary.hunkDiscards[key] = ProjectWindowsFixture.discarded
        }

        fixture.session.removeProject(fixture.b.id)
        Self.projectsChanged(fixture)
        #expect(fixture.primary.hunkDiscards[ofAOnly] == ProjectWindowsFixture.discarded)

        fixture.session.removeProject(fixture.a.id)
        Self.projectsChanged(fixture)
        // `d` still holds it.
        #expect(fixture.primary.hunkDiscards[ofD] == ProjectWindowsFixture.discarded)
        #expect(fixture.primary.hunkDiscards[ofAOnly] == nil)
        // `c` and `d` are still in it.
        #expect(fixture.primary.hunkDiscards[holdingAll] == ProjectWindowsFixture.discarded)

        // A project inside a repository: the repository's records go with it.
        fixture.session.removeProject(e.id)
        Self.projectsChanged(fixture)
        #expect(fixture.primary.hunkDiscards[holdingE] == nil)
        #expect(fixture.session.project(d.id) != nil)
    }

    /// This works either way round: a project on a folder's own path whose
    /// record spells it through a linked parent folder (as `/var` is to
    /// `/private/var`), and a project on a link whose record spells the
    /// folder it points to. We make the link here, so no temporary folder's
    /// own spelling is assumed.
    @Test func aFolderSpelledThroughALink_isTheRecordsFolder() throws {
        try withTempDir { dir in
            let fixture = Fixture()
            let manager = FileManager.default
            let real = dir.appendingPathComponent("real")
            let one = real.appendingPathComponent("one")
            let two = real.appendingPathComponent("two")
            try manager.createDirectory(at: one, withIntermediateDirectories: true)
            try manager.createDirectory(at: two, withIntermediateDirectories: true)
            let parentLink = dir.appendingPathComponent("parent-link")
            try manager.createSymbolicLink(at: parentLink, withDestinationURL: real)
            let link = dir.appendingPathComponent("link")
            try manager.createSymbolicLink(at: link, withDestinationURL: two)
            let viaTarget = fixture.session.addOrActivateProject(
                rootURL: one.resolvingSymlinksInPath(),
                suggestedName: "one"
            )
            let viaLink = fixture.session.addOrActivateProject(rootURL: link, suggestedName: "link")
            Self.projectsChanged(fixture)
            let ofOne = Self.hunk(at: parentLink.appendingPathComponent("one").path, resolvesLinks: false)
            let ofTwo = Self.hunk(at: two.resolvingSymlinksInPath().path)
            fixture.primary.hunkDiscards[ofOne] = ProjectWindowsFixture.discarded
            fixture.primary.hunkDiscards[ofTwo] = ProjectWindowsFixture.discarded

            #expect(ofOne.root != viaTarget.rootURL.path)
            #expect(ofTwo.root != viaLink.rootURL.path)
            fixture.session.removeProject(viaTarget.id)
            Self.projectsChanged(fixture)
            #expect(fixture.primary.hunkDiscards[ofOne] == nil)
            #expect(fixture.primary.hunkDiscards[ofTwo] == ProjectWindowsFixture.discarded)

            fixture.session.removeProject(viaLink.id)
            Self.projectsChanged(fixture)
            #expect(fixture.primary.hunkDiscards[ofTwo] == nil)
        }
    }

    @Test func aProjectAddedAndAnotherRemoved_inOneLook_dropOnlyTheRemovedOnesRecords() {
        let fixture = Fixture()
        let ofA = Self.hunk(at: fixture.a.rootURL.path)
        let folderD = WorkspaceSessionFixture.projectRootURL("d")
        let ofD = Self.hunk(at: folderD.path)
        fixture.primary.hunkDiscards[ofA] = ProjectWindowsFixture.discarded
        fixture.primary.hunkDiscards[ofD] = ProjectWindowsFixture.discarded

        fixture.session.removeProject(fixture.a.id)
        fixture.session.addOrActivateProject(rootURL: folderD, suggestedName: "d")
        Self.projectsChanged(fixture)

        #expect(fixture.primary.hunkDiscards[ofA] == nil)
        #expect(fixture.primary.hunkDiscards[ofD] == ProjectWindowsFixture.discarded)
    }

    /// Where a review that reads the removed project's folder is kept.
    enum KeptReview: CaseIterable, Sendable {
        /// For another project, as a window switched away from it.
        case forAProject
        /// For the scratch row, as a window on no project closed.
        case forTheScratchRow
    }

    @Test(arguments: KeptReview.allCases)
    func aKeptReviewOfTheRemovedProjectsFolder_keepsItsRecords(_ kept: KeptReview) throws {
        let fixture = Fixture()
        switch kept {
        case .forAProject:
            fixture.choose(fixture.bTab, in: fixture.primary)
            let agentPane = try #require(fixture.bTab.splitTree.allLeafIDs().first)
            fixture.primary.review = try ProjectWindowsFixture.review(agentPaneID: agentPane)
            fixture.choose(fixture.cTab, in: fixture.primary)
            #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab != nil)
        case .forTheScratchRow:
            _ = try fixture.closeAWindowOfNoProject(hasComment: true)
            #expect(fixture.registry.parkedScratchReview?.tab != nil)
        }
        #expect(fixture.primary.review == nil)
        // A project on the folder the kept review reads (`/repo`).
        let project = fixture.session.addOrActivateProject(rootURL: URL(fileURLWithPath: "/repo"), suggestedName: "repo")
        Self.projectsChanged(fixture)
        let record = Self.hunk(at: "/repo")
        fixture.primary.hunkDiscards[record] = ProjectWindowsFixture.discarded

        fixture.session.removeProject(project.id)
        Self.projectsChanged(fixture)

        #expect(fixture.primary.hunkDiscards[record] == ProjectWindowsFixture.discarded)
    }
}
