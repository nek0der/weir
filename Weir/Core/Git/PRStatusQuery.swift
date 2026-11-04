// PRStatusQuery.swift
// Weir — the one GraphQL query per repository that reads every row's pull request, and its answer.
//
// `gh pr view` costs one GraphQL point and a CLI with seven Git commands
// per row, and the points come out of the 5,000 an hour every token of
// the person shares. One `gh api graphql` per repository asks for every
// branch at once under an alias each, for about one point
// (`rateLimit.cost` says what it was), and runs no Git at all: the
// branches come from `PRStatusRepository`. GitLab gets the same through
// `glab api graphql`, which takes a list of source branches instead.
//
// The answer is the request `gh pr view` shows (gh 2.103, `finder.go`):
// of the branch's 30 newest requests from the head's owner, an open one
// before any other, then the newest; on the repository's own default
// branch, an open one only. Reading 30 for every branch would cost about
// six times as much, so the first query reads 5, and only a branch whose 5
// leave an open request possible past them is asked again for 30.
//
// `--include` puts the status line and the headers before the body, which
// is where a rate limit's reset time is when the body has none
// (`ForgeQuota`).

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("git.pr")

/// One query's branches and request numbers, in alias order, and the
/// arguments that ask the forge's CLI for them.
struct PRStatusQuery: Equatable {
    let forge: ForgeKind
    /// Alias `bN` asks for `branches[N]`.
    let branches: [String]
    /// Alias `pN` asks for request `numbers[N]`. GitHub only: GitLab's
    /// lookup has no form of it.
    let numbers: [Int]
    /// How many requests each branch is asked for, newest first, on GitHub.
    var requestsPerBranch = Self.firstRequests
    /// Where a GitLab page starts: the previous page's end cursor.
    var cursor: String?

    /// The most aliases one query carries. GitLab takes at most 100 source
    /// branches; GitHub's node limit would allow more, but one rule keeps
    /// either query's size and cost bounded the same way.
    static let maxAliases = 100

    /// How many requests a GitHub branch is first asked for. A head branch
    /// has one open request at a time; the rest are earlier ones, and other
    /// forks' branches of the same name.
    static let firstRequests = 5
    /// How many `gh pr view` reads, which a branch is asked for again when
    /// its first five do not settle it.
    static let allRequests = 30

    /// The most pages of one GitLab query that are read. Past them, a
    /// branch not settled by what was read stays unanswered.
    static let maxGitLabPages = 20

    /// The queries that ask for `selectors`, each at most `maxAliases`, each
    /// branch name or number asked once however many rows share it.
    static func queries(
        for selectors: [PRHeadSelector],
        forge: ForgeKind,
        requestsPerBranch: Int = firstRequests
    ) -> [PRStatusQuery] {
        var branches: [String] = []
        var numbers: [Int] = []
        for selector in selectors {
            switch selector {
            case let .branch(name, _) where !branches.contains(name):
                branches.append(name)
            case let .number(number) where forge == .gitHub && !numbers.contains(number):
                numbers.append(number)
            default:
                break
            }
        }
        var queries: [PRStatusQuery] = []
        while !branches.isEmpty || !numbers.isEmpty {
            let branchCount = min(branches.count, maxAliases)
            let numberCount = min(numbers.count, maxAliases - branchCount)
            queries.append(PRStatusQuery(
                forge: forge,
                branches: Array(branches.prefix(branchCount)),
                numbers: Array(numbers.prefix(numberCount)),
                requestsPerBranch: requestsPerBranch
            ))
            branches.removeFirst(branchCount)
            numbers.removeFirst(numberCount)
        }
        return queries
    }

    /// Whether this query asks for `selector`'s branch or number.
    func asks(_ selector: PRHeadSelector) -> Bool {
        switch selector {
        case let .branch(name, _): branches.contains(name)
        case let .number(number): numbers.contains(number)
        }
    }

    /// This GitLab query, from the page after `cursor`.
    func after(_ cursor: String) -> PRStatusQuery {
        var next = self
        next.cursor = cursor
        return next
    }

    // MARK: - Arguments

