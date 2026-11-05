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

    /// A newline is a byte a folder's name may hold; only NUL ends a line.
    @Test
    func parse_aPathWithANewline_keepsItWhole() {
        let porcelain = "worktree /Users/me/repo\nfeat\0HEAD aaa\0branch refs/heads/feat\0locked two\nlines\0\0"
            + "worktree /Users/me/repo\0HEAD bbb\0detached\0\0"
        let result = GitWorktreeList.parse(porcelain)
        #expect(result.map(\.path.path) == ["/Users/me/repo\nfeat", "/Users/me/repo"])
        #expect(result[0].branch == "feat")
        #expect(result[0].isLocked)
        #expect(result[1].isDetached)
    }

    @Test("a single worktree on main is parsed with its head + branch")
    func parse_singleWorktreeOnMain_extractsAllFields() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD abc123abc123abc123abc123abc123abc123abc1
        branch refs/heads/main

        """
        let result = GitWorktreeList.parse(Self.nulTerminated(porcelain))
        #expect(result.count == 1)
        #expect(result[0].path.path == "/Users/me/repo")
        #expect(result[0].headSHA == "abc123abc123abc123abc123abc123abc123abc1")
        #expect(result[0].branch == "main")
        #expect(result[0].isDetached == false)
    }

    @Test("multiple worktrees: branch / branch / detached are distinguished")
    func parse_multipleWorktrees_separatesBranchAndDetached() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD aaa
        branch refs/heads/main

        worktree /Users/me/repo-feat
        HEAD bbb
        branch refs/heads/feat-x

        worktree /Users/me/repo-detached
        HEAD ccc
        detached

        """
        let result = GitWorktreeList.parse(Self.nulTerminated(porcelain))
        #expect(result.count == 3)
        #expect(result[0].branch == "main")
        #expect(result[1].branch == "feat-x")
        #expect(result[2].branch == nil)
        #expect(result[2].isDetached)
    }

    @Test("locked / prunable flags are surfaced when git emits them")
    func parse_lockedAndPrunableFlags_areSurfaced() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD aaa
        branch refs/heads/main
        locked some-reason

        worktree /Users/me/repo-stale
        HEAD bbb
        branch refs/heads/old
        prunable

        """
        let result = GitWorktreeList.parse(Self.nulTerminated(porcelain))
        #expect(result.count == 2)
        #expect(result[0].isLocked)
        #expect(result[1].isPrunable)
    }

    @Test("a bare repo entry is recognized and has no branch / HEAD")
    func parse_bareRepo_setsBareAndOmitsHeadAndBranch() {
        let porcelain = """
        worktree /Users/me/bare.git
        bare

        """
        let result = GitWorktreeList.parse(Self.nulTerminated(porcelain))
        #expect(result.count == 1)
        #expect(result[0].isBare)
        #expect(result[0].branch == nil)
        #expect(result[0].headSHA == nil)
    }

    @Test("unknown future fields are ignored without aborting the parse")
    func parse_unknownLine_isIgnored() {
        let porcelain = """
        worktree /tmp/repo
        HEAD aaa
        branch refs/heads/main
        somefuturefield value

        """
        let result = GitWorktreeList.parse(Self.nulTerminated(porcelain))
        #expect(result.count == 1)
        #expect(result[0].branch == "main")
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
        let config = repo.url.appendingPathComponent(".git/config")
        let handle = try FileHandle(forWritingTo: config)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is no config line\n".utf8))
        try handle.close()
        await #expect(throws: GitProcessError.self) {
            try await GitWorktreeList.fetch(repoRoot: repo.url)
        }
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
