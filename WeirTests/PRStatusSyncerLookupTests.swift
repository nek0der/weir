// PRStatusSyncerLookupTests.swift
// Weir — which pull-request answers the syncer keeps when lookups overlap.
//
// The triggers (launch, the recurring tick, coming back to the app, a
// manual refresh) start independently, and a CLI answers in its own time.
// These pin that an answer reaches the store only while it still describes
// the row: the latest lookup of a container that is still there, asked for
// the branch the row shows.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("PRStatusSyncer lookups", .timeLimit(.minutes(1)))
struct PRStatusSyncerLookupTests {
    private let session: WorkspaceSession
    private let project: Project
    private let store = PRStatusStore()
    private let lookups = ScriptedPRStatusLookups()
    private let clock = ManualPRStatusClock()
    private let syncer: PRStatusSyncer

    init() {
        (session, project) = WorkspaceSessionFixture.withProject()
        syncer = PRStatusSyncer(session: session, store: store, fetcher: lookups, clock: clock)
    }

    private var container: ContainerID {
        .project(project.id)
    }

    private func checkOut(_ branch: String) {
        guard let index = session.projects.firstIndex(where: { $0.id == project.id }) else { return }
        session.projects[index].mainBranchName = branch
    }

    private static func answer(
        _ checks: PRChecksConclusion = .success,
        number: Int = 1,
        on head: CheckoutHead = .branch("a")
    ) -> PRStatusFetcher.Lookup {
        PRStatusFetcher.Lookup(
            forge: .gitHub,
            info: PRInfoFixture.make(number: number, checks: checks),
            head: head
        )
    }

    /// Waits for the scripted fetcher to have `count` lookups waiting, or
    /// for the time limit.
    private func waitForLookups(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { await lookups.waitingCount >= count }
        try #require(await lookups.waitingCount == count, sourceLocation: sourceLocation)
    }

