// WorkspaceSessionWorktreeTests.swift
// Weir — exercises WorkspaceSession+Worktree create / delete pipelines against a scripted `FakeGit`.
//
// Patterns to copy from these tests:
//   - Inject `git: FakeGit` to `createGitWorktree` / `deleteGitWorktree`.
//   - Set `nextCreateResult` / `nextRemoveResult` before the call to
//     script success or a specific stderr.
//   - Assert on the resulting WorkspaceSession state (project.worktrees
//     count, removed-pane ids, etc.), not on log output.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("WorkspaceSession +Worktree pipelines")
@MainActor
struct WorkspaceSessionWorktreeTests {

    // MARK: - Create — happy path

    @Test("createGitWorktree: success attaches a worktree row to the project")
    func createGitWorktree_whenGitSucceeds_attachesWorktreeRow() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let path = WorktreeFixture.freshPath()

        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: path,
            baseBranch: "main",
            newBranchName: "feature-x",
            openTab: false,
            git: git
        )

        let updated = try #require(session.projects.first { $0.id == project.id })
        #expect(updated.worktrees == [wt])
        #expect(wt.label == "feature-x")
        #expect(wt.workingDirectory == path)
        #expect(wt.gitRef?.branchName == "feature-x")
        #expect(wt.admission == .created)
        #expect(session.makeSnapshot().projects.first { $0.id == project.id }?.worktrees == [wt])
        #expect(session.tabs.isEmpty)
    }

    @Test("createGitWorktree: makes the new branch from the base, then adds the worktree on it")
    func createGitWorktree_withNewBranchName_forwardsBranchToGit() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let path = WorktreeFixture.freshPath()
        _ = try await session.createGitWorktree(
            projectID: project.id,
            path: path,
            baseBranch: "main",
            newBranchName: "feature-y",
            openTab: false,
            git: git
        )
        #expect(git.operations == ["branch", "worktree add"])
        let branch = try #require(git.branchCalls.first)
        #expect(branch.repoRoot == project.rootURL)
        #expect(branch.name == "feature-y")
        #expect(branch.startPoint == "main")
        let call = try #require(git.createCalls.first)
        #expect(call.repoRoot == project.rootURL)
        #expect(call.path == path)
        #expect(call.baseBranch == "feature-y")
    }

    @Test("createGitWorktree: makes no branch when the input is whitespace")
    func createGitWorktree_whenNewBranchNameIsBlank_makesNoBranch() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        _ = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "   ",
            openTab: false,
            git: git
        )
        let call = try #require(git.createCalls.first)
        #expect(call.baseBranch == "main")
        #expect(git.branchCalls.isEmpty)
    }

    // MARK: - Create — errors

    /// A `git worktree add` past its deadline is a timeout, not git's own
    /// failure (its message: `WorktreeErrorsTests`). What it had made of the
    /// worktree is removed, so a retry does not stop on a folder that is
    /// already there; the branch made for it stays.
    @Test func createGitWorktree_whenGitRunsPastItsDeadline_removesWhatItMade() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        git.nextCreateError = .timedOut(seconds: 600)
        git.leavesFolderOnError = true
        try await withTempDir { dir in
            let path = dir.appendingPathComponent("worktree")
            let thrown = await WorktreeFixture.failure(CreateWorktreeError.self) {
                try await session.createGitWorktree(
                    projectID: project.id,
                    path: path,
                    baseBranch: "main",
                    newBranchName: "feature-t",
                    openTab: false,
                    git: git
                )
            }
            guard case let .timedOut(seconds, branch, leftover)? = thrown else {
                Issue.record("expected a timeout, got \(String(describing: thrown))")
                return
            }
            #expect(seconds == 600)
            #expect(branch == "feature-t")
            #expect(leftover == nil)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(git.removeCalls.map(\.force) == [true])
            #expect(git.removeCalls.first?.path == path)
            #expect(git.removeCalls.first?.repoRoot == project.rootURL)
            #expect(git.pruneCalls == [project.rootURL])
            #expect(session.project(project.id)?.worktrees.isEmpty == true)
            #expect(session.tabs.isEmpty)
        }
    }

    /// Past its deadline, git left something running that outlived
    /// SIGKILL: the folder is kept, so a retry stops on it rather than
    /// making a worktree there that process could still write into.
    @Test func createGitWorktree_whenGitLeavesProcessesRunning_keepsTheFolder() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        git.nextCreateError = .timedOut(seconds: 600, hasProcessesLeft: true)
        git.leavesFolderOnError = true
        try await withTempDir { dir in
            let path = dir.appendingPathComponent("worktree")
            let thrown = await WorktreeFixture.failure(CreateWorktreeError.self) {
                try await session.createGitWorktree(
                    projectID: project.id,
                    path: path,
                    baseBranch: "main",
                    newBranchName: "feature-t",
                    openTab: false,
                    git: git
                )
            }
            guard case let .timedOut(_, branch, leftover)? = thrown else {
                Issue.record("expected a timeout, got \(String(describing: thrown))")
                return
            }
            #expect(branch == "feature-t")
            #expect(leftover == path)
            let leftoverFile = path.appendingPathComponent("checked-out.txt")
            let bytes = try Data(contentsOf: leftoverFile)
            #expect(bytes == Data("half".utf8))
            #expect(git.removeCalls.isEmpty)
            #expect(git.pruneCalls.isEmpty)
            #expect(session.project(project.id)?.worktrees.isEmpty == true)
            #expect(session.tabs.isEmpty)
        }
    }

    @Test("createGitWorktree: unknown project id throws projectNotFound")
    func createGitWorktree_withUnknownProject_throwsProjectNotFound() async {
        let session = WorkspaceSession()
        let git = FakeGit()
        let error = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: UUID(),
                path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                baseBranch: "main",
                newBranchName: "feature",
                openTab: false,
                git: git
            )
        }
        #expect(git.operations.isEmpty)
        guard case .projectNotFound? = error else {
            Issue.record("expected .projectNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test("createGitWorktree: existing path on disk throws pathAlreadyExists without calling git")
    func createGitWorktree_whenPathExists_throwsAndDoesNotInvokeGit() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        // Create the directory first so the guard fires.
        try await withTempDir { dir in
            let collidingPath = dir.appendingPathComponent("worktree")
            try FileManager.default.createDirectory(at: collidingPath, withIntermediateDirectories: true)
            let sentinel = collidingPath.appendingPathComponent("existing.txt")
            let original = Data("existing contents".utf8)
            try original.write(to: sentinel)
            let git = FakeGit()

            let error = await WorktreeFixture.failure(CreateWorktreeError.self) {
                try await session.createGitWorktree(
                    projectID: project.id,
                    path: collidingPath,
                    baseBranch: "main",
                    newBranchName: "feature",
                    openTab: false,
                    git: git
                )
            }
            if case let .pathAlreadyExists(path)? = error {
                #expect(path == collidingPath)
            } else {
                Issue.record("expected .pathAlreadyExists, got \(String(describing: error))")
            }
            #expect(git.operations.isEmpty)
            #expect(try Data(contentsOf: sentinel) == original)
            #expect(session.project(project.id)?.worktrees.isEmpty == true)
        }
    }

    @Test("createGitWorktree: git failure surfaces stderr through gitFailed")
    func createGitWorktree_whenGitFails_throwsGitFailedWithStderr() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        git.nextCreateResult = .failure("fatal: invalid reference: bogus")

        let error = await WorktreeFixture.failure(CreateWorktreeError.self) {
            try await session.createGitWorktree(
                projectID: project.id,
                path: WorktreeFixture.freshPath(),
                baseBranch: "bogus",
                newBranchName: nil,
                openTab: false,
                git: git
            )
        }
        let unwrapped = try #require(error)
        guard case let .gitFailed(stderr) = unwrapped else {
            Issue.record("expected .gitFailed, got \(unwrapped)")
            return
        }
        #expect(stderr == "fatal: invalid reference: bogus")
        #expect(git.operations == ["worktree add"])
        #expect(session.project(project.id)?.worktrees.isEmpty == true)
        #expect(session.tabs.isEmpty)
    }

    // MARK: - Delete — happy path

    @Test("deleteGitWorktree: success drops the row and returns the freed pane ids")
    func deleteGitWorktree_whenGitSucceeds_dropsRow() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature-z",
            openTab: false,
            git: git
        )

        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: wt.id))

        let neighbor = session.openTab(container: .project(project.id))
        let freed = try await session.deleteGitWorktree(
            projectID: project.id,
            worktreeID: wt.id,
            force: false,
            git: git
        )

        let updated = try #require(session.projects.first { $0.id == project.id })
        #expect(updated.worktrees.isEmpty)
        #expect(freed == tab.splitTree.allLeafIDs())
        #expect(session.tabs.map(\.id) == [neighbor.id])
        #expect(git.removeCalls.map(\.repoRoot) == [project.rootURL])
        #expect(git.removeCalls.map(\.path) == [wt.workingDirectory])
        #expect(git.removeCalls.map(\.force) == [false])
    }

    // MARK: - Delete — errors

    @Test("deleteGitWorktree: unknown project id throws projectNotFound")
    func deleteGitWorktree_withUnknownProject_throwsProjectNotFound() async {
        let session = WorkspaceSession()
        let git = FakeGit()
        let error = await WorktreeFixture.failure(DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(
                projectID: UUID(),
                worktreeID: UUID(),
                force: false,
                git: git
            )
        }
        #expect(git.removeCalls.isEmpty)
        guard case .projectNotFound? = error else {
            Issue.record("expected .projectNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test("deleteGitWorktree: unknown worktree id throws worktreeNotFound")
    func deleteGitWorktree_withUnknownWorktree_throwsWorktreeNotFound() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let survivor = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .opened)
        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: survivor.id))
        let rows = try #require(session.project(project.id)).worktrees
        let git = FakeGit()
        let error = await WorktreeFixture.failure(DeleteWorktreeError.self) {
            try await session.deleteGitWorktree(
                projectID: project.id,
                worktreeID: UUID(),
                force: false,
                git: git
            )
        }
        #expect(git.removeCalls.isEmpty)
        #expect(session.project(project.id)?.worktrees == rows)
        #expect(session.tabs.map(\.id) == [tab.id])
        guard case .worktreeNotFound? = error else {
            Issue.record("expected .worktreeNotFound, got \(String(describing: error))")
            return
        }
    }

    /// How a removal git refused comes out.
    enum RemovalOutcome: Equatable, Sendable {
        case dirtyNeedsForce
        case submodulesNeedForce
        case locked
        case gitFailed(String)
        /// No error, and the row is gone.
        case rowDropped
    }

    private nonisolated static let locked = "fatal: cannot remove a locked working tree, lock reason: on usb\n"
        + "use 'remove -f -f' to override or unlock first"

    @Test("deleteGitWorktree: Git’s refusal decides the error or drops an already-gone row", arguments: [
        ("fatal: '/p' contains modified or untracked files, use --force", false, RemovalOutcome.dirtyNeedsForce),
        (Self.locked, false, .locked),
        (Self.locked, true, .locked),
        ("use --force to delete", false, .dirtyNeedsForce),
        ("fatal: working trees containing submodules cannot be moved or removed", false, .submodulesNeedForce),
        ("fatal: permission denied", false, .gitFailed("fatal: permission denied")),
        ("fatal: '/p' is not a working tree", false, .rowDropped)
    ])
    func deleteGitWorktree_whenGitRefuses_readsItsWords(stderr: String, force: Bool, expected: RemovalOutcome) async throws {
        #expect(try await Self.removalOutcome(stderr: stderr, force: force) == expected)
    }

    /// "No such file or directory" is said of any file git could not open,
    /// so the row goes only once a listing no longer names the worktree.
    @Test("deleteGitWorktree: a missing file drops the row only when git no longer lists the worktree", arguments: [
        (ListingAfterRemoval.without, RemovalOutcome.rowDropped),
        (.samePathDifferentBranch, .gitFailed("error: unable to open .git/hooks/x: No such file or directory")),
        (.namingItsBranchElsewhere, .gitFailed("error: unable to open .git/hooks/x: No such file or directory")),
        (.failed, .gitFailed("error: unable to open .git/hooks/x: No such file or directory"))
    ])
    func deleteGitWorktree_whenAFileIsMissing_checksTheListing(listing: ListingAfterRemoval, expected: RemovalOutcome) async throws {
        let outcome = try await Self.removalOutcome(
            stderr: "error: unable to open .git/hooks/x: No such file or directory",
            listing: listing
        )
        #expect(outcome == expected)
    }

    /// What `git worktree list` says after a removal git refused.
    enum ListingAfterRemoval: Sendable {
        case without
        case samePathDifferentBranch
        /// Under another spelling of its path, as git lists the real one.
        case namingItsBranchElsewhere
        case failed
    }

    /// How a removal git refused with `stderr` comes out.
    private static func removalOutcome(
        stderr: String,
        force: Bool = false,
        listing: ListingAfterRemoval = .without
    ) async throws -> RemovalOutcome {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let git = FakeGit()
        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: WorktreeFixture.freshPath(),
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: git
        )
        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: wt.id))
        let rows = try #require(session.project(project.id)).worktrees
        git.nextRemoveResult = .failure(stderr)
        switch listing {
        case .without: break
        case .samePathDifferentBranch:
            git.listedWorktrees = [GitWorktreeInfo(
                path: wt.workingDirectory,
                headSHA: "abc",
                branch: "different",
                isDetached: false,
                isBare: false,
                isLocked: false,
                isPrunable: false
            )]
        case .namingItsBranchElsewhere:
            git.listedWorktrees = [GitWorktreeInfo(
                path: URL(fileURLWithPath: "/private/elsewhere/feature"),
                headSHA: "abc",
                branch: "feature",
                isDetached: false,
                isBare: false,
                isLocked: false,
                isPrunable: false
            )]
        case .failed:
            git.nextListWorktreesError = .nonZeroExit(.failure("fatal: detected dubious ownership in repository"))
        }

        do {
            let freed = try await session.deleteGitWorktree(projectID: project.id, worktreeID: wt.id, force: force, git: git)
            #expect(session.project(project.id)?.worktrees.isEmpty == true)
            #expect(session.tab(tab.id) == nil)
            #expect(freed == tab.splitTree.allLeafIDs())
            return .rowDropped
        } catch let error as DeleteWorktreeError {
            #expect(session.project(project.id)?.worktrees == rows)
            #expect(session.tab(tab.id) != nil)
            switch error {
            case .dirtyNeedsForce: return .dirtyNeedsForce
            case .submodulesNeedForce: return .submodulesNeedForce
            case .locked: return .locked
            case let .gitFailed(stderr): return .gitFailed(stderr)
            default: throw error
            }
        }
    }

    // MARK: - Admission

    /// A row kept for the same folder, hidden after its folder went missing,
    /// is taken over rather than doubled when the worktree is made again.
    @Test("createGitWorktree: a row already kept at the same folder is raised to Weir's, not doubled")
    func createGitWorktree_atAKeptRowsFolder_raisesThatRow() async throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let path = WorktreeFixture.freshPath()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        var kept = WorktreeFixture.make(workingDirectory: path, isHidden: true, isMissing: true, admission: .discovered)
        kept.gitRef = GitRef(branchName: "previous", worktreePath: path)
        kept.displayName = "Old checkout"
        session.projects[index].worktrees.append(kept)

        let wt = try await session.createGitWorktree(
            projectID: project.id,
            path: path,
            baseBranch: "main",
            newBranchName: "feature",
            openTab: false,
            git: FakeGit()
        )

        let rows = try #require(session.project(project.id)).worktrees
        #expect(wt.id == kept.id)
        #expect(rows.count == 1)
        #expect(rows.first?.admission == .created)
        #expect(rows.first?.isHidden == false)
        #expect(rows.first?.missingSince == nil)
        #expect(rows.first?.gitRef?.branchName == "feature")
        #expect(rows.first?.displayName == nil)
    }

    /// The person choosing a row, or opening a tab in it, admits a row Git
    /// only reported, and one an older file held with no admission.
    @Test("a person’s selection or tab opening admits a row and preserves created admission", arguments: [
        WorktreeAdmission?.some(.discovered), nil, .some(.created)
    ])
    func thePersonsChoice_admitsTheRow(admission: WorktreeAdmission?) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let chosen = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)
        let tabbed = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)

        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: chosen.id), in: session.primaryWindowID, intent: .person)
        session.openTab(
            container: .worktree(projectID: project.id, worktreeID: tabbed.id),
            in: session.primaryWindowID,
            intent: .person,
            selects: false
        )

        let expected: WorktreeAdmission = admission == .created ? .created : .opened
        #expect(session.worktree(projectID: project.id, worktreeID: chosen.id)?.admission == expected)
        #expect(session.worktree(projectID: project.id, worktreeID: tabbed.id)?.admission == expected)
    }

    /// Only the person opens a row: a selection that moves the window on, or
    /// work finishing behind them, leaves it among the other worktrees.
    @Test("a selection the person did not make admits nothing", arguments: [SelectionIntent.repair, .behind])
    func aSelectionNotThePersons_admitsNothing(intent: SelectionIntent) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let selected = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let opened = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let container = ContainerID.worktree(projectID: project.id, worktreeID: selected.id)
        let background = ContainerID.worktree(projectID: project.id, worktreeID: opened.id)
        let window = session.primaryWindowID
        session.setActiveContainer(.project(project.id), in: window, intent: .person)
        if intent == .behind {
            session.setWindow(window, isHidden: true)
        }

        session.setActiveContainer(container, in: window, intent: intent)
        #expect(session.primarySelection.activeContainerID == container)
        #expect(session.worktree(projectID: project.id, worktreeID: selected.id)?.admission == .discovered)
        let tab = session.openTab(container: background, in: session.primaryWindowID, intent: intent, selects: false)
        #expect(session.tabs(in: background).map(\.id) == [tab.id])
        #expect(session.primarySelection.activeContainerID == container)
        #expect(session.worktree(projectID: project.id, worktreeID: opened.id)?.admission == .discovered)
    }

    /// Move to Other Worktrees puts a row among the other worktrees and says
    /// what it was, which Undo puts back; a row already there is left.
    @Test("releaseWorktree: a row Weir made or the person opened goes back among the other worktrees", arguments: [
        WorktreeAdmission?.some(.created), .some(.opened), nil
    ])
    func releaseWorktree_movesTheRowAmongTheOthers(admission: WorktreeAdmission?) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)

        let release = try #require(session.releaseWorktree(projectID: project.id, worktreeID: row.id))

        #expect(release.previous == admission)
        #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == .discovered)
        // Undo puts back what it was, a row not admitted yet included.
        session.readmitWorktree(projectID: project.id, worktreeID: row.id, as: release.previous)
        #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == admission)
    }

    @Test("releaseWorktree: a row already among the other worktrees, or one the session does not have, is left")
    func releaseWorktree_ofADiscoveredOrAbsentRow_changesNothing() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        for (projectID, rowID) in [(project.id, row.id), (project.id, UUID()), (UUID(), row.id)] {
            #expect(session.releaseWorktree(projectID: projectID, worktreeID: rowID) == nil)
            #expect(session.project(project.id)?.worktrees == [row])
        }
    }

    // MARK: - Per-worktree last-active restoration

    @Test("setActiveContainer restores a worktree's own last-active tab, not the first, after a sibling worktree was visited")
    func setActiveContainer_worktree_restoresOwnLastActiveTab() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let a = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)
        let b = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)

        // Worktree A's active tab settles on its second tab.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: a.id))
        let a2 = session.openTab(container: .worktree(projectID: project.id, worktreeID: a.id))
        // Visiting sibling B leaves A's own last-active tab alone.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: b.id))

        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: a.id))
        #expect(session.primarySelection.activeTabID == a2.id)
    }

    @Test("setActiveContainer restores a project-direct last-active tab after interposing a worktree")
    func setActiveContainer_project_survivesWorktreeDetour() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let wt = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)

        _ = session.openTab(container: .project(project.id))
        let pg2 = session.openTab(container: .project(project.id))
        // Interpose the worktree — activating it must not clobber the
        // project-direct container's own last-active pointer.
        _ = session.openTab(container: .worktree(projectID: project.id, worktreeID: wt.id))

        session.setActiveContainer(.project(project.id))
        #expect(session.primarySelection.activeTabID == pg2.id)
    }

    // MARK: - Drag reorder

    /// A project with three worktrees.
    private func makeSessionWithThreeWorktrees() throws -> (WorkspaceSession, Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        for _ in 0..<3 {
            try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, origin: .userPinned)
        }
        return (session, project)
    }

    private func worktreeIDs(of projectID: UUID, in session: WorkspaceSession) -> [UUID] {
        session.project(projectID)?.worktrees.map(\.id) ?? []
    }

    @Test func droppingOnAWorktreeRow_isANoOp_onlyWhenItChangesNothing() throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        try #require(ids.count == 3)
        #expect(session.isNoOpDrop(of: ids[0], onWorktree: ids[0], projectID: project.id, position: .before))
        #expect(session.isNoOpDrop(of: ids[0], onWorktree: ids[1], projectID: project.id, position: .before))
        #expect(session.isNoOpDrop(of: ids[1], onWorktree: ids[0], projectID: project.id, position: .after))
        #expect(!session.isNoOpDrop(of: ids[2], onWorktree: ids[0], projectID: project.id, position: .before))

        let other = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("other"), suggestedName: "other")
        let foreign = try WorkspaceSessionFixture.appendWorktree(to: other.id, in: session)
        #expect(session.isNoOpDrop(of: foreign.id, onWorktree: ids[0], projectID: project.id, position: .before))
    }

    @Test(arguments: [(DropPosition.before, 2, 0, [2, 0, 1]), (.after, 0, 1, [1, 0, 2])])
    func reorderWorktree_placesTheSourceOnTheRequestedSide(position: DropPosition, from: Int, target: Int, order: [Int]) throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        try #require(ids.count == 3)
        session.reorderWorktree(projectID: project.id, sourceID: ids[from], target: ids[target], position: position)
        #expect(worktreeIDs(of: project.id, in: session) == order.map { ids[$0] })
    }

    @Test("reorderWorktree is a no-op when the source or target is unknown, or in another project")
    func reorderWorktree_unknownOrForeignID_isNoOp() throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        try #require(ids.count == 3)
        let other = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("other"), suggestedName: "other")
        let foreign = try WorkspaceSessionFixture.appendWorktree(to: other.id, in: session, origin: .userPinned)

        func expectUnchanged(projectID: UUID = project.id, source: UUID, target: UUID, position: DropPosition) {
            session.reorderWorktree(projectID: projectID, sourceID: source, target: target, position: position)
            #expect(worktreeIDs(of: project.id, in: session) == ids)
            #expect(worktreeIDs(of: other.id, in: session) == [foreign.id])
        }
        expectUnchanged(source: UUID(), target: ids[0], position: .before)
        expectUnchanged(source: ids[0], target: UUID(), position: .after)
        expectUnchanged(source: foreign.id, target: ids[1], position: .before)
        expectUnchanged(source: ids[1], target: foreign.id, position: .after)
        expectUnchanged(projectID: UUID(), source: ids[2], target: ids[0], position: .before)
    }

    // MARK: - Delete Worktrees

    @Test("deleteGitWorktrees: each is removed cleanly, its row dropped and its panes freed")
    func deleteGitWorktrees_whenGitSucceeds_dropsEveryRow() async throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        let roots = try #require(session.project(project.id)).worktrees.map(\.workingDirectory)
        let tabs = ids.map { session.openTab(container: .worktree(projectID: project.id, worktreeID: $0)) }
        let git = FakeGit()
        let registry = RecordingSurfaceRegistry()

        let refused = await ContainerActions.deleteGitWorktrees(
            session,
            registry: registry,
            projectID: project.id,
            worktreeIDs: [ids[0], ids[1]],
            force: false,
            git: git
        )

        #expect(refused.isEmpty)
        #expect(worktreeIDs(of: project.id, in: session) == [ids[2]])
        #expect(git.removeCalls.map(\.force) == [false, false])
        #expect(git.removeCalls.map(\.repoRoot) == [project.rootURL, project.rootURL])
        #expect(git.removeCalls.map(\.path) == Array(roots.prefix(2)))
        #expect(session.tabs.map(\.id) == [tabs[2].id])
        #expect(registry.unregisteredIDs == tabs.prefix(2).flatMap { $0.splitTree.allLeafIDs() })
    }

    @Test(arguments: [false, true])
    func deleteGitWorktrees_returnsOnlyRefusalsAndRetriesOnlyThoseRows(allRefused: Bool) async throws {
        let (session, project) = try makeSessionWithThreeWorktrees()
        let ids = worktreeIDs(of: project.id, in: session)
        let roots = try #require(session.project(project.id)).worktrees.map(\.workingDirectory)
        let tabs = ids.map { session.openTab(container: .worktree(projectID: project.id, worktreeID: $0)) }
        let refusedCount = allRefused ? 2 : 1
        let git = SelectiveRemovalGit(refusedPaths: Set(roots.prefix(refusedCount)))
        let registry = RecordingSurfaceRegistry()

        let refused = await ContainerActions.deleteGitWorktrees(
            session, registry: registry, projectID: project.id, worktreeIDs: Array(ids.prefix(2)), force: false, git: git
        )

        #expect(refused.map(\.worktreeID) == Array(ids.prefix(refusedCount)))
        #expect(refused.allSatisfy { refusal in
            if case .dirtyNeedsForce? = refusal.error as? DeleteWorktreeError {
                true
            } else {
                false
            }
        })
        let kept = Array(ids.prefix(refusedCount)) + [ids[2]]
        #expect(worktreeIDs(of: project.id, in: session) == kept)
        #expect(session.tabs.map(\.id) == Array(tabs.prefix(refusedCount)).map(\.id) + [tabs[2].id])
        let removed = Array(tabs.prefix(2).dropFirst(refusedCount))
        #expect(registry.unregisteredIDs == removed.flatMap { $0.splitTree.allLeafIDs() })

        let forced = await ContainerActions.deleteGitWorktrees(
            session, registry: registry, projectID: project.id, worktreeIDs: refused.map(\.worktreeID), force: true, git: git
        )

        #expect(forced.isEmpty)
        let calls = await git.removals
        #expect(calls.map(\.path) == Array(roots.prefix(2)) + Array(roots.prefix(refusedCount)))
        #expect(calls.map(\.repoRoot) == Array(repeating: project.rootURL, count: 2 + refusedCount))
        #expect(calls.map(\.force) == [false, false] + Array(repeating: true, count: refusedCount))
        #expect(worktreeIDs(of: project.id, in: session) == [ids[2]])
        #expect(session.tabs.map(\.id) == [tabs[2].id])
        #expect(registry.unregisteredIDs == (removed + tabs.prefix(refusedCount)).flatMap { $0.splitTree.allLeafIDs() })
    }

    @Test("The names Git refused are quoted as each language quotes them")
    func refusedNames_areQuotedInTheLanguage() {
        #expect(WorktreeOperationText.lines(["a", "b"], locale: Locale(identifier: "en")) == "\u{201C}a\u{201D}\n\u{201C}b\u{201D}")
        #expect(WorktreeOperationText.lines(["a", "b"], locale: Locale(identifier: "ja")) == "「a」\n「b」")
    }
}

