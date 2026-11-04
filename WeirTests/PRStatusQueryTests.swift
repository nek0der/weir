// PRStatusQueryTests.swift
// Weir — the batched pull request query: what it asks, and what each row's answer is.
//
// Pure text in, values out: no CLI, no network. The GitHub bodies follow
// what `gh api graphql --include` printed for the query against a real
// repository; the GitLab ones follow GitLab's GraphQL schema.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("PRStatusQuery")
struct PRStatusQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Asking

    @Test("each branch is asked once, and a query carries at most 100 aliases")
    func queries_dedupeAndSplit() {
        var selectors = (0..<250).map { PRHeadSelector.branch(name: "b\($0)", owner: "acme") }
        selectors.append(.branch(name: "b0", owner: "fork"))
        selectors.append(.number(12))
        let queries = PRStatusQuery.queries(for: selectors, forge: .gitHub)
        #expect(queries.map { $0.branches.count + $0.numbers.count } == [100, 100, 51])
        #expect(queries.last?.numbers == [12])
        #expect(queries.flatMap(\.branches).count == 250)
    }

    @Test("GitLab has no lookup by a GitHub request ref, so a number is not asked")
    func queries_gitLab_skipsNumbers() {
        let queries = PRStatusQuery.queries(for: [.number(3), .branch(name: "a", owner: nil)], forge: .gitLab)
        #expect(queries == [PRStatusQuery(forge: .gitLab, branches: ["a"], numbers: [])])
    }

    @Test("the GitHub query names the host and sends each branch as a string variable")
    func gitHubArguments_nameTheHostAndTheBranches() {
        let query = PRStatusQuery(forge: .gitHub, branches: ["main", "123"], numbers: [7])
        let arguments = query.arguments(host: "github.acme.com", repository: "acme/app")
        #expect(Array(arguments.prefix(5)) == ["api", "graphql", "--hostname", "github.acme.com", "--include"])
        for pair in [["-f", "owner=acme"], ["-f", "repo=app"], ["-f", "b0=main"], ["-f", "b1=123"], ["-F", "p0=7"]] {
            #expect(zip(arguments, arguments.dropFirst()).contains { [$0, $1] == pair })
        }
        let text = query.gitHubQuery
        #expect(text.contains("rateLimit { cost limit remaining resetAt }"))
        #expect(text.contains("b1: pullRequests(headRefName: $b1, first: 5, orderBy: {field: CREATED_AT, direction: DESC})"))
        #expect(text.contains("p0: pullRequest(number: $p0)"))
        #expect(text.contains("headRepositoryOwner { login }"))
        #expect(text.contains("contexts(first: 100)"))
        #expect(text.contains("defaultBranchRef { name }"))
    }

    @Test("the GitLab query writes the branches as escaped strings")
    func gitLabQuery_escapesTheBranches() {
        let query = PRStatusQuery(forge: .gitLab, branches: ["feat/a", #"odd"name"#], numbers: [])
        #expect(query.gitLabQuery.contains(#"sourceBranches: ["feat\/a", "odd\"name"]"#))
        let arguments = query.arguments(host: "gitlab.acme.com", repository: "group/sub/app")
        #expect(arguments.contains("fullPath=group/sub/app"))
        #expect(arguments.contains("gitlab.acme.com"))
    }

    // MARK: - GitHub answers

    @Test("an open request is chosen over a newer closed one, and a branch with none is none")
    func gitHub_prefersOpen_andAnswersNone() {
        let query = PRStatusQuery(forge: .gitHub, branches: ["a", "b"], numbers: [])
        let a = PRHeadSelector.branch(name: "a", owner: "acme")
        let b = PRHeadSelector.branch(name: "b", owner: "acme")
        let body = Self.gitHubBody(aliases: [
            "b0": Self.connection([Self.request(number: 9, state: "CLOSED"), Self.request(number: 4, state: "OPEN")]),
            "b1": Self.connection([])
        ])
        let response = query.response(Self.ok(body), for: [a, b], baseOwner: "acme", now: now)
        #expect(Self.number(response.answers[a]) == 4)
        #expect(response.answers[b] == PRStatusFetcher.Answer.none)
    }

    @Test("a branch pushed to a fork matches only that owner's request")
    func gitHub_matchesTheForkOwner() {
        let query = PRStatusQuery(forge: .gitHub, branches: ["main"], numbers: [])
        let own = PRHeadSelector.branch(name: "main", owner: "acme")
        let fork = PRHeadSelector.branch(name: "main", owner: "Someone")
        let body = Self.gitHubBody(aliases: [
            "b0": Self.connection([Self.request(number: 30, owner: "someone"), Self.request(number: 2, state: "MERGED")])
        ])
        let response = query.response(Self.ok(body), for: [own, fork], baseOwner: "acme", now: now)
        #expect(Self.number(response.answers[own]) == 2)
        #expect(Self.number(response.answers[fork]) == 30)
    }

    @Test("a request asked for by number is read from its alias")
    func gitHub_number_isRead() {
        let query = PRStatusQuery(forge: .gitHub, branches: [], numbers: [12])
        let body = Self.gitHubBody(aliases: ["p0": Self.request(number: 12)])
        #expect(Self.number(query.response(Self.ok(body), for: [.number(12)], baseOwner: "acme", now: now).answers[.number(12)]) == 12)
    }

    @Test("a repository the CLI cannot read, a timeout, and unreadable output are no answer")
    func gitHub_failures_areUnanswered() {
        let query = PRStatusQuery(forge: .gitHub, branches: ["a"], numbers: [])
        let selector = PRHeadSelector.branch(name: "a", owner: nil)
        let missing = #"{"data":{"rateLimit":null,"repository":null},"errors":[{"type":"NOT_FOUND"}]}"#
        for result in [Self.failed(missing), nil, Self.ok("{not json")] {
            #expect(query.response(result, for: [selector], baseOwner: "acme", now: now).answers[selector] == .unanswered)
        }
    }

    /// The forge's link opens on a click without asking, so one that is
    /// not a web page (a file, a custom scheme) is not taken as the PR's.
    @Test(arguments: ["file:///Applications/Calculator.app", "x-custom:open", "https:relative"])
    func gitHub_aLinkThatIsNotAWebPage_isRefused(_ link: String) {
        let query = PRStatusQuery(forge: .gitHub, branches: ["a"], numbers: [])
        let selector = PRHeadSelector.branch(name: "a", owner: nil)
        let body = Self.gitHubBody(aliases: ["b0": Self.connection([Self.request(number: 1, url: link)])])
        #expect(query.response(Self.ok(body), for: [selector], baseOwner: "acme", now: now).answers[selector] == .unanswered)
    }

    @Test(
        "checks collapse to one conclusion: a failure outranks running, which outranks passed",
        arguments: [
            ([#"{"status":"COMPLETED","conclusion":"SUCCESS"}"#, #"{"state":"SUCCESS"}"#], PRChecksConclusion.success, 2),
            ([#"{"status":"COMPLETED","conclusion":"SUCCESS"}"#, #"{"status":"IN_PROGRESS","conclusion":null}"#], .pending, 1),
            ([#"{"status":"IN_PROGRESS","conclusion":null}"#, #"{"state":"FAILURE"}"#], .failure, 0),
            ([#"{"status":"COMPLETED","conclusion":"SOMETHING_NEW"}"#], .pending, 0)
        ]
    )
    func gitHub_checks_aggregate(contexts: [String], conclusion: PRChecksConclusion, passed: Int) throws {
        let info = try #require(Self.gitHubInfo(rollup: Self.rollup(state: "PENDING", contexts: contexts)))
        #expect(info.checks?.conclusion == conclusion)
        #expect(info.checks?.counts == PRChecks.Counts(passed: passed, total: contexts.count))
    }

    @Test("no rollup, or one with no checks, is no checks")
    func gitHub_noChecks_isNil() throws {
        #expect(try #require(Self.gitHubInfo(rollup: "null")).checks == nil)
        #expect(try #require(Self.gitHubInfo(rollup: Self.rollup(state: "SUCCESS", contexts: []))).checks == nil)
    }

    @Test("more checks than one page takes the rollup's state, with no counts")
    func gitHub_truncatedChecks_useTheRollupState() throws {
        let rollup = Self.rollup(state: "FAILURE", contexts: [#"{"status":"COMPLETED","conclusion":"SUCCESS"}"#], hasNextPage: true)
        let checks = try #require(Self.gitHubInfo(rollup: rollup)?.checks)
        #expect(checks.conclusion == .failure)
        #expect(checks.counts == nil)
    }

    @Test("state and draft come through")
    func gitHub_stateAndDraft() {
        let body = Self.gitHubBody(aliases: ["b0": Self.connection([Self.request(number: 5, state: "MERGED", isDraft: true)])])
        let selector = PRHeadSelector.branch(name: "a", owner: nil)
        let response = PRStatusQuery(forge: .gitHub, branches: ["a"], numbers: []).response(
            Self.ok(body),
            for: [selector],
            baseOwner: "acme",
            now: now
        )
        guard case let .found(info)? = response.answers[selector] else {
            Issue.record("no request")
            return
        }
        #expect(info.state == .merged)
        #expect(info.isDraft)
        #expect(info.forge == .gitHub)
    }

    // MARK: - Reading as many as gh does

    @Test("no open match among the first five, with more not read, asks the branch again instead of taking a closed one")
    func gitHub_closedAmongTheFirstFive_asksAgain() {
        let query = PRStatusQuery(forge: .gitHub, branches: ["main", "a"], numbers: [])
        let main = PRHeadSelector.branch(name: "main", owner: "acme")
        let feature = PRHeadSelector.branch(name: "a", owner: "acme")
        let body = Self.gitHubBody(aliases: [
            // Five newer requests from other forks push the person's own out.
            "b0": Self.connection((1...5).map { Self.request(number: $0, owner: "fork\($0)") }, hasNextPage: true),
            "b1": Self.connection([Self.request(number: 9, state: "CLOSED")], hasNextPage: true)
        ])
        let response = query.response(Self.ok(body), for: [main, feature], baseOwner: "acme", now: now)
        #expect(response.needsMore == [main, feature])
        #expect(response.answers[main] == .unanswered)
        #expect(response.answers[feature] == .unanswered)
    }

    @Test("asked again for 30, as gh reads, the branch is settled the way gh settles it")
    func gitHub_askedForThirty_settlesAsGhDoes() {
        let selector = PRHeadSelector.branch(name: "a", owner: "acme")
        let again = PRStatusQuery.queries(for: [selector], forge: .gitHub, requestsPerBranch: PRStatusQuery.allRequests)
        guard let query = again.first else {
            Issue.record("no query")
            return
        }
        #expect(query.gitHubQuery.contains("first: 30"))
        let open = Self.gitHubBody(aliases: ["b0": Self.connection(
            [Self.request(number: 9, state: "CLOSED"), Self.request(number: 4)],
            hasNextPage: true
        )])
        #expect(Self.number(query.response(Self.ok(open), for: [selector], baseOwner: "acme", now: now).answers[selector]) == 4)
        // With none open among 30, gh shows the newest; with none of the
        // owner's, it shows none.
        let closed = Self.gitHubBody(aliases: ["b0": Self.connection([Self.request(number: 9, state: "CLOSED")], hasNextPage: true)])
        #expect(Self.number(query.response(Self.ok(closed), for: [selector], baseOwner: "acme", now: now).answers[selector]) == 9)
        let others = Self.gitHubBody(aliases: ["b0": Self.connection([Self.request(number: 1, owner: "other")], hasNextPage: true)])
        let none = query.response(Self.ok(others), for: [selector], baseOwner: "acme", now: now).answers[selector]
        #expect(none == PRStatusFetcher.Answer.none)
    }

    @Test("the repository's own default branch shows an open request only")
    func gitHub_ownDefaultBranch_showsAnOpenRequestOnly() {
        let query = PRStatusQuery(forge: .gitHub, branches: ["main"], numbers: [])
        let own = PRHeadSelector.branch(name: "main", owner: "acme")
        let fork = PRHeadSelector.branch(name: "main", owner: "someone")
        let body = Self.gitHubBody(
            aliases: ["b0": Self.connection([
                Self.request(number: 8, state: "MERGED"),
                Self.request(number: 7, state: "MERGED", owner: "someone")
            ])],
            defaultBranch: "main"
        )
        let response = query.response(Self.ok(body), for: [own, fork], baseOwner: "acme", now: now)
        #expect(response.answers[own] == PRStatusFetcher.Answer.none)
        // A fork's `main` is not the repository's default branch.
        #expect(Self.number(response.answers[fork]) == 7)
    }

    // MARK: - GitLab answers

    @Test("GitLab: the number is the iid, an opened request comes first, and a branch with none is none")
    func gitLab_answers() {
        let a = PRHeadSelector.branch(name: "a", owner: nil)
        let b = PRHeadSelector.branch(name: "b", owner: nil)
        let answers = Self.gitLabAnswers(for: [a, b], pages: [Self.gitLabBody([
            Self.mergeRequest(iid: "9", state: "merged", branch: "a"),
            Self.mergeRequest(iid: "7", state: "opened", branch: "a", draft: true, pipeline: "RUNNING")
        ])])
        guard case let .found(info)? = answers[a] else {
            Issue.record("no request")
            return
        }
        #expect(info.number == 7)
        #expect(info.isDraft)
        #expect(info.checks == PRChecks(conclusion: .pending, counts: nil))
        #expect(info.forge == .gitLab)
        #expect(answers[b] == PRStatusFetcher.Answer.none)
    }

    @Test("GitLab states and pipeline statuses map as the REST ones did", arguments: [
        ("locked", PRState.open, "SUCCESS", PRChecksConclusion.success),
        ("closed", .closed, "FAILED", .failure),
        ("merged", .merged, "CANCELED", .failure)
    ])
    func gitLab_stateAndPipeline(state: String, expected: PRState, pipeline: String, conclusion: PRChecksConclusion) {
        let selector = PRHeadSelector.branch(name: "a", owner: nil)
        let body = Self.gitLabBody([Self.mergeRequest(iid: "3", state: state, branch: "a", pipeline: pipeline)])
        guard case let .found(info)? = Self.gitLabAnswers(for: [selector], pages: [body])[selector] else {
            Issue.record("no request")
            return
        }
        #expect(info.state == expected)
        #expect(info.checks?.conclusion == conclusion)
    }

    @Test("GitLab: a branch's opened request on a later page is found, past another branch's many")
    func gitLab_laterPage_isRead() {
        let busy = PRHeadSelector.branch(name: "busy", owner: nil)
        let quiet = PRHeadSelector.branch(name: "quiet", owner: nil)
        let first = Self.gitLabBody(
            (1...100).map { Self.mergeRequest(iid: "\($0 + 100)", state: "merged", branch: "busy") },
            nextCursor: "c1"
        )
        let second = Self.gitLabBody([Self.mergeRequest(iid: "5", state: "opened", branch: "quiet")])
        // One page alone settles neither: `quiet` may have one on the next.
        let firstOnly = Self.gitLabAnswers(for: [busy, quiet], pages: [first])
        #expect(firstOnly[quiet] == .unanswered)
        #expect(firstOnly[busy] == .unanswered)
        let both = Self.gitLabAnswers(for: [busy, quiet], pages: [first, second])
        #expect(Self.number(both[quiet]) == 5)
        #expect(Self.number(both[busy]) == 101)
        // The next page is asked for after the cursor.
        let query = PRStatusQuery(forge: .gitLab, branches: ["busy", "quiet"], numbers: []).after("c1")
        #expect(query.gitLabQuery.contains(#"first: 100, after: "c1""#))
    }

    @Test("GitLab: a project it cannot read gives no page")
    func gitLab_unreadableProject_givesNoPage() {
        let query = PRStatusQuery(forge: .gitLab, branches: ["a"], numbers: [])
        let selector = PRHeadSelector.branch(name: "a", owner: nil)
        let response = query.response(Self.ok(#"{"data":{"project":null}}"#), for: [selector], baseOwner: nil, now: now)
        #expect(response.gitLabPage == nil)
        #expect(response.answers[selector] == .unanswered)
    }

    // MARK: - Output

    @Test("--include output is split into status, headers, and body")
    func httpOutput_splits() {
        let output = "HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nRetry-After: 60\r\n\r\n{\"message\":\"x\"}"
        let http = HTTPOutput(output)
        #expect(http.status == 403)
        #expect(http.headers["x-ratelimit-remaining"] == "0")
        #expect(http.headers["retry-after"] == "60")
        #expect(http.body == "{\"message\":\"x\"}")
        #expect(HTTPOutput("{}").body == "{}")
        #expect(HTTPOutput("{}").status == nil)
    }

    /// Braces inside a string value must not close the object early —
    /// the scanner has to track string and escape state, not just
    /// count braces.
    ///
    /// The brace sits unbalanced *and* between escaped quotes, which
    /// is what makes the fixture discriminate on both counts. Drop the
    /// escape tracking and the first `\"` reads as a real quote, so
    /// the scanner believes it has left the string and takes the `}`
    /// as the object's end. Drop the string tracking and it never
    /// entered one.
    @Test("braces and escaped quotes inside values do not truncate the object")
    func firstJSONObject_bracesInsideStringValues() throws {
        let stdout = #"noise {"title":"a bare \"}\" here","n":1} noise after {still not json}"#
        let data = try #require(PRStatusFetcher.firstJSONObject(in: stdout))
        #expect(String(bytes: data, encoding: .utf8) == #"{"title":"a bare \"}\" here","n":1}"#)
        #expect(PRStatusFetcher.firstJSONObject(in: "just a warning line") == nil)
        #expect(PRStatusFetcher.firstJSONObject(in: #"{"iid": 9, "state": "opened""#) == nil)
    }

    // MARK: - Fixtures

    private static func ok(_ body: String) -> ToolResult {
        ToolResult(exitCode: 0, stdout: "HTTP/2.0 200 OK\nContent-Type: application/json\n\n" + body, stderr: "")
    }

    private static func failed(_ body: String) -> ToolResult {
        ToolResult(exitCode: 1, stdout: "HTTP/2.0 200 OK\n\n" + body, stderr: "gh: Could not resolve to a Repository")
    }

    private static func number(_ answer: PRStatusFetcher.Answer?) -> Int? {
        if case let .found(info)? = answer {
            info.number
        } else {
            nil
        }
    }

    private static func gitHubBody(aliases: [String: String], defaultBranch: String = "trunk") -> String {
        let fields = ([#""defaultBranchRef":{"name":"\#(defaultBranch)"}"#] + aliases.map { #""\#($0.key)":\#($0.value)"# })
            .joined(separator: ",")
        let rateLimit = #"{"cost":1,"limit":5000,"remaining":4900,"resetAt":"2027-01-15T08:00:00Z"}"#
        return #"{"data":{"rateLimit":\#(rateLimit),"repository":{\#(fields)}}}"#
    }

    private static func connection(_ requests: [String], hasNextPage: Bool = false) -> String {
        #"{"pageInfo":{"hasNextPage":\#(hasNextPage)},"nodes":[\#(requests.joined(separator: ","))]}"#
    }

    private static func request(
        number: Int,
        state: String = "OPEN",
        isDraft: Bool = false,
        owner: String = "acme",
        url: String? = nil,
        rollup: String = "null"
    ) -> String {
        let link = url ?? "https://github.com/acme/app/pull/\(number)"
        return #"""
        {"number":\#(number),"state":"\#(state)","isDraft":\#(isDraft),"title":"Show PR status","url":"\#(link)",\#
        "headRepositoryOwner":{"login":"\#(owner)"},"commits":{"nodes":[{"commit":{"statusCheckRollup":\#(rollup)}}]}}
        """#
    }

    private static func rollup(state: String, contexts: [String], hasNextPage: Bool = false) -> String {
        #"""
        {"state":"\#(state)","contexts":{"pageInfo":{"hasNextPage":\#(hasNextPage)},"nodes":[\#(contexts.joined(separator: ","))]}}
        """#
    }

    private static func gitHubInfo(rollup: String) -> PRInfo? {
        let selector = PRHeadSelector.branch(name: "a", owner: nil)
        let body = gitHubBody(aliases: ["b0": connection([request(number: 1, rollup: rollup)])])
        let response = PRStatusQuery(forge: .gitHub, branches: ["a"], numbers: [])
            .response(ok(body), for: [selector], baseOwner: "acme", now: Date())
        if case let .found(info)? = response.answers[selector] {
            return info
        }
        return nil
    }

    /// A page of a GitLab query; `nextCursor` says there is another.
    private static func gitLabBody(_ requests: [String], nextCursor: String? = nil) -> String {
        let pageInfo = nextCursor.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false}"#
        return #"""
        {"data":{"project":{"mergeRequests":{"pageInfo":\#(pageInfo),"nodes":[\#(requests.joined(separator: ","))]}}}}
        """#
    }

    /// The answers from `pages` read in turn, as the fetcher reads a GitLab
    /// query's pages, complete when the last has no next page.
    private static func gitLabAnswers(for selectors: [PRHeadSelector], pages: [String]) -> [PRHeadSelector: PRStatusFetcher.Answer] {
        let query = PRStatusQuery(forge: .gitLab, branches: selectors.compactMap {
            if case let .branch(name, _) = $0 {
                name
            } else {
                nil
            }
        }, numbers: [])
        var requests: [GlabRequest] = []
        var isComplete = false
        for body in pages {
            guard let page = query.response(ok(body), for: selectors, baseOwner: nil, now: Date()).gitLabPage else { break }
            requests += page.requests
            isComplete = page.nextCursor == nil
        }
        return PRStatusQuery.gitLabAnswers(requests, for: selectors, isComplete: isComplete)
    }

    private static func mergeRequest(
        iid: String,
        state: String,
        branch: String,
        draft: Bool = false,
        pipeline: String? = nil
    ) -> String {
        let headPipeline = pipeline.map { #"{"status":"\#($0)"}"# } ?? "null"
        return #"""
        {"iid":"\#(iid)","state":"\#(state)","draft":\#(draft),"title":"Show PR status",\#
        "webUrl":"https://gitlab.com/acme/app/-/merge_requests/\#(iid)","sourceBranch":"\#(branch)","headPipeline":\#(headPipeline)}
        """#
    }
}