    /// The CLI's arguments. `repository` is `owner/name` on GitHub and the
    /// project's full path on GitLab. Each branch goes as a variable with
    /// `-f`, which sends it as a string whatever it looks like, where `-F`
    /// would turn `123` into a number and `@file` into a file's contents.
    func arguments(host: String, repository: String) -> [String] {
        var arguments = ["api", "graphql", "--hostname", host, "--include"]
        switch forge {
        case .gitHub:
            let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
            arguments += ["-f", "query=\(gitHubQuery)"]
            arguments += ["-f", "owner=\(parts.first ?? "")", "-f", "repo=\(parts.count > 1 ? parts[1] : "")"]
            for (index, branch) in branches.enumerated() {
                arguments += ["-f", "b\(index)=\(branch)"]
            }
            for (index, number) in numbers.enumerated() {
                arguments += ["-F", "p\(index)=\(number)"]
            }
        case .gitLab:
            arguments += ["-f", "query=\(gitLabQuery)", "-f", "fullPath=\(repository)"]
        }
        return arguments
    }

    /// The fields Weir reads (`PRInfo`) and whose fork the head is in.
    /// `contexts(first: 100)` is as many as `gh pr view` reads on its first
    /// page; past that, the rollup's own state stands for the rest.
    private static let gitHubRequestFields = """
    fragment request on PullRequest { number state isDraft title url headRepositoryOwner { login } \
    commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { \
    pageInfo { hasNextPage } nodes { ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } } }
    """

    var gitHubQuery: String {
        let variables = ["$owner: String!", "$repo: String!"]
            + branches.indices.map { "$b\($0): String!" }
            + numbers.indices.map { "$p\($0): Int!" }
        let branchAliases = branches.indices.map {
            "b\($0): pullRequests(headRefName: $b\($0), first: \(requestsPerBranch), "
                + "orderBy: {field: CREATED_AT, direction: DESC}) { pageInfo { hasNextPage } nodes { ...request } }"
        }
        let numberAliases = numbers.indices.map { "p\($0): pullRequest(number: $p\($0)) { ...request }" }
        let fields = ["defaultBranchRef { name }"] + branchAliases + numberAliases
        return """
        query(\(variables.joined(separator: ", "))) { rateLimit { cost limit remaining resetAt } \
        repository(owner: $owner, name: $repo) { \(fields.joined(separator: " ")) } } \
        \(Self.gitHubRequestFields)
        """
    }

    /// GitLab's GraphQL takes the branches as one list, and its first 100
    /// requests are shared by every branch in it, so the pages are read on
    /// (`cursor`). The branches and the cursor are written into the query
    /// as JSON strings, whose escapes GraphQL's string literals share,
    /// because `glab api` has no form of a list variable.
    var gitLabQuery: String {
        let list = branches.map(Self.graphQLString).joined(separator: ", ")
        let after = cursor.map { ", after: \(Self.graphQLString($0))" } ?? ""
        return """
        query($fullPath: ID!) { project(fullPath: $fullPath) { mergeRequests(sourceBranches: [\(list)], \
        sort: CREATED_DESC, first: 100\(after)) { pageInfo { hasNextPage endCursor } nodes { iid state draft title \
        webUrl sourceBranch headPipeline { status } } } } }
        """
    }