    @Test("a refresh while a lookup runs waits for it, and its own answer is the one kept")
    func refresh_duringLookup_laterAnswerWins() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            checkOut("a")
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            await syncer.refresh(container: container)
            // The second request asked no CLI of its own while the first ran.
            #expect(await lookups.lookupCount == 1)
            await lookups.answer(Self.answer(.pending))
            try await waitForLookups(1)
            #expect(store.info(for: container)?.checks?.conclusion == .pending)
            await lookups.answer(Self.answer(.success))
            await first
            #expect(store.info(for: container)?.checks?.conclusion == .success)
            #expect(await lookups.peakRunningCount == 1)
        }
    }

    @Test("a turn's end looks the row up once the gathering ends, without re-reading the forge")
    func aTurnsEnd_looksTheRowUp() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            syncer.turnEnded(in: container)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { clock.sleeperCount == 1 }
            try #require(clock.sleeperCount == 1)
            #expect(await lookups.lookupCount == 0)
            #expect(clock.deadlines == [clock.monotonicNow().advanced(by: .seconds(5))])
            clock.advance(by: 4)
            #expect(await lookups.lookupCount == 0)
            try #require(clock.sleeperCount == 1)
            clock.advance(by: 1)
            try await waitForLookups(1)
            #expect(await lookups.asked == [[container]])
            await lookups.answer(Self.answer(number: 7))
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { store.info(for: container) != nil }
            #expect(store.info(for: container)?.number == 7)
            #expect(await lookups.invalidationCount == 0)
        }
    }

    @Test("two refreshes while a lookup runs ask for one more lookup, not two")
    func refresh_twiceDuringLookup_coalescesToOneFollowUp() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            checkOut("a")
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            await syncer.refresh(container: container)
            await syncer.refresh(container: container)
            await lookups.answer(Self.answer(.pending))
            try await waitForLookups(1)
            await lookups.answer(Self.answer(.success))
            await first
            #expect(await lookups.lookupCount == 2)
            // Each manual lookup re-read the forge, the follow-up included.
            #expect(await lookups.invalidationCount == 2)
        }
    }

    @Test("an answer for the branch the checkout left clears the row instead of showing either branch's request")
    func refresh_branchSwitchedDuringLookup_clearsRow() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            checkOut("a")
            store.update(container: container, info: PRInfoFixture.make(number: 7), forge: .gitHub)
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            checkOut("b")
            await lookups.answer(Self.answer(number: 1, on: .branch("a")))
            await first
            #expect(store.info(for: container) == nil)
            #expect(store.forge(for: container) == nil)
            // Asking again before the row's branch moves would get the same
            // mismatch, so nothing more is launched.
            await syncer.recheckLeftBranches()
            #expect(await lookups.lookupCount == 1)
        }
    }

    @Test("a row whose Git is behind its checkout is asked again only once its branch moves")
    func refresh_branchDisagrees_waitsForRowToMove() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            checkOut("a")
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            await lookups.answer(Self.answer(on: .branch("b")))
            await first
            #expect(store.info(for: container) == nil)
            // Wakes while the row still shows the old branch launch nothing.
            await syncer.recheckLeftBranches()
            await syncer.recheckLeftBranches()
            #expect(await lookups.lookupCount == 1)
            // Git is read again for the row, and the wake asks once more.
            checkOut("b")
            async let wake: Void = syncer.recheckLeftBranches()
            try await waitForLookups(1)
            await lookups.answer(Self.answer(number: 5, on: .branch("b")))
            await wake
            #expect(store.info(for: container)?.number == 5)
        }
    }

    @Test("a switch with no lookup running clears the previous branch's request on the next wake")
    func recheck_branchSwitchedBetweenLookups_clearsAndAsksAgain() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            checkOut("a")
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            await lookups.answer(Self.answer(number: 1, on: .branch("a")))
            await first
            #expect(store.info(for: container)?.number == 1)
            checkOut("b")
            async let wake: Void = syncer.recheckLeftBranches()
            try await waitForLookups(1)
            #expect(store.info(for: container) == nil)
            await lookups.answer(Self.answer(number: 2, on: .branch("b")))
            await wake
            #expect(store.info(for: container)?.number == 2)
        }
    }

    @Test("an answer for the branch the row shows is kept")
    func refresh_sameBranch_keepsAnswer() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            checkOut("b")
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            await lookups.answer(Self.answer(number: 3, on: .branch("b")))
            await first
            #expect(store.info(for: container)?.number == 3)
            #expect(store.forge(for: container) == .gitHub)
        }
    }

    @Test("an answer that lands after the row was pruned does not put it back, and the follow-up leaves the row out")
    func refresh_rowPrunedDuringLookup_doesNotReinsert() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
            let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
            async let first: Void = syncer.refresh(container: row)
            try await waitForLookups(1)
            // A follow-up is asked for, then the row goes away before it runs.
            await syncer.refresh(container: row)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            session.projects[index].worktrees.removeAll { $0.id == worktree.id }
            syncer.forgetGoneRows()
            await lookups.answer(Self.answer())
            try await waitForLookups(1)
            await lookups.answer(Self.answer())
            await first
            #expect(store.info(for: row) == nil)
            #expect(store.forge(for: row) == nil)
            #expect(await lookups.asked == [[container, row], [container]])
        }
    }

    @Test("an answer for a row pruned and brought back while it ran is not kept")
    func refresh_rowPrunedAndRestoredDuringLookup_dropsAnswer() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            var worktree = WorktreeFixture.make()
            worktree.gitRef = GitRef(branchName: "a", headSHA: "abc1234")
            let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            session.projects[index].worktrees.append(worktree)
            async let first: Void = syncer.refresh(container: row)
            try await waitForLookups(1)
            session.projects[index].worktrees.removeAll { $0.id == worktree.id }
            syncer.forgetGoneRows()
            // The same worktree is reported again, under the same identity.
            session.projects[index].worktrees.append(worktree)
            #expect(PRStatusSyncer.head(of: row, in: session) == .branch("a"))
            await lookups.answer(Self.answer())
            await first
            #expect(await lookups.asked == [[container, row]])
            #expect(store.info(for: container)?.number == 1, "the live peer's reply was applied")
            #expect(store.info(for: row) == nil)
            #expect(store.forge(for: row) == nil)
        }
    }

    @Test("a detached row keeps an answer asked for a detached HEAD")
    func refresh_detachedRow_keepsDetachedAnswer() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            let index = try #require(session.projects.firstIndex { $0.id == project.id })
            session.projects[index].mainHeadSHA = "abc1234"
            #expect(PRStatusSyncer.head(of: container, in: session) == .detached)
            async let first: Void = syncer.refresh(container: container)
            try await waitForLookups(1)
            await lookups.answer(PRStatusFetcher.Lookup(forge: .gitHub, head: .detached))
            await first
            #expect(store.forge(for: container) == .gitHub)
        }
    }

    @Test("a worktree row's branch is read from its Git ref")
    func head_worktreeRow_readsGitRef() throws {
        var worktree = WorktreeFixture.make()
        worktree.gitRef = GitRef(branchName: "feature", headSHA: "abc1234")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].worktrees.append(worktree)
        let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        #expect(PRStatusSyncer.head(of: row, in: session) == .branch("feature"))
        session.projects[index].worktrees[0].gitRef = GitRef(headSHA: "abc1234")
        #expect(PRStatusSyncer.head(of: row, in: session) == .detached)
    }

    @Test("the row has an unknown head until Git facts arrive")
    func head_withoutGitFacts_isUnknown() {
        #expect(PRStatusSyncer.head(of: container, in: session) == .unknown)
    }

    @Test("checkout-head policy compares known branches and detached state", arguments: [
        (CheckoutHead.unknown, CheckoutHead.branch("a"), true),
        (.branch("a"), .unknown, true),
        (.branch("a"), .branch("a"), true),
        (.branch("a"), .branch("b"), false),
        (.branch("a"), .detached, false),
        (.detached, .branch("a"), false),
        (.detached, .detached, true)
    ])
    func aRowHeadAdmitsOnlyACompatibleAnswer(row: CheckoutHead, answer: CheckoutHead, admits: Bool) {
        #expect(row.admits(answer) == admits)
    }
}

