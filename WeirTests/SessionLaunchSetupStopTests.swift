// SessionLaunchSetupStopTests.swift
// Weir — a new session's setup stopped by a skip, a delete, a hidden worktree, or the quit.

import Foundation
import Observation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLaunchSetupStopTests {
    typealias Fixture = SessionLaunchFixture

    @Test func skippingTheSetup_stopsTheRunningStep_andOpensOneShellTab() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, request: Fixture.shell)
            let id = fixture.worktree.id
            try #require(Fixture.isRunning(pid))
            let running = try #require(fixture.store.launches[id])
            guard case .settingUp = running.phase else {
                Issue.record("the setup step did not start")
                return
            }
            fixture.store.retry(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id] == running)
            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            #expect(fixture.tabs.isEmpty, "not before the step has stopped")
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }
            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.count == 1)
            let tab = try #require(fixture.tabs.first)
            #expect(tab.initialCommands.isEmpty)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @MainActor
    private final class TabInsertion {
        var wasStepRunning: Bool?
    }

    @Test func skippingASetupThatIgnoresSIGTERM_addsOneTabAfterTheStepStops() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true)
            try #require(Fixture.isRunning(pid))
            let id = fixture.worktree.id
            let insertion = TabInsertion()
            withObservationTracking {
                _ = fixture.session.tabs
            } onChange: {
                MainActor.assumeIsolated {
                    insertion.wasStepRunning = Fixture.isRunning(pid)
                }
            }

            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id]?.isStoppingSetup == true)
            fixture.store.skipSetup(worktreeID: id, in: fixture.session)

            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !fixture.tabs.isEmpty }

            #expect(insertion.wasStepRunning == false)
            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.count == 1)
        }
    }

    @Test func stoppingASetup_waitsForAChildThatIgnoresSIGTERM_afterItsShellDied() async throws {
        try await withTempDir { dir in
            let leaderFile = dir.appendingPathComponent("leader")
            let childFile = dir.appendingPathComponent("child")
            // The setup shell takes SIGTERM. Its child keeps the ignored signal through exec.
            let command = """
            echo $$ > "\(leaderFile.path)"
            sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 30' sh "\(childFile.path)" &
            wait
            """
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand(command)])
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                Fixture.pid(in: leaderFile) != nil && Fixture.pid(in: childFile) != nil
            }
            let leader = try #require(Fixture.pid(in: leaderFile))
            let child = try #require(Fixture.pid(in: childFile))
            try #require(leader > 1 && child > 1 && leader != child)
            defer {
                if WorktreeSetup.isRunning(group: leader) {
                    kill(-leader, SIGKILL)
                }
            }
            try #require(Fixture.isRunning(leader) && Fixture.isRunning(child))

            let cancellation = Task {
                await fixture.store.cancelSetup(worktreeID: fixture.worktree.id)
                return Fixture.isRunning(child)
            }
            var observedChildWithoutLeader = false
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                observedChildWithoutLeader = !Fixture.isRunning(leader) && Fixture.isRunning(child)
                return observedChildWithoutLeader
            }

            #expect(observedChildWithoutLeader)
            #expect(await cancellation.value == false)
            #expect(!Fixture.isRunning(leader))
            #expect(!Fixture.isRunning(child))
            #expect(fixture.store.launches.isEmpty)
            #expect(fixture.tabs.isEmpty)
        }
    }

    @Test func deletingAWorktreeWhileItsSkippedSetupStops_waitsForTheStep_andStartsNothing() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true)
            let id = fixture.worktree.id

            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            await fixture.store.cancelSetup(worktreeID: id)

            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.isEmpty)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func hidingAWorktree_thenPruningForgetsItsLaunch_andStopsItsStep() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir)
            try #require(Fixture.isRunning(pid))
            let id = fixture.worktree.id
            try #require(fixture.session.visibleWorktreeIDs == [id])
            try #require(fixture.store.launches[id] != nil)

            fixture.session.hideWorktree(projectID: fixture.project.id, worktreeID: id)
            #expect(fixture.session.visibleWorktreeIDs.isEmpty)
            fixture.store.prune(keeping: fixture.session.visibleWorktreeIDs)

            #expect(fixture.store.launches.isEmpty)
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { !Fixture.isRunning(pid) }
            #expect(!Fixture.isRunning(pid))
            #expect(fixture.tabs.isEmpty)
        }
    }

    @Test func deletingTheWorktree_stopsItsSetupFirst() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir)
            // Returns once the step has ended.
            await fixture.store.cancelSetup(worktreeID: fixture.worktree.id)
            #expect(fixture.store.launches.isEmpty)
            #expect(!Fixture.isRunning(pid))
        }
    }

    @Test func cancellingSetupOrSkipping_doesNotChangeAnAlreadyStagedAgent() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let id = fixture.worktree.id
            fixture.begin(SessionLaunchRequest(open: .agent(.claude)))
            let starting = try #require(fixture.store.launches[id])
            try #require(starting.phase == .starting(isLaunched: false))
            try #require(!starting.isStoppingSetup)
            let pane = try #require(starting.paneID)
            let tab = try #require(fixture.session.tab(containing: pane))
            #expect(tab.initialCommands == [pane: "claude"])
            #expect(fixture.tabs.map(\.id) == [tab.id])

            await fixture.store.cancelSetup(worktreeID: id)
            #expect(fixture.store.launches[id] == starting)
            #expect(fixture.tabs.map(\.id) == [tab.id])
            #expect(fixture.session.tab(containing: pane)?.initialCommands == [pane: "claude"])

            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id] == starting)
            #expect(fixture.tabs.map(\.id) == [tab.id])
            #expect(fixture.session.tab(containing: pane)?.initialCommands == [pane: "claude"])
        }
    }

    @Test func cancellingSetup_leavesItsRecordedFailure() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("echo 'setup failed' >&2; exit 3")])
            let id = fixture.worktree.id
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { fixture.store.launches[id]?.failure != nil }
            let failed = try #require(fixture.store.launches[id])
            let failure = try #require(failed.failure)
            #expect(failed.phase == .failed(failure))
            #expect(failure.stage == .setup(stepIndex: 0))
            #expect(failure.logTail == "setup failed")

            await fixture.store.cancelSetup(worktreeID: id)

            #expect(fixture.store.launches[id] == failed)
            #expect(fixture.tabs.isEmpty)
        }
    }

    /// At quit nothing waits for the SIGKILL a cancel schedules seconds
    /// later: Weir would be gone first, and the step would go on in a
    /// worktree no one watches. So the quit sends it before it returns.
    @Test func cancellingAll_endsTheStepWithoutWaitingForItsCancellationEscalation() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true)

            try #require(Fixture.isRunning(pid))
            let clock = ContinuousClock()
            let started = clock.now
            fixture.store.cancelAll()

            // Kernel exit can follow signal delivery. The task's own cancellation escalates
            // after three seconds. WorktreeSetupTests checks the quit signal itself.
            await pollUntil(timeout: .seconds(2), interval: .milliseconds(20)) { !Fixture.isRunning(pid) }
            #expect(!Fixture.isRunning(pid))
            #expect(clock.now - started < .seconds(3))
            #expect(fixture.tabs.isEmpty)
        }
    }
}
