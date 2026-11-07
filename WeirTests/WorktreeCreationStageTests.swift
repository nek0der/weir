// WorktreeCreationStageTests.swift
// Weir — creating a worktree in stages: each failure named by its stage, and a retry that makes nothing twice.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeCreationStageTests {
    private static func session(bootstrap: [BootstrapItem] = []) -> (WorkspaceSession, Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].bootstrap = bootstrap
        return (session, session.projects[index])
    }

    /// The test's own `PATH`: no login shell is started.
    private nonisolated static let path = ProcessInfo.processInfo.environment["PATH"]

    private static func failure(_ body: () async throws -> some Any) async -> CreateWorktreeError? {
        await WorktreeFixture.failure(CreateWorktreeError.self, of: body)
    }

    @Test func aBranchThatCannotBeMade_isTheWorktreeStage_andLeavesNothing() async {
        let (session, project) = Self.session()
        let git = FakeGit()
        git.nextBranchResult = .failure("fatal: a branch named 'feat/x' already exists")
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "main", newBranchName: "feat/x", openTab: false,
                git: git
            )
        }
        #expect(error?.stage == .creatingWorktree)
        #expect(error?.logTail == "fatal: a branch named 'feat/x' already exists")
        guard case .gitFailed = error else {
            Issue.record("a branch that was never made was reported as left behind: \(String(describing: error))")
            return
        }
        #expect(git.createCalls.isEmpty)
        #expect(session.project(project.id)?.worktrees.isEmpty == true)
    }

    @Test func partialBranchSuccess_isReusable() async throws {
        let (session, project) = Self.session()
        let git = FakeGit()
        git.nextCreateResult = .failure("fatal: could not create work tree dir")
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "main", newBranchName: "feat/x", openTab: false,
                git: git
            )
        }
        guard case let .gitFailedLeavingBranch(_, branch) = error else {
            Issue.record("expected the branch left behind, got \(String(describing: error))")
            return
        }
        #expect(branch == "feat/x")

        // The retry uses the branch as an existing one: no second branch.
        git.nextCreateResult = .success()
        let worktree = try await session.createGitWorktree(
            projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "feat/x", newBranchName: nil, openTab: false, git: git
        )
        #expect(git.branchCalls.count == 1)
        #expect(git.createCalls.last?.baseBranch == "feat/x")
        #expect(session.project(project.id)?.worktrees.map(\.id) == [worktree.id])
    }

    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func partialBranchSuccess_isReusable_inARealRepository() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let session = WorkspaceSession()
        let project = session.addOrActivateProject(rootURL: repo.url, suggestedName: "real")
        // A file where the worktree's parent folder should be: git makes the
        // branch, then cannot add the worktree.
        let blocker = repo.url.appendingPathComponent("blocker")
        try #require(FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8)))
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id,
                path: blocker.appendingPathComponent("wt"),
                baseBranch: "main",
                newBranchName: "feat/real",
                openTab: false
            )
        }
        guard case let .gitFailedLeavingBranch(_, branch) = error else {
            Issue.record("expected the branch left behind, got \(String(describing: error))")
            return
        }
        #expect(branch == "feat/real")
        let mainTip = try await repo.git(["rev-parse", "main"])
        #expect(try await repo.git(["rev-parse", "--verify", "refs/heads/feat/real"]) == mainTip)
        #expect(session.project(project.id)?.worktrees.isEmpty == true)
        let linked = repo.url.appendingPathComponent("wt")
        let worktree = try await session.createGitWorktree(
            projectID: project.id,
            path: linked,
            baseBranch: branch,
            newBranchName: nil,
            openTab: false
        )
        #expect(worktree.gitRef?.branchName == "feat/real")
        #expect(try await TempGitRepo.git(["symbolic-ref", "--short", "HEAD"], in: linked) == "feat/real")
        let topLevel = try await TempGitRepo.git(["rev-parse", "--show-toplevel"], in: linked)
        #expect(URL(fileURLWithPath: topLevel).resolvingSymlinksInPath().path == linked.resolvingSymlinksInPath().path)
        #expect(worktree.workingDirectory.resolvingSymlinksInPath().path == linked.resolvingSymlinksInPath().path)
        #expect(session.project(project.id)?.worktrees.map(\.id) == [worktree.id])
    }

    @Test func retryAfterSetupFailure_doesNotCreateSecondWorktree() async throws {
        try await withTempDir { dir in
            let marker = dir.appendingPathComponent("marker")
            let trace = dir.appendingPathComponent("trace")
            let (session, project) = Self.session(bootstrap: [
                .shorthand("echo first >> '\(trace.path)'"),
                .shorthand("""
                echo attempt >> '\(trace.path)'
                test -f '\(marker.path)' || { echo 'missing marker' >&2; exit 3; }
                """),
                .shorthand("echo last >> '\(trace.path)'")
            ])
            let git = FakeGit()
            git.createsDirectoryOnSuccess = true
            let path = dir.appendingPathComponent("worktree")

            // The worktree stage ends with the row; the setup is the next one.
            let worktree = try await session.createGitWorktree(
                projectID: project.id, path: path, baseBranch: "main", newBranchName: "feat/x", openTab: false, git: git
            )
            let error = await Self.failure {
                try await session.runSetup(projectID: project.id, worktreeID: worktree.id, path: { Self.path })
            }
            #expect(error?.stage == .setup(stepIndex: 1))
            #expect(error?.logTail == "missing marker")
            #expect(try String(contentsOf: trace, encoding: .utf8) == "first\nattempt\n")
            #expect(session.project(project.id)?.worktrees.map(\.id) == [worktree.id])

            try #require(FileManager.default.createFile(atPath: marker.path, contents: nil))
            try await session.runSetup(projectID: project.id, worktreeID: worktree.id, from: 1, path: { Self.path })
            let expectedTrace = "first\nattempt\nattempt\nlast\n"
            #expect(try String(contentsOf: trace, encoding: .utf8) == expectedTrace)
            #expect(git.branchCalls.count == 1)
            #expect(git.createCalls.count == 1)
            #expect(session.project(project.id)?.worktrees.map(\.id) == [worktree.id])
            // Past the last command there is nothing to run.
            try await session.runSetup(projectID: project.id, worktreeID: worktree.id, from: 5, path: { Self.path })
            #expect(try String(contentsOf: trace, encoding: .utf8) == expectedTrace)
        }
    }

    @Test func aBranchNameGitWouldReadAsAnOption_isRefused_beforeGitRuns() async {
        let (session, project) = Self.session()
        let git = FakeGit()
        let error = await Self.failure {
            try await session.createGitWorktree(
                projectID: project.id, path: WorktreeFixture.freshPath(), baseBranch: "develop", newBranchName: "-D", openTab: false,
                git: git
            )
        }
        #expect(error?.stage == .creatingWorktree)
        guard case .invalidBranchName("-D") = error else {
            Issue.record("not refused: \(String(describing: error))")
            return
        }
        #expect(git.branchCalls.isEmpty)
        #expect(git.createCalls.isEmpty)
        #expect(session.project(project.id)?.worktrees.isEmpty == true)
    }

    @Test func gitsWords_keepTheirEnd_asALogDoes() {
        let long = String(repeating: "x", count: 20000) + "the end"
        let tail = CreateWorktreeError.tail(long)
        #expect(tail.hasSuffix("the end"))
        #expect(tail.utf8.count <= WorktreeSetup.logTailBytes)
        #expect(CreateWorktreeError.tail("  short \n") == "short")
    }
}
