// CodexShimScriptTests.swift
// Weir — drives `codex-shim/codex` with `WEIR_REAL_CODEX` pointed at a
// stub that records what it was handed. This pins what the shim owes its
// caller: the user's arguments arrive untouched behind our own, and the pid
// the receiver watches is the agent's own.

import Foundation
import Testing
@testable import Weir

@Suite("Codex shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"), .timeLimit(.minutes(1)))
struct CodexShimScriptTests {
    private struct Handoff {
        var argv: [String]
        var codexPID: String?
        /// The stub's own pid, which `exec` makes the agent's pid too.
        var ownPID: String?
        /// The `CODEX_HOME` the agent was started with.
        var codexHome: String?
    }

    /// `prepare` is given the temporary directory the shim runs in, and
    /// returns what to add to its environment.
    private func runShim(
        _ args: [String],
        hookArgs: String? = nil,
        prepare: (URL) throws -> [String: String] = { _ in [:] },
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Handoff {
        try withTempDir { dir in
            let stub = dir.appendingPathComponent("fake-codex")
            let argvFile = dir.appendingPathComponent("argv")
            let envFile = dir.appendingPathComponent("env")
            try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile, then: """
            printf '%s\\n%s\\n%s\\n' "${WEIR_CODEX_PID:-}" "$$" "${CODEX_HOME:-}" > "\(envFile.path)"
            exit 0
            """), at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["WEIR_REAL_CODEX"] = stub.path
            environment["WEIR_CODEX_HOOK_ARGS"] = hookArgs
            try environment.merge(prepare(dir)) { _, added in added }
            let process = try ShimHarness.run(ShimHarness.shim("codex"), args, environment: environment, currentDirectory: dir)
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            let argv = try #require(ShimHarness.recordedArgv(argvFile), sourceLocation: sourceLocation)
            let lines = try String(contentsOf: envFile, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Handoff(
                argv: argv,
                codexPID: lines.first.flatMap { $0.isEmpty ? nil : $0 },
                ownPID: lines.count > 1 ? lines[1] : nil,
                codexHome: lines.count > 2 && !lines[2].isEmpty ? lines[2] : nil
            )
        }
    }

    @Test("Direct launches without hook flags pass the complete argv unchanged", arguments: [
        ["exec", "--skip-git-repo-check", "hello world"],
        ["resume"]
    ])
    func passesArgumentsThrough(args: [String]) throws {
        let handoff = try runShim(args)
        #expect(handoff.argv == args)
    }

    /// The flags arrive through the environment rather than being built
    /// in shell: the same Swift that hashes their trust has to produce
    /// them, or the hashes stop covering what is actually passed.
    @Test("splices the hook flags in ahead of the user's arguments")
    func splicesHookArgumentsBeforeUserArguments() throws {
        let handoff = try runShim(
            ["resume"],
            hookArgs: "-c\nhooks.Stop=[{hooks=[]}]\n-c\ntui.terminal_title=[]"
        )
        #expect(handoff.argv == [
            "-c", "hooks.Stop=[{hooks=[]}]", "-c", "tui.terminal_title=[]", "resume"
        ])
    }

    /// `exec` gives the shim's shell pid to the agent, so exporting it
    /// before the handover is what lets the receiver skip walking the
    /// process tree to guess which ancestor is Codex.
    @Test("exports its own pid as the agent's")
    func exportsItsOwnPidAsTheAgents() throws {
        let handoff = try runShim([])
        #expect(handoff.codexPID != nil)
        #expect(handoff.codexPID == handoff.ownPID)
    }

    /// Codex resolves a relative `CODEX_HOME` against the directory it
    /// starts in, and our hook, which runs in the session's `cwd`, cannot:
    /// without this it reads Codex's memory agent as the person's.
    @Test("makes a relative CODEX_HOME absolute against where Codex starts")
    func relativeCodexHome_isMadeAbsolute() throws {
        var expected = ""
        let handoff = try runShim([]) { dir in
            expected = dir.appendingPathComponent(".codex-work").path
            return ["CODEX_HOME": ".codex-work"]
        }
        /// The shell's `$PWD` and Foundation spell the temporary directory
        /// with and without `/private`.
        func unprivate(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let home = try #require(handoff.codexHome)
        #expect(home.hasPrefix("/"), "\(home)")
        #expect(unprivate(home) == unprivate(expected))
    }

    @Test("leaves an absolute CODEX_HOME, and an unset one, as they are")
    func absoluteOrUnsetCodexHome_isLeftAlone() throws {
        #expect(try runShim([]) { _ in ["CODEX_HOME": "/opt/codex"] }.codexHome == "/opt/codex")
        #expect(try runShim([]).codexHome == nil)
    }

    /// Where the shim handed control, once tmux hosting is switched on.
    private enum Handover: Equatable {
        case direct([String])
        case tmux([String])
        /// Neither stub ran. Distinguished from `.direct([])` because a
        /// shim that exits before handing off at all would otherwise
        /// satisfy every assertion about an argument-free handoff.
        case none
    }

    /// Runs the shim under a pty. The hosting decision asks whether
    /// stdin and stdout are terminals, and a `Process` pipe is not one,
    /// so the harness above can never reach the tmux branch at all. The
    /// stand-in tmux starts the session as a server another pane started
    /// would (`ShimHarness.fakeTmux`), so a hosted Codex runs too;
    /// `seenAgent` is handed its environment, and the saved pane
    /// environments left in the temporary folder.
    private func runShimHosted(
        _ args: [String],
        hookArgs: String? = nil,
        paneID: String? = "547D688D-39DF-4A06-BD6F-316C3385532C",
        insideTmux: Bool = false,
        environment: [String: String] = [:],
        knownLocation: String? = nil,
        onPath: Bool = false,
        seenFound: ((String?) -> Void)? = nil,
        seenAgent: (([String: String], [String]) -> Void)? = nil
    ) throws -> Handover {
        try withTempDir { dir in
            let codexArgv = dir.appendingPathComponent("codex.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            // With `knownLocation`, the stub is there, under the temporary
            // folder, and the shim finds it from the catalog's list
            // rather than being pointed at it; `onPath`, on the PATH.
            let codexStub = dir.appendingPathComponent(knownLocation ?? (onPath ? "bin/codex" : "fake-codex"))
            try FileManager.default.createDirectory(at: codexStub.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmuxStub = dir.appendingPathComponent("fake-tmux")
            /// Beside the argv, what each stub saw of the sheet's executable
            /// (`seenFound`), and the agent's whole environment.
            func seen(_ argvFile: URL) -> String {
                "printf '%s' \"${WEIR_FOUND_CODEX-unset}\" > \"\(argvFile.path).found\""
            }
            try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: codexArgv, then: """
            \(seen(codexArgv))
            /usr/bin/env -0 > "\(codexArgv.path).env"
            exit 0
            """), at: codexStub)
            try ShimHarness.writeExecutable(ShimHarness.fakeTmux(into: tmuxArgv, then: seen(tmuxArgv)), at: tmuxStub)

            var shimEnvironment = ShimHarness.environment(in: dir)
            shimEnvironment.merge([
                "WEIR_REAL_CODEX": codexStub.path,
                "WEIR_AGENT_TMUX": tmuxStub.path,
                "WEIR_AGENT_TMUX_SOCKET": "weir-test.socket",
                // Spaces on purpose: these reach the session through the
                // saved environment.
                "WEIR_CODEX_SESSIONS_DIR": "/App Support/codex-sessions",
                "WEIR_CODEX_AGENT_STATES_DIR": "/App Support/codex-agent-states"
            ]) { _, new in new }
            shimEnvironment["WEIR_PANE_ID"] = paneID
            shimEnvironment["WEIR_CODEX_HOOK_ARGS"] = hookArgs
            if insideTmux {
                shimEnvironment["TMUX"] = "/tmp/tmux-501/default,4242,0"
            }
            if knownLocation != nil {
                shimEnvironment["WEIR_REAL_CODEX"] = nil
                shimEnvironment["WEIR_CODEX_KNOWN_LOCATIONS"] = codexStub.path
            }
            if onPath {
                shimEnvironment["WEIR_REAL_CODEX"] = nil
                shimEnvironment["PATH"] = "\(codexStub.deletingLastPathComponent().path):\(ShimHarness.systemPath)"
            }
            shimEnvironment.merge(environment) { _, new in new }
            let process = try ShimHarness.run(ShimHarness.shim("codex"), args, environment: shimEnvironment, underPTY: true)
            #expect(process.terminationStatus == 0)

            /// Each stub truncates its file before recording, so the file
            /// existing is what says the stub ran at all.
            func argv(_ url: URL) -> [String]? {
                ShimHarness.recordedArgv(url)
            }
            if let seenFound {
                let ran = FileManager.default.fileExists(atPath: tmuxArgv.path) ? tmuxArgv : codexArgv
                seenFound(try? String(contentsOfFile: ran.path + ".found", encoding: .utf8))
            }
            if let seenAgent {
                let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                    .filter { $0.hasPrefix("weir-hosted-env.") }
                let recorded = try #require(ShimHarness.recordedEnvironment(codexArgv.appendingPathExtension("env")))
                seenAgent(recorded, left)
            }
            if let recorded = argv(tmuxArgv) {
                return .tmux(recorded)
            }
            if let recorded = argv(codexArgv) {
                return .direct(recorded)
            }
            return .none
        }
    }

    /// The whole handoff is one invocation: the server options are set
    /// in the same command that creates the session, so they are in
    /// force before the pane exists. A server of our own because
    /// `escape-time` and the terminal overrides are server-wide and not
    /// ours to change on the one the user also uses.
    @Test("hosts the agent in a tmux session of its own")
    func hostedInvocation_buildsTheSessionAndItsServer() throws {
        let handover = try runShimHosted([])
        guard case let .tmux(argv) = handover else {
            Issue.record("expected a tmux handover, got \(handover)")
            return
        }
        #expect(argv.prefix(2) == ["-L", "weir-test.socket"])
        // `-L` picks the socket but leaves `~/.tmux.conf` loading, which
        // would bring the user's hooks and plugins onto our server.
        #expect(argv.dropFirst(2).prefix(2) == ["-f", "/dev/null"])
        // `-A` would attach to an existing session of the same name and
        // silently drop the command, handing back the running agent.
        #expect(!argv.contains("-A"))
        // More than one argument after `new-session -s <name>`, which is
        // what makes tmux exec the argv directly instead of handing a
        // single string to `sh -c`: the reader of the pane's environment,
        // its file, then the agent.
        let session = try #require(argv.firstIndex(of: "new-session"))
        #expect(argv[session + 1] == "-s")
        #expect(argv[(session + 3)...].prefix(2) == ["/bin/sh", "-c"])
        #expect(argv[session + 6] == "weir-env")
        #expect(argv[session + 7].contains("/weir-hosted-env."))
        #expect(argv.last?.hasSuffix("/fake-codex") == true)
    }

    /// The reason nothing here is quoted. Each `-c` value is TOML with
    /// spaces, quotes and brackets, and it has to reach Codex byte for
    /// byte or the trust hashes stop covering what was passed.
    @Test("carries the hook flags through tmux untouched")
    func hostedInvocation_preservesHookArguments() throws {
        let value = "hooks.Stop=[{hooks=[{command=[\"/a b/hook\", \"x\"]}]}]"
        let handover = try runShimHosted(["resume"], hookArgs: "-c\n\(value)")
        guard case let .tmux(argv) = handover else {
            Issue.record("expected a tmux handover, got \(handover)")
            return
        }
        #expect(argv.suffix(3) == ["-c", value, "resume"])
    }

    /// The environment the hosted Codex saw, failing the test when the
    /// shim did not host it or left the saved pane environment behind.
    private func hostedAgentEnvironment(
        environment: [String: String] = [:],
        knownLocation: String? = nil,
        onPath: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: String] {
        var seen: [String: String] = [:]
        var left: [String] = []
        let handover = try runShimHosted(
            [],
            environment: environment,
            knownLocation: knownLocation,
            onPath: onPath,
            seenAgent: { environment, leftFiles in
                seen = environment
                left = leftFiles
            }
        )
        guard case .tmux = handover else {
            Issue.record("expected a tmux handover, got \(handover)", sourceLocation: sourceLocation)
            return [:]
        }
        #expect(left.isEmpty, "\(left)", sourceLocation: sourceLocation)
        return seen
    }

    /// The bug this guards: a session takes every variable it is not
    /// given from the tmux server's environment, which is that of the pane
    /// whose agent started the server — measured 2026-09-06, a second
    /// session read the first one's `WEIR_CODEX_AGENT_STATES_DIR`. Codex
    /// sees this pane's variables, the person's own exports included,
    /// none of the other pane's, and tmux's own for the terminal it draws
    /// on.
    @Test("starts a hosted agent with the pane's environment, not the tmux server's")
    func hostedLaunch_getsThePanesEnvironmentNotTheServers() throws {
        let env = try hostedAgentEnvironment(environment: ["PERSON_EXPORT": "this pane's\nsecond line"])
        #expect(env["PERSON_EXPORT"] == "this pane's\nsecond line")
        #expect(env["OTHER_PANE_ONLY"] == nil)
        for (name, value) in ShimHarness.tmuxSessionVariables {
            #expect(env[name] == value, "\(name)")
        }
        #expect(env["WEIR_PANE_ID"] == "547D688D-39DF-4A06-BD6F-316C3385532C")
        #expect(env["WEIR_AGENT_RUN_ID"]?.isEmpty == false)
        #expect(env["WEIR_AGENT_TMUX_HOST_MODE"] == "weirHosted")
    }

    /// The receiver writes its records where these point, so a Dev agent
    /// that took a Release server's would write into the Release
    /// directories.
    @Test("starts a hosted agent with the pane's record directories")
    func hostedInvocation_passesTheRecordDirectories() throws {
        let env = try hostedAgentEnvironment()
        #expect(env["WEIR_CODEX_SESSIONS_DIR"] == "/App Support/codex-sessions")
        #expect(env["WEIR_CODEX_AGENT_STATES_DIR"] == "/App Support/codex-agent-states")
    }

    /// The server's `CODEX_HOME` is another pane's, and the hook would
    /// read the memory agent against another home. A pane with none
    /// starts Codex with none, which reads its default home, as it would
    /// outside tmux.
    @Test("starts a hosted agent with the pane's CODEX_HOME, or none")
    func hostedInvocation_passesThePanesCodexHome() throws {
        #expect(try hostedAgentEnvironment(environment: ["CODEX_HOME": "/opt/codex"])["CODEX_HOME"] == "/opt/codex")
        let unset = try hostedAgentEnvironment()
        #expect(!unset.isEmpty)
        #expect(unset["CODEX_HOME"] == nil)
    }

    /// The pane's `PATH` too, whichever way the agent was found: the
    /// server's is the `PATH` of the pane that started it, which a mise,
    /// direnv or `.nvmrc` folder makes another project's.
    @Test("starts a hosted agent on the pane's PATH")
    func hostedInvocation_passesThePanesPath() throws {
        let path = try hostedAgentEnvironment(onPath: true)["PATH"]
        // As the pane had it: found on it, the agent adds nothing.
        #expect(path?.hasSuffix("/bin:/usr/bin:/bin:/usr/sbin:/sbin") == true, "\(path ?? "nil")")
        #expect(path?.components(separatedBy: ":").count == 5, "\(path ?? "nil")")
    }

    /// Found at a known location, the agent's folder has joined the
    /// `PATH`, and the session gets that `PATH`.
    @Test("starts a hosted agent found at a known location on the PATH with its folder")
    func hostedInvocation_ofAnAgentAtAKnownLocation_passesThePathWithItsFolder() throws {
        let location = ".nvm/versions/node/v22.3.0/bin/codex"
        let path = try hostedAgentEnvironment(knownLocation: location)["PATH"]
        #expect(path?.hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin:") == true, "\(path ?? "nil")")
        #expect(path?.hasSuffix("/.nvm/versions/node/v22.3.0/bin") == true, "\(path ?? "nil")")
        guard case let .tmux(argv) = try runShimHosted([], knownLocation: location) else {
            Issue.record("expected a tmux handover")
            return
        }
        #expect(argv.last?.hasSuffix(location) == true, "\(argv)")
    }

    /// What the new workspace sheet found stays with the pane's shell: a
    /// tmux server started with it would hand it to every session after,
    /// in whatever folder. Neither the tmux client nor the agent has it.
    @Test("keeps what the sheet found out of tmux")
    func hostedInvocation_keepsTheSheetsExecutableOutOfTmux() throws {
        var seen: String?
        let handover = try runShimHosted([], environment: ["WEIR_FOUND_CODEX": "/opt/tools/bin/codex"]) { seen = $0 }
        guard case let .tmux(argv) = handover else {
            Issue.record("expected a tmux handover, got \(handover)")
            return
        }
        #expect(seen == "unset")
        #expect(!argv.contains { $0.contains("WEIR_FOUND_") })
        #expect(try hostedAgentEnvironment(environment: ["WEIR_FOUND_CODEX": "/opt/tools/bin/codex"])["WEIR_FOUND_CODEX"] == nil)
    }

    @Test("does not wrap again once inside tmux")
    func insideTmux_handsOffDirectly() throws {
        #expect(try runShimHosted([], insideTmux: true) == .direct([]))
    }

    /// Anything printed inside tmux is erased when the client leaves the
    /// alternate screen, so a one-shot invocation has to run directly.
    /// `-m gpt-5 exec` is the case that decided the shape of this rule.
    /// A global option can sit in front of a subcommand, so reading the
    /// first argument does not find it, and wrapping `exec` would send
    /// its output to a screen tmux erases on the way out. A prompt is
    /// indistinguishable from a subcommand, so a prompt on the command
    /// line is not hosted either. A one-shot flag after an entry point
    /// (`resume --help`) still prints and exits.
    @Test("runs anything it does not recognize directly", arguments: [
        ["--version"], ["--help"], ["--print", "hi"], ["login"],
        ["exec", "check this"], ["-m", "gpt-5", "exec", "check this"],
        ["fix the failing test"], ["hello"], ["resume", "--help"]
    ])
    func unrecognizedInvocations_areNotHosted(_ args: [String]) throws {
        #expect(try runShimHosted(args) == .direct(args))
    }

    /// The interactive entry points, which is the whole allow list: a
    /// bare launch, and the two ways back into an existing session.
    @Test("hosts the interactive entry points", arguments: [
        [], ["resume"], ["resume", "--last"], ["fork"]
    ])
    func interactiveInvocations_areHosted(_ args: [String]) throws {
        guard case .tmux = try runShimHosted(args) else {
            Issue.record("expected a tmux handover for \(args)")
            return
        }
    }

    /// Weir sets the pane id and the tmux path together, so a missing
    /// pane id means this is not a Weir pane and there is nothing to
    /// name the session after.
    @Test("does not host without a pane id")
    func withoutPaneID_handsOffDirectly() throws {
        #expect(try runShimHosted([], paneID: nil) == .direct([]))
    }

    @Test("preserves empty record directory variables when hosting an agent")
    func hostedLaunch_passesEmptyRecordDirectories() throws {
        // A demo pane empties them; the session must not take the tmux
        // server's values, which are another build's directories.
        let env = try hostedAgentEnvironment(environment: [
            "WEIR_CODEX_AGENT_STATES_DIR": "",
            "WEIR_CODEX_SESSIONS_DIR": ""
        ])
        #expect(env["WEIR_CODEX_AGENT_STATES_DIR"] == "")
        #expect(env["WEIR_CODEX_SESSIONS_DIR"] == "")
    }
}
