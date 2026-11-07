// GitFactsTests.swift
// Weir — what a session's folder holds toward a pull request, read from a real repository.

import Foundation
import Testing
@testable import Weir

@Suite(.tags(.smoke), .timeLimit(.minutes(1)))
struct GitFactsTests {
    @Test func aRepositoryWithNoRemote_countsAgainstItsLocalMain_andHasNoUnpushedCount() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        let onMain = try await read(repo.url)
        #expect(onMain.branch == "main")
        #expect(onMain.base == GitFacts.Base(ref: "main"))
        #expect(onMain.isOnBase)
        #expect(onMain.commitsNotOnBase == 0)
        #expect(onMain.unpushedCommits == nil)
        #expect(onMain.uncommittedFiles == 0)

        try await repo.git(["switch", "-q", "-c", "feat/x"])
        try repo.write("a.txt", to: "a.txt")
        try await repo.commit("a.txt", paths: ["a.txt"])
        try repo.write("b.txt", to: "b.txt")
        try await repo.commit("b.txt", paths: ["b.txt"])
        let onBranch = try await read(repo.url)
        #expect(onBranch.branch == "feat/x")
        #expect(onBranch.base == GitFacts.Base(ref: "main"))
        #expect(!onBranch.isOnBase)
        #expect(onBranch.commitsNotOnBase == 2)
        #expect(onBranch.unpushedCommits == nil)
    }

    @Test func uncommittedFiles_countEachPathOnce_evenWhenStagedAndUnstaged() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("original", to: "both.txt")
        try repo.write("original", to: "unstaged.txt")
        try await repo.commit("tracked files", paths: ["both.txt", "unstaged.txt"])

        try repo.write("staged", to: "both.txt")
        try repo.write("staged only", to: "staged.txt")
        try await repo.git(["add", "--", "both.txt", "staged.txt"])
        try repo.write("unstaged after staging", to: "both.txt")
        try repo.write("unstaged only", to: "unstaged.txt")
        try repo.write("untracked", to: "new/one.txt")
        try repo.write("untracked", to: "new/two.txt")

        let facts = try await read(repo.url)
        #expect(facts.uncommittedFiles == 5)
    }

    @Test func withARemote_theBaseIsOriginsDefault_andUnpushedCommitsAreThoseNoRemoteHas() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let remote = try await TempGitRepo.make()
        defer { remote.cleanup() }
        try await remote.git(["branch", "-m", "trunk"])
        try remote.write("only on trunk", to: "base.txt")
        try await remote.commit("trunk base", paths: ["base.txt"])
        try await repo.git(["remote", "add", "origin", remote.url.path])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["remote", "set-head", "origin", "trunk"])
        try await repo.git(["switch", "-q", "--no-track", "-c", "feat/x", "origin/trunk"])
        try repo.write("a.txt", to: "a.txt")
        try await repo.commit("a.txt", paths: ["a.txt"])
        try repo.write("b.txt", to: "b.txt")
        try await repo.commit("b.txt", paths: ["b.txt"])

        let unpushed = try await read(repo.url)
        #expect(unpushed.branch == "feat/x")
        #expect(unpushed.base?.ref == "origin/trunk")
        #expect(unpushed.base?.name == "trunk")
        #expect(unpushed.commitsNotOnBase == 2)
        #expect(unpushed.unpushedCommits == 2)

        try await repo.git(["push", "-q", "-u", "origin", "feat/x"])
        let pushed = try await read(repo.url)
        #expect(pushed.unpushedCommits == 0)
        // Pushed is not merged: the pull request would still carry them.
        #expect(pushed.commitsNotOnBase == 2)

        // Past its upstream, counted against the upstream.
        try repo.write("c.txt", to: "c.txt")
        try await repo.commit("c.txt", paths: ["c.txt"])
        #expect(try await read(repo.url).unpushedCommits == 1)

        // A deleted upstream leaves the count unknown even while local
        // commits are still outside the base.
        try await repo.git(["push", "-q", "origin", "--delete", "feat/x"])
        try await repo.git(["fetch", "-q", "--prune", "origin"])
        let gone = try await read(repo.url)
        #expect(gone.unpushedCommits == nil)
        #expect(gone.commitsNotOnBase == 3)
    }

    @Test func aBranchTrackingTheDefaultBranch_isPushedOnceARemoteHasItsCommits() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let remote = try await TempGitRepo.make()
        defer { remote.cleanup() }
        try await repo.git(["remote", "add", "origin", remote.url.path])
        try await repo.git(["fetch", "-q", "origin"])
        // Made from origin/main, the branch tracks origin/main, as an
        // agent's worktree often does.
        try await repo.git(["switch", "-q", "--track", "-c", "feat/x", "origin/main"])
        try repo.write("a.txt", to: "a.txt")
        try await repo.commit("a.txt", paths: ["a.txt"])
        #expect(try await read(repo.url).unpushedCommits == 1)

        // Pushed without -u: still ahead of its upstream, but on a remote.
        try await repo.git(["push", "-q", "origin", "feat/x"])
        let upstream = try await repo.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        #expect(upstream == "origin/main")
        let facts = try await read(repo.url)
        #expect(facts.commitsNotOnBase == 1)
        #expect(facts.unpushedCommits == 0)
    }

    @Test(arguments: [false, true])
    func aFolderThatIsNoWorkTree_hasNoFacts(isBare: Bool) async throws {
        try await withTempDir { folder in
            if isBare {
                try await TempGitRepo.git(["-c", "init.templateDir=", "init", "--bare", "-q"], in: folder)
            }
            #expect(await ReviewGit.facts(at: folder) == .notWorkTree)
        }
    }

    @Test func aRepositoryWithUnreadableConfiguration_hasUnansweredFacts() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        _ = try await read(repo.url)
        let config = repo.url.appendingPathComponent(".git/config")
        let original = try Data(contentsOf: config)
        try Data("[broken\n".utf8).write(to: config)
        #expect(await ReviewGit.facts(at: repo.url) == .unanswered)
        try original.write(to: config)
        _ = try await read(repo.url)
    }

    /// The facts at `folder`, which a real repository must give.
    private func read(_ folder: URL) async throws -> GitFacts {
        guard case let .facts(facts) = await ReviewGit.facts(at: folder) else {
            throw NoFacts(folder: folder)
        }
        return facts
    }
}

private struct NoFacts: Error {
    let folder: URL
}
