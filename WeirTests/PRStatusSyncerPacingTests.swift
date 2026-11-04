// PRStatusSyncerPacingTests.swift
// Weir — how often the syncer asks the forge, and about which rows.
//
// Every lookup spends the person's forge quota, which all their tokens
// share. These pin that a project's rows go in one lookup, that coming
// back to the app and turn ends are gathered and floored per project, that
// a finished request is asked about at most once an hour, and that the
// polling of running checks stops while the quota runs low. The clock is
// stepped by hand, so nothing here waits on time.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("PRStatusSyncer pacing", .timeLimit(.minutes(1)))
struct PRStatusSyncerPacingTests {
    private let session: WorkspaceSession
    private let project: Project
    private let store = PRStatusStore()
    private let lookups = ScriptedPRStatusLookups()
    private let clock = ManualPRStatusClock()
    private let syncer: PRStatusSyncer
    private let first: ContainerID
    private let second: ContainerID

    init() throws {
        (session, project) = WorkspaceSessionFixture.withProject()
        let one = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let two = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        first = .worktree(projectID: project.id, worktreeID: one.id)
        second = .worktree(projectID: project.id, worktreeID: two.id)
        syncer = PRStatusSyncer(session: session, store: store, fetcher: lookups, clock: clock)
    }

    private var root: ContainerID {
        .project(project.id)
    }

