// ProcessDrainTests.swift
// Weir — the shared runner's cap on stdout and its report of an output left unfinished, on real child processes.

import Foundation
import Testing
@testable import Weir

@Suite("Shared process runner")
struct ProcessDrainTests {
    private struct StartedProcess {
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
    }

    private func start(
        _ script: String,
        workingDirectory: URL? = nil
    ) throws -> StartedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = workingDirectory
        let stdout = Pipe.forChildProcess()
        let stderr = Pipe.forChildProcess()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return StartedProcess(process: process, stdout: stdout, stderr: stderr)
    }

    /// Starts `script` under `/bin/sh` with both pipes, and runs it on the
    /// shared runner.
    private func run(
        _ script: String,
        stdoutLimitBytes: Int? = nil,
        timeout: Duration = .seconds(5)
    ) throws -> DrainedOutput {
        let child = try start(script)
        return drainAndWait(child.process, stdout: child.stdout, stderr: child.stderr, timeout: timeout, stdoutLimitBytes: stdoutLimitBytes)
    }

    @Test func aChildWritingPastTheCap_isEnded_andKeepsNoMoreThanTheCap() throws {
        let start = SuspendingClock.now
        // `yes` never stops on its own: only the cap ends it, or else the
        // timeout, 30 seconds.
        let output = try run("exec /usr/bin/yes", stdoutLimitBytes: 4096, timeout: .seconds(30))
        #expect(output.ending == .outputLimit)
        #expect(output.stdout.count <= 4096)
        // `yes` ends on the SIGTERM the cap sends, a fraction of a second.
        // The bound is well short of the timeout and leaves room for a busy
        // CI runner.
        #expect(SuspendingClock.now - start < .seconds(15), "the cap, not the timeout")
    }

    @Test func aChildThatExitedOverTheCap_isStillReportedOverIt() throws {
        let child = try start("printf abcdef")
        // Six bytes fit in the pipe before it is read, so waiting first does not block the writer.
        child.process.waitUntilExit()
        try #require(!child.process.isRunning && child.process.terminationStatus == 0)

        let output = drainAndWait(child.process, stdout: child.stdout, stderr: child.stderr, stdoutLimitBytes: 3)

        #expect(output.ending == .outputLimit)
        #expect(output.stdout.count <= 3)
        #expect(output.isStdoutComplete)
    }

    @Test func outputAtTheCap_isWhole() throws {
        let output = try run("printf abc; printf oops >&2", stdoutLimitBytes: 3)
        #expect(output.ending == .exited)
        #expect(output.isStdoutComplete)
        #expect(String(data: output.stdout, encoding: .utf8) == "abc")
        #expect(String(data: output.stderr, encoding: .utf8) == "oops")
    }

    /// The grandchild holds stdout past its parent's exit. Removing the hold
    /// file releases it permanently, even when the temporary directory is
    /// removed before its next poll. Its own watchdog bounds a broken drain;
    /// a test time limit cannot interrupt the synchronous runner.
    @Test(.timeLimit(.minutes(1)))
    func aGrandchildHoldingStdout_leavesTheOutputUnfinished_afterTheDrainGrace() async throws {
        try await withTempDir { directory in
            let hold = directory.appendingPathComponent("hold")
            let finished = directory.appendingPathComponent("finished")
            try Data().write(to: hold)
            defer { try? FileManager.default.removeItem(at: hold) }
            let timing = ProcessDrainTiming(terminationGrace: .milliseconds(200), drainGrace: .milliseconds(200), pollMilliseconds: 10)
            let script = "(i=0; while [ -e hold ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done; : > finished) & exit 0"
            let child = try start(script, workingDirectory: directory)
            child.process.waitUntilExit()
            try #require(child.process.terminationStatus == 0)

            let clock = ContinuousClock()
            let started = clock.now
            let output = drainAndWait(child.process, stdout: child.stdout, stderr: child.stderr, timing: timing)

            #expect(clock.now - started >= timing.drainGrace)
            #expect(!FileManager.default.fileExists(atPath: finished.path))
            #expect(output.ending == .exited)
            #expect(!output.isStdoutComplete)
            #expect(!output.hasStdoutReadFailed)

            try FileManager.default.removeItem(at: hold)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) {
                FileManager.default.fileExists(atPath: finished.path)
            }
            #expect(FileManager.default.fileExists(atPath: finished.path), "the grandchild left its hold loop")
        }
    }

    /// Both ends are closed on `exec`, so a process another thread starts
    /// holds neither, and the child the pipe is for still writes to it.
    @Test func aPipeForAChild_staysOutOfOtherProcesses_andStillCarriesItsChildsOutput() throws {
        let pipe = Pipe.forChildProcess()
        let readFlags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFD)
        let writeFlags = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETFD)
        try #require(readFlags >= 0 && writeFlags >= 0)
        #expect(readFlags & FD_CLOEXEC != 0)
        #expect(writeFlags & FD_CLOEXEC != 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf abc"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = drainAndWait(process, stdout: pipe, stderr: nil, timeout: .seconds(30))
        #expect(output.stdout == Data("abc".utf8))
        #expect(output.isStdoutComplete)
    }

    /// A long-lived process a test starts must not hold another test's pipe:
    /// that made a Git query running beside it read as timed out on CI.
    @Test(.timeLimit(.minutes(1)))
    func aProcessGroupATestStarts_holdsNoPipeOfTheTestHost() throws {
        // A plain pipe on purpose: its descriptors stay open across `exec`.
        let pipe = Pipe()
        let group = try spawnProcessGroup(["/bin/sleep", "30"])
        defer {
            kill(group, SIGKILL)
            var status: Int32 = 0
            waitpid(group, &status, 0)
        }
        try pipe.fileHandleForWriting.close()
        let readFD = pipe.fileHandleForReading.fileDescriptor
        try #require(fcntl(readFD, F_GETFD) >= 0)
        var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
        try #require(poll(&descriptor, 1, 5000) == 1)
        try #require(descriptor.revents & Int16(POLLHUP) != 0)
        try #require(descriptor.revents & Int16(POLLERR | POLLNVAL) == 0)
        var byte: UInt8 = 0
        #expect(read(readFD, &byte, 1) == 0)
        #expect(ProcessLiveness.isLive(group))
    }
}
