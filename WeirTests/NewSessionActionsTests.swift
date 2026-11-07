// NewSessionActionsTests.swift
// Weir — the new worktree sheet's form as it opens, its fetch, "Create", and ⌥⌘N, without drawing the sheet.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionActionsTests {
    /// A project in a window, and the stores the sheet's actions use, with
    /// Git, the folder, and the settings of their own.
    @MainActor
    final class Fixture {
        let session: WorkspaceSession
        let project: Project
        let windows: WindowRegistry
        let launches: SessionLaunchStore
        let settings: SettingsStore
        let git = FakeGit()
        var facts = NewSessionFacts(localBranches: ["main"], defaultBase: "main", head: "main")
        /// The forge for a pull request source; none unless a suite gives one.
        var pullRequests: (any PullRequestReading)?
        /// How many files the shown row has uncommitted.
        var changedFiles: Int? = 0
        /// This is the day the suggested name is dated by, fixed so that a
        /// run across midnight names the branch by the day it expects.
        let today = Date(timeIntervalSinceReferenceDate: 800_000_000)

        /// This is the suggested name's date part (`BranchNameSuggester`).
        var todayInName: String {
            let parts = Calendar.current.dateComponents([.month, .day], from: today)
            return String(format: "%02d%02d", parts.month ?? 1, parts.day ?? 1)
        }

        init(directory: URL) {
            let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
            self.session = session
            self.project = project
            session.setActiveContainer(.project(project.id))
            windows = WindowRegistry(primary: session.primarySelection)
            launches = SessionLaunchStore(path: { nil }, git: git)
            settings = SettingsStore(directory: directory.appendingPathComponent("settings"))
        }

        var window: ProjectWindowState {
            windows.primary
        }

        var stores: NewSessionStores {
            var stores = NewSessionStores(session: session, launches: launches, settingsStore: settings)
            let facts = facts
            stores.readFacts = { _, _ in facts }
            stores.git = git
            stores.pullRequests = pullRequests
            let changedFiles = changedFiles
            stores.countChanges = { _ in changedFiles }
            stores.folderExists = { _ in false }
            let today = today
            stores.today = { today }
            stores.remembersChoices = true
            return stores
        }

        /// The form as the sheet has it once up: loaded, and the shown
        /// row's changes counted.
        func load() async throws -> NewSessionModel {
            var model = try #require(await NewSessionActions.load(
                NewSessionSheetRequest(projectID: project.id),
                window: window,
                stores: stores
            ))
            await model.setCarryCount(NewSessionActions.countCarryChanges(for: model, stores: stores))
            return model
        }

        func create(_ model: NewSessionModel) async -> NewSessionActions.CreateOutcome {
            await NewSessionActions.create(model, request: NewSessionSheetRequest(projectID: project.id), window: window, stores: stores)
        }

        /// The row the window shows, when it is a worktree of the project.
        var shownWorktree: ContainerID? {
            guard case .worktree = window.selection.activeContainerID else { return nil }
            return window.selection.activeContainerID
        }
    }

    private static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await withTempDir { dir in
            try await body(Fixture(directory: dir))
        }
    }

    @Test func theForm_opensWithWhatTheFolderSays_andTheProjectsRememberedChoices() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts(
                localBranches: ["main", "feat/x"],
                defaultBase: "origin/main",
                head: "main",
                installations: [
                    AgentInstallation(kind: .claude, executable: "/opt/bin/claude"),
                    AgentInstallation(kind: .codex, executable: "/opt/bin/codex")
                ],
                remotes: ["origin"]
            )
            let remembered = NewWorktreeChoices(open: .agent(.codex), fetches: false, copiesIgnoredFiles: false, runsSetup: false)
            fixture.settings.settings.newSession.remember(remembered, forProjectAt: fixture.project.rootURL)
            fixture.settings.settings.newSession.remember(
                NewWorktreeChoices(open: .shell, fetches: true, copiesIgnoredFiles: true, runsSetup: true),
                forProjectAt: WorkspaceSessionFixture.projectRootURL("other")
            )

            var stores = fixture.stores
            let facts = fixture.facts
            let root = fixture.project.rootURL
            let projectID = fixture.project.id
            let reads = Recorded(0)
            stores.readFacts = { url, id in
                #expect(url == root)
                #expect(id == projectID)
                reads.update { $0 += 1 }
                return facts
            }
            let model = try #require(await NewSessionActions.load(
                NewSessionSheetRequest(projectID: projectID), window: fixture.window, stores: stores
            ))

            #expect(reads.value == 1)
            // Fetch is remembered globally. Open, copy, and setup are remembered for this project.
            #expect(model.choices == NewWorktreeChoices(open: .agent(.codex), fetches: true, copiesIgnoredFiles: false, runsSetup: false))
            #expect(model.context.localBranches == ["main", "feat/x"])
            #expect(model.context.fetchRemote == "origin")
            #expect(model.base?.name == "origin/main")
            #expect(model.context.checkedOutBranches == ["main"])
            #expect(model.context.installedAgents == [.claude, .codex])
            #expect(model.context.agentExecutables == [.claude: "/opt/bin/claude", .codex: "/opt/bin/codex"])
        }
    }

    @Test func theProjectGone_opensNoForm() async throws {
        try await Self.withFixture { fixture in
            let gate = Gate<Void>()
            var stores = fixture.stores
            let facts = fixture.facts
            stores.readFacts = { _, _ in
                await gate.wait()
                return facts
            }
            // An absent project must return without calling the reader.
            var absentStores = stores
            absentStores.readFacts = { _, _ in
                Issue.record("read facts for an absent project")
                return facts
            }
            #expect(await NewSessionActions.load(
                NewSessionSheetRequest(projectID: UUID()),
                window: fixture.window,
                stores: absentStores
            ) == nil)

            let load = Task {
                await NewSessionActions.load(
                    NewSessionSheetRequest(projectID: fixture.project.id), window: fixture.window, stores: stores
                ) == nil
            }
            do {
                try await gate.waitUntilRequested()
            } catch {
                gate.open()
                _ = await load.value
                throw error
            }
            fixture.session.removeProject(fixture.project.id)
            gate.open()
            #expect(await load.value)
        }
    }

    @Test func aWorktreeMade_isSelected_itsLaunchBegins_andTheChoicesAreKept() async throws {
        try await Self.withFixture { fixture in
            var model = try await fixture.load()
            model.open = .shell
            model.setBranchName("feat/try")

            let outcome = await fixture.create(model)

            #expect(outcome == .created(branch: "feat/try"))
            let row = try #require(fixture.shownWorktree)
            // The launch goes on in the row: with no setup, the shell's tab.
            await pollUntil { !fixture.session.tabs(in: row).isEmpty }
            #expect(fixture.session.tabs(in: row).count == 1)
            #expect(fixture.git.branchCalls.map(\.name) == ["feat/try"])
            #expect(fixture.settings.settings.newSession.memory(forProjectAt: fixture.project.rootURL)?.open == "shell")
            #expect(fixture.settings.settings.newSession.lastOpen == "shell")
        }
    }

    /// A sidebar header's ＋ on a project no window shows: the worktree made
    /// switches this window to it, and its launch goes on here.
    @Test func aWorktreeOfAProjectNoWindowShows_switchesThisWindow_andItsLaunchIsHere() async throws {
        try await Self.withFixture { fixture in
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            let request = NewSessionSheetRequest(projectID: other.id)
            var model = try #require(await NewSessionActions.load(request, window: fixture.window, stores: fixture.stores))
            model.open = .shell
            model.setBranchName("feat/other")

            #expect(await NewSessionActions.create(model, request: request, window: fixture.window, stores: fixture.stores)
                == .created(branch: "feat/other"))

            let worktree = try #require(fixture.session.project(other.id)?.worktrees.first)
            let row = ContainerID.worktree(projectID: other.id, worktreeID: worktree.id)
            #expect(fixture.window.selection.activeContainerID == row)
            await pollUntil { !fixture.session.tabs(in: row).isEmpty }
            let tab = try #require(fixture.session.tabs(in: row).first)
            #expect(fixture.window.selection.activeTabID == tab.id)
            #expect(tab.workingDirectory == worktree.workingDirectory.path)
        }
    }

    /// Another window shows the project by the time the worktree is made:
    /// the selection and the launch go to that window.
    @Test func aWorktreeOfAProjectAnotherWindowShows_isSelectedAndLaunchedThere() async throws {
        try await Self.withFixture { fixture in
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            let request = NewSessionSheetRequest(projectID: other.id)
            var model = try #require(await NewSessionActions.load(request, window: fixture.window, stores: fixture.stores))
            model.open = .shell
            model.setBranchName("feat/there")
            let original = ContainerID.project(fixture.project.id)
            let originalTab = fixture.session.openTab(container: original, in: fixture.window.id)
            let gate = Gate<Void>()
            fixture.git.worktreeAddGate = gate
            let create = Task {
                await NewSessionActions.create(model, request: request, window: fixture.window, stores: fixture.stores)
            }
            do {
                try await gate.waitUntilRequested()
            } catch {
                gate.open()
                _ = await create.value
                throw error
            }
            #expect(fixture.session.project(other.id)?.worktrees.isEmpty == true)
            let second = fixture.session.addWindow(showing: other.id, layoutFrom: fixture.window.id)
            gate.open()
            #expect(await create.value == .created(branch: "feat/there"))

            let worktree = try #require(fixture.session.project(other.id)?.worktrees.first)
            let row = ContainerID.worktree(projectID: other.id, worktreeID: worktree.id)
            #expect(second.activeContainerID == row)
            await pollUntil { !fixture.session.tabs(in: row).isEmpty }
            let tab = try #require(fixture.session.tabs(in: row).first)
            #expect(second.activeTabID == tab.id)
            #expect(tab.workingDirectory == worktree.workingDirectory.path)
            #expect(fixture.window.selection.activeContainerID == original)
            #expect(fixture.window.selection.activeTabID == originalTab.id)
        }
    }

    @Test func nothingToOpen_makesTheRowWithNoTab() async throws {
        try await Self.withFixture { fixture in
            var model = try await fixture.load()
            model.open = .nothing
            #expect(await fixture.create(model) == .created(branch: "task/\(fixture.todayInName)-1"))
            let row = try #require(fixture.shownWorktree)
            #expect(fixture.session.tabs(in: row).isEmpty)
            #expect(fixture.launches.launches.isEmpty)
        }
    }

    /// Git made the branch, then could not add the worktree on it: the
    /// sheet stays open saying so, the retry checks the branch out rather
    /// than making it again, and nothing is remembered from a create that
    /// made no worktree.
    @Test func aWorktreeGitCouldNotAddOnTheBranchItMade_failsWithTheBranch_forTheRetry() async throws {
        try await Self.withFixture { fixture in
            fixture.git.nextCreateResult = .failure("fatal: could not create work tree dir")
            var model = try await fixture.load()
            model.setBranchName("feat/try")

            let outcome = await fixture.create(model)

            guard case let .failed(message, madeBranch) = outcome else {
                Issue.record("the create did not fail: \(outcome)")
                return
            }
            let branch = try #require(madeBranch)
            #expect(branch == "feat/try")
            #expect(message == CreateWorktreeError.gitFailedLeavingBranch(
                stderr: "fatal: could not create work tree dir", branch: branch
            ).message)
            #expect(fixture.settings.settings.newSession.memory(forProjectAt: fixture.project.rootURL) == nil)
            #expect(fixture.settings.settings.newSession.lastOpen == nil)
            #expect(fixture.window.selection.activeContainerID == .project(fixture.project.id))
            #expect(fixture.session.project(fixture.project.id)?.worktrees.isEmpty == true)
            #expect(fixture.launches.launches.isEmpty)

            model.useMadeBranch(branch)
            let retry = try #require(model.plan)
            #expect(retry.newBranch == nil)
            #expect(retry.start == branch)
            fixture.git.nextCreateResult = .success()
            #expect(await fixture.create(model) == .created(branch: branch))
            #expect(fixture.git.branchCalls.map(\.name) == [branch])
            #expect(fixture.git.createCalls.map(\.baseBranch) == [branch, branch])
            #expect(fixture.session.project(fixture.project.id)?.worktrees.count == 1)
        }
    }

    // MARK: - Fetch

    /// Create uses the same remote ref that Fetch compares with the local branch.
    @Test func create_usesTheRemoteRefComparedByFetch() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts(localBranches: ["main"], defaultBase: "main", head: "main", remotes: ["origin", "fork"])
            fixture.git.behind = 2
            var model = try await fixture.load()
            model.setBranchName("feat/fresh")
            model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
            #expect(model.fetchState == .fetched(behind: 2))
            #expect(model.baseLine == .behind(local: "main", count: 2, remote: "origin/main"))

            #expect(await fixture.create(model) == .created(branch: "feat/fresh"))
            let root = fixture.project.rootURL
            let remoteRef = "refs/remotes/origin/main"
            #expect(fixture.git.branchFetchCalls == [.init(repoRoot: root, remote: "origin", branch: "main")])
            #expect(fixture.git.comparisonCalls == [
                .init(repoRoot: root, local: remoteRef, upstream: remoteRef),
                .init(repoRoot: root, local: "refs/heads/main", upstream: remoteRef)
            ])
            #expect(fixture.git.operations == ["fetch", "branch", "worktree add"])
            #expect(fixture.git.branchCalls.map(\.startPoint) == [remoteRef])
        }
    }

    /// The test repositories have no remote: nothing is fetched, and the
    /// base is the local branch as before.
    @Test func noRemote_fetchesNothing_andStartsFromTheLocalBranch() async throws {
        try await Self.withFixture { fixture in
            var model = try await fixture.load()
            #expect(model.fetches)
            #expect(model.fetchRemote == nil)
            #expect(await NewSessionActions.fetch(for: model, stores: fixture.stores) == .none)
            model.setBranchName("feat/local")
            #expect(await fixture.create(model) == .created(branch: "feat/local"))
            #expect(fixture.git.fetchCalls.isEmpty)
            #expect(fixture.git.branchCalls.first?.startPoint == "refs/heads/main")
        }
    }

    enum FetchFailure: CaseIterable {
        case timeout
        case nonzeroExit
    }

    @Test(arguments: FetchFailure.allCases)
    func aFailedFetch_stillMakesTheWorktree_fromTheLocalBranch_withANote(_ failure: FetchFailure) async throws {
        try await Self.withFixture { fixture in
            fixture.facts.remotes = ["origin"]
            switch failure {
            case .timeout:
                fixture.git.nextFetchError = .timedOut(seconds: 20)
            case .nonzeroExit:
                fixture.git.nextFetchResult = .failure("fatal: could not read from remote repository")
            }
            var model = try await fixture.load()
            model.open = .shell
            model.setBranchName("feat/offline")
            model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
            #expect(model.fetchState == .failed)

            #expect(await fixture.create(model) == .created(branch: "feat/offline"))
            #expect(fixture.git.branchFetchCalls == [.init(repoRoot: fixture.project.rootURL, remote: "origin", branch: "main")])
            #expect(fixture.git.comparisonCalls.isEmpty)
            #expect(fixture.git.branchCalls.map(\.startPoint) == ["refs/heads/main"])
            let row = try #require(fixture.shownWorktree)
            let launch = try #require(fixture.launches.launch(in: row))
            #expect(launch.notes == [.fetch(.failed(start: "main", isLastFetched: false))])
            #expect(launch.phase == .done)
        }
    }

    enum MissingRemoteBranch: CaseIterable {
        case noTrackingRefAfterFetch
        case deletedBranchWithStaleTrackingRef
    }

    @Test(arguments: MissingRemoteBranch.allCases)
    func aRemoteWithoutTheBranch_startsFromTheLocalOne_andSaysWhy(_ missing: MissingRemoteBranch) async throws {
        try await Self.withFixture { fixture in
            fixture.facts.remotes = ["origin"]
            let root = fixture.project.rootURL
            let comparisons: [FakeGit.ComparisonCall]
            switch missing {
            case .noTrackingRefAfterFetch:
                fixture.git.behind = nil
                comparisons = [.init(repoRoot: root, local: "refs/remotes/origin/main", upstream: "refs/remotes/origin/main")]
            case .deletedBranchWithStaleTrackingRef:
                fixture.git.behind = 3
                fixture.git.nextFetchResult = .failure("fatal: couldn't find remote ref refs/heads/main")
                comparisons = []
            }
            var model = try await fixture.load()
            model.open = .shell
            model.setBranchName("feat/missing")
            model.fetchState = await NewSessionActions.fetch(for: model, stores: fixture.stores)
            #expect(model.fetchState == .remoteBranchMissing)

            #expect(await fixture.create(model) == .created(branch: "feat/missing"))
            #expect(fixture.git.branchFetchCalls == [.init(repoRoot: root, remote: "origin", branch: "main")])
            #expect(fixture.git.comparisonCalls == comparisons)
            #expect(fixture.git.branchCalls.map(\.startPoint) == ["refs/heads/main"])
            let row = try #require(fixture.shownWorktree)
            let launch = try #require(fixture.launches.launch(in: row))
            #expect(launch.notes == [.fetch(.remoteBranchMissing(remote: "origin/main", start: "main"))])
            #expect(launch.phase == .done)
        }
    }

    enum LocalBase: CaseIterable {
        case rootBranchWithoutDefault
        case shownWorktreeBranch
    }

    @Test(arguments: LocalBase.allCases)
    func aLocalBase_isNotFetchedFor(_ localBase: LocalBase) async throws {
        try await Self.withFixture { fixture in
            let model: NewSessionModel
            switch localBase {
            case .rootBranchWithoutDefault:
                fixture.facts = NewSessionFacts(localBranches: ["dev"], head: "dev", remotes: ["origin"])
                model = try await fixture.load()
                #expect(model.base?.ref == "refs/heads/dev")
            case .shownWorktreeBranch:
                var shown = try await fixture.load()
                shown.open = .nothing
                shown.setBranchName("feat/current")
                #expect(await fixture.create(shown) == .created(branch: "feat/current"))
                _ = try #require(fixture.shownWorktree)
                fixture.facts.localBranches.append("feat/current")
                fixture.facts.remotes = ["origin"]

                var loaded = try await fixture.load()
                #expect(loaded.base?.ref == "refs/remotes/origin/main")
                loaded.baseName = "feat/current"
                #expect(loaded.base?.ref == "refs/heads/feat/current")
                model = loaded
            }
            #expect(!model.needsFetch)
            #expect(await NewSessionActions.fetch(for: model, stores: fixture.stores) == .none)
            #expect(fixture.git.fetchCalls.isEmpty)
            #expect(fixture.git.comparisonCalls.isEmpty)
        }
    }

    /// ⌥⌘N pressed again while the first runs makes no second worktree:
    /// both would take the same suggested name.
    @Test func createAtOnce_twice_makesOneWorktree() async throws {
        try await Self.withFixture { fixture in
            let gate = Gate<Void>()
            let reads = Recorded(0)
            let facts = fixture.facts
            var stores = fixture.stores
            stores.readFacts = { _, _ in
                reads.update { $0 += 1 }
                // A second read would expose a regression without waiting on the first.
                if gate.requests == 0 {
                    await gate.wait()
                }
                return facts
            }
            let window = fixture.window
            let first = Task { await NewSessionActions.createAtOnce(in: window, stores: stores) }
            do {
                try await gate.waitUntilRequested()
            } catch {
                gate.open()
                _ = await first.value
                throw error
            }
            #expect(window.isCreatingWorktreeAtOnce)
            #expect(await NewSessionActions.createAtOnce(in: window, stores: stores) == .nothing)
            #expect(reads.value == 1)
            #expect(fixture.git.operations.isEmpty)

            gate.open()
            let branch = "task/\(fixture.todayInName)-1"
            #expect(await first.value == .created(branch: branch))
            #expect(fixture.git.branchCalls.map(\.name) == [branch])
            #expect(fixture.git.createCalls.map(\.baseBranch) == [branch])
            #expect(fixture.session.project(fixture.project.id)?.worktrees.count == 1)
            #expect(!window.isCreatingWorktreeAtOnce)
        }
    }

    // MARK: - ⌥⌘N

    @Test func createAtOnce_fetchesBeforeCreating_andReturnsTheBranch() async throws {
        try await Self.withFixture { fixture in
            fixture.facts.remotes = ["origin"]
            fixture.git.behind = 0
            fixture.settings.settings.newSession.remember(
                NewWorktreeChoices(open: .nothing, fetches: true, copiesIgnoredFiles: true, runsSetup: true),
                forProjectAt: fixture.project.rootURL
            )

            let outcome = await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores)

            #expect(outcome == .created(branch: "task/\(fixture.todayInName)-1"))
            #expect(fixture.git.branchFetchCalls == [.init(repoRoot: fixture.project.rootURL, remote: "origin", branch: "main")])
            #expect(fixture.git.operations == ["fetch", "branch", "worktree add"])
            #expect(fixture.git.branchCalls.map(\.startPoint) == ["refs/remotes/origin/main"])
            #expect(fixture.window.newSession == nil)
            let row = try #require(fixture.shownWorktree)
            #expect(fixture.session.tabs(in: row).isEmpty)
            #expect(fixture.launches.launch(in: row) == nil)
        }
    }

    /// ⌥⌘N reads the form before Git starts: a person who moved to another
    /// row during that read is not taken back to the worktree made.
    @Test func createAtOnce_aMoveDuringTheLoad_keepsThePersonWhereTheyWent() async throws {
        try await Self.withFixture { fixture in
            let other = fixture.session.addOrActivateProject(
                rootURL: WorkspaceSessionFixture.projectRootURL("other"),
                suggestedName: "other"
            )
            fixture.session.setActiveContainer(.project(fixture.project.id), in: fixture.window.id, intent: .person)
            var stores = fixture.stores
            let facts = fixture.facts
            let session = fixture.session
            let windowID = fixture.window.id
            stores.readFacts = { _, _ in
                await MainActor.run {
                    session.setActiveContainer(.project(other.id), in: windowID, intent: .person)
                }
                return facts
            }

            let outcome = await NewSessionActions.createAtOnce(in: fixture.window, stores: stores)

            #expect(outcome == .created(branch: "task/\(fixture.todayInName)-1"))
            #expect(fixture.window.selection.activeContainerID == .project(other.id))
            #expect(fixture.session.project(fixture.project.id)?.worktrees.count == 1)
        }
    }

    @Test func createAtOnce_opensTheSheet_whenTheFormMakesNothing_orGitFails() async throws {
        try await Self.withFixture { fixture in
            fixture.facts = NewSessionFacts()
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .openedSheet)
            let request = try #require(fixture.window.newSession)
            #expect(request.projectID == fixture.project.id)
            #expect(request.failure == nil)
            #expect(fixture.git.operations.isEmpty)
        }
        let stderr = "fatal: not a valid object name"
        let message = CreateWorktreeError.gitFailed(stderr: stderr).message
        try await Self.withFixture { fixture in
            fixture.git.nextBranchResult = .failure(stderr)
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .openedSheet)
            let request = try #require(fixture.window.newSession)
            #expect(request.projectID == fixture.project.id)
            #expect(request.failure == message)
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .nothing)
            #expect(fixture.window.newSession == request)
            #expect(fixture.git.operations == ["branch"])
        }
        try await Self.withFixture { fixture in
            fixture.git.nextBranchResult = .failure(stderr)
            fixture.window.hasAttachedSheet = true
            #expect(await NewSessionActions.createAtOnce(in: fixture.window, stores: fixture.stores) == .failedUnshown(message))
            #expect(fixture.window.newSession == nil)
            #expect(fixture.window.hasAttachedSheet)
            #expect(fixture.git.operations == ["branch"])
        }
    }

    // MARK: - The sheet in its window

    @Test func aSecondRequest_doesNotReplaceTheOpenSheet() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        session.setActiveContainer(.project(project.id))
        let window = ProjectWindowState(selection: session.primarySelection)
        SupervisionWindowActions.newSession(in: window, session: session)
        let open = window.newSession
        #expect(open != nil)
        if let open {
            window.newWorktreeSheet.appeared(open.id)
        }
        SupervisionWindowActions.newSession(in: window, session: session)
        #expect(window.newSession == open)
    }
}

