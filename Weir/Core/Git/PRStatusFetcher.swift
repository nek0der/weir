// PRStatusFetcher.swift
// Weir — reads the pull requests of a repository's checkouts through the forge CLI, one query for them all.
//
// Separate from `GitProcess` because these CLIs are optional
// dependencies: the user may not have them installed, may not be
// authenticated, or may be offline. Every failure mode here resolves
// to "keep what the row showed, and log at debug", which is a different
// posture than the `git` path that surfaces errors interactively.
//
// One lookup covers the rows of one repository: each row's branch is read
// with Git, the branch its request's head is on comes from the
// repository's configuration (`PRStatusRepository`), and one GraphQL query
// asks for all of them (`PRStatusQuery`). A host whose rate limit ran out
// is asked nothing until it resets (`ForgeRateLimiter`).

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("git.pr")

/// One row a lookup is asked for: where its checkout is.
struct PRStatusRow: Hashable {
    let container: ContainerID
    let workingDirectory: URL
}

/// What one lookup of a repository's rows found.
struct PRStatusBatch {
    var lookups: [ContainerID: PRStatusFetcher.Lookup] = [:]
    /// Whether less than a tenth of the host's quota is left; `nil` when the
    /// lookup asked no forge.
    var isQuotaLow: Bool?
}

/// What `PRStatusSyncer` asks for a repository's requests through: the
/// forge CLIs in the app, and a scripted stand-in in the tests, which have
/// to hold one answer back to order it against another.
protocol PRStatusLookups: Sendable {
    /// Looks up `rows`, every one of them a checkout of one repository.
    func lookup(_ rows: [PRStatusRow]) async -> PRStatusBatch
    /// Forget what was resolved about each folder's forge, for a manual
    /// refresh: the user may have just added a remote or signed a CLI in.
    func invalidate() async
}

/// Which branch a checkout has out, as far as one side can tell: what ties
/// a request to the checkout it was asked for, so that an answer for a
/// branch the checkout has since left is not shown on it.
enum CheckoutHead: Equatable {
    /// Not known: a row before Git was first read for it, or a lookup that
    /// ran no CLI.
    case unknown
    case detached
    case branch(String)

    /// Whether an answer asked for `answered` belongs to a checkout that is
    /// at `self` now. A side that does not know agrees with anything: a row
    /// before its first sync would otherwise show nothing until Git is
    /// read, and a lookup that ran no CLI says nothing about a branch.
    func admits(_ answered: CheckoutHead) -> Bool {
        self == .unknown || answered == .unknown || self == answered
    }
}

