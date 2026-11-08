// PRStatusFetcherTests.swift
// Weir — one repository's rows read with one forge query, each row's head branch read as gh reads it.
//
// The repositories are real (`TempGitRepo`), so the branch, the remotes,
// and `@{push}` come from Git itself. The forge's CLI is a stand-in that
// records what it was asked and answers what the test scripted: no
// network, no credentials, and no `gh` needed on the machine.

import Foundation
import os
import Testing
@testable import Weir

/// The forge's CLI for a suite: records each run's arguments and answers
/// the scripted output, running `beforeAnswer` first.
private final class ScriptedForgeCLI: Sendable {
    private struct State {
        var calls: [[String]] = []
        var outputs: [ToolResult] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let beforeAnswer: @Sendable () async -> Void

    init(beforeAnswer: @escaping @Sendable () async -> Void = {}) {
        self.beforeAnswer = beforeAnswer
    }

    var calls: [[String]] {
        state.withLock { $0.calls }
    }

    /// Queues `output` for the next run; a run with none queued answers
    /// the last one again.
    func script(_ output: ToolResult) {
        state.withLock { $0.outputs.append(output) }
    }

    func run(_ arguments: [String]) async -> ToolResult? {
        await beforeAnswer()
        return state.withLock { state in
            state.calls.append(arguments)
            return state.outputs.count > 1 ? state.outputs.removeFirst() : state.outputs.first
        }
    }
}

/// Counts the Git commands a lookup runs, and runs them.
private final class CountedGit: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var runs: Int {
        count.withLock { $0 }
    }

    func run(_ arguments: [String], in directory: URL) async -> ToolResult? {
        count.withLock { $0 += 1 }
        return await PRStatusFetcher.liveGit(arguments, directory)
    }
}

@Suite("PRStatusFetcher", .timeLimit(.minutes(1)))
struct PRStatusFetcherTests {
    private let clock = ManualPRStatusClock()

    /// `remotes` reads the checkout's remotes for its forge; by default
    /// through `git`, as the app does.
    private func makeFetcher(
        _ cli: ScriptedForgeCLI,
        git: CountedGit = CountedGit(),
        remotes: PRStatusFetcher.GitRun? = nil
    ) -> PRStatusFetcher {
        let locator = ToolLocator(known: ["gh": URL(fileURLWithPath: "/usr/bin/false"), "glab": URL(fileURLWithPath: "/usr/bin/false")])
        let now: @Sendable () -> Date = { [clock] in clock.now() }
        let run: PRStatusFetcher.GitRun = { await git.run($0, in: $1) }
        return PRStatusFetcher(
            resolver: ForgeResolver(locator: locator, git: remotes ?? run),
            locator: locator,
            limiter: ForgeRateLimiter(now: now, monotonicNow: { [clock] in clock.monotonicNow() }, jitter: { 1 }),
            now: now,
            git: run,
            forgeCLI: { _, arguments, _, _ in await cli.run(arguments) }
        )
    }

    /// A repository on `main` with `origin` on GitHub, and two linked
    /// worktrees on `a` and `b`, as rows of one project.
    private func repository() async throws -> (TempGitRepo, [PRStatusRow]) {
        let repo = try await TempGitRepo.make()
        try await repo.git(["remote", "add", "origin", "git@github.com:acme/app.git"])
        let first = try await repo.addLinkedWorktree(branch: "a")
        let second = try await repo.addLinkedWorktree(branch: "b")
        let project = UUID()
        let rows = [
            PRStatusRow(container: .project(project), workingDirectory: repo.url),
            PRStatusRow(container: .worktree(projectID: project, worktreeID: UUID()), workingDirectory: first),
            PRStatusRow(container: .worktree(projectID: project, worktreeID: UUID()), workingDirectory: second)
        ]
        return (repo, rows)
    }

    private static func ok(_ body: String, headers: String = "") -> ToolResult {
        ToolResult(exitCode: 0, stdout: "HTTP/2.0 200 OK\n\(headers)\n" + body, stderr: "")
    }

