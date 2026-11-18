// TmuxCommandTests.swift
// Weir — real child processes pin timeout, pipe, and cancellation contracts.

import Foundation
import Testing
@testable import Weir

@Suite("Bounded tmux command")
struct TmuxCommandTests {
    @Test func exitStatusAndLaunchFailure_areToldApart_andEmptyOutputIsSuccess() {
        // A timeout no run here reaches. Under the half-second default, one
        // local run reported `/usr/bin/true` as `.timedOut`, most likely
        // because a loaded machine started it late; the timeout is not what
        // this test is about.
        #expect(TmuxCommand().run(executable: "/usr/bin/true", arguments: [], timeout: 30) == .success(""))
        #expect(TmuxCommand().run(executable: "/usr/bin/false", arguments: [], timeout: 30) == .failed(1))
        #expect(TmuxCommand().run(executable: "/nonexistent/weir-tmux", arguments: [], timeout: 30) == .launchFailed)
    }

    @Test func ignoredTermination_isKilledWithinTotalDeadline() throws {
        try withTempDir { folder in
            let armed = folder.appendingPathComponent("ignores-term")
            let start = ProcessInfo.processInfo.systemUptime
            let result = TmuxCommand().run(
                executable: "/bin/sh",
                arguments: ["-c", #"trap '' TERM; : > "$1"; exec /bin/sleep 60"#, "sh", armed.path],
                timeout: 10
            )
            // The marker is written once the trap is set. The timeout leaves a
            // loaded runner ample time for that, so the SIGTERM meets a client
            // that ignores it and only the SIGKILL after the grace ends it.
            #expect(FileManager.default.fileExists(atPath: armed.path))
            #expect(result == .timedOut)
            // The 10-second timeout and the 0.2-second grace, well short of the
            // 60 seconds the client sleeps.
            #expect(ProcessInfo.processInfo.systemUptime - start < 40)
        }
    }

    @Test func descendantHoldingWriter_doesNotKeepReaderAlive() throws {
        try withTempDir { folder in
            let descendant = folder.appendingPathComponent("descendant.pid")
            defer { killRecordedProcess(in: descendant) }
            let start = ProcessInfo.processInfo.systemUptime
            // The fixture descendant exits independently; the runner owns only
            // its client and must not signal arbitrary descendant processes.
            let result = TmuxCommand().run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 60 & echo $! > \"$1\"; exit 0", "sh", descendant.path],
                timeout: 30
            )
            #expect(FileManager.default.fileExists(atPath: descendant.path))
            #expect(result == .timedOut)
            // The exit and the 0.2-second drain grace. The 20-second bound
            // leaves room for a busy CI runner and catches a regression that
            // waits for the descendant, which holds the pipe for 60 seconds, to
            // exit on its own.
            #expect(ProcessInfo.processInfo.systemUptime - start < 20, "the drain grace, not the descendant's own end")
        }
    }

    @Test func cancellationBeforeAndAfterLaunch_returnsCanceled() async throws {
        let canceled = TmuxCommand()
        canceled.cancel()
        #expect(canceled.run(executable: "/usr/bin/true", arguments: []) == .canceled)

        try await withTempDir { folder in
            let marker = folder.appendingPathComponent("started")
            let command = TmuxCommand()
            let run = Task.detached {
                command.run(
                    executable: "/bin/sh",
                    arguments: ["-c", #": > "$1"; exec /bin/sleep 30"#, "sh", marker.path],
                    timeout: 30
                )
            }
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(10)) {
                FileManager.default.fileExists(atPath: marker.path)
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            command.cancel()
            #expect(await run.value == .canceled)
        }
    }

    @Test func outputLimitAndInvalidEncoding_areNotPartialSuccess() {
        // A timeout no run here reaches, as in the first test: the half-second
        // default could report a late start as `.timedOut`.
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["abc"], timeout: 30, outputLimit: 3) == .success("abc"))
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["abcdef"], timeout: 30, outputLimit: 3) == .outputLimit)
        #expect(TmuxCommand().run(executable: "/usr/bin/printf", arguments: ["\\377"], timeout: 30) == .invalidOutput)
    }
}