struct PRStatusFetcher: PRStatusLookups {
    /// Runs `git` with these arguments in a folder.
    typealias GitRun = @Sendable (_ arguments: [String], _ workingDirectory: URL) async -> ToolResult?
    /// Runs a forge's CLI.
    typealias ForgeRun = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ workingDirectory: URL,
        _ environment: [String: String]
    ) async -> ToolResult?

    private let resolver: ForgeResolver
    private let locator: ToolLocator
    private let limiter: ForgeRateLimiter
    private let now: @Sendable () -> Date
    private let git: GitRun
    private let forgeCLI: ForgeRun

    /// The collaborators are injected for the tests, which run a stand-in
    /// for the forge's CLI and step the clock the rate limit is read by.
    init(
        resolver: ForgeResolver,
        locator: ToolLocator,
        limiter: ForgeRateLimiter = ForgeRateLimiter(),
        now: @escaping @Sendable () -> Date = { Date() },
        git: @escaping GitRun = Self.liveGit,
        forgeCLI: @escaping ForgeRun = Self.liveForgeCLI
    ) {
        self.resolver = resolver
        self.locator = locator
        self.limiter = limiter
        self.now = now
        self.git = git
        self.forgeCLI = forgeCLI
    }

    /// Ceiling on one query. Longer than one `gh pr view` was given, since
    /// it answers for every row of a repository; short enough that a hung
    /// binary cannot hold the lookups for long.
    private static let timeout: Duration = .seconds(10)

    static let liveGit: GitRun = { arguments, workingDirectory in
        guard let result = try? await GitProcess.run(arguments, cwd: workingDirectory) else { return nil }
        return ToolResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    static let liveForgeCLI: ForgeRun = { executable, arguments, workingDirectory, environment in
        await runTool(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
    }

    /// What one lookup learns of a row: the request, and the forge whose
    /// CLI is installed for the folder's remote whether or not a request was
    /// found, which is what "Create PR" needs. `isAnswered` is false
    /// when the CLI did not say whether there is a request (a timeout, the
    /// network, rate limits, credentials): now that the changes panel
    /// offers "Create PR" and "Clean Up Worktree…" by the request's state,
    /// such a lookup must not read as "no request" and offer a second one
    /// for a branch already merged.
    ///
    /// No forge and no request, answered, when the worktree has no remote,
    /// its host is not a forge we support (resolved once and cached by
    /// `ForgeResolver`), or the CLI is not installed. We deliberately do
    /// not `throw`: the lookup is best-effort, and failures log at
    /// `.debug` so anyone diagnosing can use `log show`.
    struct Lookup: Equatable {
        var forge: ForgeKind?
        var info: PRInfo?
        var isAnswered = true
        /// The branch the forge was asked about. The checkout can move to
        /// another branch while a lookup runs; the syncer compares this
        /// with the branch the row shows before it keeps the answer.
        var head: CheckoutHead = .unknown
    }

    /// What the forge said of one branch's request.
    enum Answer: Equatable {
        case found(PRInfo)
        case none
        case unanswered
    }

    func invalidate() async {
        await resolver.invalidate()
    }

    func lookup(_ rows: [PRStatusRow]) async -> PRStatusBatch {
        guard let directory = rows.first?.workingDirectory else { return PRStatusBatch() }
        func batch(_ lookup: Lookup) -> PRStatusBatch {
            PRStatusBatch(lookups: Dictionary(rows.map { ($0.container, lookup) }, uniquingKeysWith: { first, _ in first }))
        }
        let noForge = batch(Lookup())
        let forge: ForgeKind
        switch await resolver.answer(for: directory) {
        case let .known(known?):
            forge = known
        case .known(nil):
            return noForge
        case .unavailable:
            // Remotes that could not be read say nothing of the rows, so
            // each keeps what it showed until the next lookup.
            log.debug("the checkout's remotes could not be read; no answer")
            return batch(Lookup(isAnswered: false))
        }
        guard let executable = await locator.locate(forge.executableName) else {
            log.debug("\(forge.executableName, privacy: .public) not installed")
            return noForge
        }
        // Read on both sides of the query: a checkout that switched branch
        // in between was asked about a branch it no longer has, which is no
        // answer, and keeps what was known until the next lookup.
        var heads: [ContainerID: CheckoutHead] = [:]
        for row in rows {
            heads[row.container] = await head(of: row.workingDirectory)
        }
        let answers = await ask(forge: forge, executable: executable, directory: directory, rows: rows, heads: heads)
        var batch = PRStatusBatch(isQuotaLow: answers.isQuotaLow)
        for row in rows {
            let before = heads[row.container] ?? .unknown
            guard await head(of: row.workingDirectory) == before else {
                log.debug("checkout changed branch during the lookup; no answer")
                batch.lookups[row.container] = Lookup(forge: forge, isAnswered: false)
                continue
            }
            let answer = answers.bySelector[row.container].flatMap { answers.answers[$0] } ?? .unanswered
            batch.lookups[row.container] = switch answer {
            case let .found(info): Lookup(forge: forge, info: info, head: before)
            case .none: Lookup(forge: forge, head: before)
            case .unanswered: Lookup(forge: forge, isAnswered: false, head: before)
            }
        }
        return batch
    }

    /// The rows' selectors and what the forge said of each.
    private struct Asked {
        var bySelector: [ContainerID: PRHeadSelector] = [:]
        var answers: [PRHeadSelector: Answer] = [:]
        var isQuotaLow: Bool?
    }

    /// Asks the forge about every row on a branch; a detached or unread
    /// checkout has no branch to ask about, which `gh pr view` answered
    /// with an error, so it stays unanswered.
    private func ask(
        forge: ForgeKind,
        executable: URL,
        directory: URL,
        rows: [PRStatusRow],
        heads: [ContainerID: CheckoutHead]
    ) async -> Asked {
        var asked = Asked()
        let branches = heads.values.compactMap { head -> String? in
            if case let .branch(name) = head {
                name
            } else {
                nil
            }
        }
        guard !branches.isEmpty else { return asked }
        guard let repository = await readRepository(in: directory, branches: Set(branches)),
              let base = repository.baseRepository(forge: forge)
        else {
            log.debug("no repository to ask the forge about")
            return asked
        }
        var selectors: [PRHeadSelector] = []
        for container in rows.map(\.container) {
            guard case let .branch(name)? = heads[container] else { continue }
            let selector = repository.selector(for: name, baseOwner: base.owner, forge: forge)
            asked.bySelector[container] = selector
            if !selectors.contains(selector) {
                selectors.append(selector)
            }
        }
        let sender = Sender(fetcher: self, executable: executable, directory: directory, base: base)
        asked.answers = switch forge {
        case .gitHub: await askGitHub(selectors, through: sender)
        case .gitLab: await askGitLab(selectors, through: sender)
        }
        asked.isQuotaLow = await limiter.isLow(host: base.host)
        return asked
    }

    /// Runs queries against one repository, through the host's rate limit,
    /// and stops once the limit says to.
    private final class Sender {
        let fetcher: PRStatusFetcher
        let executable: URL
        let directory: URL
        let base: PRStatusRepository.BaseRepository
        /// Set once a query was held or refused for the rate limit.
        private(set) var isStopped = false

        init(fetcher: PRStatusFetcher, executable: URL, directory: URL, base: PRStatusRepository.BaseRepository) {
            self.fetcher = fetcher
            self.executable = executable
            self.directory = directory
            self.base = base
        }

        /// `nil` when the host's lookups wait for its rate limit.
        func send(_ query: PRStatusQuery, for selectors: [PRHeadSelector]) async -> PRStatusQuery.Response? {
            guard !isStopped else { return nil }
            let admission = await fetcher.limiter.admit(host: base.host)
            guard admission != .held else {
                log.debug("lookups of this host wait for its rate limit")
                isStopped = true
                return nil
            }
            let result = await fetcher.forgeCLI(
                executable,
                query.arguments(host: base.host, repository: base.path),
                directory,
                ForgePullRequests.quietEnvironment(for: query.forge)
            )
            let response = query.response(result, for: selectors.filter(query.asks), baseOwner: base.owner, now: fetcher.now())
            await fetcher.limiter.record(response.quota, host: base.host, admission: admission)
            if response.quota.isRateLimited {
                isStopped = true
            }
            return response
        }
    }

    /// Each branch asked for its 5 newest requests, and the branches those
    /// do not settle asked again for 30, as many as `gh pr view` reads.
    private func askGitHub(_ selectors: [PRHeadSelector], through sender: Sender) async -> [PRHeadSelector: Answer] {
        var answers: [PRHeadSelector: Answer] = [:]
        var needsMore: [PRHeadSelector] = []
        for query in PRStatusQuery.queries(for: selectors, forge: .gitHub) {
            guard let response = await sender.send(query, for: selectors) else { break }
            answers.merge(response.answers) { _, new in new }
            needsMore += response.needsMore
        }
        let again = PRStatusQuery.queries(for: needsMore, forge: .gitHub, requestsPerBranch: PRStatusQuery.allRequests)
        for query in again {
            guard let response = await sender.send(query, for: needsMore) else { break }
            answers.merge(response.answers) { _, new in new }
        }
        return answers
    }

    /// Each query's pages read on until the last, since one page of 100 is
    /// shared by every branch in it.
    private func askGitLab(_ selectors: [PRHeadSelector], through sender: Sender) async -> [PRHeadSelector: Answer] {
        var answers: [PRHeadSelector: Answer] = [:]
        for first in PRStatusQuery.queries(for: selectors, forge: .gitLab) {
            var query = first
            var requests: [GlabRequest] = []
            var isComplete = false
            for _ in 0..<PRStatusQuery.maxGitLabPages {
                guard let page = await sender.send(query, for: selectors)?.gitLabPage else { break }
                requests += page.requests
                guard let cursor = page.nextCursor else {
                    isComplete = true
                    break
                }
                query = first.after(cursor)
            }
            // Nothing read at all is no answer, not "none".
            guard isComplete || !requests.isEmpty else { continue }
            let asked = selectors.filter(first.asks)
            answers.merge(PRStatusQuery.gitLabAnswers(requests, for: asked, isComplete: isComplete)) { _, new in new }
        }
        return answers
    }

    /// The repository's configuration, read once for every row: worktrees
    /// share it. `nil` when `git config` did not answer; exit 1 is a
    /// repository with none of the keys.
    private func readRepository(in directory: URL, branches: Set<String>) async -> PRStatusRepository? {
        guard let config = await git(PRStatusRepository.configArguments, directory),
              config.exitCode == 0 || config.exitCode == 1
        else { return nil }
        // A Git too old for `%(push:remotename)` fails here, and every
        // branch then goes by its configuration alone, as `gh` does when
        // `@{push}` does not resolve.
        let pushes = await git(PRStatusRepository.pushArguments(branches: branches.sorted()), directory)
        return PRStatusRepository.parse(
            config: config.stdout,
            pushes: pushes?.isSuccess == true ? pushes?.stdout ?? "" : "",
            branches: branches
        )
    }

    /// The branch `workingDirectory` has out, by its full name, which is
    /// how `git worktree list` names the row's branch.
    /// `symbolic-ref` rather than `rev-parse --abbrev-ref`: the latter
    /// shortens a name a tag shares to `heads/…`, and fails on a branch
    /// with no commit yet, so the two would never agree for such a branch.
    /// Exit 1 is a detached HEAD; anything else that keeps git from naming
    /// one (not a repository, a git that would not run) is not known.
    private func head(of workingDirectory: URL) async -> CheckoutHead {
        guard let result = await git(["symbolic-ref", "--quiet", "HEAD"], workingDirectory) else { return .unknown }
        switch result.exitCode {
        case 0:
            let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "refs/heads/"
            guard ref.hasPrefix(prefix), ref.count > prefix.count else { return .unknown }
            return .branch(String(ref.dropFirst(prefix.count)))
        case 1:
            return .detached
        default:
            return .unknown
        }
    }

    /// Slice out the first complete JSON object in `raw`, ignoring
    /// whatever follows it — and whatever precedes it, as long as that
    /// carries no `{` of its own.
    ///
    /// `JSONDecoder` rejects trailing bytes, and neither CLI documents
    /// stdout as payload-only; today they keep their diagnostics on
    /// stderr, but that is a habit rather than a promise, and a
    /// version that broke it would take the feature down for a whole
    /// forge with no error to show for it. Scanning for a balanced
    /// object — tracking string and escape state so braces inside
    /// values don't confuse the depth count — makes a stray line
    /// harmless instead.
    static func firstJSONObject(in raw: String) -> Data? {
        let bytes = Array(raw.utf8)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        var isInString = false
        var isEscaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if isInString {
                if byte == UInt8(ascii: #"\"#) {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    return Data(bytes[start...index])
                }
            default:
                break
            }
        }
        return nil
    }
}
