// TestProcess.swift
// Weir — runs a child for a test or a scenario on the app's own bounded runner, feeding its stdin and answering what it wrote.

import Foundation
@testable import Weir

/// This is the one way a test runs a child and reads what it wrote: `ps`,
/// `pgrep`, `tmux`, a hook, the Hook Helper, a shell.
///
/// Each copy before this waited in its own order, and each order could
/// hang: reading stdout to its end before waiting never reached the
/// timeout while the child held stdout open, and waiting before reading
/// left stderr undrained and then read stdout with no limit at all, which
/// blocks for as long as anything the child started holds the pipe. So we
/// run on `drainAndWait`, which drains both pipes together, ends the child
/// past `timeout` with SIGTERM and then SIGKILL, and stops reading a moment
/// after the child has exited.
///
/// The timeout is on `drainAndWait`'s `ContinuousClock`, which keeps
/// running while the Mac sleeps, unlike the `SuspendingClock` `pollUntil`
/// waits on. We keep it: that choice in `pollUntil` matches the timers of
/// the code under test, and nothing here races one. The children a test
/// runs finish well inside the timeout, so a sleep in the middle of a run
/// at worst ends that child early and fails its caller's expectation; it
/// never makes a run hang. It is also the clock the app's own tmux client
/// (`TmuxCommand`) is ended on, so a test of tmux waits as the app does.
///
/// This file must not import `Testing`: `scripts/validate-review-core.sh`
/// compiles it outside the test target. What a caller asserts about a run
/// (that it exited in time, with which status, or what it said) stays with
/// the caller.
enum TestProcess {
    /// What a run wrote, how it ended, and the status it exited with.
    struct Output {
        let stdout: Data
        let stderr: Data
        let ending: ProcessEnding
        /// The child's exit status, or the signal that ended it: a run ended
        /// at its timeout has been reaped too, so this is that signal.
        let status: Int32
        /// The child's process id, for a test that looks the child up by it
        /// (in `ps` output, say).
        let pid: Int32

        /// What the run wrote to stdout, as UTF-8 text, or empty when the
        /// output is not UTF-8.
        var stdoutText: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }

        /// What the run wrote to stderr, read as `stdoutText` is.
        var stderrText: String {
            String(data: stderr, encoding: .utf8) ?? ""
        }
    }

    /// Runs `executable` with `arguments` and answers what it wrote and how
    /// it ended. Its stdin reads `stdin` when given and is the null device
    /// otherwise. `environment` replaces the test's own when given, so that
    /// `ps`, say, answers in UTC and the C locale. `cwd` is the folder it starts
    /// in, the test runner's own when nil. Throws only when the child cannot
    /// be started, or its stdin cannot be written.
    ///
    /// The stdin is a file, never a pipe we write: a pipe needs a writer
    /// beside the drain, and the run could then return only once that writer
    /// had run on a thread of its own. A test calls this on a thread of
    /// Swift's cooperative pool or on the main thread, which it holds for the
    /// whole run, so the run would wait on a thread the system need not give
    /// while that pool is held. On a CI runner with three cores the whole test
    /// run stopped at the first runs given stdin. A file holds a payload of
    /// any size before the child starts, so nothing waits on the child
    /// reading it, and a child that never reads it, or leaves something
    /// running that holds it, holds nothing of ours.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin input: Data? = nil,
        cwd: URL? = nil,
        timeout: Duration = .seconds(10)
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        let stdout = Pipe.forChildProcess()
        let stderr = Pipe.forChildProcess()
        let stdin = try input.map(stdinFile)
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdin?.close()
        }
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Our copies of the write ends would keep the pipes from ever
        // reaching EOF once the child has exited.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let output = drainAndWait(process, stdout: stdout, stderr: stderr, timeout: timeout)
        return Output(
            stdout: output.stdout,
            stderr: output.stderr,
            ending: output.ending,
            status: process.terminationStatus,
            pid: process.processIdentifier
        )
    }

    /// A handle that reads `data` from its start, on a file that is already
    /// gone from the temporary directory: only the handle, and the child
    /// that inherits it, keep it, so nothing is left behind however the run
    /// ends. It is closed on exec, as `Pipe.forChildProcess()` makes a pipe,
    /// so a child another test starts meanwhile does not inherit it.
    private static func stdinFile(_ data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("weir-stdin-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        return handle
    }
}