    static func graphQLString(_ value: String) -> String {
        // A string always encodes to UTF-8; the fallback only keeps this total.
        (try? JSONEncoder().encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "\"\""
    }

    // MARK: - Answer

    /// What one run of the query said: each selector's answer, what it said
    /// of the rate limit, the GitHub branches whose first requests did not
    /// settle them, and a GitLab page.
    struct Response {
        var answers: [PRHeadSelector: PRStatusFetcher.Answer] = [:]
        var quota = ForgeQuota(hasAnswer: false)
        /// GitHub branches to ask again for `allRequests`.
        var needsMore: [PRHeadSelector] = []
        /// The GitLab page read, `nil` when none was.
        var gitLabPage: GitLabPage?
    }

    /// One page of a GitLab query.
    struct GitLabPage {
        var requests: [GlabRequest]
        /// Where the next page starts, `nil` on the last.
        var nextCursor: String?
    }

    /// Reads one run. A selector the run did not answer for is
    /// `.unanswered`, which keeps what the row showed: a timeout, an error,
    /// a repository the CLI cannot read, a rate limit. GitLab's answers come
    /// from all its pages (`gitLabAnswers`), so a GitLab run answers none.
    func response(_ result: ToolResult?, for selectors: [PRHeadSelector], baseOwner: String?, now: Date) -> Response {
        var response = Response()
        for selector in selectors {
            response.answers[selector] = .unanswered
        }
        guard let result else {
            log.debug("\(forge.executableName, privacy: .public) did not complete")
            return response
        }
        let http = HTTPOutput(result.stdout)
        switch forge {
        case .gitHub:
            let decoded = Self.decode(GhResponse.self, from: http.body)
            if let repository = decoded?.data?.repository {
                readGitHub(repository, for: selectors, baseOwner: baseOwner, into: &response)
            }
            response.quota = ForgeQuota(
                result: result,
                http: http,
                rateLimit: decoded?.data?.rateLimit,
                errorTypes: decoded?.errors?.compactMap(\.type) ?? [],
                now: now
            )
        case .gitLab:
            let decoded = Self.decode(GlabResponse.self, from: http.body)
            response.gitLabPage = decoded?.data?.project?.mergeRequests.map { requests in
                GitLabPage(
                    requests: requests.nodes,
                    nextCursor: requests.pageInfo?.hasNextPage == true ? requests.pageInfo?.endCursor : nil
                )
            }
            response.quota = ForgeQuota(result: result, http: http, rateLimit: nil, errorTypes: [], now: now)
        }
        if !result.isSuccess {
            log.debug("""
            \(forge.executableName, privacy: .public) exit \(result.exitCode, privacy: .public): \
            \(result.stderr, privacy: .private)
            """)
        }
        return response
    }

    private static func decode<T: Decodable>(_: T.Type, from body: String) -> T? {
        guard let data = PRStatusFetcher.firstJSONObject(in: body) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.debug("PR query decode failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func readGitHub(
        _ repository: GhRepository,
        for selectors: [PRHeadSelector],
        baseOwner: String?,
        into response: inout Response
    ) {
        let isLastTry = requestsPerBranch >= Self.allRequests
        for selector in selectors {
            switch selector {
            case let .branch(name, owner):
                guard let index = branches.firstIndex(of: name),
                      case let .connection(connection)? = repository.aliases["b\(index)"]
                else { continue }
                // `gh pr view` shows only an open request of the repository's
                // own default branch, as it is where every other one merges.
                let isOwnDefaultBranch = name == repository.defaultBranch
                    && (owner == nil || owner?.caseInsensitiveCompare(baseOwner ?? "") == .orderedSame)
                switch Self.selectAnswer(in: connection, owner: owner, isOwnDefaultBranch: isOwnDefaultBranch, isLastTry: isLastTry) {
                case let .answer(answer): response.answers[selector] = answer
                case .needsMore: response.needsMore.append(selector)
                }
            case let .number(number):
                guard let index = numbers.firstIndex(of: number),
                      case let .request(request)? = repository.aliases["p\(index)"],
                      let info = request.info
                else { continue }
                response.answers[selector] = .found(info)
            }
        }
    }

    /// What the requests read settle about a branch.
    enum Selection: Equatable {
        case answer(PRStatusFetcher.Answer)
        /// An open request may be among the requests not read.
        case needsMore
    }

    /// The request `gh pr view` shows for a branch, of those read: an open
    /// one from the head's owner, else the newest of that owner's, else
    /// none; on the repository's own default branch, an open one only. While
    /// more were not read and none read is open, an open one may be among
    /// them, so the branch is asked again, unless this was the last try,
    /// which reads as many as `gh` does.
    static func selectAnswer(
        in connection: GhConnection,
        owner: String?,
        isOwnDefaultBranch: Bool = false,
        isLastTry: Bool
    ) -> Selection {
        let matching = connection.nodes.filter { node in
            if isOwnDefaultBranch, !node.isOpen {
                return false
            }
            guard let owner else { return true }
            return node.headRepositoryOwner?.login.caseInsensitiveCompare(owner) == .orderedSame
        }
        if let open = matching.first(where: \.isOpen) {
            return .answer(open.info.map(PRStatusFetcher.Answer.found) ?? .unanswered)
        }
        if connection.pageInfo?.hasNextPage == true, !isLastTry {
            return .needsMore
        }
        guard let newest = matching.first else { return .answer(.none) }
        return .answer(newest.info.map(PRStatusFetcher.Answer.found) ?? .unanswered)
    }

    /// Each branch's answer from every GitLab request read: an opened one
    /// before any other, then the newest. GitLab's lookup does not tell
    /// forks apart by owner, as `glab mr view` does not: a merge request
    /// lists its source branch, and the source project only by an id. When
    /// not every page was read (`isComplete`), only a branch with an opened
    /// request read is settled; any other may have one on a page not read.
    static func gitLabAnswers(
        _ requests: [GlabRequest],
        for selectors: [PRHeadSelector],
        isComplete: Bool
    ) -> [PRHeadSelector: PRStatusFetcher.Answer] {
        var answers: [PRHeadSelector: PRStatusFetcher.Answer] = [:]
        for selector in selectors {
            guard case let .branch(name, _) = selector else { continue }
            let matching = requests.filter { $0.sourceBranch == name }
            if let opened = matching.first(where: \.isOpened) {
                answers[selector] = opened.info.map(PRStatusFetcher.Answer.found) ?? .unanswered
            } else if !isComplete {
                answers[selector] = .unanswered
            } else if let newest = matching.first {
                answers[selector] = newest.info.map(PRStatusFetcher.Answer.found) ?? .unanswered
            } else {
                answers[selector] = PRStatusFetcher.Answer.none
            }
        }
        return answers
    }
}

// MARK: - HTTP output

/// `--include` output: a status line, headers, a blank line, the body.
/// Output without a status line is all body.
struct HTTPOutput {
    var status: Int?
    /// Lowercased names.
    var headers: [String: String] = [:]
    var body: String

    init(_ output: String) {
        // `\r\n` is one `Character`, so lines split on any line break.
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, first.hasPrefix("HTTP/") else {
            body = output
            return
        }
        status = first.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        var index = 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if line.isEmpty {
                break
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        body = lines[min(index, lines.count)...].joined(separator: "\n")
    }
}

// MARK: - GitHub payload

private struct GhResponse: Decodable {
    struct Payload: Decodable {
        let rateLimit: GhRateLimit?
        let repository: GhRepository?
    }

    struct GraphQLError: Decodable {
        let type: String?
    }

    let data: Payload?
    let errors: [GraphQLError]?
}

struct GhRateLimit: Decodable {
    let cost: Int?
    let limit: Int?
    let remaining: Int?
    let resetAt: String?
}

/// The repository's default branch and its aliases' values, which are
/// named only at run time.
private struct GhRepository: Decodable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    private struct BranchRef: Decodable {
        let name: String
    }

    let defaultBranch: String?
    /// A null alias (a request number that does not exist) is absent.
    let aliases: [String: GhAlias]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        defaultBranch = try container.decodeIfPresent(BranchRef.self, forKey: Key(stringValue: "defaultBranchRef"))?.name
        var aliases: [String: GhAlias] = [:]
        for key in container.allKeys where key.stringValue != "defaultBranchRef" {
            aliases[key.stringValue] = try container.decodeIfPresent(GhAlias.self, forKey: key)
        }
        self.aliases = aliases
    }
}

/// An alias's value: a branch's requests (`bN`) or one request (`pN`).
private enum GhAlias: Decodable {
    case connection(GhConnection)
    case request(GhRequest)

