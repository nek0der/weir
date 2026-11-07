// TmuxClientProbeTests.swift
// Weir — pins how we read a pane's tmux binding out of
// `tmux list-clients`. The parsing tests fix the contract; the smoke
// test asks a real tmux whether we read it correctly, because the
// format string is the part no unit test can validate.

import Darwin
import Foundation
import Testing
@testable import Weir

/// The tmux the app would run, found where the app looks for one.
private let installedTmux = TmuxClientProbe.locateTmux(candidates: TmuxClientProbe.tmuxCandidates)

/// The Unix epoch second `pid` started, read the way a run's hook reads its
/// tmux server's (`ps -o lstart=` in UTC and the C locale, `process.rs`), as
/// text; empty when `ps` says nothing.
private func psStartSecond(of pid: pid_t) -> String {
    guard let output = try? TestProcess.run(
        URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-p", String(pid), "-o", "lstart="],
        environment: ["LC_ALL": "C", "TZ": "UTC"]
    ), output.ending == .exited else { return "" }
    let text = output.stdoutText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter.date(from: text).map { String(Int($0.timeIntervalSince1970)) } ?? ""
}

@Suite("TmuxClientProbe parsing")
struct TmuxClientProbeParsingTests {
    @Test(arguments: ["", ".", "../socket", "relative/socket", "/tmp/socket\u{0}suffix"])
    func socketIdentity_invalidPaths_areRejected(path: String) {
        #expect(TmuxSocketPath(path) == nil)
    }

    @Test("dot-dot follows symlink semantics instead of lexical URL shortening")
    func socketIdentity_symlinkThenParent_matchesPhysicalParent() throws {
        try withTempDir { directory in
            let nested = directory.appendingPathComponent("physical/child")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
            let aliased = try #require(TmuxSocketPath(alias.path + "/../socket"))
            let physical = try #require(TmuxSocketPath(directory.path + "/physical/socket"))
            #expect(aliased == physical)
            let physicalRoot = try #require(realpath(directory.path, nil))
            defer { free(physicalRoot) }
            #expect(aliased.value == String(cString: physicalRoot) + "/physical/socket")
        }
    }

    @Test("custom symlinked directories and their physical paths identify one socket")
    func normalizeSocketPath_customSymlinkAndMissingLeaf_areStable() throws {
        try withTempDir { directory in
            let physical = directory.appendingPathComponent("physical")
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
            let physicalPath = physical.appendingPathComponent("socket, with spaces").path
            let aliasPath = alias.appendingPathComponent("socket, with spaces").path
            let root = try #require(realpath(directory.path, nil))
            defer { free(root) }
            let expected = String(cString: root) + "/physical/socket, with spaces"
            let before = TmuxClientProbe.normalizeSocketPath(aliasPath)
            #expect(before == expected)
            try #require(FileManager.default.createFile(atPath: physicalPath, contents: Data()))
            #expect(TmuxClientProbe.normalizeSocketPath(aliasPath) == expected)
            var repeated = expected
            for _ in 0..<5 {
                repeated = TmuxClientProbe.normalizeSocketPath(repeated)
                #expect(repeated == expected)
            }
            try FileManager.default.removeItem(atPath: physicalPath)
            #expect(TmuxClientProbe.normalizeSocketPath(aliasPath) == before)
        }
    }

    @Test("normalizes the macOS /tmp symlink used by tmux")
    func normalizeSocketPath_tmpAndPrivateTmpMatch() {
        #expect(
            TmuxClientProbe.normalizeSocketPath("/tmp/tmux-501/default")
                == TmuxClientProbe.normalizeSocketPath("/private/tmp/tmux-501/default")
        )
    }

    private static let socketPath = "/tmp/tmux-501/default"

    private static func binding(_ id: String, _ name: String) -> TmuxBinding {
        TmuxBinding(socketPath: socketPath, sessionID: id, sessionName: name)
    }

    @Test(arguments: [
        ("/dev/ttys016\t$0\tprobe\n", ["/dev/ttys016": binding("$0", "probe")]),
        ("/dev/ttys1\t$3\tmy work session\n", ["/dev/ttys1": binding("$3", "my work session")]),
        ("/dev/ttys1\t$0\ta\n/dev/ttys2\t$1\tb\n", [
            "/dev/ttys1": binding("$0", "a"), "/dev/ttys2": binding("$1", "b")
        ]),
        ("\nnot-a-record\n/dev/ttys1\t$0\tok\n\n", ["/dev/ttys1": binding("$0", "ok")]),
        ("", [:])
    ])
    func parseClients_returnsExactBindings(output: String, expected: [String: TmuxBinding]) {
        #expect(TmuxClientProbe.parseClients(output, socketPath: Self.socketPath) == expected)
    }

    @Test("reads a live process's start as the second ps reports")
    func processStartSecond_isTheSecondPSReports() throws {
        let pid = getpid()
        let start = try #require(TmuxClientProbe.processStartSecond(of: pid))
        #expect(start == psStartSecond(of: pid))
        #expect(TmuxClientProbe.processStartSecond(of: -1) == nil)
    }

}