@MainActor
@Suite("PR status test fixtures", .timeLimit(.minutes(1)))
struct PRStatusTestFixtureTests {
    @Test("canceling one scripted lookup leaves the other waiting for its answer")
    func cancelLookup_onlyReleasesItsOwnRequest() async throws {
        let lookups = ScriptedPRStatusLookups()
        try await withPRStatusCleanup(clock: ManualPRStatusClock(), lookups: lookups) {
            let directory = WorkspaceSessionFixture.projectRootURL("pr-status-lookups")
            let keptRow = PRStatusRow(container: .project(UUID()), workingDirectory: directory)
            let canceledRow = PRStatusRow(container: .project(UUID()), workingDirectory: directory)
            var keptBatch: PRStatusBatch?
            var canceledBatch: PRStatusBatch?
            let kept = Task { keptBatch = await lookups.lookup([keptRow]) }
            defer { kept.cancel() }
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { await lookups.waitingCount == 1 }
            try #require(await lookups.waitingCount == 1)
            let canceled = Task { canceledBatch = await lookups.lookup([canceledRow]) }
            defer { canceled.cancel() }
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { await lookups.waitingCount == 2 }
            try #require(await lookups.waitingCount == 2)

            canceled.cancel()
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { canceledBatch != nil }
            let batch = try #require(canceledBatch)
            #expect(batch.lookups.isEmpty)
            #expect(batch.isQuotaLow == nil)
            try #require(await lookups.waitingCount == 1)

            let answer = PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(number: 17))
            await lookups.answer(answer)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { keptBatch != nil }
            #expect(keptBatch?.lookups == [keptRow.container: answer])
        }
    }

    @Test("finishing the scripted fetcher releases a pending lookup and one that registers later")
    func finishLookups_releasesPendingAndFutureRequests() async throws {
        let lookups = ScriptedPRStatusLookups()
        try await withPRStatusCleanup(clock: ManualPRStatusClock(), lookups: lookups) {
            let row = PRStatusRow(
                container: .project(UUID()),
                workingDirectory: WorkspaceSessionFixture.projectRootURL("pr-status-lookups")
            )
            var batches: [PRStatusBatch] = []
            let pending = Task {
                let batch = await lookups.lookup([row])
                batches.append(batch)
            }
            defer { pending.cancel() }
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { await lookups.waitingCount == 1 }
            try #require(await lookups.waitingCount == 1)

            await lookups.finish()
            let future = Task {
                let batch = await lookups.lookup([row])
                batches.append(batch)
            }
            defer { future.cancel() }
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { batches.count == 2 }
            try #require(batches.count == 2)
            #expect(batches.allSatisfy { $0.lookups.isEmpty && $0.isQuotaLow == nil })
            #expect(await lookups.waitingCount == 0)
        }
    }

    @Test("finishing the manual clock cancels a pending sleep and one that registers later")
    func finishClock_cancelsPendingAndFutureSleeps() async throws {
        let clock = ManualPRStatusClock()
        defer { clock.finish() }
        var canceledCount = 0
        let sleep: @MainActor () async throws -> Void = {
            do {
                try await clock.sleep(for: 45)
            } catch is CancellationError {
                canceledCount += 1
            }
        }
        let pending = Task { try await sleep() }
        defer { pending.cancel() }
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { clock.sleeperCount == 1 }
        try #require(clock.sleeperCount == 1)

        clock.finish()
        let future = Task { try await sleep() }
        defer { future.cancel() }
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { canceledCount == 2 }
        #expect(canceledCount == 2)
        #expect(clock.sleeperCount == 0)
    }
}