    private static func request(_ number: Int, owner: String, state: String = "OPEN") -> String {
        #"""
        {"number":\#(number),"state":"\#(state)","isDraft":false,"title":"t","url":"https://github.com/acme/app/pull/\#(number)",\#
        "headRepositoryOwner":{"login":"\#(owner)"},"commits":{"nodes":[]}}
        """#
    }

    /// A GitHub answer with alias `bN` holding `aliases[N]`'s requests, and
    /// more not read where `hasNextPage` says so.
    private static func body(_ aliases: [String], hasNextPage: [Bool] = []) -> String {
        let fields = aliases.enumerated().map { index, nodes in
            let hasMore = index < hasNextPage.count && hasNextPage[index]
            return #""b\#(index)":{"pageInfo":{"hasNextPage":\#(hasMore)},"nodes":[\#(nodes)]}"#
        }
        let rateLimit = #"{"cost":1,"limit":5000,"remaining":4999,"resetAt":"2027-01-01T00:00:00Z"}"#
        return #"{"data":{"rateLimit":\#(rateLimit),"repository":{\#(fields.joined(separator: ","))}}}"#
    }

    private static func hasArgument(_ value: String, for flag: String, in arguments: [String]) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == flag && $1 == value }
    }

    private static func expectedHeads(_ rows: [PRStatusRow], isAnswered: Bool = true) -> [ContainerID: PRStatusFetcher.Lookup] {
        Dictionary(uniqueKeysWithValues: zip(rows, ["main", "a", "b"]).map { row, branch in
            (row.container, PRStatusFetcher.Lookup(forge: .gitHub, isAnswered: isAnswered, head: .branch(branch)))
        })
    }

    @Test("a repository's rows cost one query and three Git reads of its own, with each row's head asked for by its owner")
    func rows_costOneQuery() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        // `a` is pushed to a fork, so only the fork owner's request is its.
        try await repo.git(["remote", "add", "fork", "git@github.com:me/app.git"])
        try await repo.git(["config", "branch.a.pushRemote", "fork"])
        let cli = ScriptedForgeCLI()
        cli.script(Self.ok(Self.body([
            "",
            Self.request(9, owner: "acme") + "," + Self.request(5, owner: "me"),
            Self.request(6, owner: "acme", state: "MERGED")
        ])))
        let git = CountedGit()
        let batch = await makeFetcher(cli, git: git).lookup(rows)

        #expect(cli.calls.count == 1)
        let arguments = try #require(cli.calls.first)
        #expect(Self.hasArgument("github.com", for: "--hostname", in: arguments))
        for field in ["owner=acme", "repo=app", "b0=main", "b1=a", "b2=b"] {
            #expect(Self.hasArgument(field, for: "-f", in: arguments))
        }
        // A `git symbolic-ref` per row before the query and after it, and
        // for the repository one `git config` for its forge, which is kept
        // for the next lookup, then one for its branches and one
        // `git for-each-ref`.
        #expect(git.runs == rows.count * 2 + 3)
        #expect(batch.lookups[rows[0].container] == PRStatusFetcher.Lookup(forge: .gitHub, head: .branch("main")))
        #expect(batch.lookups[rows[1].container]?.info?.number == 5)
        #expect(batch.lookups[rows[1].container]?.head == .branch("a"))
        #expect(batch.lookups[rows[2].container]?.info?.number == 6)
        #expect(batch.lookups[rows[2].container]?.info?.state == .merged)
        #expect(batch.lookups[rows[2].container]?.head == .branch("b"))
        #expect(Set(batch.lookups.keys) == Set(rows.map(\.container)))
        #expect(batch.isQuotaLow == false)
    }

    @Test("a rate limit suppresses requests to the host until the reset")
    func rateLimit_holdsTheHostUntilTheReset() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        let cli = ScriptedForgeCLI()
        cli.script(ToolResult(exitCode: 1, stdout: "HTTP/1.1 429 Too Many Requests\nRetry-After: 120\n\n{}", stderr: ""))
        cli.script(Self.ok(Self.body(["", "", ""])))
        let fetcher = makeFetcher(cli)

        let unanswered = Self.expectedHeads(rows, isAnswered: false)
        let answered = Self.expectedHeads(rows)
        #expect(await fetcher.lookup(rows).lookups == unanswered)
        #expect(await fetcher.lookup(rows).lookups == unanswered)
        #expect(cli.calls.count == 1)

        clock.advance(by: 119)
        #expect(await fetcher.lookup(rows).lookups == unanswered)
        #expect(cli.calls.count == 1)

        clock.advance(by: 1)
        #expect(await fetcher.lookup(rows).lookups == answered)
        #expect(cli.calls.count == 2)
        #expect(await fetcher.lookup(rows).lookups == answered)
        #expect(cli.calls.count == 3)
    }

    @Test("a checkout whose remotes could not be read gets no answer, and the forge is not asked")
    func unreadRemotes_areNoAnswer() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        let cli = ScriptedForgeCLI()
        cli.script(Self.ok(Self.body(["", "", ""])))
        // `git config` that did not run, or ran past its limit.
        let batch = await makeFetcher(cli, remotes: { _, _ in nil }).lookup(rows)
        #expect(cli.calls.isEmpty)
        let expected = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.container, PRStatusFetcher.Lookup(isAnswered: false))
        })
        #expect(batch.lookups == expected)
    }

    @Test("a checkout with no remote is answered with no forge, and the forge is not asked")
    func noRemote_isAnsweredWithNoForge() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        try await repo.git(["remote", "remove", "origin"])
        let cli = ScriptedForgeCLI()
        let batch = await makeFetcher(cli).lookup(rows)
        #expect(cli.calls.isEmpty)
        let expected = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.container, PRStatusFetcher.Lookup())
        })
        #expect(batch.lookups == expected)
    }

    @Test("a checkout that switches branch during the query gets no answer")
    func branchSwitchDuringTheQuery_isNoAnswer() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        let moved = rows[1].workingDirectory
        let checkout = Recorded<String?>(nil)
        let cli = ScriptedForgeCLI {
            do {
                try await TempGitRepo.git(["checkout", "-q", "-b", "elsewhere"], in: moved)
                let head = try await TempGitRepo.git(["symbolic-ref", "--short", "HEAD"], in: moved)
                checkout.update { $0 = head }
            } catch {
                Issue.record("could not switch the checkout during the forge query: \(error)")
            }
        }
        cli.script(Self.ok(Self.body(["", Self.request(5, owner: "acme"), ""])))
        let batch = await makeFetcher(cli).lookup(rows)
        #expect(checkout.value == "elsewhere")
        var expected = Self.expectedHeads(rows)
        expected[rows[1].container] = PRStatusFetcher.Lookup(forge: .gitHub, isAnswered: false)
        #expect(batch.lookups == expected)
    }

    @Test("the repository `gh repo set-default` chose is the one asked, not a fork cloned as origin")
    func setDefault_namesTheRepositoryAsked() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        try await repo.git(["remote", "set-url", "origin", "git@github.com:me/app-fork.git"])
        try await repo.git(["remote", "add", "parent", "git@github.com:acme/app-parent.git"])
        try await repo.git(["config", "remote.parent.gh-resolved", "base"])
        let cli = ScriptedForgeCLI()
        cli.script(Self.ok(Self.body(["", "", ""])))
        _ = await makeFetcher(cli).lookup(rows)
        #expect(cli.calls.count == 1)
        let arguments = try #require(cli.calls.first)
        #expect(Self.hasArgument("github.com", for: "--hostname", in: arguments))
        #expect(Self.hasArgument("owner=acme", for: "-f", in: arguments))
        #expect(Self.hasArgument("repo=app-parent", for: "-f", in: arguments))
    }

    @Test("a branch its first five requests do not settle is asked again, alone, for 30")
    func unsettledBranch_isAskedAgainForThirty() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        let cli = ScriptedForgeCLI()
        // Five newer requests from forks, and more not read.
        let forks = (1...5).map { Self.request($0, owner: "fork\($0)") }.joined(separator: ",")
        cli.script(Self.ok(Self.body(["", forks, ""], hasNextPage: [false, true, false])))
        cli.script(Self.ok(Self.body([Self.request(42, owner: "acme")])))
        let batch = await makeFetcher(cli).lookup(rows)
        #expect(cli.calls.count == 2)
        let again = try #require(cli.calls.last)
        // Only `a`, which the first five did not settle, is asked again.
        let branchVariables = again.filter { $0.range(of: #"^b[0-9]+="#, options: .regularExpression) != nil }
        #expect(branchVariables == ["b0=a"])
        #expect(Self.hasArgument("b0=a", for: "-f", in: again))
        #expect(again.contains { $0.contains("first: 30") })
        let retried = try #require(batch.lookups[rows[1].container])
        #expect(retried.info?.number == 42)
        #expect(retried.head == .branch("a"))
        #expect(retried.isAnswered)
        #expect(batch.lookups[rows[0].container] == PRStatusFetcher.Lookup(forge: .gitHub, head: .branch("main")))
        #expect(batch.lookups[rows[2].container] == PRStatusFetcher.Lookup(forge: .gitHub, head: .branch("b")))
    }

    @Test("GitLab's pages are read on, so a branch's request past another branch's hundred is found")
    func gitLab_readsEveryPage() async throws {
        let (repo, rows) = try await repository()
        defer { repo.cleanup() }
        try await repo.git(["remote", "set-url", "origin", "git@gitlab.com:acme/app.git"])
        let cli = ScriptedForgeCLI()
        let busy = (1...100).map { number in
            #"{"iid":"\#(number)","state":"merged","draft":false,"title":"t","webUrl":"https://gitlab.com/m/\#(number)","sourceBranch":"a"}"#
        }
        let quiet = #"{"iid":"500","state":"opened","draft":false,"title":"t","webUrl":"https://gitlab.com/m/500","sourceBranch":"b"}"#
        cli.script(Self.ok(Self.gitLabPage(busy, nextCursor: "c1")))
        cli.script(Self.ok(Self.gitLabPage([quiet], nextCursor: nil)))
        let batch = await makeFetcher(cli).lookup(rows)
        #expect(cli.calls.count == 2)
        #expect(cli.calls.last?.contains { $0.contains(#"after: "c1""#) } == true)
        #expect(batch.lookups[rows[2].container]?.info?.number == 500)
        #expect(batch.lookups[rows[1].container]?.info?.number == 1)
        #expect(batch.lookups[rows[0].container] == PRStatusFetcher.Lookup(forge: .gitLab, head: .branch("main")))
    }

    private static func gitLabPage(_ requests: [String], nextCursor: String?) -> String {
        let pageInfo = nextCursor.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false}"#
        return #"{"data":{"project":{"mergeRequests":{"pageInfo":\#(pageInfo),"nodes":[\#(requests.joined(separator: ","))]}}}}"#
    }

    @Test("gh's set-default picks the base repository in remote order", arguments: [
        ("remote.origin.gh-resolved base", "acme/app"),
        ("remote.origin.gh-resolved parent/app", "parent/app"),
        ("remote.fork.gh-resolved base", "me/app"),
        ("", "acme/app"),
        ("remote.fork.gh-resolved base\nremote.origin.gh-resolved base", "acme/app")
    ])
    func baseRepository_followsGh(config: String, expected: String) {
        let remotes = "remote.origin.url git@github.com:acme/app.git\nremote.fork.url https://github.com/me/app.git\n"
        let parsed = PRStatusRepository.parse(config: remotes + config, pushes: "", branches: [])
        #expect(parsed.baseRepository(forge: .gitHub) == PRStatusRepository.BaseRepository(host: "github.com", path: expected))
    }

    @Test func gitLabIgnoresGitHubDefaultRepositoryMarkers() {
        let config = """
        remote.origin.url git@gitlab.com:group/sub/app.git
        remote.fork.url git@gitlab.com:me/app.git
        remote.fork.gh-resolved base
        remote.origin.gh-resolved other/app
        """
        let parsed = PRStatusRepository.parse(config: config, pushes: "", branches: [])
        #expect(parsed.baseRepository(forge: .gitLab) == PRStatusRepository.BaseRepository(host: "gitlab.com", path: "group/sub/app"))
    }

    // MARK: - Head branches

    @Test("@{push} from Git names the head branch")
    func push_readFromGit() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try await repo.git(["remote", "add", "origin", "git@github.com:acme/app.git"])
        try await repo.git(["config", "branch.main.remote", "origin"])
        try await repo.git(["config", "branch.main.merge", "refs/heads/main"])
        let config = try await repo.git(PRStatusRepository.configArguments)
        let pushes = try await repo.git(PRStatusRepository.pushArguments(branches: ["main"]))
        let parsed = PRStatusRepository.parse(config: config, pushes: pushes, branches: ["main"])
        #expect(parsed.pushes["main"] == PRStatusRepository.Push(remote: "origin", trackingRef: "refs/remotes/origin/main"))
        #expect(parsed.remotes["origin"] == "git@github.com:acme/app.git")
        #expect(parsed.selector(for: "main", baseOwner: "acme") == .branch(name: "main", owner: "acme"))
    }

    @Test("the head branch follows gh's rules", arguments: [
        // `@{push}` to a fork's branch of another name.
        ("", "refs/heads/x\tfork\trefs/remotes/fork/feature", PRHeadSelector.branch(name: "feature", owner: "me")),
        // What `gh pr checkout` sets up for a fork it has no remote for.
        ("branch.x.remote origin\nbranch.x.merge refs/pull/42/head", "", .number(42)),
        // `push.default upstream` pushes to the upstream's branch.
        ("push.default upstream\nbranch.x.remote origin\nbranch.x.merge refs/heads/y", "", .branch(name: "y", owner: "acme")),
        // Otherwise the local name, on the push remote, which may be a URL.
        ("branch.x.merge refs/heads/y\nbranch.x.pushremote git@github.com:me/app.git", "", .branch(name: "x", owner: "me")),
        ("remote.pushdefault fork", "", .branch(name: "x", owner: "me")),
        ("", "", .branch(name: "x", owner: "acme")),
        ("branch.x.pushremote fork\nremote.pushdefault origin\nbranch.x.remote parent", "", .branch(name: "x", owner: "me")),
        ("remote.pushdefault fork\nbranch.x.remote parent", "", .branch(name: "x", owner: "me")),
        ("branch.x.pushremote origin", "refs/heads/x\tfork\trefs/remotes/fork/feature", .branch(name: "feature", owner: "me"))
    ])
    func selector_followsGhsRules(config: String, pushes: String, expected: PRHeadSelector) {
        let remotes = "remote.origin.url git@github.com:acme/app.git\nremote.fork.url https://github.com/me/app.git\nremote.parent.url git@github.com:parent/app.git\n"
        let parsed = PRStatusRepository.parse(config: remotes + config, pushes: pushes, branches: ["x"])
        #expect(parsed.selector(for: "x", baseOwner: "acme") == expected)
    }

    @Test func gitLabAsksForTheLocalBranchOfAGitHubPullRequestRef() {
        let parsed = PRStatusRepository.parse(config: "branch.x.merge refs/pull/42/head", pushes: "", branches: ["x"])
        #expect(parsed.selector(for: "x", baseOwner: "acme", forge: .gitHub) == .number(42))
        #expect(parsed.selector(for: "x", baseOwner: "acme", forge: .gitLab) == .branch(name: "x", owner: nil))
    }

}