@Suite("TmuxClientProbe server directory")
struct TmuxClientProbeServerDirectoryTests {
    @Test(arguments: [
        (String?.none, "/tmp/tmux-42"), ("", "/tmp/tmux-42"), ("/var/folders/x", "/var/folders/x/tmux-42")
    ])
    func defaultServerDirectory_usesOnlyANonemptyOverride(override: String?, expected: String) {
        let environment = override.map { ["TMUX_TMPDIR": $0] } ?? [:]
        #expect(TmuxClientProbe.defaultServerDirectory(environment: environment, uid: 42).path == expected)
    }

}

@Suite("TmuxClientProbe socket discovery")
struct TmuxClientProbeSocketTests {
    @Test func socketPaths_serverDirectory_listsVisibleEntriesBeforeValidation() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent("tmux-501", isDirectory: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("folder"), withIntermediateDirectories: true)
            for name in ["default", "stale", ".hidden"] {
                try Data().write(to: home.appendingPathComponent(name))
            }
            let found = TmuxClientProbe.socketPaths(inServerDirectory: home).map(\.lastPathComponent).sorted()
            #expect(found == ["default", "folder", "stale"])
        }
    }

    @Test func attachedClients_noServerDirectory_neverStartsTmux() throws {
        try withTempDir { directory in
            let tmux = directory.appendingPathComponent("tmux")
            try ShimHarness.writeExecutable("#!/bin/sh\n: > \"$0.invoked\"\n", at: tmux)
            let absent = directory.appendingPathComponent("absent")
            #expect(TmuxClientProbe.attachedClients(tmuxPath: tmux.path, serverDirectory: absent).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: tmux.path + ".invoked"))
        }
    }

    @Test("is empty when the user has never started a server")
    func socketPaths_missingDirectory_isEmpty() throws {
        try withTempDir { dir in
            let absent = dir.appendingPathComponent("tmux-501", isDirectory: true)
            #expect(TmuxClientProbe.socketPaths(inServerDirectory: absent).isEmpty)
        }
    }
}

/// Serialized: each case fills most of a pass's budget with slow calls,
/// and two at once would slow each other's past what the timings assume.
@Suite("TmuxClientProbe poll budget", .serialized)
struct TmuxClientProbeBudgetTests {
    /// More servers than one pass's budget reaches, each answering slowly
    /// but within its own timeout: the server the budget ran out on is left
    /// unvisited for the next pass to start with, not recorded as having
    /// timed out, which would drop what the last pass heard from it.
    @Test(.timeLimit(.minutes(1)))
    func serverTheBudgetRunsOutOn_isLeftForTheNextPass() throws {
        let folder = try makeSlowServers()
        defer { try? FileManager.default.removeItem(atPath: folder.path) }

        let batch = TmuxClientProbe.probe(tmuxPath: folder.tmux, paths: Set(folder.sockets), timeout: Self.callTimeout)
        let sockets = folder.sockets.sorted()
        let answered = Set(batch.snapshot.outcomes.keys)
        try #require(!answered.isEmpty && answered.count < sockets.count)
        #expect(answered == Set(sockets.prefix(answered.count)))
        #expect(batch.snapshot.outcomes.values.allSatisfy { $0 == .failed(1) })
        #expect(Set(batch.snapshot.observedAt.keys) == answered)
        #expect(batch.nextCursor == answered.count)
        let calls = try folder.calls()
        #expect(calls == Array(sockets.prefix(calls.count)))
        #expect((answered.count...(answered.count + 1)).contains(calls.count))

        try Data().write(to: folder.log)
        _ = TmuxClientProbe.probe(
            tmuxPath: folder.tmux, paths: Set(sockets), cursor: batch.nextCursor, timeout: Self.callTimeout
        )
        #expect(try folder.calls().first == sockets[answered.count])
    }

