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

    private static func open(_ checks: PRChecksConclusion = .success, number: Int = 1) -> PRStatusFetcher.Lookup {
        PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(number: number, checks: checks))
    }

    private func waitForLookups(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { await lookups.waitingCount >= count }
        try #require(await lookups.waitingCount == count, sourceLocation: sourceLocation)
    }

    private func waitForSleepers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { clock.sleeperCount == count }
        try #require(clock.sleeperCount == count, sourceLocation: sourceLocation)
    }

    private func waitForDeadline(_ deadline: Date, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) { clock.deadlines.contains(deadline) }
        try #require(clock.deadlines.contains(deadline), sourceLocation: sourceLocation)
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
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            async let refresh: Void = syncer.refresh(container: first)
            try await waitForLookups(1)
            #expect(await lookups.asked == [[root, first, second]])
            await lookups.answer(Self.open())
            await refresh
            #expect(store.info(for: second)?.number == 1)
        }
    }

    @Test("turn ends a few seconds apart are gathered into one lookup")
    func turnEnds_closeTogether_areGathered() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
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
    }

    @Test("turn ends that keep coming are looked up at the longest wait")
    func turnEnds_keepComing_areLookedUpAtTheLongestWait() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            let start = clock.now()
            syncer.turnEnded(in: first)
            try await waitForDeadline(start.addingTimeInterval(5))
            for (beforeTurn, deadline) in [(4.0, 9.0), (3, 13), (3, 15)] {
                clock.advance(by: beforeTurn)
                syncer.turnEnded(in: first)
                clock.advance(by: 1)
                try await waitForDeadline(start.addingTimeInterval(deadline))
            }
            clock.advance(by: 1)
            #expect(clock.now() == start.addingTimeInterval(14))
            #expect(clock.deadlines == [start.addingTimeInterval(15)])
            #expect(await lookups.lookupCount == 0)

            clock.advance(by: 1)
            try await waitForLookups(1)
            #expect(await lookups.asked == [[root, first, second]])
            await lookups.answer(Self.open(number: 7))
            await pollUntil { store.info(for: root)?.number == 7 }
            #expect(store.info(for: root)?.number == 7)
        }
    }

    @Test("activation is dropped before the repository floor and accepted at it", arguments: [59.0, 60.0])
    func activation_withinTheFloor_isDropped(gatheredAt: TimeInterval) async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            let initial = clock.now()
            try await start(answering: Self.open())
            clock.advance(by: gatheredAt - 5)
            try await waitForDeadline(clock.now().addingTimeInterval(45))
            #expect(await lookups.lookupCount == 1)

            syncer.appDidBecomeActive()
            try await waitForDeadline(initial.addingTimeInterval(gatheredAt))
            clock.advance(by: 5)
            await pollUntil { syncer.gatheringProjects.isEmpty }
            try #require(syncer.gatheringProjects.isEmpty)
            if gatheredAt < 60 {
                #expect(await lookups.lookupCount == 1)
                #expect(clock.deadlines == [initial.addingTimeInterval(gatheredAt + 40)])
                syncer.appDidBecomeActive()
                try await waitForDeadline(clock.now().addingTimeInterval(5))
                clock.advance(by: 5)
            }

            try await waitForLookups(1)
            #expect(await lookups.asked == [[root, first, second], [root, first, second]])
            await lookups.answer(Self.open(number: 8))
            await pollUntil { store.info(for: root)?.number == 8 }
            #expect(store.info(for: root)?.number == 8)
        }
    }

    @Test("a turn's end waits until the repository floor and forces its own row")
    func turnEnd_withinTheFloor_waitsForIt() async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            let initial = clock.now()
            async let refresh: Void = syncer.refresh(container: root)
            try await waitForLookups(1)
            let merged = PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(state: .merged))
            await lookups.answer([root: Self.open(), first: merged, second: Self.open()])
            await refresh
            #expect(store.info(for: first)?.state == .merged)
            syncer.turnEnded(in: first)
            try await waitForDeadline(initial.addingTimeInterval(5))
            clock.advance(by: 5)
            try await waitForDeadline(initial.addingTimeInterval(60))
            clock.advance(by: 54)
            #expect(await lookups.lookupCount == 1)
            #expect(clock.deadlines == [initial.addingTimeInterval(60)])

            clock.advance(by: 1)
            try await waitForLookups(1)
            #expect(await lookups.asked == [[root, first, second], [root, first, second]])
            await lookups.answer(Self.open(number: 9))
            await pollUntil { store.info(for: first)?.number == 9 }
            #expect(store.info(for: first)?.number == 9)
        }
    }

    @Test("a merged row joins again at one hour, or sooner after its own turn", arguments: [3599.0, 3600.0])
    func mergedRow_isAskedAboutHourly(gatheredAt: TimeInterval) async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            let initial = clock.now()
            async let refresh: Void = syncer.refresh(container: root)
            try await waitForLookups(1)
            let merged = PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(state: .merged))
            await lookups.answer([root: merged, first: Self.open(), second: Self.open()])
            await refresh
            #expect(store.info(for: root)?.state == .merged)

            clock.advance(by: gatheredAt - 5)
            syncer.turnEnded(in: first)
            try await waitForDeadline(initial.addingTimeInterval(gatheredAt))
            clock.advance(by: 5)
            try await waitForLookups(1)
            #expect(await lookups.asked.last == (gatheredAt < 3600 ? [first, second] : [root, first, second]))
            var answer = [first: Self.open(number: 2), second: Self.open()]
            if gatheredAt == 3600 {
                answer[root] = PRStatusFetcher.Lookup(forge: .gitHub, info: PRInfoFixture.make(number: 3, state: .merged))
            }
            await lookups.answer(answer)
            await pollUntil { store.info(for: first)?.number == 2 }
            try #require(store.info(for: first)?.number == 2)
            #expect(store.info(for: root)?.number == (gatheredAt < 3600 ? 1 : 3))
            #expect(store.info(for: root)?.state == .merged)

            // A new lookup below the next hourly boundary still forces the
            // merged checkout when its own turn ends.
            syncer.turnEnded(in: root)
            try await waitForDeadline(clock.now().addingTimeInterval(5))
            clock.advance(by: 5)
            try await waitForDeadline(initial.addingTimeInterval(gatheredAt + 60))
            clock.advance(by: 55)
            try await waitForLookups(1)
            #expect(await lookups.asked.last == [root, first, second])
            #expect(await lookups.lookupCount == 3)
            await lookups.answer(Self.open(number: 4))
            await pollUntil { store.info(for: root)?.number == 4 }
            #expect(store.info(for: root)?.number == 4)
        }
    }

    @Test("running checks are polled every wake, unless the quota runs low", arguments: [false, true])
    func runningChecks_pollEveryWakeUnlessTheQuotaIsLow(isQuotaLow: Bool) async throws {
        try await withPRStatusCleanup(clock: clock, lookups: lookups) {
            try await start(answering: Self.open(.pending), isQuotaLow: isQuotaLow)
            clock.advance(by: 45)
            // The wake either looks the project up, or goes back to sleep.
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(1)) {
                await lookups.waitingCount == 1 || clock.sleeperCount == 1
            }
            guard isQuotaLow else {
                try #require(await lookups.waitingCount == 1)
                return
            }
            try #require(clock.sleeperCount == 1)
            try #require(await lookups.waitingCount == 0)
            clock.advance(by: 45)
            try await waitForLookups(1)
        }
    }

    @Test("a finished row is never due on a recurring wake, and pending checks are due sooner with quota")
    func recurringDuePolicyUsesTheRowsStateAndQuota() {
        let now = Date()
        let merged = PRInfoFixture.make(state: .merged)
        #expect(!PRStatusSyncer.isDue(info: merged, lastFetch: nil, now: now))
        let running = PRInfoFixture.make(checks: .pending)
        #expect(PRStatusSyncer.isDue(info: running, lastFetch: now.addingTimeInterval(-45), now: now))
        #expect(!PRStatusSyncer.isDue(info: running, lastFetch: now.addingTimeInterval(-45), now: now, isQuotaLow: true))
    }
}