/// Scripts a refusal by path so one batch can contain both outcomes.
private actor SelectiveRemovalGit: GitRunning {
    private let refusedPaths: Set<URL>
    private let otherOperations = FakeGit()
    private(set) var removals: [FakeGit.RemoveCall] = []

    init(refusedPaths: Set<URL>) {
        self.refusedPaths = refusedPaths
    }

    func removeWorktree(repoRoot: URL, path: URL, force: Bool) async throws -> GitResult {
        removals.append(.init(repoRoot: repoRoot, path: path, force: force))
        if !force, refusedPaths.contains(path) {
            return .failure("fatal: contains modified or untracked files, use --force to delete it")
        }
        return .success()
    }

    func createWorktree(repoRoot: URL, path: URL, baseBranch: String) async throws -> GitResult {
        try await otherOperations.createWorktree(repoRoot: repoRoot, path: path, baseBranch: baseBranch)
    }

    func createBranch(repoRoot: URL, name: String, startPoint: String) async throws -> GitResult {
        try await otherOperations.createBranch(repoRoot: repoRoot, name: name, startPoint: startPoint)
    }

    func pruneWorktrees(repoRoot: URL) async throws -> GitResult {
        try await otherOperations.pruneWorktrees(repoRoot: repoRoot)
    }

    func listWorktrees(repoRoot: URL) async throws -> [GitWorktreeInfo] {
        try await otherOperations.listWorktrees(repoRoot: repoRoot)
    }

    func fetch(repoRoot: URL, remote: String, branch: String) async throws -> GitResult {
        try await otherOperations.fetch(repoRoot: repoRoot, remote: remote, branch: branch)
    }

    nonisolated func fetchRef(repoRoot: URL, remote: String, ref: String) async throws -> FetchedRef {
        try await otherOperations.fetchRef(repoRoot: repoRoot, remote: remote, ref: ref)
    }

    func listIgnored(repoRoot: URL) async throws -> [String] {
        try await otherOperations.listIgnored(repoRoot: repoRoot)
    }

    func commitsBehind(repoRoot: URL, local: String, upstream: String) async -> Int? {
        await otherOperations.commitsBehind(repoRoot: repoRoot, local: local, upstream: upstream)
    }
}
