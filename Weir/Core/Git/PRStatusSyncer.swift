// PRStatusSyncer.swift
// Weir — schedules forge lookups per repository and writes the
// results into `PRStatusStore`. Sibling to `GitSyncCoordinator` but
// kept deliberately separate because:
//   - `gh` / `glab` are optional dependencies; a failure here must
//     never poison local `git` sync.
//   - Pull-request state moves on the forge's clock, not the local
//     repo's, so the cadence is time-driven rather than mutation-driven,
//     with a lookup when an agent's turn ends (`TurnEndPRRefresh`), which
//     is often what moved it.
//   - It has no setting: pull requests show wherever `gh`
//     or `glab` can read them, and a CLI that is absent or signed out is
//     found out by the lookup itself.
//
// The unit of a lookup is a project: its rows are the worktrees of one
// repository, and one query answers for all of them (`PRStatusFetcher`).
// Every lookup spends the person's forge quota, which all their tokens
// share, so a project is looked up when its most pressing row is due,
// coming back to the app and a turn's end are gathered for a few
// seconds first, and a request that is merged or closed is asked about
// at most once an hour.
//
// Lifecycle:
//   - `init` takes every collaborator, and where the requests come from
//     (`PRStatusSource`), rather than reaching for the session, the
//     store, or the demo flag through a global.
//   - `start()` arms a focus observer and a recurring task for the forge
//     CLIs; a fixture is written to the store once and nothing is
//     scheduled.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("git.pr.sync")

/// Where `PRStatusSyncer` learns each row's request. The app chooses it
/// at launch (`AppState`), so the syncer reads no demo flag itself.
enum PRStatusSource {
    /// Asks the forge CLI for each repository, on the syncer's cadence. The
    /// syncer builds its fetcher from these two, so the resolver a manual
    /// refresh invalidates is always the one its lookups read.
    case forgeCLI(resolver: ForgeResolver, locator: ToolLocator)
    /// Shows these requests and asks nothing, for demo mode: the hero
    /// screenshot has to look the same on every contributor's Mac, and a
    /// CLI answers from whatever is on disk under whatever credentials
    /// happen to be present. No forge is recorded either, as for a folder
    /// whose CLI is not installed.
    case fixture([ContainerID: PRInfo])

    /// The forge CLIs, found through `locator`.
    static func live(locator: ToolLocator) -> PRStatusSource {
        .forgeCLI(resolver: ForgeResolver(locator: locator), locator: locator)
    }
}

/// The time the lookups pace themselves by. A protocol so the tests step
/// it by hand rather than wait out a debounce or an interval.
protocol PRStatusClock: Sendable {
    /// Returns wall time for the forge's absolute reset dates and Retry-After projection.
    func now() -> Date
    /// Returns a monotonic instant for process-local pacing, including time spent asleep.
    func monotonicNow() -> ContinuousClock.Instant
    /// Returns after `interval`, or throws once the task is canceled.
    func sleep(for interval: TimeInterval) async throws
}

struct SystemPRStatusClock: PRStatusClock {
    func now() -> Date {
        Date()
    }

    func monotonicNow() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}

@MainActor
final class PRStatusSyncer {
    private weak var session: WorkspaceSession?
    private weak var store: PRStatusStore?

    /// A fixture's requests, written once by `start()`. `nil` for the
    /// forge CLIs, which `fetcher` asks instead.
    private let fixture: [ContainerID: PRInfo]?
    /// Built from the source's resolver and locator. Optional because a
    /// fixture asks no CLI, so it has nothing to fetch with.
    private let fetcher: (any PRStatusLookups)?
    /// What the new worktree sheet reads a pull request with, on the
    /// same resolver and locator, so the sheet and the marks agree on the
    /// forge and a manual refresh resets both. `nil` for a fixture, which
    /// asks no CLI.
    let pullRequests: (any PullRequestReading)?
    private let clock: any PRStatusClock