    /// A server that answered last time is asked on every pass, even when
    /// the turns of the others would not reach it within the budget, and
    /// the server whose turn it is is asked before it, so the turns move on
    /// however long the answering servers take.
    @Test(.timeLimit(.minutes(1)))
    func serverThatAnsweredLastTime_isAskedEveryPass_afterTheOneWhoseTurnItIs() throws {
        let folder = try makeSlowServers(hasLiveServer: true)
        defer { try? FileManager.default.removeItem(atPath: folder.path) }
        let live = try #require(folder.live)
        let turns = folder.sockets.filter { $0 != live }.sorted()
        let previous = TmuxClientProbe.probe(tmuxPath: folder.tmux, paths: [live], timeout: Self.callTimeout)
        try #require(previous.snapshot.outcomes == [live: .success("")])
        try Data().write(to: folder.log)

        let batch = TmuxClientProbe.probe(
            tmuxPath: folder.tmux, paths: Set(folder.sockets),
            answering: Set(previous.snapshot.outcomes.keys), cursor: 3, timeout: Self.callTimeout
        )

        #expect(batch.snapshot.outcomes[live] == .success(""))
        #expect(batch.snapshot.outcomes[turns[3]] == .failed(1))
        let calls = try folder.calls()
        #expect(calls.prefix(4) == [turns[3], live, live, live])
        let others = batch.snapshot.outcomes.keys.filter { $0 != live }
        #expect(batch.nextCursor == (3 + others.count) % turns.count)
    }

    /// What each call is given: five times what the stand-in takes, so a
    /// loaded machine does not make a call time out on its own.
    private static let callTimeout: TimeInterval = 1

    /// A folder of socket files and the tmux stand-in that answers for them.
    private struct SlowServers {
        let path: String
        let tmux: String
        let sockets: [String]
        let live: String?

        var log: URL {
            URL(fileURLWithPath: tmux + ".calls")
        }

        func calls() throws -> [String] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        }
    }

    /// Sixteen socket files whose tmux takes 0.2 s a call and finds no
    /// server: more than one pass can afford for all of them.
    private func makeSlowServers(hasLiveServer: Bool = false) throws -> SlowServers {
        let folder = "/private/tmp/weir-budget-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        do {
            let tmux = "\(folder)/tmux"
            let script = """
            #!/bin/sh
            printf '%s\\n' "$3" >> "$0.calls"
            if [ "${3##*/}" = live ]; then
                case "$4" in
                    list-panes) printf '%s\\t123\\t$0\\t@0\\t%%0\\t1\\t1\\n' \(getpid()) ;;
                    list-clients) ;;
                    display-message) printf '%s\\t123\\n' \(getpid()) ;;
                    *) exit 2 ;;
                esac
                exit 0
            fi
            /bin/sleep 0.2
            exit 1
            """
            try ShimHarness.writeExecutable(script, at: URL(fileURLWithPath: tmux))
            let live = hasLiveServer ? "\(folder)/live" : nil
            var sockets = (0..<16).map { "\(folder)/s\($0)" }
            if let live {
                sockets.append(live)
            }
            for path in sockets {
                try bindSocket(at: path)
            }
            return SlowServers(path: folder, tmux: tmux, sockets: sockets, live: live)
        } catch {
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
    }

    /// A Unix socket file at `path`, which is all `probe` checks before it
    /// asks tmux; nothing listens on it.
    private func bindSocket(at path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)
    }
}