    private static func open(_ checks: PRChecksConclusion = .success) -> PRStatusFetcher.Lookup {
        PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(checks: checks))
    }

    private func waitForLookups(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { await lookups.waitingCount >= count }
        try #require(await lookups.waitingCount == count, sourceLocation: sourceLocation)
    }

    private func waitForSleepers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { clock.sleeperCount == count }
        try #require(clock.sleeperCount == count, sourceLocation: sourceLocation)
    }

    /// Starts the syncer and answers its launch lookup with `lookup`.
    private func start(answering lookup: PRStatusFetcher.Lookup, isQuotaLow: Bool = false) async throws {
        syncer.start()
        try await waitForLookups(1)
        await lookups.answer(lookup, isQuotaLow: isQuotaLow)
        // The launch lookup is over once its answer is in the store; a wake
        // before that would only ask it for a follow-up.
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { store.info(for: root) != nil }
        try #require(store.info(for: root) != nil)
        try await waitForSleepers(1)
    }

    @Test("a project's rows are asked about in one lookup")
    func refresh_asksForEveryRowOfTheProjectAtOnce() async throws {
        async let refresh: Void = syncer.refresh(container: first)
        try await waitForLookups(1)
        #expect(await lookups.asked == [[root, first, second]])
        await lookups.answer(Self.open())
        await refresh
        #expect(store.info(for: second)?.number == 1)
    }

    @Test("turn ends a few seconds apart are gathered into one lookup")
    func turnEnds_closeTogether_areGathered() async throws {
        syncer.turnEnded(in: first)
        try await waitForSleepers(1)
        clock.advance(by: 3)
        syncer.turnEnded(in: second)
        clock.advance(by: 3)
        // The first wait ended, and the second turn's end moved the
        // lookup to five seconds after it.
        try await waitForSleepers(1)
        #expect(await lookups.lookupCount == 0)
        clock.advance(by: 2)
        try await waitForLookups(1)
        #expect(await lookups.asked == [[root, first, second]])
    }

    @Test("turn ends that keep coming are looked up at the longest wait")
    func turnEnds_keepComing_areLookedUpAtTheLongestWait() async throws {
        syncer.turnEnded(in: first)
        try await waitForSleepers(1)
        for _ in 0..<3 {
            clock.advance(by: 4)
            syncer.turnEnded(in: first)
            try await waitForSleepers(1)
        }
        #expect(await lookups.lookupCount == 0)
        clock.advance(by: PRStatusSyncer.longestWait - 12)
        try await waitForLookups(1)
    }

    @Test("coming back to the app within a minute of a project's lookup asks nothing; later it does")
    func activation_withinTheFloor_isDropped() async throws {
        try await start(answering: Self.open())
        syncer.appDidBecomeActive()
        try await waitForSleepers(2)
        clock.advance(by: PRStatusSyncer.quietPeriod)
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { syncer.gatheringProjects.isEmpty }
        #expect(syncer.gatheringProjects.isEmpty)
        #expect(await lookups.lookupCount == 1)

        clock.advance(by: PRStatusSyncer.repositoryFloor)
        syncer.appDidBecomeActive()
        try await waitForSleepers(2)
        clock.advance(by: PRStatusSyncer.quietPeriod)
        try await waitForLookups(1)
        #expect(await lookups.lookupCount == 2)
    }

    @Test("a turn's end within a minute of the project's lookup waits for the minute instead of being dropped")
    func turnEnd_withinTheFloor_waitsForIt() async throws {
        async let refresh: Void = syncer.refresh(container: root)
        try await waitForLookups(1)
        await lookups.answer(Self.open())
        await refresh
        syncer.turnEnded(in: first)
        try await waitForSleepers(1)
        clock.advance(by: PRStatusSyncer.quietPeriod)
        try await waitForSleepers(1)
        #expect(await lookups.lookupCount == 1)
        clock.advance(by: PRStatusSyncer.repositoryFloor - PRStatusSyncer.quietPeriod)
        try await waitForLookups(1)
        #expect(await lookups.lookupCount == 2)
    }

    @Test("a merged request's row goes along at most once an hour, unless its own turn ended")
    func mergedRow_isAskedAboutHourly() async throws {
        async let refresh: Void = syncer.refresh(container: root)
        try await waitForLookups(1)
        let merged = PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(state: .merged))
        await lookups.answer([root: merged, first: Self.open(), second: Self.open()])
        await refresh

        syncer.turnEnded(in: first)
        try await waitForSleepers(1)
        clock.advance(by: PRStatusSyncer.repositoryFloor)
        try await waitForLookups(1)
        #expect(await lookups.asked.last == [first, second])
        await lookups.answer(Self.open())

        clock.advance(by: PRStatusSyncer.finishedInterval)
        syncer.turnEnded(in: first)
        try await waitForSleepers(1)
        clock.advance(by: PRStatusSyncer.quietPeriod)
        try await waitForLookups(1)
        #expect(await lookups.asked.last == [root, first, second])
        await lookups.answer(Self.open())

        // A turn that ended in the merged row's own checkout asks about it
        // however recently it was looked up.
        syncer.turnEnded(in: root)
        try await waitForSleepers(1)
        clock.advance(by: PRStatusSyncer.repositoryFloor)
        try await waitForLookups(1)
        #expect(await lookups.asked.last?.contains(root) == true)
    }

    @Test("running checks are polled every wake, unless the quota runs low", arguments: [false, true])
    func runningChecks_pollEveryWakeUnlessTheQuotaIsLow(isQuotaLow: Bool) async throws {
        try await start(answering: Self.open(.pending), isQuotaLow: isQuotaLow)
        clock.advance(by: 45)
        // The wake either looks the project up, or goes back to sleep.
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) {
            await lookups.waitingCount == 1 || clock.sleeperCount == 1
        }
        #expect(await lookups.waitingCount == (isQuotaLow ? 0 : 1))
        guard isQuotaLow else { return }
        clock.advance(by: 45)
        try await waitForLookups(1)
    }

    @Test("a project whose rows are all finished is not due, and one with checks running is")
    func isDue_followsTheMostPressingRow() {
        let now = Date()
        let merged = PRInfoFixture.make(state: .merged)
        #expect(!PRStatusSyncer.isDue(info: merged, lastFetch: nil, now: now))
        let running = PRInfoFixture.make(checks: .pending)
        #expect(PRStatusSyncer.isDue(info: running, lastFetch: now.addingTimeInterval(-45), now: now))
        #expect(!PRStatusSyncer.isDue(info: running, lastFetch: now.addingTimeInterval(-45), now: now, isQuotaLow: true))
    }
}
