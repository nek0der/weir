// GitSyncCoordinatorTests.swift
// Weir — which `git worktree list` the sidebar ends up showing when syncs overlap.

import Foundation
import os
import Testing
@testable import Weir
@testable import WeirDomain

/// What `GitSyncCoordinatorTests.ChangingRepository` holds: its worktrees,
/// and the listings begun and done.
private struct ChangingRepositoryState {
    var worktrees: [GitWorktreeInfo]
    var started = 0
    var finished = 0
}

@MainActor
struct GitSyncCoordinatorTests {
    /// A repository whose listing changes while a listing runs: each
    /// listing describes it as it was when that listing began, and one that
    /// began while it still held a worktree answers only when `answerLate`
    /// says. The late one is not cut short by cancellation, as `git` is not.
    private final class ChangingRepository: Sendable {
        private let state: OSAllocatedUnfairLock<ChangingRepositoryState>
        private let lateAnswer = Gate<Void>()

        init(worktrees: [GitWorktreeInfo]) {
            state = OSAllocatedUnfairLock(initialState: ChangingRepositoryState(worktrees: worktrees))
        }

        var startedCount: Int {
            state.withLock { $0.started }
        }

        var finishedCount: Int {
            state.withLock { $0.finished }
        }

        /// The worktree removed outside Weir.
        func removeEveryWorktree() {
            state.withLock { $0.worktrees = [] }
        }

        /// Lets the listing that still saw a worktree return.
        func answerLate() {
            lateAnswer.open()
        }

        func list(_: URL) async -> [GitWorktreeInfo] {
            let seen = state.withLock { state in
                state.started += 1
                return state.worktrees
            }
            defer { state.withLock { $0.finished += 1 } }
            if !seen.isEmpty {
                await lateAnswer.wait()
            }
            return seen
        }
    }

    /// A listing's entry for `path`: detached when it names no branch.
    private static func listed(
        _ path: URL,
        headSHA: String,
        branch: String?,
        isBare: Bool = false,
        isPrunable: Bool = false
    ) -> GitWorktreeInfo {
        GitWorktreeInfo(
            path: path,
            headSHA: headSHA,
            branch: branch,
            isDetached: branch == nil && !isBare,
            isBare: isBare,
            isLocked: false,
            isPrunable: isPrunable
        )
    }