@Suite("TmuxClientProbe tmux discovery")
struct TmuxClientProbeLocateTests {
    /// Existence is not the bar. A `tmux` we cannot execute — a
    /// Homebrew install mid-upgrade, a path the sandbox denies — would
    /// make every probe fail at spawn time instead of being skipped for
    /// the next candidate.
    @Test("skips a candidate that exists but cannot be executed")
    func locateTmux_nonExecutableCandidate_isSkipped() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("missing").path
            let unrunnable = dir.appendingPathComponent("not-runnable")
            let first = dir.appendingPathComponent("first")
            let second = dir.appendingPathComponent("second")
            try #require(FileManager.default.createFile(
                atPath: unrunnable.path, contents: Data(), attributes: [.posixPermissions: 0o644]
            ))
            for candidate in [first, second] {
                try ShimHarness.writeExecutable("#!/bin/sh\n", at: candidate)
            }
            #expect(TmuxClientProbe.locateTmux(candidates: [missing, unrunnable.path, first.path, second.path]) == first.path)
        }
    }

    /// The user has no tmux, which is the common case; nothing to probe
    /// and nothing to record.
    @Test("is nil when no candidate exists")
    func locateTmux_notInstalled_isNil() {
        #expect(TmuxClientProbe.locateTmux(candidates: ["/nonexistent/tmux"]) == nil)
    }
}