    private enum Keys: String, CodingKey {
        case nodes
    }

    init(from decoder: any Decoder) throws {
        if try decoder.container(keyedBy: Keys.self).contains(.nodes) {
            self = try .connection(GhConnection(from: decoder))
        } else {
            self = try .request(GhRequest(from: decoder))
        }
    }
}

struct GhPageInfo: Decodable {
    let hasNextPage: Bool
    /// Where the next page starts; asked for on GitLab only.
    var endCursor: String?
}

struct GhConnection: Decodable {
    let pageInfo: GhPageInfo?
    let nodes: [GhRequest]
}

struct GhRequest: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    struct Commits: Decodable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable {
        let commit: Commit
    }

    struct Commit: Decodable {
        let statusCheckRollup: Rollup?
    }

    struct Rollup: Decodable {
        let state: String?
        let contexts: Contexts?
    }

    struct Contexts: Decodable {
        let pageInfo: GhPageInfo?
        let nodes: [GhStatusCheck]
    }

    let number: Int
    let state: String
    let isDraft: Bool
    let title: String
    let url: URL
    let headRepositoryOwner: Owner?
    let commits: Commits?

    var isOpen: Bool {
        state.uppercased() == "OPEN"
    }

    /// `nil` for a link that is not a web page (`PRInfo.isWebLink`).
    var info: PRInfo? {
        let info = PRInfo(
            number: number,
            state: PRState(forgeState: state),
            isDraft: isDraft,
            title: title,
            url: url,
            forge: .gitHub,
            checks: checks
        )
        return info.hasWebLink ? info : nil
    }