    /// Counts the listings asked for, and fails each one, as `git worktree
    /// list` does on a repository git refuses.
    private final class FailingListing: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)

        var calls: Int {
            count.withLock { $0 }
        }

        func list(_: URL) async throws -> [GitWorktreeInfo] {
            count.withLock { $0 += 1 }
            throw GitProcessError.nonZeroExit(.failure("fatal: detected dubious ownership in repository"))
        }
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
            let listing = FailingListing()
            let coordinator = GitSyncCoordinator(session: session) { try await listing.list($0) }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) { listing.calls >= 1 }
            // The sync writes on the main actor after its listing returns:
            // the shortest wait that would let a write land.
            await pollUntil(timeout: .milliseconds(200)) {
                session.projects.first { $0.id == project.id } != before
            }
            var after = try #require(session.projects.first { $0.id == project.id })
            // What git said goes on the project, for the sidebar to show.
            #expect(after.trouble == .listingFailed(detail: "fatal: detected dubious ownership in repository"))
            after.trouble = nil
            #expect(after == before)
            #expect(!session.hasMissingWorktrees(projectID: project.id))
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A listing that fails or succeeds as `fails` says, counting the calls.
    private final class SwitchableListing: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (fails: true, calls: 0))

        var calls: Int {
            state.withLock { $0.calls }
        }

        func setFails(_ fails: Bool) {
            state.withLock { $0.fails = fails }
        }

        func list(_: URL) async throws -> [GitWorktreeInfo] {
            let fails = state.withLock { state in
                state.calls += 1
                return state.fails
            }
            if fails {
                throw GitProcessError.launchFailed("The folder does not exist")
            }
            return []
        }
    }

    /// The project's folder renamed away: the listing fails, and the
    /// project says its folder is missing rather than only the log saying
    /// git failed. Put back, the next sync takes the trouble down.
    @Test func aListing_inAFolderThatIsGone_marksTheProjectsFolderMissing_untilItIsBack() async throws {
        try await withTempDir { dir in
            let root = dir.appendingPathComponent("repo")
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let listing = SwitchableListing()
            let coordinator = GitSyncCoordinator(session: session) { try await listing.list($0) }
            @MainActor func trouble() -> ProjectTrouble? {
                session.projects.first { $0.id == project.id }?.trouble
            }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) { trouble() != nil }
            #expect(trouble() == .folderMissing)
            #expect(session.isFolderMissing(.project(project.id)))

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            listing.setFails(false)
            coordinator.appDidBecomeActive()
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) { trouble() == nil }
            #expect(trouble() == nil)
            #expect(!session.isFolderMissing(.project(project.id)))
            withExtendedLifetime(coordinator) {}
        }
    }

    /// Git keeps listing a worktree whose folder was deleted outside it,
    /// marked prunable, until `git worktree prune`: its row is missing.
    @Test func aSync_marksAPrunableWorktreeMissing() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent("deleted")
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            session.projects[index].worktrees.append(WorktreeFixture.make(workingDirectory: path, admission: .opened))
            let infos = [
                Self.listed(root, headSHA: "abc", branch: "main"),
                Self.listed(path, headSHA: "abc", branch: "deleted", isPrunable: true)
            ]
            let coordinator = GitSyncCoordinator(session: session) { _ in infos }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                session.hasMissingWorktrees(projectID: project.id)
            }
            #expect(session.hasMissingWorktrees(projectID: project.id))
            withExtendedLifetime(coordinator) {}
        }
    }

    /// With the repository cloned bare and worked on in linked worktrees,
    /// the listing's first entry is the bare repository itself, which is no
    /// checkout: only the other worktrees become rows.
    @Test func aSync_ofABareRepository_makesNoRowForIt() async throws {
        try await withTempDir { root in
            let checkout = root.appendingPathComponent("main")
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: checkout)
            let infos = [
                Self.listed(root.appendingPathComponent(".bare"), headSHA: "abc", branch: nil, isBare: true),
                Self.listed(checkout, headSHA: "abc", branch: "main"),
                Self.listed(root.appendingPathComponent("feat-x"), headSHA: "abc", branch: "feat-x")
            ]
            let coordinator = GitSyncCoordinator(session: session) { _ in infos }
            @MainActor func rows() -> [Worktree] {
                session.projects.first { $0.id == project.id }?.worktrees.filter { $0.origin == .gitWorktree } ?? []
            }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) { !rows().isEmpty }
            #expect(rows().map(\.workingDirectory.lastPathComponent) == ["feat-x"])
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A sync started later describes the repository as it is later, so an
    /// earlier one that a later one replaced must not write over it when it
    /// finally returns.
    @Test func aSyncReplacedByALaterOne_doesNotWriteOverIt() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let gone = Self.listed(root.appendingPathComponent("gone"), headSHA: "abc", branch: "gone")
            let repository = ChangingRepository(worktrees: [gone])
            let coordinator = GitSyncCoordinator(session: session) { await repository.list($0) }
            // The first sync's listing is under way, seeing the worktree;
            // then it is removed, and a second sync is asked for.
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) { repository.startedCount >= 1 }
            repository.removeEveryWorktree()

            NotificationCenter.default.post(name: .weirGitSyncRequested, object: project.id)
            // The second listing has answered while the first still waits.
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) {
                repository.startedCount >= 2 && repository.finishedCount >= 1
            }
            repository.answerLate()
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                repository.finishedCount >= 2 && repository.finishedCount == repository.startedCount
            }
            @MainActor func worktrees() -> [Worktree] {
                session.projects.first { $0.id == project.id }?.worktrees ?? []
            }
            // The late listing has returned. Its sync writes on the main
            // actor after that, and nothing marks a write it withheld: the
            // shortest wait that would let it land, ending early if it does.
            await pollUntil(timeout: .milliseconds(200)) { worktrees().contains { $0.origin == .gitWorktree } }
            #expect(worktrees().allSatisfy { $0.origin != .gitWorktree })
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A main folder checked out at a commit has no branch, but is still a
    /// repository: the sync keeps its commit, which the worktree menu reads.
    @Test func aSync_ofADetachedMainCheckout_keepsItsCommit() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let main = Self.listed(root, headSHA: "abc1234", branch: nil)
            let coordinator = GitSyncCoordinator(session: session) { _ in [main] }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                session.projects.first { $0.id == project.id }?.mainHeadSHA != nil
            }
            let synced = try #require(session.projects.first { $0.id == project.id })
            #expect(synced.mainBranchName == nil)
            #expect(synced.mainHeadSHA == "abc1234")
            withExtendedLifetime(coordinator) {}
        }
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
    ) async -> [Worktree] {
        let infos = paths.map { listed($0, headSHA: "abc", branch: $0.lastPathComponent) }
        let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in infos }, homePath: homePath)
        @MainActor func rows() -> [Worktree] {
            session.projects.first { $0.id == projectID }?.worktrees.filter { $0.origin == .gitWorktree } ?? []
        }
        await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
            let synced = rows()
            return synced.count == paths.count && synced.allSatisfy { $0.gitRef?.headSHA == "abc" && $0.admission != nil }
        }
        withExtendedLifetime(coordinator) {}
        return rows()
    }

    /// A worktree a sync finds first was made outside Weir: it is one Git
    /// only reported, wherever it sits, until the person opens it.
    @Test func aWorktreeASyncFindsFirst_isDiscovered() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let rows = await Self.syncedRows(session, project.id, listing: [root.appendingPathComponent("feat-x")])
            #expect(rows.map(\.admission) == [.discovered])
        }
    }

    /// A sync takes each row's branch and HEAD from Git, never its
    /// admission: a row Weir made, or one the person opened, stays so.
    @Test(arguments: [WorktreeAdmission.created, .opened, .discovered])
    func aSync_keepsTheAdmissionARowHas(admission: WorktreeAdmission) async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent(".claude/worktrees/agent-x")
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            session.projects[index].worktrees.append(
                WorktreeFixture.make(workingDirectory: path, admission: admission)
            )
            let rows = await Self.syncedRows(session, project.id, listing: [path])
            #expect(rows.map(\.admission) == [admission])
        }
    }

    /// A sync updates a row in place, so a name the person gave it stays.
    @Test func aSync_keepsTheNameARowWasGiven() async throws {
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let path = root.appendingPathComponent("feat-x")
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            var row = WorktreeFixture.make(workingDirectory: path, admission: .opened)
            row.displayName = "Release prep"
            session.projects[index].worktrees.append(row)
            let rows = await Self.syncedRows(session, project.id, listing: [path])
            #expect(rows.map(\.displayName) == ["Release prep"])
            #expect(rows.first?.gitRef?.branchName == "feat-x")
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
            session.openTab(
                container: .worktree(projectID: project.id, worktreeID: withTab.id),
                in: session.primaryWindowID,
                intent: .repair,
                selects: false
            )
            session.setActiveContainer(
                .worktree(projectID: project.id, worktreeID: selected.id),
                in: session.primaryWindowID,
                intent: .repair
            )
            #expect(session.holdsSelection(of: .worktree(projectID: project.id, worktreeID: selected.id)))
            #expect(session.worktree(projectID: project.id, worktreeID: selected.id)?.admission == nil)

            let rows = await Self.syncedRows(
                session,
                project.id,
                listing: [remembered, withTab, selected, unused, plain].map(\.workingDirectory)
            )
            let admissions = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.admission) })
            #expect(admissions[remembered.id] == .opened)
            #expect(admissions[withTab.id] == .opened)
            #expect(admissions[selected.id] == .opened)
            #expect(admissions[unused.id] == .discovered)
            #expect(admissions[plain.id] == .opened)
            #expect(session.worktree(projectID: project.id, worktreeID: pinned.id)?.admission == .opened)
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
            let listing = Gate<Void>()
            let infos = [Self.listed(row.workingDirectory, headSHA: "abc", branch: "x")]
            let change = Gate<Void>()
            let changing = Task { @MainActor in
                await session.withWorktreeMutationGated(row.id) { await change.wait() }
            }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(10)) {
                session.worktreeMutationsInFlight.contains(row.id)
            }
            let coordinator = GitSyncCoordinator(session: session, listWorktrees: { _ in
                defer { listing.open() }
                return infos
            }, homePath: "/Users/someone")
            await listing.wait()
            // The listing has returned; its write lands on the main actor
            // after it, so give it the shortest wait that would let it.
            await pollUntil(timeout: .milliseconds(200)) {
                session.worktree(projectID: project.id, worktreeID: row.id)?.admission != nil
            }
            #expect(session.worktree(projectID: project.id, worktreeID: row.id)?.admission == nil)
            change.open()
            await changing.value
            withExtendedLifetime(coordinator) {}
        }
    }

    /// A sync reads one `git worktree list` and nothing per worktree: what
    /// it shows of each comes from that listing. Here the listing says the
    /// worktree is detached while the folder's own `git status` would name
    /// a branch; a sync that ran `git status` in every worktree took the
    /// branch from it, on every activation, for a value nothing reads.
    @Test func aSync_takesEachWorktreeFromTheListingAlone() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await withTempDir { root in
            let (session, project) = WorkspaceSessionFixture.withProject(rootURL: root)
            let listed = Self.listed(repo.url, headSHA: "abc", branch: nil)
            let coordinator = GitSyncCoordinator(session: session) { _ in [listed] }
            await pollUntil(timeout: .seconds(3), interval: .milliseconds(20)) {
                session.projects.first { $0.id == project.id }?.worktrees.contains { $0.origin == .gitWorktree } == true
            }
            let worktree = try #require(session.projects.first { $0.id == project.id }?.worktrees.first { $0.origin == .gitWorktree })
            #expect(worktree.gitRef?.branchName == nil)
            #expect(worktree.gitRef?.headSHA == "abc")
            withExtendedLifetime(coordinator) {}
        }
    }
}