    /// How long a row waits between recurring lookups, from what its last
    /// one found; `nil` for a row the recurring lookups leave alone. A
    /// project is looked up when any of its rows is due, so its interval is
    /// its shortest row's; only what can still change soon is asked often:
    ///
    /// - Checks running: a run that finishes in a couple of minutes should
    ///   not read as running well after it stopped. Not while the quota
    ///   runs low (`isQuotaLow`), when this polling is what spends the most
    ///   for the least, and the row waits as an open request does.
    /// - An open request: it is what a merge moves to Ready to Clean Up.
    /// - No request: one may be opened, which matters less soon.
    /// - A merged or closed request: nothing is left to wait for. It goes
    ///   along with its project's lookups at most once an hour
    ///   (`finishedInterval`), and with a turn's end in its row, which is how
    ///   a reopened one is found.
    static func recurringInterval(for info: PRInfo?, isQuotaLow: Bool = false) -> TimeInterval? {
        guard let info else { return noRequestInterval }
        guard info.state == .open else { return nil }
        return info.checks?.conclusion == .pending && !isQuotaLow ? pollInterval : openRequestInterval
    }

    private static let openRequestInterval: TimeInterval = 90
    private static let noRequestInterval: TimeInterval = 300

    /// The least time between two lookups of a project that coming back to
    /// the app or a turn's end ask for, so rapid app switching or a run of
    /// short turns cannot spend a query each. `refreshNow` deliberately
    /// ignores it — see there.
    static let repositoryFloor: TimeInterval = 60

    /// How long the requests of coming back to the app and of turn ends are
    /// gathered: a lookup goes once none has come for `quietPeriod`, and at
    /// the latest `longestWait` after the first. Several agents often end
    /// their turns together, and switching apps comes in bursts.
    static let quietPeriod: TimeInterval = 5
    static let longestWait: TimeInterval = 15

    /// The least time between two lookups of a row whose request is merged
    /// or closed, short of a turn's end in it or a manual refresh.
    static let finishedInterval: TimeInterval = 3600

    /// Last attempted fetch time per row. We track attempts (not just
    /// successes) so the floors still apply when the CLI fails.
    private var lastFetchAt: [ContainerID: ContinuousClock.Instant] = [:]
    /// Last attempted lookup time per project, for `repositoryFloor`.
    private var lastLookupAt: [UUID: ContinuousClock.Instant] = [:]
    /// Whether each project's host was low on quota at its last lookup.
    private var lowQuotaProjects: Set<UUID> = []

    /// The projects with a lookup running, and what was asked of them while
    /// it ran. At most one runs per project: the triggers start
    /// independently, and two lookups of one row in flight could answer in
    /// either order, a slow earlier one putting back the CI state a later
    /// one had replaced. A request that finds one running asks for one
    /// lookup after it rather than its own, since the running one may have
    /// asked before whatever the request is about (a push, a merge).
    private var inFlight: [UUID: FollowUp] = [:]

    /// What was asked of a running lookup's project while it ran.
    private struct FollowUp {
        var isRequested = false
        /// Whether a manual refresh asked for it, which re-reads the forge.
        var invalidatesForges = false
        /// The rows that have to be in it whatever their pace.
        var forced: Set<ContainerID> = []
    }

    /// A gathered request waiting for its project's lookup: the first and
    /// latest moment it was asked for, and the rows a turn ended in.
    private struct PendingRequest {
        var firstAt: ContinuousClock.Instant
        var lastAt: ContinuousClock.Instant
        var forced: Set<ContainerID>
    }

    private var pending: [UUID: PendingRequest] = [:]

    /// The projects with a gathered request still waiting, for the tests
    /// that check one was dropped rather than looked up.
    var gatheringProjects: Set<UUID> {
        Set(pending.keys)
    }

    /// The token of each container's latest lookup, taken from
    /// `nextLookupToken`. An answer is kept only while its token is still
    /// the container's: dropping a container drops its token, so an
    /// answer that lands after a prune cannot put the row back, even if a
    /// row with the same identity has come back since.
    private var lookupTokens: [ContainerID: UInt64] = [:]
    private var nextLookupToken: UInt64 = 0

    /// The branch each kept answer was asked for. The store keys a request
    /// by the row alone, and a checkout switched to another branch keeps
    /// its row, so this is what tells the previous branch's request from
    /// the current one's (`recheckLeftBranches`).
    private var answeredHeads: [ContainerID: CheckoutHead] = [:]