/// CI sets `TEST_RUNNER_WEIR_REQUIRE_TMUX_TESTS`, which xcodebuild hands the
/// test process as `WEIR_REQUIRE_TMUX_TESTS`, like the case-folding one.
@Suite(
    "TmuxClientProbe smoke",
    .tags(.smoke),
    .disabled(if: installedTmux == nil && ProcessInfo.processInfo.environment["WEIR_REQUIRE_TMUX_TESTS"] != "1", "no tmux installed")
)
struct TmuxClientProbeSmokeTests {
    @Test("an unresponsive real server cannot block a later probe")
    func stoppedServer_returnsWithinDeadlineAndRecovers() async throws {
        let tmux = try #require(installedTmux)
        let socket = "/private/tmp/weir-deadline-\(UUID().uuidString.prefix(8)).sock"
        _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "deadline", "sleep 30"])
        defer { stopServer(tmux, socket: socket) }
        let raw = try run(tmux, ["-S", socket, "display-message", "-p", "#{pid}\t#{pane_id}"])
        let fields = raw.split(separator: "\t")
        try #require(fields.count == 2)
        let pid = try #require(Int32(fields[0]))
        let rescue = DispatchWorkItem { @Sendable in kill(pid, SIGCONT) }
        defer {
            rescue.cancel()
            kill(pid, SIGCONT)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: rescue)
        try #require(kill(pid, SIGSTOP) == 0)
        func isStopped() -> Bool {
            let result = try? TestProcess.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-p", String(pid), "-o", "state="])
            return result?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T") == true
        }
        await pollUntil(timeout: .seconds(2), interval: .milliseconds(20)) { isStopped() }
        try #require(isStopped())
        let start = ProcessInfo.processInfo.systemUptime
        let stopped = TmuxClientProbe.topology(tmuxPath: tmux, socketPaths: [URL(fileURLWithPath: socket)], timeout: 0.1)
        // The 0.1-second timeout and the grace after it, against the 30
        // seconds until the rescue resumes the server. The bound is well
        // short of that and leaves room for a busy CI runner.
        #expect(ProcessInfo.processInfo.systemUptime - start < 10, "the deadline, not the rescue")
        #expect(stopped.outcomes[socket] == .timedOut)
        try #require(kill(pid, SIGCONT) == 0)
        let recovered = TmuxClientProbe.topology(tmuxPath: tmux, socketPaths: [URL(fileURLWithPath: socket)])
        #expect(recovered.outcomes == [socket: .success("")])
        #expect(recovered.panes.map(\.serverPID) == [String(pid)])
        #expect(recovered.panes.map(\.paneID) == [String(fields[1])])
    }

    @Test("a real socket survives discovery, parsing, and endpoint matching")
    func topology_realSocket_roundTripsThroughEveryBoundary() throws {
        let tmux = try #require(installedTmux)
        let socket = "/private/tmp/weir-runtime-\(UUID().uuidString.prefix(8)).sock"
        defer { stopServer(tmux, socket: socket) }
        _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "runtime", "sleep 120"])
        let raw = try run(tmux, ["-S", socket, "display-message", "-p", "#{pid}\t#{pane_id}"])
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        try #require(fields.count == 2)
        let pid = try #require(pid_t(fields[0]))
        let recordedStart = psStartSecond(of: pid)
        try #require(Int64(recordedStart) != nil)
        let alias = String(socket.dropFirst("/private".count))
        let endpoint = TmuxRuntimeEndpoint(socketPath: alias, serverPID: fields[0], serverStartedAt: recordedStart, paneID: fields[1])
        let snapshot = TmuxClientProbe.topology(tmuxPath: tmux, socketPaths: [socket, alias].map { URL(fileURLWithPath: $0) })
        let pane = try #require(snapshot.panes.first)
        #expect(snapshot.outcomes == [socket: .success("")])
        #expect(pane.socketPath == socket)
        #expect(pane.serverProcessStartedAt == recordedStart)
        #expect(pane.paneID == fields[1])
        #expect(snapshot.locations(for: endpoint) == [pane])
    }

    /// An app opened from Finder or the Dock has no locale, where tmux
    /// prints a format's tabs as `_`. The test host's locale can hide that,
    /// so we set the C locale on the client ourselves.
    @Test("a real tmux keeps a format's tabs with no UTF-8 locale")
    func clientArguments_cLocale_keepsTheFieldsParseable() throws {
        let tmux = try #require(installedTmux)
        try withShortTempDir { dir in
            let socket = dir.appendingPathComponent("s").path
            defer { stopServer(tmux, socket: socket) }
            _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "locale", "sleep 120"])
            let output = try TestProcess.run(
                URL(fileURLWithPath: tmux),
                arguments: TmuxClientProbe.clientArguments(socketPath: socket) + TmuxTopology.paneArguments,
                environment: ["LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C"]
            )
            try #require(output.ending == .exited && output.status == 0, "\(output.stderrText)")
            let paneID = try run(tmux, ["-S", socket, "display-message", "-p", "#{pane_id}"])
            let sessionID = try run(tmux, ["-S", socket, "display-message", "-p", "#{session_id}"])
            let panes = TmuxTopology.parsePanes(output.stdoutText, socketPath: socket)
            #expect(panes.map(\.paneID) == [paneID])
            #expect(panes.map(\.sessionID) == [sessionID])
        }
    }

    /// The end-to-end read used on quit, with a real attached client.
    @Test func attachedClients_runningServer_findsTheExactBinding() async throws {
        let tmux = try #require(installedTmux)
        try await withShortTempDir { dir in
            let socket = dir.appendingPathComponent("default").path
            defer { stopServer(tmux, socket: socket) }
            let session = "work session"
            _ = try run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", session, "sleep 120"])
            let client = try attachClient(tmux: tmux, socket: socket, session: session)
            defer {
                try? (client.standardInput as? Pipe)?.fileHandleForWriting.close()
                _ = client.waitUntilExit(within: 1)
            }
            func clientTTY() -> String? {
                try? run(tmux, ["-S", socket, "list-clients", "-F", "#{client_tty}"])
            }
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(100)) {
                clientTTY()?.hasPrefix("/dev/") == true
            }
            let tty = try #require(clientTTY())
            try #require(tty.hasPrefix("/dev/"))
            let id = try run(tmux, ["-S", socket, "display-message", "-p", "-t", session, "#{session_id}"])
            let path = try #require(realpath(socket, nil))
            defer { free(path) }
            let expected = TmuxBinding(socketPath: String(cString: path), sessionID: id, sessionName: session)
            #expect(TmuxClientProbe.attachedClients(tmuxPath: tmux, serverDirectory: dir) == [tty: expected])
        }
    }

    /// A client needs stdin held open, or it reads EOF and detaches at
    /// once, and a `TERM`, without which `attach` exits with "open
    /// terminal failed" and the server is left with no clients at all.
    private func attachClient(tmux: String, socket: String, session: String) throws -> Process {
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        client.arguments = ["-q", "/dev/null", tmux, "-S", socket, "attach", "-t", session]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TMUX"] = nil
        client.environment = environment
        client.standardInput = Pipe()
        client.standardOutput = FileHandle.nullDevice
        client.standardError = FileHandle.nullDevice
        try client.run()
        return client
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let output = try TestProcess.run(URL(fileURLWithPath: path), arguments: arguments)
        try #require(output.ending == .exited && output.status == 0, "\(output.stderrText)")
        return output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopServer(_ tmux: String, socket: String) {
        _ = try? TestProcess.run(URL(fileURLWithPath: tmux), arguments: ["-S", socket, "kill-server"])
    }
}