    /// Collapse the per-context list into counts plus a single
    /// conclusion. `nil` for an absent or empty rollup so the card can
    /// say "no checks" rather than "0 of 0 passed".
    private var checks: PRChecks? {
        guard let rollup = commits?.nodes.last?.commit.statusCheckRollup,
              let contexts = rollup.contexts, !contexts.nodes.isEmpty
        else { return nil }
        // More than one page: the rollup's state covers every check, and
        // the counts of one page would be wrong, so the card states the
        // conclusion alone, as it does for GitLab.
        if contexts.pageInfo?.hasNextPage == true {
            return PRChecks(conclusion: PRChecksConclusion(rawStatus: rollup.state), counts: nil)
        }
        var passed = 0
        var hasFailure = false
        var hasPending = false
        for check in contexts.nodes {
            switch check.normalized {
            case .success: passed += 1
            case .failure: hasFailure = true
            case .pending: hasPending = true
            }
        }
        // Failure outranks pending: a run still going does not soften
        // one that already went red.
        let conclusion: PRChecksConclusion = if hasFailure {
            .failure
        } else if hasPending {
            .pending
        } else {
            .success
        }
        return PRChecks(conclusion: conclusion, counts: PRChecks.Counts(passed: passed, total: contexts.nodes.count))
    }
}

/// One check. A `CheckRun` has `conclusion` and `status`, a
/// `StatusContext` has `state`, so all three are optional and normalized to
/// one tri-state. GraphQL leaves a running CheckRun's `conclusion` null, so
/// its `status` (`IN_PROGRESS`, `QUEUED`) is what reads as pending.
struct GhStatusCheck: Decodable {
    let conclusion: String?
    let state: String?
    let status: String?

    var normalized: PRChecksConclusion {
        PRChecksConclusion(rawStatus: conclusion ?? state ?? status)
    }
}

// MARK: - GitLab payload

private struct GlabResponse: Decodable {
    struct Payload: Decodable {
        let project: Project?
    }

    struct Project: Decodable {
        let mergeRequests: GlabConnection?
    }

    let data: Payload?
}

private struct GlabConnection: Decodable {
    let pageInfo: GhPageInfo?
    let nodes: [GlabRequest]
}

struct GlabRequest: Decodable {
    struct Pipeline: Decodable {
        let status: String?
    }

    /// GitLab's GraphQL gives the per-project number (`iid`, the one its UI
    /// and `glab` use) as a string.
    let iid: String
    let state: String
    let draft: Bool?
    let title: String
    let webUrl: URL
    let sourceBranch: String
    let headPipeline: Pipeline?

    var isOpened: Bool {
        state.lowercased() == "opened"
    }

    var info: PRInfo? {
        guard let number = Int(iid) else { return nil }
        let info = PRInfo(
            number: number,
            // `locked` is a locked discussion, not a finished request, so
            // it reads as open.
            state: PRState(forgeState: state),
            isDraft: draft ?? false,
            title: title,
            url: webUrl,
            forge: .gitLab,
            // One pipeline status and no per-job breakdown, so `counts`
            // stays nil and the card phrases the result without numbers.
            checks: headPipeline?.status.map { PRChecks(conclusion: PRChecksConclusion(rawStatus: $0), counts: nil) }
        )
        return info.hasWebLink ? info : nil
    }
}

extension PRInfo {
    /// Whether the request's link is a web page. The link opens on a click
    /// without asking, so a file or a custom scheme from a forge (or
    /// whatever answers as one) would launch its handler. Plain http stays,
    /// for a self-hosted GitLab that serves no TLS.
    var hasWebLink: Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host?.isEmpty == false
    }
}