    /// Rows whose answer named another branch than the row shows, with the
    /// branch the row showed then. The fetcher already gives no answer for a
    /// checkout that switched while it ran, so a mismatch means Git has not
    /// been read again for the row since its checkout moved; asking again
    /// before it is would get the same mismatch. A wake looks such a row up
    /// only once the branch it shows has changed (`recheckLeftBranches`).
    private var leftBranches: [ContainerID: CheckoutHead] = [:]

    private var recurringTask: Task<Void, Never>?

    /// How often the recurring task wakes to reconsider, the shortest
    /// `recurringInterval`: waking more often would decide nothing sooner.
    private static let pollInterval: TimeInterval = 45

    /// Set by `start()`, once there is something to refetch.
    private var isFollowingActivation = false

    convenience init(
        session: WorkspaceSession,
        store: PRStatusStore,
        source: PRStatusSource,
        clock: any PRStatusClock = SystemPRStatusClock()
    ) {
        switch source {
        case let .forgeCLI(resolver, locator):
            let now: @Sendable () -> Date = { clock.now() }
            self.init(
                session: session,
                store: store,
                fetcher: PRStatusFetcher(
                    resolver: resolver,
                    locator: locator,
                    limiter: ForgeRateLimiter(now: now, monotonicNow: { clock.monotonicNow() }),
                    now: now
                ),
                pullRequests: ForgePullRequests(resolver: resolver, locator: locator),
                clock: clock
            )
        case let .fixture(requests):
            self.init(session: session, store: store, fetcher: nil, pullRequests: nil, fixture: requests, clock: clock)
        }
    }

    /// Takes the fetcher itself, for the tests that script its answers.
    init(
        session: WorkspaceSession,
        store: PRStatusStore,
        fetcher: (any PRStatusLookups)?,
        pullRequests: (any PullRequestReading)? = nil,
        fixture: [ContainerID: PRInfo]? = nil,
        clock: any PRStatusClock = SystemPRStatusClock()
    ) {
        self.session = session
        self.store = store
        self.fetcher = fetcher
        self.pullRequests = pullRequests
        self.fixture = fixture
        self.clock = clock
    }

    // MARK: - Lifecycle

    func start() {
        // A fixture is the whole truth and never reaches a CLI, so
        // nothing is scheduled to refetch it.
        if let requests = fixture {
            for (container, info) in requests {
                store?.update(container: container, info: info)
            }
            return
        }
        isFollowingActivation = true
        scheduleRecurring()
        // start() runs on @MainActor, so the implicit Task isolation
        // is also @MainActor — no need to re-annotate.
        Task { [weak self] in
            await self?.tick(reason: .initial)
        }
    }

    // MARK: - Triggers

    /// The user often comes back to Weir expecting "what I did outside is
    /// reflected" — pushing a PR, merging it on the web, approving a review.
    /// Becoming active is a cheap signal that covers all three. Each
    /// project's lookup is gathered with the others asked for in the next
    /// few seconds, and dropped when the project was looked up within
    /// `repositoryFloor`. A fixture never starts this, so it is never
    /// refetched.
    func appDidBecomeActive() {
        guard isFollowingActivation, let session else { return }
        for project in session.projects {
            requestGathered(project.id, forcing: [])
        }
    }

