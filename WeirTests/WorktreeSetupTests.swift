// WorktreeSetupTests.swift
// Weir — a worktree's setup commands: run in order in the worktree, stopped at the first failure or on cancel, their log's end kept.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeSetupTests {
    /// The test's own `PATH`: no login shell is started.
    private nonisolated static let path = ProcessInfo.processInfo.environment["PATH"]

    @Test func setupSteps_runInOrder_inTheWorktree_andStopAtTheFirstFailure() async throws {
        try await withTempDir { folder in
            let failure = try await WorktreeSetup.run([
                .shorthand("echo one > order.txt"),
                .shorthand("echo two >> order.txt; printf 'line\\n%.0s' $(seq 1 3000); echo 'the last words' >&2; exit 7"),
                .shorthand("echo three >> order.txt")
            ], in: folder, path: Self.path)
            let order = try String(contentsOf: folder.appendingPathComponent("order.txt"), encoding: .utf8)
            #expect(order == "one\ntwo\n")
            #expect(failure?.offset == 1)
            guard case let .exited(logTail) = failure?.reason else {
                Issue.record("not an exit: \(String(describing: failure))")
                return
            }
            #expect(logTail.hasSuffix("the last words"))
            // Only the end is kept of a long log.
            #expect(logTail.utf8.count <= WorktreeSetup.logTailBytes)
            #expect(try await WorktreeSetup.run([.shorthand("true")], in: folder, path: Self.path) == nil)
        }
    }

    @Test func theLogsEnd_keepsWholeCharacters_andSurvivesBytesThatAreNotUTF8() throws {
        try withTempDir { folder in
            let japanese = folder.appendingPathComponent("ja.log")
            try Data(String(repeating: "あ", count: 3000).utf8).write(to: japanese)
            let tail = WorktreeSetup.tail(of: japanese)
            #expect(!tail.isEmpty)
            #expect(tail.allSatisfy { $0 == "あ" })

            let mixed = folder.appendingPathComponent("mixed.log")
            try (Data("before ".utf8) + Data([0xFF, 0xFE]) + Data(" after".utf8)).write(to: mixed)
            #expect(WorktreeSetup.tail(of: mixed).hasSuffix("after"))
        }
    }

    @Test func aMissingWorktreeRoot_reportsItsPath() async throws {
        try await withTempDir { scratch in
            let missing = scratch.appendingPathComponent("missing-root")
            let failure = try await WorktreeSetup.run([.shorthand("true")], in: missing, path: Self.path)
            #expect(failure?.offset == 0)
            guard case let .exited(logTail) = failure?.reason else {
                Issue.record("Expected a worktree resolution failure")
                return
            }
            #expect(logTail.hasPrefix("\(missing.path): "))
        }
    }

    @Test(arguments: ["../", "inside/.."])
    func aStepWhoseFolderTraversesAParent_stopsTheSetupUnrun(cwd: String) async throws {
        try await withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            // The inside/.. control resolves back to the root, so resolved
            // containment alone would accept it.
            let failure = try await WorktreeSetup.run(
                [.shorthand("touch before.txt"), Self.touch(in: cwd), .shorthand("touch after.txt")],
                in: worktree,
                path: Self.path
            )
            #expect(failure?.offset == 1)
            #expect(failure?.reason == .directoryOutsideWorktree(cwd))
            #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("before.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("ran.txt").path))
            #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("ran.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("after.txt").path))
        }
    }

    /// A worktree with an `inside` folder, and a folder beside it that is
    /// not in it, both under `scratch`.
    private static func worktreeAndOutside(in scratch: URL) throws -> (worktree: URL, outside: URL) {
        let worktree = scratch.appendingPathComponent("worktree")
        let outside = scratch.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent("inside"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("web"),
            withIntermediateDirectories: true
        )
        return (worktree, outside)
    }

    private static func touch(in cwd: String) -> BootstrapItem {
        .detailed(BootstrapDetail(cmd: "touch ran.txt", timeout: nil, cwd: cwd))
    }

    @Test(arguments: [false, true])
    func aStepFolderThatResolvesOutside_stopsTheSetupUnrun(hasAncestorLink: Bool) async throws {
        try await withTempDir { scratch in
            let (worktree, outside) = try Self.worktreeAndOutside(in: scratch)
            let cwd = hasAncestorLink ? "packages/web" : "frontend"
            let link = hasAncestorLink ? "packages" : "frontend"
            let destination = hasAncestorLink ? outside.appendingPathComponent("web") : outside
            try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent(link), withDestinationURL: outside)

            let failure = try await WorktreeSetup.run(
                [Self.touch(in: cwd), .shorthand("touch after.txt")],
                in: worktree,
                path: Self.path
            )

            #expect(failure?.offset == 0)
            #expect(failure?.reason == .directoryOutsideWorktree(cwd))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("ran.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("after.txt").path))
        }
    }

    @Test func aSiblingWhoseNameStartsWithTheWorktrees_isOutsideIt() throws {
        try withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            let sibling = scratch.appendingPathComponent("worktree-other")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: worktree.appendingPathComponent("next"),
                withDestinationURL: sibling
            )
            guard case .outside = WorktreeSetup.stepDirectory("next", in: worktree) else {
                Issue.record("a sibling counted as inside the worktree")
                return
            }
        }
    }

    @Test(arguments: ["inside", "alias"])
    func aStepFolderInsideTheWorktree_runsInTheResolvedFolder(cwd: String) async throws {
        try await withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            try FileManager.default.createSymbolicLink(
                atPath: worktree.appendingPathComponent("alias").path,
                withDestinationPath: "inside"
            )

            #expect(try await WorktreeSetup.run([Self.touch(in: cwd)], in: worktree, path: Self.path) == nil)
            #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("inside/ran.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("ran.txt").path))
        }
    }

    @Test(arguments: ["missing", "dangling"])
    func aStepFolderThatIsMissing_stopsTheSetupUnrun_andSaysWhy(cwd: String) async throws {
        try await withTempDir { scratch in
            let (worktree, _) = try Self.worktreeAndOutside(in: scratch)
            try FileManager.default.createSymbolicLink(
                atPath: worktree.appendingPathComponent("dangling").path,
                withDestinationPath: "nowhere"
            )

            let failure = try await WorktreeSetup.run(
                [Self.touch(in: cwd), .shorthand("touch after.txt")],
                in: worktree,
                path: Self.path
            )

            #expect(failure?.offset == 0)
            guard case let .exited(logTail) = failure?.reason else {
                Issue.record("Expected a step directory resolution failure")
                return
            }
            #expect(logTail.hasPrefix("\(worktree.appendingPathComponent(cwd).path): "))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("ran.txt").path))
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("after.txt").path))
        }
    }

    @Test func aWorktreeReachedThroughALink_stillHoldsItsSubfolder() throws {
        try withTempDir { scratch in
            let (worktree, outside) = try Self.worktreeAndOutside(in: scratch)
            let link = scratch.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: worktree)
            guard case .inside = WorktreeSetup.stepDirectory("inside", in: link) else {
                Issue.record("a subfolder of a linked worktree counted as outside")
                return
            }
            try FileManager.default.createSymbolicLink(
                at: worktree.appendingPathComponent("frontend"),
                withDestinationURL: outside
            )
            guard case .outside = WorktreeSetup.stepDirectory("frontend", in: link) else {
                Issue.record("a link out of a linked worktree counted as inside")
                return
            }
        }
    }

    @Test(arguments: [false, true])
    func cancellingTheSetup_stopsTheLiveStepAndChildren_beforeReturning(ignoresTerm: Bool) async throws {
        try await withTempDir { folder in
            let pidFile = folder.appendingPathComponent("started.pid")
            let command = ignoresTerm
                ? "trap '' TERM; /bin/sleep 30 & printf '%s\\n' \"$!\" > started.pid; wait"
                : "printf '%s\\n' \"$$\" > started.pid; exec /bin/sleep 30"
            let task = Task {
                try await WorktreeSetup.run(
                    [.shorthand(command), .shorthand("touch after.txt")],
                    in: folder,
                    path: Self.path
                )
            }
            defer { task.cancel() }
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty == false
            }
            let text = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            try #require(pid > 0)
            try #require(ProcessLiveness.isLive(pid))
            let group = getpgid(pid)
            try #require(group > 0)
            try #require(group != getpgrp())
            defer {
                if WorktreeSetup.isRunning(group: group) {
                    kill(-group, SIGKILL)
                }
            }
            let started = SuspendingClock.now

            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }

            #expect(!ProcessLiveness.isLive(pid))
            #expect(!WorktreeSetup.isRunning(group: group))
            #expect(SuspendingClock.now - started < .seconds(15), "the cancel must precede the step's natural exit")
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("after.txt").path))
        }
    }

    /// The wait for a stopped step sends SIGKILL itself, rather than
    /// counting on the timer `RunningStep.stop` schedules, which a busy
    /// runner can hold back past any deadline the wait keeps. Here no
    /// timer runs, and no signal is sent before the wait, so only the
    /// wait's SIGKILL ends the group.
    @Test func theWaitForAStoppedStep_killsItsGroup_withoutTheStopsTimer() async throws {
        let group = try spawnProcessGroup(["/bin/sleep", "30"])
        var reaped = false
        defer {
            if !reaped {
                kill(-group, SIGKILL)
                var status: Int32 = 0
                waitpid(group, &status, 0)
            }
        }
        try #require(WorktreeSetup.isRunning(group: group))

        let clock = SuspendingClock()
        let started = clock.now
        await WorktreeSetup.waitForGroup(group)

        #expect(!WorktreeSetup.isRunning(group: group))
        // The step still had its time to end on SIGTERM.
        #expect(clock.now - started >= .seconds(3))
        var status: Int32 = 0
        reaped = waitpid(group, &status, WNOHANG) == group
        try #require(reaped)
        #expect(status & 0x7F == SIGKILL)
    }

    /// Before Weir exits, the quit sends SIGKILL to a step that ignores
    /// SIGTERM. No timer runs here, unlike a cancel's, so a step that ends
    /// was ended by the quit, however long that takes on a busy runner. The
    /// step is on the list once its start returns, with no later call to
    /// put it there.
    @Test func theQuit_killsAStepThatIgnoresSIGTERM_withNoTimerOfItsOwn() async throws {
        try await withTempDir { folder in
            let ready = folder.appendingPathComponent("ready")
            let steps = WorktreeSetup.RunningSteps()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // `exec` keeps the ignored SIGTERM, as a step's children do.
            process.arguments = ["-c", "trap '' TERM; touch \"$1\"; exec sleep 60", "sh", ready.path]
            try #require(try steps.start(process))
            let group = process.processIdentifier
            defer {
                if WorktreeSetup.isRunning(group: group) {
                    kill(-group, SIGKILL)
                }
            }
            // The stop comes once the trap is set, so only SIGKILL can end
            // the step.
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                FileManager.default.fileExists(atPath: ready.path)
            }
            try #require(FileManager.default.fileExists(atPath: ready.path))
            try #require(process.isRunning)
            try #require(WorktreeSetup.isRunning(group: group))

            steps.stopBeforeExit()

            // The synchronous signal can precede Foundation's observation
            // of exit. Inspect the reason once Foundation reaps the child.
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { !process.isRunning }
            try #require(!process.isRunning)
            #expect(process.terminationReason == .uncaughtSignal)
            #expect(process.terminationStatus == SIGKILL)
            #expect(!WorktreeSetup.isRunning(group: group))
        }
    }

    /// A step that reaches its start after the quit stopped the owner's
    /// steps is not started. The quit cancels the setups' tasks, but a
    /// step whose start runs on another thread can be past that check, and
    /// the quit's stop would not know of it: it went on in the worktree
    /// after Weir exited. Here its task is never canceled, so only the
    /// stop can keep it from starting.
    @Test func aStepThatReachesItsStartAfterTheQuit_isNotStarted_andCancelsTheSetup() async throws {
        try await withTempDir { folder in
            let steps = WorktreeSetup.RunningSteps()
            let reached = folder.appendingPathComponent("reached")
            await #expect(throws: CancellationError.self) {
                try await WorktreeSetup.run([.shorthand("touch ran.txt")], in: folder, path: Self.path, steps: steps) { offset in
                    #expect(offset == 0)
                    #expect(FileManager.default.createFile(atPath: reached.path, contents: nil))
                    steps.stopBeforeExit()
                }
            }
            #expect(FileManager.default.fileExists(atPath: reached.path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("ran.txt").path))
        }
    }

    /// Once the quit has stopped the steps, a start starts nothing.
    @Test func aStartAfterTheQuit_startsNoProcess() throws {
        let steps = WorktreeSetup.RunningSteps()
        steps.stopBeforeExit()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]

        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        #expect(try !steps.start(process))
        #expect(!process.isRunning)
        #expect(process.processIdentifier == 0)
    }
}
