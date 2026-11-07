// GitSyncCoordinatorTests.swift
// Weir — how Git listings reconcile sidebar worktrees and project state.

import Foundation
import os
import Testing
@testable import Weir
@testable import WeirDomain

private struct ChangingRepositoryState {
    var worktrees: [GitWorktreeInfo]
    var started = 0
    var didCancelFirstListing = false
    var didReleaseFirstListing = false
}

@MainActor
struct GitSyncCoordinatorTests {
    /// A repository whose listing changes while a listing runs: each
    /// listing describes it as it was when that listing began. The first
    /// listing waits for `answerLate`, even after cancellation, so it can
    /// arrive after a newer listing.
    private final class ChangingRepository: Sendable {
        private let state: OSAllocatedUnfairLock<ChangingRepositoryState>
        private let lateAnswer = Gate<Void>()

        init(worktrees: [GitWorktreeInfo]) {
            state = OSAllocatedUnfairLock(initialState: ChangingRepositoryState(worktrees: worktrees))
        }

        var startedCount: Int {
            state.withLock { $0.started }
        }

        var didCancelFirstListing: Bool {
            state.withLock { $0.didCancelFirstListing }
        }

        var didReleaseFirstListing: Bool {
            state.withLock { $0.didReleaseFirstListing }
        }

        /// Replaces the result of subsequent listings.
        func replaceWorktrees(with worktrees: [GitWorktreeInfo]) {
            state.withLock { $0.worktrees = worktrees }
        }

        /// Lets the listing that still saw a worktree return.
        func answerLate() {
            lateAnswer.open()
        }

        func list(_: URL) async -> [GitWorktreeInfo] {
            let (seen, isFirst) = state.withLock { state in
                state.started += 1
                return (state.worktrees, state.started == 1)
            }
            if isFirst {
                await withTaskCancellationHandler {
                    await lateAnswer.wait()
                } onCancel: {
                    self.state.withLock { $0.didCancelFirstListing = true }
                }
                state.withLock { $0.didReleaseFirstListing = true }
            }
            return seen
        }
    }

    /// A listing's entry for `path`: detached when it names no branch.
    private static func listed(
        _ path: URL,
        headSHA: String,
        branch: String?
    ) -> GitWorktreeInfo {
        GitWorktreeInfo(
            path: path,
            headSHA: headSHA,
            branch: branch,
            isDetached: branch == nil,
            isBare: false,
            isLocked: false,
            isPrunable: false
        )
    }