    /// Wake on a fixed granularity and let each project decide whether it is
    /// due (`isDue`), rather than sleeping for one interval: rows differ, and
    /// a row's interval moves as its request does. A wake looks up only the
    /// projects that are due, so waking often costs no CLI.
    private func scheduleRecurring() {
        recurringTask?.cancel()
        recurringTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
                // `self` is only reached after the sleep so the task
                // does not hold the syncer alive across it.
                guard !Task.isCancelled, let self else { return }
                // A request shown for a branch the checkout has left is
                // wrong, not just old.
                await recheckLeftBranches()
                await tick(reason: .recurring)
            }
        }
    }

    // MARK: - Tick

    private enum Reason: String {
        case initial
        case recurring
    }

    private func tick(reason: Reason) async {
        guard let session, fetcher != nil else { return }
        let now = clock.monotonicNow()
        var attempted = 0
        let projects = session.projects.map(\.id)
        for project in projects {
            if reason == .recurring, !isDue(project, now: now) {
                continue
            }
            // One CLI at a time per tick: the lookup is awaited unless one
            // for the project was already running, which then runs once
            // more instead.
            await requestLookup(project, forcing: [], invalidatesForges: false)
            // Re-check after the await: a canceled task ends the tick
            // rather than going on to the next project.
            guard !Task.isCancelled else { return }
            attempted += 1
        }
        forgetGoneRows()
        log.debug("""
        PR sync (\(reason.rawValue, privacy: .public)): \
        \(attempted, privacy: .public) of \(projects.count, privacy: .public) projects
        """)
    }

    /// Drop what is kept for rows we no longer fetch for, at the end of
    /// every tick. Internal so the tests can run it without a whole tick.
    func forgetGoneRows() {
        guard let session else { return }
        // Rows come and go. Recomputed rather than reusing a tick's
        // snapshot because the tick awaited a CLI per project, and a
        // worktree added in that window would otherwise be pruned the
        // moment it appeared.
        let live = Set(Self.enumerableTargets(session: session).map(\.container))
        let projects = Set(session.projects.map(\.id))
        lastFetchAt = lastFetchAt.filter { live.contains($0.key) }
        lookupTokens = lookupTokens.filter { live.contains($0.key) }
        answeredHeads = answeredHeads.filter { live.contains($0.key) }
        leftBranches = leftBranches.filter { live.contains($0.key) }
        lastLookupAt = lastLookupAt.filter { projects.contains($0.key) }
        lowQuotaProjects.formIntersection(projects)
        store?.prune(keeping: live)
    }

    /// One entry per sidebar row we are willing to fetch for.
    struct Target {
        let container: ContainerID
        let workingDirectory: URL
        /// One of the other worktrees, folded away: a worktree Git
        /// only reported, with no tab in it. Read at most every
        /// `occasionalInterval`, here and by `GitFactsStore`: a repository
        /// whose agents left fifty of them would otherwise run Git fifty
        /// times a cycle for rows nobody looks at. Opening one admits it,
        /// and it is read on the next cycle as any row is.
        var isOccasional = false
    }

    /// The least time between two reads of one of the other worktrees.
    static let occasionalInterval: TimeInterval = 300

    /// Snapshot the rows we fetch for, taken under MainActor.
    ///
    /// Includes each project's own root: `GitSyncCoordinator` keeps
    /// the main checkout out of `project.worktrees` because the
    /// Project row already stands for it, but that checkout has a
    /// branch and can have a request like any other. Leaving it out
    /// would mean the row a single-checkout user works in every day is
    /// the one row that never shows anything.
    ///
    /// Worktree rows drop out when they are missing on disk (nothing
    /// to run in), hidden (the sidebar isn't drawing them), or
    /// user-pinned — those are plain subdirectories with no branch of
    /// their own.
    ///
    /// Static and internal so tests can pin that row set without
    /// standing up a syncer and its six collaborators — same reason
    /// `ForgeResolver.classify` is reachable.
    static func enumerableTargets(session: WorkspaceSession) -> [Target] {
        session.projects.flatMap { targets(of: $0, in: session) }
    }

    /// `project`'s rows among `enumerableTargets`: the worktrees of one
    /// repository, which one lookup answers for.
    static func targets(of project: Project, in session: WorkspaceSession) -> [Target] {
        let main = Target(
            container: .project(project.id),
            workingDirectory: project.rootURL
        )
        let worktrees = project.worktrees
            .filter(isFetchable)
            .map { worktree in
                let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
                return Target(
                    container: container,
                    workingDirectory: worktree.workingDirectory,
                    isOccasional: SidebarSectionRule.isUnopened(
                        admission: worktree.admission,
                        hasTabs: !session.tabs(in: container).isEmpty
                    )
                )
            }
        return [main] + worktrees
    }

    /// Whether a worktree row is one `enumerableTargets` fetches for.
    private static func isFetchable(_ worktree: Worktree) -> Bool {
        !worktree.isMissing && !worktree.isHidden && worktree.origin == .gitWorktree
    }

    /// Where `container` is fetched, while it is a row `enumerableTargets`
    /// fetches for; `nil` once it is not. Looked up directly rather than
    /// by scanning every row, since every answer asks it.
    static func workingDirectory(of container: ContainerID, in session: WorkspaceSession) -> URL? {
        switch container {
        case .loose:
            nil
        case let .project(projectID):
            session.project(projectID)?.rootURL
        case let .worktree(projectID, worktreeID):
            session.worktree(projectID: projectID, worktreeID: worktreeID)
                .flatMap { isFetchable($0) ? $0.workingDirectory : nil }
        }
    }

    /// The branch the row for `container` shows, which an answer has to
    /// have been asked for to be kept (`CheckoutHead.admits`).
    static func head(of container: ContainerID, in session: WorkspaceSession) -> CheckoutHead {
        let branch: String?
        let commit: String?
        switch container {
        case .loose:
            return .unknown
        case let .project(projectID):
            let project = session.project(projectID)
            branch = project.flatMap { CheckoutName.of($0) }
            commit = project?.mainHeadSHA
        case let .worktree(projectID, worktreeID):
            let worktree = session.worktree(projectID: projectID, worktreeID: worktreeID)
            branch = worktree.flatMap { CheckoutName.branch(of: $0) }
            commit = worktree?.gitRef?.headSHA
        }
        if let branch {
            return .branch(branch)
        }
        // A commit with no branch is a detached HEAD; neither is a row Git
        // has not been read for yet.
        return commit.map { $0.isEmpty ? .unknown : .detached } ?? .unknown
    }

    // MARK: - Manual refresh

    /// Refetch one container's project immediately, ignoring the floors
    /// and the gathering. Those exist to absorb *incidental* triggers; a
    /// user picking "Refresh" from the context menu has asked for exactly
    /// one fetch, and silently doing nothing because they refreshed 40
    /// seconds ago would read as the command being broken.
    func refreshNow(container: ContainerID) {
        Task { [weak self] in
            await self?.refresh(container: container)
        }
    }

    /// `refreshNow`, returning once its lookup has answered, or at once
    /// when it joined one already running as that lookup's follow-up.
    func refresh(container: ContainerID) async {
        guard let project = container.projectID else { return }
        // A manual refresh is also the moment to re-read remotes: the user
        // may have just added one, or authenticated a CLI, and this is the
        // only affordance that says "look again" out loud.
        await requestLookup(project, forcing: [container], invalidatesForges: true)
    }

    /// An agent's turn ended in `container`, as a turn is often what opened
    /// or merged the request. Gathered with the other requests of the next
    /// few seconds, and held until `repositoryFloor` has passed rather than
    /// dropped, so a merge right after an earlier lookup is still found. The
    /// forge is not re-read, as nothing says it changed.
    func turnEnded(in container: ContainerID) {
        guard let project = container.projectID else { return }
        requestGathered(project, forcing: [container])
    }

    // MARK: - Gathering

    /// Ask for a lookup of `project` once the requests of the next few
    /// seconds are in (`quietPeriod`, `longestWait`).
    private func requestGathered(_ project: UUID, forcing rows: Set<ContainerID>) {
        let now = clock.monotonicNow()
        if pending[project] != nil {
            pending[project]?.lastAt = now
            pending[project]?.forced.formUnion(rows)
            return
        }
        pending[project] = PendingRequest(firstAt: now, lastAt: now, forced: rows)
        Task { [weak self] in
            await self?.runGathered(project)
        }
    }

    /// Waits out the gathering and the floor of `project`'s request, then
    /// looks it up. Reads the request again after each wait, since more may
    /// have come in.
    private func runGathered(_ project: UUID) async {
        while let request = pending[project] {
            let now = clock.monotonicNow()
            let gathered = min(
                request.lastAt.advanced(by: .seconds(Self.quietPeriod)),
                request.firstAt.advanced(by: .seconds(Self.longestWait))
            )
            let floor = lastLookupAt[project]?.advanced(by: .seconds(Self.repositoryFloor))
            let wakeAt: ContinuousClock.Instant
            if gathered > now {
                wakeAt = gathered
            } else if let floor, floor > now {
                // Coming back to the app asks for what happened elsewhere,
                // and a lookup within the floor already saw it. A turn's end
                // waits instead: its turn may have merged the request after
                // that lookup.
                guard !request.forced.isEmpty else {
                    pending[project] = nil
                    return
                }
                wakeAt = floor
            } else {
                pending[project] = nil
                await requestLookup(project, forcing: request.forced, invalidatesForges: false)
                return
            }
            do {
                try await clock.sleep(for: now.duration(to: wakeAt) / .seconds(1))
            } catch {
                pending[project] = nil
                return
            }
        }
    }

    // MARK: - Lookup

    /// The rows of `project` a lookup asks about: every row, except one of
    /// the other worktrees read within `occasionalInterval` and a finished
    /// request's row read within `finishedInterval`, which go at their own
    /// slower pace, unless `forcing` names them.
    private func rowsToLookUp(_ project: UUID, forcing: Set<ContainerID>, now: ContinuousClock.Instant) -> [Target] {
        guard let session, let model = session.project(project) else { return [] }
        return Self.targets(of: model, in: session).filter { target in
            if forcing.contains(target.container) {
                return true
            }
            guard let last = lastFetchAt[target.container] else { return true }
            let age = last.duration(to: now)
            if target.isOccasional, age < .seconds(Self.occasionalInterval) {
                return false
            }
            if let info = store?.info(for: target.container), info.state != .open, age < .seconds(Self.finishedInterval) {
                return false
            }
            return true
        }
    }

    /// Look `project`'s requests up, or, while a lookup for it is running,
    /// ask that one to run once more when it ends. Requests made while it
    /// runs come to one more lookup, however many there were.
    ///
    /// Returns once the lookups this call ran have answered, follow-ups
    /// included. Each one asks only about rows that are still ones we
    /// fetch for, so a row that went away stops being asked about.
    private func requestLookup(_ project: UUID, forcing: Set<ContainerID>, invalidatesForges: Bool) async {
        // The menu entry shows for a fixture's requests too, and refetches
        // nothing for them: a fixture never reaches a CLI.
        guard let fetcher else { return }
        if inFlight[project] != nil {
            inFlight[project]?.isRequested = true
            inFlight[project]?.forced.formUnion(forcing)
            if invalidatesForges {
                inFlight[project]?.invalidatesForges = true
            }
            return
        }
        inFlight[project] = FollowUp()
        defer { inFlight[project] = nil }
        var forced = forcing
        var isInvalidating = invalidatesForges
        while true {
            let now = clock.monotonicNow()
            let targets = rowsToLookUp(project, forcing: forced, now: now)
            guard !targets.isEmpty else { return }
            let tokens = beginLookup(of: targets, in: project, at: now)
            if isInvalidating {
                await fetcher.invalidate()
            }
            let batch = await fetcher.lookup(targets.map { PRStatusRow(container: $0.container, workingDirectory: $0.workingDirectory) })
            // A canceled task gives no answer and starts nothing more of its
            // own. A follow-up someone else asked for still runs, on a task
            // of its own: the caller that asked has already returned.
            guard !Task.isCancelled else {
                if let followUp = inFlight[project], followUp.isRequested {
                    Task { [weak self] in
                        await self?.requestLookup(project, forcing: followUp.forced, invalidatesForges: followUp.invalidatesForges)
                    }
                }
                return
            }
            publish(batch, of: project, tokens: tokens)
            guard let followUp = inFlight[project], followUp.isRequested else { return }
            forced = followUp.forced
            isInvalidating = followUp.invalidatesForges
            inFlight[project] = FollowUp()
        }
    }

    /// Note a lookup of `targets` starting at `now`, and answer the token of
    /// each row's lookup (`lookupTokens`).
    private func beginLookup(of targets: [Target], in project: UUID, at now: ContinuousClock.Instant) -> [ContainerID: UInt64] {
        var tokens: [ContainerID: UInt64] = [:]
        for target in targets {
            nextLookupToken &+= 1
            tokens[target.container] = nextLookupToken
            lookupTokens[target.container] = nextLookupToken
            lastFetchAt[target.container] = now
        }
        lastLookupAt[project] = now
        return tokens
    }

    /// Keep what `batch` says of the host's quota, and write each row's
    /// answer; a row the batch did not answer keeps what it showed.
    private func publish(_ batch: PRStatusBatch, of project: UUID, tokens: [ContainerID: UInt64]) {
        if let isLow = batch.isQuotaLow {
            if isLow {
                lowQuotaProjects.insert(project)
            } else {
                lowQuotaProjects.remove(project)
            }
        }
        for (container, token) in tokens {
            publish(batch.lookups[container] ?? PRStatusFetcher.Lookup(isAnswered: false), for: container, token: token)
        }
    }

    /// Write `lookup` into the store if it still describes the row: its
    /// lookup is the container's latest, the row is still one we fetch for,
    /// and the row's checkout is on the branch the lookup asked about.
    private func publish(_ lookup: PRStatusFetcher.Lookup, for container: ContainerID, token: UInt64) {
        // No answer keeps what was known (`PRStatusFetcher.Lookup`).
        guard lookup.isAnswered, let session, let store else { return }
        guard lookupTokens[container] == token,
              Self.workingDirectory(of: container, in: session) != nil
        else {
            log.debug("PR lookup answered for a row that is gone; dropped")
            return
        }
        let rowHead = Self.head(of: container, in: session)
        guard rowHead.admits(lookup.head) else {
            log.debug("PR lookup answered for a branch the row does not show; cleared")
            // The checkout and the row disagree on the branch, so whatever
            // the row shows may be the other branch's request. Showing none
            // until an answer agrees offers less, never a second "Create PR"
            // or a "Clean Up Worktree…" for a request of another branch.
            forget(container, in: store)
            leftBranches[container] = rowHead
            return
        }
        store.update(container: container, info: lookup.info, forge: lookup.forge)
        answeredHeads[container] = lookup.head
        leftBranches[container] = nil
    }

    private func forget(_ container: ContainerID, in store: PRStatusStore) {
        answeredHeads[container] = nil
        store.update(container: container, info: nil, forge: nil)
    }

    /// Clear each row whose shown request was answered for a branch the
    /// row no longer shows, and look those rows' projects up again, with
    /// the rows a branch mismatch left waiting (`leftBranches`) whose
    /// branch has moved since.
    ///
    /// A checkout switched to another branch keeps its row and so its
    /// stored request, and its next lookup can be minutes away; until
    /// then the row would show the previous branch's request, number, and
    /// CI. Checked on every wake, since it compares maps and runs the CLI
    /// only for the projects whose rows' branch moved, once per move.
    func recheckLeftBranches() async {
        guard let session, let store, fetcher != nil else { return }
        var due: [UUID: Set<ContainerID>] = [:]
        for (container, answered) in answeredHeads where !Self.head(of: container, in: session).admits(answered) {
            forget(container, in: store)
            if let project = container.projectID {
                due[project, default: []].insert(container)
            }
        }
        for (container, shown) in leftBranches where Self.head(of: container, in: session) != shown {
            leftBranches[container] = nil
            if let project = container.projectID {
                due[project, default: []].insert(container)
            }
        }
        for (project, rows) in due {
            await requestLookup(project, forcing: rows, invalidatesForges: false)
            guard !Task.isCancelled else { return }
        }
    }

    /// Whether a recurring wake looks `project` up: whether any of the rows
    /// a lookup would ask about is due.
    private func isDue(_ project: UUID, now: ContinuousClock.Instant) -> Bool {
        let isQuotaLow = lowQuotaProjects.contains(project)
        return rowsToLookUp(project, forcing: [], now: now).contains { target in
            Self.isDue(
                info: store?.info(for: target.container),
                lastFetch: lastFetchAt[target.container],
                now: now,
                isQuotaLow: isQuotaLow
            )
        }
    }

    /// Whether a recurring wake looks a row up. A lookup a turn's end or
    /// the app's focus started can fall just short of a wake, so half a wake
    /// is forgiven: without it, the row would wait a whole wake more for a
    /// few seconds' difference.
    static func isDue(
        info: PRInfo?,
        lastFetch: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        isQuotaLow: Bool = false
    ) -> Bool {
        guard let interval = recurringInterval(for: info, isQuotaLow: isQuotaLow) else { return false }
        guard let lastFetch else { return true }
        return lastFetch.duration(to: now) >= .seconds(interval - pollInterval / 2)
    }
}
