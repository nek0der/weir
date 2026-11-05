// ReviewBaseRefTests.swift
// Weir — the review's base read as a branch where a tag shares its name, and a submodule counted the same by every comparison.

import Foundation
import Testing
@testable import Weir

@Suite(.tags(.smoke), .timeLimit(.minutes(1)))
struct ReviewBaseRefTests {
    /// A tag `main` left on the first commit, and `main` one commit past it
    /// with `landed.txt`: a bare `main` is the tag's commit to Git, and the
    /// branch view then listed `landed.txt` as the branch's own work.
    @Test func aTagNamedLikeTheBase_isNotWhatTheBranchIsComparedAgainst() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.git(["tag", "main"])
        try repo.write("landed\n", to: "landed.txt")
        try await repo.commit("landed", paths: ["landed.txt"])
        try await repo.git(["switch", "-q", "-c", "feat/x"])
        try repo.write("work\n", to: "work.txt")
        try await repo.commit("work", paths: ["work.txt"])
        let root = try await ReviewGit.root(at: repo.url)

        #expect(try await ReviewGit.defaultBase(at: root) == "main")
        #expect(try await ReviewGit.branchRef(named: "main", root: root) == "refs/heads/main")
        #expect(try await ReviewGit.mergeBase("main", root: root) == repo.git(["rev-parse", "refs/heads/main"]))
        let scope = ReviewScope.branch(base: "main")
        let files = try await ReviewGit.files(at: root, scope: scope)
        #expect(files.filter { $0.layer == .branch }.map(\.path) == ["work.txt"])
        #expect(try await ReviewGit.stats(at: root, scope: scope).keys.sorted() == ["branch:work.txt"])

        guard case let .facts(facts) = await ReviewGit.facts(at: root) else {
            Issue.record("a repository gave no facts")
            return
        }
        #expect(facts.base == GitFacts.Base(ref: "main"))
        #expect(facts.commitsNotOnBase == 1)
    }

    /// origin's default named as the branch it is, where a tag of the same
    /// name would make Git's short form `remotes/origin/main`, and counted
    /// against that branch rather than the tag.
    @Test func aTagNamedLikeOriginsDefault_leavesTheRemoteBranchTheBase() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.addBareOrigin()
        try await repo.git(["remote", "set-head", "origin", "main"])
        try await repo.git(["tag", "origin/main"])
        try repo.write("landed\n", to: "landed.txt")
        try await repo.commit("landed", paths: ["landed.txt"])
        try await repo.git(["push", "-q", "origin", "main"])
        try await repo.git(["switch", "-q", "-c", "feat/x"])
        try repo.write("work\n", to: "work.txt")
        try await repo.commit("work", paths: ["work.txt"])
        let root = try await ReviewGit.root(at: repo.url)

        #expect(try await ReviewGit.defaultBase(at: root) == "origin/main")
        #expect(try await ReviewGit.branchRef(named: "origin/main", root: root) == "refs/remotes/origin/main")
        // The name earlier builds gave it, which a comment's scope keeps.
        #expect(try await ReviewGit.branchRef(named: "remotes/origin/main", root: root) == "refs/remotes/origin/main")
        let files = try await ReviewGit.files(at: root, scope: .branch(base: "origin/main"))
        #expect(files.filter { $0.layer == .branch }.map(\.path) == ["work.txt"])
        guard case let .facts(facts) = await ReviewGit.facts(at: root) else {
            Issue.record("a repository gave no facts")
            return
        }
        #expect(facts.base?.name == "main")
        #expect(facts.commitsNotOnBase == 1)
    }

    /// A local branch before the remote's of the same name, as Git reads a
    /// bare name; a tag alone is no branch, and no base is offered for it.
    @Test func branchRef_takesTheLocalBranchFirst_andNoTag() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.addBareOrigin()
        try await repo.git(["branch", "origin/main"])
        #expect(try await ReviewGit.branchRef(named: "origin/main", root: repo.url) == "refs/heads/origin/main")
        #expect(try await ReviewGit.branchRef(named: "feat", root: repo.url) == nil)

        // A branch below the name (`main/x`) is not the name.
        try await repo.git(["switch", "-q", "-c", "trunk"])
        try await repo.git(["branch", "-q", "-D", "origin/main"])
        try await repo.git(["remote", "remove", "origin"])
        try await repo.git(["branch", "-q", "-D", "main"])
        try await repo.git(["tag", "main"])
        try await repo.git(["branch", "master/x"])
        #expect(try await ReviewGit.branchRef(named: "main", root: repo.url) == nil)
        #expect(try await ReviewGit.branchRef(named: "master", root: repo.url) == nil)
        #expect(try await ReviewGit.defaultBase(at: repo.url) == nil)
    }

    /// A submodule whose `.gitmodules` says `ignore = all`, moved to another
    /// commit on the branch and again in the worktree: Git's own diff
    /// leaves it out, and the list, the line counts, the totals, and the
    /// paths changed each count it.
    @Test func aSubmoduleIgnoredByItsSetting_isCountedByEveryComparison() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let module = repo.url.appendingPathComponent("module", isDirectory: true)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try await TempGitRepo.initialize(module)
        try await TempGitRepo.git(["commit", "-q", "--allow-empty", "-m", "m1"], in: module)
        try repo.write("[submodule \"module\"]\n\tpath = module\n\turl = ./module\n\tignore = all\n", to: ".gitmodules")
        try await repo.git(["add", "-f", ".gitmodules", "module"])
        try await repo.git(["commit", "-q", "-m", "add module"])
        let before = try await repo.git(["rev-parse", "HEAD^{tree}"])
        try await repo.git(["switch", "-q", "-c", "feat/x"])
        try await TempGitRepo.git(["commit", "-q", "--allow-empty", "-m", "m2"], in: module)
        try await repo.git(["add", "-f", "module"])
        try await repo.git(["commit", "-q", "-m", "move module"])
        let after = try await repo.git(["rev-parse", "HEAD^{tree}"])
        let root = try await ReviewGit.root(at: repo.url)

        let moved = ReviewFileStat(added: 1, removed: 1)
        let branch = ReviewScope.branch(base: "main")
        #expect(try await ReviewGit.files(at: root, scope: branch).map(\.id) == ["branch:module"])
        #expect(try await ReviewGit.stats(at: root, scope: branch) == ["branch:module": moved])
        #expect(try await ReviewGit.counts(from: before, to: after, root: root) == .changed(files: 1, added: 1, removed: 1))
        #expect(try await ReviewGit.pathsChanged(from: before, to: after, at: root) == ["module"])

        try await TempGitRepo.git(["commit", "-q", "--allow-empty", "-m", "m3"], in: module)
        #expect(try await ReviewGit.files(at: root).map(\.id) == ["unstaged:module"])
        #expect(try await ReviewGit.stats(at: root) == ["unstaged:module": moved])
        #expect(try await ReviewGit.pathsChanged(since: after, at: root).paths == ["module"])
    }
}