    /// A listing that failed says nothing about the worktrees: every row
    /// stays as it was, none is marked missing for Remove Missing to close,
    /// and the main checkout keeps its branch.
    @Test func aFailedListing_keepsEveryRow_andMarksNoneMissing() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            let row = WorktreeFixture.make(workingDirectory: root.appendingPathComponent("feat-x"), admission: .opened)
            session.projects[index].worktrees.append(row)
            session.projects[index].mainBranchName = "main"
            let before = session.projects[index]
            let requestedRoots = Recorded<[URL]>([])
            let detail = "fatal: detected dubious ownership in repository"
            let expected = ProjectTrouble.listingFailed(detail: detail)
            let coordinator = GitSyncCoordinator(session: session) { root in
                requestedRoots.update { $0.append(root) }
                throw GitProcessError.nonZeroExit(.failure(detail))
            }
            await pollUntil { session.project(project.id)?.trouble == expected }
            var after = try #require(session.project(project.id))
            #expect(after.trouble == expected)
            #expect(requestedRoots.value == [project.rootURL])
            after.trouble = nil
            #expect(after == before)
            #expect(!session.hasMissingWorktrees(projectID: project.id))
            withExtendedLifetime(coordinator) {}
        }
    }

    /// The project's folder renamed away: the listing fails, and the
    /// project says its folder is missing rather than only the log saying
    /// git failed. Put back, the next sync takes the trouble down.
    @Test func aListing_inAFolderThatIsGone_marksTheProjectsFolderMissing_untilItIsBack() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let head = try await repo.git(["rev-parse", "HEAD"])
        let renamed = repo.scratch.appendingPathComponent("away")
        try FileManager.default.moveItem(at: repo.url, to: renamed)
        let (session, project) = WorkspaceSessionFixture.withProject(rootURL: repo.url)
        let coordinator = GitSyncCoordinator(session: session)
        await pollUntil { session.project(project.id)?.trouble == .folderMissing }
        try #require(session.project(project.id)?.trouble == .folderMissing)
        #expect(session.isFolderMissing(.project(project.id)))

        try FileManager.default.moveItem(at: renamed, to: repo.url)
        coordinator.appDidBecomeActive()
        await pollUntil { session.project(project.id)?.mainHeadSHA == head }
        let restored = try #require(session.project(project.id))
        #expect(restored.trouble == nil)
        #expect(restored.mainBranchName == "main")
        #expect(restored.mainHeadSHA == head)
        #expect(!session.isFolderMissing(.project(project.id)))
        withExtendedLifetime(coordinator) {}
    }

    /// Git keeps listing a worktree whose folder was deleted outside it,
    /// marked prunable, until `git worktree prune`: its row is missing.
    @Test func aSync_marksAPrunableWorktreeMissing() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let deletedPath = try await repo.addLinkedWorktree(branch: "deleted")
        let retainedPath = try await repo.addLinkedWorktree(branch: "retained")
        let initial = try await GitWorktreeList.fetch(repoRoot: repo.url)
        let deleted = try #require(initial.first { $0.branch == "deleted" })
        let retained = try #require(initial.first { $0.branch == "retained" })
        try #require(deleted.path.lastPathComponent == deletedPath.lastPathComponent)
        try #require(retained.path.lastPathComponent == retainedPath.lastPathComponent)

        try FileManager.default.removeItem(at: deletedPath)
        let listing = try await GitWorktreeList.fetch(repoRoot: repo.url)
        try #require(listing.contains { $0.path.path == deleted.path.path && $0.isPrunable })
        let (session, project) = WorkspaceSessionFixture.withProject(rootURL: repo.url)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        var row = WorktreeFixture.make(workingDirectory: deleted.path, admission: .opened)
        row.gitRef = GitRef(branchName: "deleted")
        session.projects[index].worktrees.append(row)
        let coordinator = GitSyncCoordinator(session: session)
        await pollUntil { session.projects[index].mainHeadSHA != nil }
        let synced = session.projects[index]
        let missing = try #require(synced.worktree(row.id))
        #expect(missing.missingSince != nil)
        #expect(missing.workingDirectory == row.workingDirectory)
        #expect(missing.admission == .opened)
        let live = try #require(synced.worktrees.first { $0.workingDirectory == retained.path.standardizedFileURL })
        #expect(live.missingSince == nil)
        #expect(live.gitRef?.branchName == "retained")
        #expect(synced.worktrees.count == 2)
        #expect(session.hasMissingWorktrees(projectID: project.id))
        withExtendedLifetime(coordinator) {}
    }

    /// With the repository cloned bare and worked on in linked worktrees,
    /// the listing's first entry is the bare repository itself, which is no
    /// checkout: only the other worktrees become rows.
    @Test func aSync_ofABareRepository_makesNoRowForIt() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let bare = repo.scratch.appendingPathComponent("bare")
        let checkout = repo.scratch.appendingPathComponent("main")
        let feature = repo.scratch.appendingPathComponent("feat-x")
        let head = try await repo.git(["rev-parse", "HEAD"])
        try await repo.git(["clone", "-q", "--bare", "--", repo.url.path, bare.path])
        try await TempGitRepo.configureForTests(bare)
        try await TempGitRepo.git(["worktree", "add", "-q", "--", checkout.path, "main"], in: bare)
        try await TempGitRepo.git(["worktree", "add", "-q", "-b", "feat-x", "--", feature.path], in: bare)
        let (session, project) = WorkspaceSessionFixture.withProject(rootURL: checkout)
        let coordinator = GitSyncCoordinator(session: session)
        await pollUntil { session.project(project.id)?.mainHeadSHA == head }
        let synced = try #require(session.project(project.id))
        #expect(synced.mainBranchName == "main")
        #expect(synced.mainHeadSHA == head)
        #expect(synced.worktrees.map(\.workingDirectory) == [feature.standardizedFileURL])
        #expect(synced.worktrees.map { $0.gitRef?.branchName } == ["feat-x"])
        withExtendedLifetime(coordinator) {}
    }

    /// A sync started later describes the repository as it is later, so an
    /// earlier one that a later one replaced must not write over it when it
    /// finally returns.
    @Test func aSyncReplacedByALaterOne_doesNotWriteOverIt() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let gone = Self.listed(root.appendingPathComponent("gone"), headSHA: "abc", branch: "gone")
            let repository = ChangingRepository(worktrees: [gone])
            defer { repository.answerLate() }
            let coordinator = GitSyncCoordinator(session: session) { await repository.list($0) }
            // The first sync's listing is under way, seeing the worktree;
            // then it is removed, and a second sync is asked for.
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) { repository.startedCount >= 1 }
            try #require(repository.startedCount >= 1)
            repository.replaceWorktrees(with: [Self.listed(root, headSHA: "new-head", branch: "main")])

            NotificationCenter.default.post(name: .weirGitSyncRequested, object: project.id)
            // The second listing has answered while the first still waits.
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) {
                session.projects.first { $0.id == project.id }?.mainHeadSHA == "new-head"
            }
            try #require(session.projects.first { $0.id == project.id }?.mainHeadSHA == "new-head")
            let updated = try #require(session.project(project.id))
            #expect(updated.mainBranchName == "main")
            #expect(updated.worktrees.isEmpty)
            #expect(repository.startedCount == 2)
            #expect(repository.didCancelFirstListing)
            #expect(!repository.didReleaseFirstListing)

            repository.answerLate()
            await pollUntil { repository.didReleaseFirstListing }
            try #require(repository.didReleaseFirstListing)
            // The lister reports release before the coordinator resumes.
            // Watch for a stale write within this observation window.
            await pollUntil(timeout: .milliseconds(200)) { session.project(project.id) != updated }
            #expect(session.project(project.id) == updated)
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A main folder checked out at a commit has no branch, but is still a
    /// repository: the sync keeps its commit, which the worktree menu reads.
    @Test func aSync_ofADetachedMainCheckout_keepsItsCommit() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let head = try await repo.git(["rev-parse", "HEAD"])
        try await repo.git(["switch", "-q", "--detach", head])
        let (session, project) = WorkspaceSessionFixture.withProject(rootURL: repo.url)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].mainBranchName = "main"
        let coordinator = GitSyncCoordinator(session: session)
        await pollUntil { session.projects[index].mainHeadSHA == head }
        let synced = session.projects[index]
        #expect(synced.mainBranchName == nil)
        #expect(synced.mainHeadSHA == head)
        #expect(synced.worktrees.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    @Test func anExactPathMatch_keepsItsIdentity_whenAnEarlierRowSharesItsBranch() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            var removed = WorktreeFixture.make(
                label: "Removed",
                workingDirectory: root.appendingPathComponent("removed"),
                admission: .opened
            )
            var surviving = WorktreeFixture.make(
                label: "Surviving",
                workingDirectory: root.appendingPathComponent("surviving"),
                admission: .opened
            )
            removed.displayName = "Removed"
            surviving.displayName = "Surviving"
            removed.gitRef = GitRef(branchName: "shared")
            surviving.gitRef = GitRef(branchName: "shared")
            session.projects[index].worktrees = [removed, surviving]
            let info = Self.listed(surviving.workingDirectory, headSHA: "fresh", branch: "shared")
            let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in [info] })
            await pollUntil(timeout: .seconds(3)) {
                session.projects[index].worktrees.contains { $0.gitRef?.headSHA == "fresh" }
            }
            let rows = session.projects[index].worktrees
            let kept = try #require(rows.first { $0.id == surviving.id })
            let missing = try #require(rows.first { $0.id == removed.id })
            #expect(rows.count == 2)
            #expect(kept.workingDirectory == surviving.workingDirectory)
            #expect(kept.displayName == "Surviving")
            #expect(kept.gitRef?.headSHA == "fresh")
            #expect(kept.missingSince == nil)
            #expect(missing.workingDirectory == removed.workingDirectory)
            #expect(missing.missingSince != nil)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test func branchFallback_preservesIdentityOnlyForAnUnambiguousMove() async throws {
        for (oldCount, newCount, isFirstChanging) in [(1, 1, false), (1, 2, false), (2, 1, false), (2, 1, true)] {
            try await withTempDir { root in
                let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
                let index = try #require(session.projects.firstIndex { $0.id == project.id })
                let old = (0..<oldCount).map { number in
                    var row = WorktreeFixture.make(workingDirectory: root.appendingPathComponent("old-\(number)"), admission: .opened)
                    row.displayName = "Saved \(number)"
                    row.gitRef = GitRef(branchName: "shared")
                    return row
                }
                session.projects[index].worktrees = old
                let change = Gate<Void>()
                defer { change.open() }
                let changing = Task { @MainActor in
                    if isFirstChanging {
                        await session.withWorktreeMutationGated(old[0].id) { await change.wait() }
                    }
                }
                if isFirstChanging {
                    await pollUntil { session.worktreeMutationsInFlight.contains(old[0].id) }
                    try #require(session.worktreeMutationsInFlight.contains(old[0].id))
                }
                let infos = (0..<newCount).map { Self.listed(root.appendingPathComponent("new-\($0)"), headSHA: "fresh", branch: "shared") }
                let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in infos })
                await pollUntil(timeout: .seconds(3)) {
                    session.projects[index].worktrees.filter { $0.gitRef?.headSHA == "fresh" }.count == newCount
                }
                let rows = session.projects[index].worktrees
                if oldCount == 1, newCount == 1 {
                    #expect(rows.map(\.id) == old.map(\.id))
                    #expect(rows.first?.workingDirectory == infos[0].path)
                    #expect(rows.first?.displayName == "Saved 0")
                    #expect(rows.first?.missingSince == nil)
                } else {
                    #expect(rows.count == oldCount + newCount)
                    for previous in old {
                        let retained = try #require(rows.first { $0.id == previous.id })
                        #expect(retained.workingDirectory == previous.workingDirectory)
                        if isFirstChanging, previous.id == old[0].id {
                            #expect(retained == previous)
                        } else {
                            #expect(retained.missingSince != nil)
                        }
                    }
                    let fresh = rows.filter { $0.gitRef?.headSHA == "fresh" }
                    #expect(Set(fresh.map(\.workingDirectory)) == Set(infos.map(\.path)))
                    #expect(fresh.allSatisfy { $0.admission == .discovered && $0.missingSince == nil })
                }
                change.open()
                await changing.value
                withExtendedLifetime(coordinator) {}
            }
        }
    }

    // MARK: - Admission

    /// The project's git rows once a sync has listed every one of `paths`.
    private static func syncedRows(
        _ session: WorkspaceSession,
        _ projectID: UUID,
        listing paths: [URL],
        homePath: String = "/Users/someone"
    ) async throws -> [Worktree] {
        let infos = paths.map { listed($0, headSHA: "abc", branch: $0.lastPathComponent) }
        let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in infos }, homePath: homePath)
        @MainActor func rows() -> [Worktree] {
            session.projects.first { $0.id == projectID }?.worktrees.filter { $0.origin == .gitWorktree } ?? []
        }
        @MainActor func hasSynced() -> Bool {
            let current = rows()
            return current.count == paths.count && current.allSatisfy { $0.gitRef?.headSHA == "abc" && $0.admission != nil }
        }
        await pollUntil { hasSynced() }
        try #require(hasSynced())
        withExtendedLifetime(coordinator) {}
        return rows()
    }

    /// A worktree a sync finds first was made outside Weir: it is one Git
    /// only reported, wherever it sits, until the person opens it.
    @Test func aWorktreeASyncFindsFirst_isDiscovered() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent("feat-x")
            let rows = try await Self.syncedRows(session, project.id, listing: [path])
            #expect(rows.map(\.workingDirectory) == [path.standardizedFileURL])
            #expect(rows.map(\.admission) == [.discovered])
            #expect(rows.map { $0.gitRef?.branchName } == ["feat-x"])
        }
    }

    /// A sync takes the branch and HEAD from Git, and keeps the row's
    /// identity, admission, and user-assigned name.
    @Test(arguments: [WorktreeAdmission.created, .opened, .discovered])
    func aSync_refreshesGitMetadata_andKeepsTheRowsIdentityAdmissionAndName(admission: WorktreeAdmission) async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent(".claude/worktrees/agent-x")
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            var row = WorktreeFixture.make(label: "old-branch", workingDirectory: path, admission: admission)
            row.gitRef = GitRef(branchName: "old-branch", headSHA: "old-head")
            row.displayName = "Release prep"
            session.projects[index].worktrees.append(row)

            let rows = try await Self.syncedRows(session, project.id, listing: [path])
            let updated = try #require(rows.first)
            #expect(updated.id == row.id)
            #expect(updated.workingDirectory == path.standardizedFileURL)
            #expect(updated.admission == admission)
            #expect(updated.displayName == "Release prep")
            #expect(updated.label == "agent-x")
            #expect(updated.gitRef?.branchName == "agent-x")
            #expect(updated.gitRef?.headSHA == "abc")
        }
    }

    /// A row an older `state.json` holds with no admission is admitted by
    /// its use first: one the person used under `.claude/worktrees/` stays
    /// a working row, and only an agent's unused one waits among the other
    /// worktrees.
    @Test func aSync_admitsARowWithNoAdmission_byItsUseThenItsPath() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            let agents = root.appendingPathComponent(".claude/worktrees")
            var remembered = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("remembered"))
            remembered.lastActiveTabID = UUID()
            let withTab = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("with-tab"))
            let selected = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("selected"))
            let unused = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("unused"))
            let plain = WorktreeFixture.make(workingDirectory: root.appendingPathComponent("plain"))
            let pinned = WorktreeFixture.make(workingDirectory: agents.appendingPathComponent("pinned"), origin: .userPinned)
            session.projects[index].worktrees = [remembered, withTab, selected, unused, plain, pinned]
            // The window shows the project; a tab opened, and a row chosen,
            // by anyone but the person admit nothing on their own: the rows
            // are used.
            session.setActiveContainer(.project(project.id))
            let withTabContainer = ContainerID.worktree(projectID: project.id, worktreeID: withTab.id)
            let selectedContainer = ContainerID.worktree(projectID: project.id, worktreeID: selected.id)
            session.openTab(
                container: withTabContainer,
                in: session.primaryWindowID,
                intent: .repair,
                selects: false
            )
            let tabRowIndex = try #require(session.projects[index].worktrees.firstIndex { $0.id == withTab.id })
            session.projects[index].worktrees[tabRowIndex].lastActiveTabID = nil
            session.setActiveContainer(selectedContainer, in: session.primaryWindowID, intent: .repair)
            try #require(session.tabs(in: withTabContainer).count == 1)
            try #require(!session.holdsSelection(of: withTabContainer))
            try #require(session.tabs(in: selectedContainer).isEmpty)
            try #require(session.holdsSelection(of: selectedContainer))
            try #require(session.projects[index].worktrees.allSatisfy { $0.admission == nil })

            let rows = try await Self.syncedRows(
                session,
                project.id,
                listing: [remembered, withTab, selected, unused, plain].map(\.workingDirectory)
            )
            let admissions = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                row.admission.map { (row.id, $0) }
            })
            #expect(admissions == [
                remembered.id: .opened, withTab.id: .opened, selected.id: .opened,
                unused.id: .discovered, plain.id: .opened
            ])
            var admittedPinned = pinned
            admittedPinned.admission = .opened
            #expect(session.worktree(projectID: project.id, worktreeID: pinned.id) == admittedPinned)
        }
    }

    /// A row being changed (moved, deleted) is left as the change has it,
    /// as the reconcile leaves it: a sync admits it once the change is done.
    @Test func aSync_leavesARowBeingChangedUnadmitted() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            let row = WorktreeFixture.make(workingDirectory: root.appendingPathComponent(".claude/worktrees/x"))
            session.projects[index].worktrees = [row]
            let infos = [
                Self.listed(root, headSHA: "synced-head", branch: "main"),
                Self.listed(row.workingDirectory, headSHA: "abc", branch: "x")
            ]
            let change = Gate<Void>()
            defer { change.open() }
            let changing = Task { @MainActor in
                await session.withWorktreeMutationGated(row.id) { await change.wait() }
            }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) {
                session.worktreeMutationsInFlight.contains(row.id)
            }
            try #require(session.worktreeMutationsInFlight.contains(row.id))
            let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in infos }, homePath: "/Users/someone")
            await pollUntil {
                session.projects.first { $0.id == project.id }?.mainHeadSHA == "synced-head"
            }
            try #require(session.projects.first { $0.id == project.id }?.mainHeadSHA == "synced-head")
            #expect(session.worktree(projectID: project.id, worktreeID: row.id) == row)
            change.open()
            await changing.value
            NotificationCenter.default.post(name: .weirGitSyncRequested, object: project.id)
            await pollUntil { session.worktree(projectID: project.id, worktreeID: row.id)?.admission != nil }
            let updated = try #require(session.worktree(projectID: project.id, worktreeID: row.id))
            #expect(updated.admission == .discovered)
            #expect(updated.gitRef?.branchName == "x")
            #expect(updated.gitRef?.headSHA == "abc")
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A listing's branch and HEAD are authoritative even when the
    /// checkout would report different values.
    @Test func aSync_usesTheListingsBranchAndHead() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let checkedOutBranch = try await repo.git(["branch", "--show-current"])
        let checkedOutHead = try await repo.git(["rev-parse", "HEAD"])
        try #require(checkedOutBranch == "main")
        try #require(checkedOutHead != "listed-head")
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let listed = Self.listed(repo.url, headSHA: "listed-head", branch: nil)
            let requestedRoots = Recorded<[URL]>([])
            let coordinator = GitSyncCoordinator(session: session) { root in
                requestedRoots.update { $0.append(root) }
                return [listed]
            }
            await pollUntil { session.project(project.id)?.worktrees.count == 1 }
            let synced = try #require(session.project(project.id))
            let worktree = try #require(synced.worktrees.first)
            #expect(requestedRoots.value == [project.rootURL])
            #expect(synced.worktrees.count == 1)
            #expect(worktree.origin == .gitWorktree)
            #expect(worktree.workingDirectory == repo.url.standardizedFileURL)
            #expect(worktree.gitRef?.branchName == nil)
            #expect(worktree.gitRef?.headSHA == "listed-head")
            withExtendedLifetime(coordinator) {}
        }
    }
}
