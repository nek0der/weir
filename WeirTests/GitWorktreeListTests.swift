// GitWorktreeListTests.swift
// Weir — parser tests for `git worktree list --porcelain -z` plus a smoke run against a fresh temp repo.

import Foundation
import Testing
@testable import Weir

@Suite("GitWorktreeList parser")
struct GitWorktreeListParserTests {
    /// The listing as `-z` writes it: the fixtures are written one line
    /// per line for reading, and Git ends each with NUL instead.
    private static func nulTerminated(_ lines: String) -> String {
        lines.replacingOccurrences(of: "\n", with: "\0")
    }

    private static func entry(
        _ path: String, head: String? = nil, branch: String? = nil,
        isDetached: Bool = false, isBare: Bool = false, isLocked: Bool = false, isPrunable: Bool = false
    ) -> GitWorktreeInfo {
        GitWorktreeInfo(
            path: URL(fileURLWithPath: path), headSHA: head, branch: branch,
            isDetached: isDetached, isBare: isBare, isLocked: isLocked, isPrunable: isPrunable
        )
    }

    /// A newline is a byte a folder's name may hold. Only NUL ends a field.
    @Test func parse_aPathWithANewline_keepsItWhole() {
        let porcelain = "worktree /Users/me/repo\nfeat\0HEAD aaa\0branch refs/heads/feat\0locked two\nlines\0\0"
            + "worktree /Users/me/repo\0HEAD bbb\0detached\0\0"
        #expect(GitWorktreeList.parse(porcelain) == [
            Self.entry("/Users/me/repo\nfeat", head: "aaa", branch: "feat", isLocked: true),
            Self.entry("/Users/me/repo", head: "bbb", isDetached: true)
        ])
    }

    @Test("porcelain records retain checkout order, paths, heads and branch state", arguments: [false, true])
    func parse_multipleWorktrees_separatesBranchAndDetached(hasLinkedWorktrees: Bool) {
        let primary = """
        worktree /Users/me/repo
        HEAD abc123abc123abc123abc123abc123abc123abc1
        branch refs/heads/main


        """
        let linked = """
        worktree /Users/me/repo-feat
        HEAD bbb
        branch refs/heads/feat-x

        worktree /Users/me/repo-detached
        HEAD ccc
        detached

        """
        var expected = [Self.entry("/Users/me/repo", head: "abc123abc123abc123abc123abc123abc123abc1", branch: "main")]
        if hasLinkedWorktrees {
            expected += [
                Self.entry("/Users/me/repo-feat", head: "bbb", branch: "feat-x"),
                Self.entry("/Users/me/repo-detached", head: "ccc", isDetached: true)
            ]
        }
        let porcelain = Self.nulTerminated(primary + (hasLinkedWorktrees ? linked : ""))
        #expect(GitWorktreeList.parse(porcelain) == expected)
    }

    @Test("locked and prunable flags stay with their own worktree")
    func parse_lockedAndPrunableFlags_areSurfaced() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD aaa
        branch refs/heads/main
        locked being repaired

        worktree /Users/me/repo-stale
        HEAD bbb
        branch refs/heads/old
        prunable gitdir points to missing location

        worktree /Users/me/repo-other
        HEAD ccc
        branch refs/heads/other

        """
        #expect(GitWorktreeList.parse(Self.nulTerminated(porcelain)) == [
            Self.entry("/Users/me/repo", head: "aaa", branch: "main", isLocked: true),
            Self.entry("/Users/me/repo-stale", head: "bbb", branch: "old", isPrunable: true),
            Self.entry("/Users/me/repo-other", head: "ccc", branch: "other")
        ])
    }

    @Test("a bare repo entry is recognized and has no branch or HEAD")
    func parse_bareRepo_setsBareAndOmitsHeadAndBranch() {
        let porcelain = """
        worktree /Users/me/bare.git
        bare

        """
        #expect(GitWorktreeList.parse(Self.nulTerminated(porcelain)) == [Self.entry("/Users/me/bare.git", isBare: true)])
    }

    @Test("unknown future fields are ignored without aborting the parse")
    func parse_unknownLine_isIgnored() {
        let porcelain = """
        worktree /tmp/repo
        HEAD aaa
        somefuturefield value
        branch refs/heads/main

        """
        #expect(GitWorktreeList.parse(Self.nulTerminated(porcelain)) == [Self.entry("/tmp/repo", head: "aaa", branch: "main")])
    }

    /// Smoke test against a freshly-initialized git repo.
    @Test(.tags(.smoke))
    func fetch_freshTempRepo_listsTheInitialWorktree() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let worktrees = try await GitWorktreeList.fetch(repoRoot: repo.url)
        let head = try await repo.git(["rev-parse", "HEAD"])
        // Git prints the real path: `/private/var`, where the temporary
        // directory is spelled `/var`. Foundation's symlink resolving drops
        // that `/private`, so the top comes from Git too.
        let top = try await repo.git(["rev-parse", "--show-toplevel"])
        #expect(worktrees == [GitWorktreeInfo(
            path: URL(fileURLWithPath: top),
            headSHA: head,
            branch: "main",
            isDetached: false,
            isBare: false,
            isLocked: false,
            isPrunable: false
        )])
    }
}

/// What a listing says when git does not answer with one.
@Suite("GitWorktreeList fetch", .tags(.smoke))
struct GitWorktreeListFetchTests {
    /// A folder in no repository has no worktrees: that is an answer.
    @Test
    func fetch_outsideARepository_isEmpty() async throws {
        try await withTempDir { directory in
            let worktrees = try await GitWorktreeList.fetch(repoRoot: directory)
            #expect(worktrees.isEmpty)
        }
    }

    /// A repository git refuses is not one with no worktrees: read as
    /// that, every row of it was marked missing.
    @Test
    func fetch_ofARepositoryGitRefuses_throws() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let listed = try await GitWorktreeList.fetch(repoRoot: repo.url)
        try #require(listed.map(\.branch) == ["main"])
        let config = repo.url.appendingPathComponent(".git/config")
        let original = try Data(contentsOf: config)
        try (original + Data("this is no config line\n".utf8)).write(to: config, options: .atomic)

        let error = await #expect(throws: GitProcessError.self) {
            try await GitWorktreeList.fetch(repoRoot: repo.url)
        }
        guard case let .nonZeroExit(result)? = error else {
            Issue.record("Expected git to reject the repository configuration")
            return
        }
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("bad config line"))
        #expect(result.stderr.contains(".git/config"))
    }

    /// A worktree whose folder was deleted outside git stays listed,
    /// marked prunable, until `git worktree prune`.
    @Test
    func fetch_afterAWorktreeFolderIsDeleted_marksItPrunable() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let linked = try await repo.addLinkedWorktree(branch: "gone")
        try FileManager.default.removeItem(at: linked)
        let worktrees = try await GitWorktreeList.fetch(repoRoot: repo.url)
        #expect(worktrees.map(\.branch) == ["main", "gone"])
        #expect(worktrees.last?.path.lastPathComponent == linked.lastPathComponent)
        #expect(worktrees.map(\.isPrunable) == [false, true])
    }

    /// A linked worktree in a folder whose name holds a newline is listed
    /// at that folder, not at the part of its path before the newline.
    @Test
    func fetch_aWorktreeWhosePathHasANewline_listsItsWholePath() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let linked = repo.scratch.appendingPathComponent("feat\nline")
        _ = try await repo.git(["worktree", "add", "-q", "-b", "feat", "--", linked.path])
        let worktrees = try await GitWorktreeList.fetch(repoRoot: repo.url)
        #expect(worktrees.count == 2)
        #expect(worktrees.last?.path.lastPathComponent == "feat\nline")
        #expect(worktrees.last?.branch == "feat")
        #expect(worktrees.last?.isPrunable == false)
    }
}