/// The fetch against real Git: a bare repository as `origin`, moved on
/// from another clone, as a teammate's push moves it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewSessionFetchGitTests {
    @Test func aFetchedRemote_isTheBase_andTheWorktreeStartsFromItsNewCommit() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        let local = try await repo.git(["rev-parse", "refs/heads/main"])
        let pushed = try await repo.advance(bare)

        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "repo")
        let window = ProjectWindowState(selection: session.primarySelection)
        let request = NewSessionSheetRequest(projectID: project.id)
        var stores = NewSessionStores(
            session: session,
            launches: SessionLaunchStore(path: { nil }),
            settingsStore: SettingsStore(directory: repo.scratch.appendingPathComponent("settings"))
        )
        stores.readFacts = { root, _ in
            let facts = await NewSessionFacts.readGit(root: root)
            #expect(facts.remotes == ["origin"])
            #expect(facts.upstreamRemote == "origin")
            return facts
        }
        var model = try #require(await NewSessionActions.load(request, window: window, stores: stores))
        model.open = .nothing
        model.setBranchName("feat/from-remote")
        #expect(model.fetchRemote == "origin")
        #expect(model.base?.ref == "refs/remotes/origin/main")
        #expect(try await repo.git(["rev-parse", "refs/remotes/origin/main"]) == local)

        model.fetchState = await NewSessionActions.fetch(for: model, stores: stores)
        #expect(model.fetchState == .fetched(behind: 1))
        #expect(await NewSessionActions.create(model, request: request, window: window, stores: stores)
            == .created(branch: "feat/from-remote"))
        let worktree = try #require(session.project(project.id)?.worktrees.first)
        #expect(try await TempGitRepo.git(["rev-parse", "HEAD"], in: worktree.workingDirectory) == pushed)
        #expect(try await repo.git(["rev-parse", "refs/heads/feat/from-remote"]) == pushed)
        #expect(try await repo.git(["rev-parse", "refs/remotes/origin/main"]) == pushed)
        #expect(try await repo.git(["rev-parse", "refs/heads/main"]) == local)
    }

    /// A tag `main` on an older commit must not change the new branch's start.
    @Test func aTagNamedLikeTheBase_leavesTheWorktreeOnTheBranch() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.git(["tag", "main"])
        try repo.write("landed\n", to: "landed.txt")
        try await repo.commit("landed", paths: ["landed.txt"])
        let tip = try await repo.git(["rev-parse", "refs/heads/main"])

        let (session, model) = try await Self.form(for: repo, fetches: false)
        let project = model.context.project
        let plan = try #require(model.plan)
        #expect(plan.start == "refs/heads/main")
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: plan.path,
            baseBranch: plan.start,
            newBranchName: plan.newBranch,
            openTab: false
        )
        #expect(try await TempGitRepo.git(["rev-parse", "HEAD"], in: worktree.workingDirectory) == tip)
    }

    /// A tag `origin/main` on an older commit: the fetch and the start take
    /// the remote's branch, which the fetch brought up to date.
    @Test func aTagNamedLikeTheRemotesBranch_leavesTheFetchAndTheWorktreeOnTheBranch() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        try await repo.git(["remote", "set-head", "origin", "main"])
        try await repo.git(["tag", "origin/main"])
        let pushed = try await repo.advance(bare)

        let (session, model) = try await Self.form(for: repo, fetches: true)
        let project = model.context.project
        let stores = NewSessionStores(session: session, launches: SessionLaunchStore(path: { nil }), settingsStore: SettingsStore(
            directory: repo.scratch.appendingPathComponent("settings")
        ))
        var fetched = model
        fetched.fetchState = await NewSessionActions.fetch(for: model, stores: stores)
        #expect(fetched.fetchState == .fetched(behind: 1))
        let plan = try #require(fetched.plan)
        #expect(plan.start == "refs/remotes/origin/main")
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: plan.path,
            baseBranch: plan.start,
            newBranchName: plan.newBranch,
            openTab: false
        )
        #expect(try await TempGitRepo.git(["rev-parse", "HEAD"], in: worktree.workingDirectory) == pushed)
    }

    /// The sheet's form for `repo`, as it opens with what the folder says.
    private static func form(
        for repo: TempGitRepo,
        fetches: Bool
    ) async throws -> (WorkspaceSession, NewSessionModel) {
        let facts = await NewSessionFacts.readGit(root: repo.url)
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "repo")
        let model = NewSessionModel(
            context: .init(
                project: project,
                localBranches: facts.localBranches,
                checkedOutBranches: ["main"],
                defaultBase: facts.defaultBase,
                shownBranch: nil,
                head: facts.head,
                fetchRemote: NewSessionModel.fetchRemote(
                    defaultBase: facts.defaultBase,
                    upstreamRemote: facts.upstreamRemote,
                    remotes: facts.remotes
                ),
                today: Date(),
                folderExists: { FileManager.default.fileExists(atPath: $0.path) }
            ),
            choices: NewWorktreeChoices(open: .nothing, fetches: fetches, copiesIgnoredFiles: false, runsSetup: false)
        )
        return (session, model)
    }

    @Test func aMissingRemoteRepository_failsTheFetch_withoutReportingAMissingBranch() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.addBareOrigin()
        try await repo.git(["remote", "set-url", "origin", repo.url.appendingPathComponent("gone.git").path])
        let result = try await LiveGit().fetch(repoRoot: repo.url, remote: "origin", branch: "main")
        #expect(!result.succeeded)
        #expect(!LiveGit.isMissingRemoteBranch(result), "the remote did not answer; it did not say the branch is gone")
    }

    /// A branch-specific fetch reports a deletion even with a local tracking ref.
    @Test func aBranchDeletedOnTheRemote_failsItsFetch_asMissing() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = try await repo.addBareOrigin()
        try await repo.git(["push", "-q", "origin", "main:topic"])
        #expect(try await LiveGit().fetch(repoRoot: repo.url, remote: "origin", branch: "topic").succeeded)
        let tracked = try await repo.git(["rev-parse", "--verify", "refs/remotes/origin/topic"])
        #expect(try await repo.git(["rev-parse", "refs/heads/main"]) == tracked)
        try await TempGitRepo.git(["branch", "-q", "-D", "topic"], in: bare)

        let result = try await LiveGit().fetch(repoRoot: repo.url, remote: "origin", branch: "topic")

        #expect(LiveGit.isMissingRemoteBranch(result))
        #expect(try await repo.git(["rev-parse", "--verify", "refs/remotes/origin/topic"]) == tracked)
    }

    struct SSHSetting {
        let label: String
        var environment: String?
        var configured: String?
        var hasSSHProgram = false
        let expected: String?

        static let cases: [Self] = [
            .init(label: "default", expected: "ssh -o BatchMode=yes"),
            .init(
                label: "blank environment and trimmed config",
                environment: " ",
                configured: "ssh -i other\n",
                expected: "ssh -i other -o BatchMode=yes"
            ),
            .init(label: "program alone", hasSSHProgram: true, expected: nil),
            .init(
                label: "environment before config",
                environment: "ssh -i ~/.ssh/work",
                configured: "ssh -i other",
                expected: "ssh -i ~/.ssh/work -o BatchMode=yes"
            ),
            .init(
                label: "environment before program",
                environment: "ssh -i env",
                hasSSHProgram: true,
                expected: "ssh -i env -o BatchMode=yes"
            ),
            .init(
                label: "config before program",
                configured: "ssh -i other",
                hasSSHProgram: true,
                expected: "ssh -i other -o BatchMode=yes"
            ),
            .init(
                label: "all three",
                environment: "ssh -i env",
                configured: "ssh -i other",
                hasSSHProgram: true,
                expected: "ssh -i env -o BatchMode=yes"
            )
        ]
    }

    @Test(arguments: SSHSetting.cases)
    func batchSSHCommand_respectsGitPrecedence_andPreservesStandalonePrograms(_ setting: SSHSetting) {
        let command = LiveGit.batchSSHCommand(
            environment: setting.environment,
            configured: setting.configured,
            hasSSHProgram: setting.hasSSHProgram
        )
        #expect(command == setting.expected, "\(setting.label)")
    }
}
