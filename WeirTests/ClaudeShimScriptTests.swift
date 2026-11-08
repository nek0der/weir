// ClaudeShimScriptTests.swift
// Weir — drives `claude-shim/claude` with `WEIR_REAL_CLAUDE` pointed at
// a stub that records its argv, the only way to see what the shim decided
// Claude should receive. `--settings` overwrites rather than merges, so the
// shim has to fold a user-supplied one into its own and pass a single flag;
// these pin that it does, in both spellings and for a file as well as
// inline JSON.

import Foundation
import Testing
@testable import Weir

@Suite("Claude shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"), .timeLimit(.minutes(1)))
struct ClaudeShimScriptTests {
    /// Run the shim with `args` and return the argv the real claude would
    /// have been exec'd with.
    private func runShim(
        _ args: [String],
        hookNamespace: String? = nil,
        setsTemporaryDirectory: Bool = true,
        prepareTemporaryDirectory: (URL) throws -> Void = { _ in },
        temporaryDirectory: (URL) throws -> URL = { $0 },
        shim: (URL) throws -> URL = { _ in try ShimHarness.shim("claude") },
        stderr: Recorded<String>? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String] {
        try withTempDir { dir in
            try prepareTemporaryDirectory(dir)
            let shim = try shim(dir)
            let stub = dir.appendingPathComponent("fake-claude")
            // The settings payload is pretty-printed JSON, which is why the
            // argv is recorded NUL-separated.
            let argvFile = dir.appendingPathComponent("argv.txt")
            try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile), at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["WEIR_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
            environment["WEIR_REAL_CLAUDE"] = stub.path
            environment["WEIR_CLAUDE_HOOK_NAMESPACE"] = hookNamespace
            environment["TMPDIR"] = setsTemporaryDirectory ? try temporaryDirectory(dir).path : nil
            let process = try TestProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: [shim.path] + args, environment: environment)
            stderr?.value = process.stderrText
            try #require(process.ending == .exited && process.status == 0, "\(process.stderrText)", sourceLocation: sourceLocation)
            return try #require(ShimHarness.recordedArgv(argvFile, keepsEmptyArguments: true), sourceLocation: sourceLocation)
        }
    }

    /// The value of the single `--settings` the shim passed, decoded.
    private func settingsPayload(
        in argv: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any]? {
        let flags = argv.indices.filter { argv[$0] == "--settings" || argv[$0].hasPrefix("--settings=") }
        try #require(flags.count == 1, sourceLocation: sourceLocation)
        let index = try #require(flags.first, sourceLocation: sourceLocation)
        try #require(argv[index] == "--settings" && argv.indices.contains(index + 1), sourceLocation: sourceLocation)
        return try JSONSerialization.jsonObject(with: Data(argv[index + 1].utf8)) as? [String: Any]
    }

    private func sessionStartGroups(_ payload: [String: Any]?) -> [[String: Any]] {
        let hooks = payload?["hooks"] as? [String: Any]
        return hooks?["SessionStart"] as? [[String: Any]] ?? []
    }

    private func sessionStartCommand(_ argv: [String]) throws -> String {
        let decodedPayload = try settingsPayload(in: argv)
        let payload = try #require(decodedPayload)
        let groups = sessionStartGroups(payload)
        try #require(groups.count == 1)
        let hooks = try #require(groups.first?["hooks"] as? [[String: Any]])
        try #require(hooks.count == 1 && hooks.first?["type"] as? String == "command")
        return try #require(hooks.first?["command"] as? String)
    }

    @Test("injects our settings when the user passes none")
    func noUserSettings_injectsOurs() throws {
        let argv = try runShim([])
        #expect(argv.count == 2)
        let command = try sessionStartCommand(argv)
        #expect(command.hasSuffix("/weir-claude-shim-default/weir-hook"))
    }

    /// The hook path is captured by a running Claude process. Separate stable
    /// names let a new invocation refresh its own build without redirecting a
    /// session launched by another build: the Release app, or a Debug build
    /// from another worktree, which has the same bundle id.
    @Test("namespaces the no-space hook link by build identity")
    func hookLink_separatesBuilds() throws {
        let release = WeirPaths.buildIdentity(bundleID: "com.nekoder.Weir", bundlePath: "/Applications/Weir.app")
        let firstDebug = WeirPaths.buildIdentity(
            bundleID: "com.nekoder.Weir.dev",
            bundlePath: "/DerivedData/Weir-aaaa/Build/Products/Debug/Weir Dev.app"
        )
        let secondDebug = WeirPaths.buildIdentity(
            bundleID: "com.nekoder.Weir.dev",
            bundlePath: "/DerivedData/Weir-bbbb/Build/Products/Debug/Weir Dev.app"
        )
        try withTempDir { root in
            let shared = root.appendingPathComponent("shared")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            let source = try ShimHarness.shim("claude").deletingLastPathComponent()
            var expectedTargets: [String: String] = [:]
            for namespace in [release, firstDebug, secondDebug] {
                let copy = root.appendingPathComponent(namespace)
                try FileManager.default.copyItem(at: source, to: copy)
                let argv = try runShim(
                    [], hookNamespace: namespace, temporaryDirectory: { _ in shared },
                    shim: { _ in copy.appendingPathComponent("claude") }
                )
                let link = shared.appendingPathComponent("weir-claude-shim-\(namespace)/weir-hook")
                #expect(try sessionStartCommand(argv) == link.path)
                expectedTargets[link.path] = copy.appendingPathComponent("weir-hook").path
            }

            #expect(expectedTargets.count == 3)
            for (link, target) in expectedTargets {
                let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link)
                #expect(URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: target).resolvingSymlinksInPath().path)
            }
        }
    }

    /// A link folder someone else put in place (here a link to another
    /// folder) is not used: the hooks Claude runs would be whatever that
    /// folder holds. The shim falls back to the hooks' own paths.
    @Test func hookLink_refusesAFolderThatIsALink() throws {
        try withTempDir { elsewhere in
            let argv = try runShim([], hookNamespace: "planted") { dir in
                try FileManager.default.createSymbolicLink(
                    at: dir.appendingPathComponent("weir-claude-shim-planted"),
                    withDestinationURL: elsewhere
                )
            }
            let command = try sessionStartCommand(argv)
            #expect(!command.contains("weir-claude-shim-planted"))
            #expect(command.hasSuffix("/claude-shim/weir-hook"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }
    }

    /// Without TMPDIR (an ssh login, a tmux server started with a stripped
    /// environment) the links go to the folder macOS keeps for this user,
    /// not to a shared /tmp.
    @Test func hookLink_withoutTMPDIR_usesTheUsersOwnTemporaryFolder() throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        try #require(length > 0)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let userTemporary = try #require(String(bytes: bytes, encoding: .utf8))
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let namespace = "test-\(UUID().uuidString)"
        let linkFolder = URL(fileURLWithPath: userTemporary).appendingPathComponent("weir-claude-shim-\(namespace)")
        defer { try? FileManager.default.removeItem(at: linkFolder) }

        let argv = try runShim([], hookNamespace: namespace, setsTemporaryDirectory: false)
        let command = try sessionStartCommand(argv)

        #expect(command == linkFolder.appendingPathComponent("weir-hook").path)
        #expect(!command.hasPrefix("/tmp/"))
        let mode = try FileManager.default.attributesOfItem(atPath: linkFolder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test(arguments: [false, true])
    func userSettings_preservePrecedenceAndAppendWeirHooks(usesEquals: Bool) throws {
        let theirs = #"""
        {
          "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/true"}]}]},
          "env":{"USER_KEY":"1"},
          "preferredNotifChannel":"terminal_bell"
        }
        """#
        let argv = try runShim(usesEquals ? ["--settings=\(theirs)"] : ["--settings", theirs])
        let decoded = try settingsPayload(in: argv)
        let payload = try #require(decoded)
        let groups = sessionStartGroups(payload)
        let commands = groups.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        try #require(commands.count == 2)
        #expect(commands[0] == "/bin/true")
        #expect(commands[1].hasSuffix("/weir-claude-shim-default/weir-hook"))
        #expect((payload["env"] as? [String: String]) == ["USER_KEY": "1"])
        #expect(payload["preferredNotifChannel"] as? String == "terminal_bell")
        #expect(argv.count == 2)
    }

    @Test("merges a user settings file, not just inline JSON")
    func userSettingsFile_merged() throws {
        let payload = try withTempDir { dir -> [String: Any]? in
            let file = dir.appendingPathComponent("theirs.json")
            try #"{"env":{"FROM_FILE":"1"}}"#.write(to: file, atomically: true, encoding: .utf8)
            return try settingsPayload(in: runShim(["--settings", file.path]))
        }
        #expect(sessionStartGroups(payload).count == 1)
        #expect((payload?["env"] as? [String: Any])?["FROM_FILE"] as? String == "1")
    }

    /// The merge used to write both documents into the link folder, so with
    /// that folder refused it failed, and Claude started on the person's
    /// settings alone, without a word and without any of Weir's hooks.
    @Test func userSettings_areMergedWhenTheLinkFolderIsUnusable() throws {
        try withTempDir { elsewhere in
            let theirs = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}"#
            let argv = try runShim(["--settings", theirs], hookNamespace: "planted") { dir in
                try FileManager.default.createSymbolicLink(
                    at: dir.appendingPathComponent("weir-claude-shim-planted"),
                    withDestinationURL: elsewhere
                )
            }
            let groups = try sessionStartGroups(settingsPayload(in: argv))
            #expect(groups.count == 2)
            let commands = groups.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
            #expect(commands.first == "/bin/true")
            #expect(commands.last?.hasSuffix("/claude-shim/weir-hook") == true)
            let permission = try #require(settingsPayload(in: argv)?["hooks"] as? [String: Any])["PermissionRequest"]
            #expect(permission != nil)
        }
    }

    /// Claude Code runs a hook's command under `sh -c`. A path holding what
    /// the shell, JSON, or the template's sed would read as their own
    /// (`'`, a space, `&`, `|`, `"`, `\`) still names the hook, whether it
    /// is the link in the temporary folder or, with that folder refused, the
    /// hook's own path.
    @Test(arguments: [true, false])
    func hookPaths_needingQuotes_stillRunTheHook(isLinkFolderUsable: Bool) throws {
        try withTempDir { outer in
            let awkward = outer.appendingPathComponent(#"R&D |"it's" \x"#)
            let shimFolder = awkward.appendingPathComponent("claude-shim")
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: awkward, withIntermediateDirectories: true)
            try fileManager.copyItem(at: ShimHarness.shim("claude").deletingLastPathComponent(), to: shimFolder)
            // A hook that says it ran, in place of the one that would reach
            // the helper.
            let ran = outer.appendingPathComponent("ran")
            let hook = shimFolder.appendingPathComponent("weir-hook")
            try fileManager.removeItem(at: hook)
            try ShimHarness.writeExecutable("#!/bin/sh\n: > '\(ran.path)'\n", at: hook)
            if !isLinkFolderUsable {
                try fileManager.createSymbolicLink(
                    at: awkward.appendingPathComponent("weir-claude-shim-awkward"),
                    withDestinationURL: outer
                )
            }

            let argv = try runShim(
                [],
                hookNamespace: "awkward",
                temporaryDirectory: { _ in awkward },
                shim: { _ in shimFolder.appendingPathComponent("claude") }
            )
            let command = try sessionStartCommand(argv)
            #expect(command.contains("weir-claude-shim-awkward") == isLinkFolderUsable)

            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", command]
            shell.standardInput = FileHandle.nullDevice
            try shell.run()
            try #require(shell.waitUntilExit(within: 10))
            #expect(shell.terminationStatus == 0)
            #expect(fileManager.fileExists(atPath: ran.path))
        }
    }

    /// A settings file is read by the merge, not passed to it: its text may
    /// be larger than one argument can hold (`ARG_MAX` is 1 MiB), though
    /// the document it holds is small.
    @Test func userSettingsFile_largerThanAnArgument_isMerged() throws {
        let payload = try withTempDir { dir -> [String: Any]? in
            let file = dir.appendingPathComponent("theirs.json")
            let text = String(repeating: " ", count: 1_100_000) + #"{"env":{"FROM_FILE":"1"}}"#
            try text.write(to: file, atomically: true, encoding: .utf8)
            return try settingsPayload(in: runShim(["--settings", file.path]))
        }
        #expect(sessionStartGroups(payload).count == 1)
        #expect((payload?["env"] as? [String: Any])?["FROM_FILE"] as? String == "1")
    }

    /// A control character in the link folder's path is one no escaping
    /// carries into the settings. Claude starts as it would without us,
    /// rather than on a document it would refuse.
    @Test func hookPath_thatCannotBeWritten_startsClaudeWithoutOurSettings() throws {
        let stderr = Recorded("")
        let argv = try runShim(
            ["--version"],
            prepareTemporaryDirectory: { dir in
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("a\tb"),
                    withIntermediateDirectories: true
                )
            },
            temporaryDirectory: { $0.appendingPathComponent("a\tb") },
            stderr: stderr
        )
        #expect(argv == ["--version"])
        #expect(stderr.value == "weir: a hook path here cannot be written into the settings, so this claude runs without Weir's hooks\n")
        let control = try runShim(["--version"])
        #expect(try sessionStartCommand(control).hasSuffix("/weir-hook"))
        #expect(control.dropFirst(2) == ["--version"])
    }

    @Test("passes an unmergeable user value straight through")
    func unmergeableUserSettings_leftAlone() throws {
        let input = ["--settings", "{bad"]
        let stderr = Recorded("")
        #expect(try runShim(input, stderr: stderr) == input)
        #expect(stderr.value == "weir: could not read --settings as JSON, so this claude runs without Weir's hooks\n")
    }

    @Test(arguments: [String?.none, "1"])
    func terminalTitleSwitch_preservesTheUsersChoice(choice: String?) throws {
        try withTempDir { dir in
            let stub = dir.appendingPathComponent("fake-claude")
            // The switch also turns off Claude's OSC 7501 reports, which the
            // projection reads (`PaneProgramStatusStore`).
            try ShimHarness.writeExecutable("""
            #!/bin/sh
            printf '%s' "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE-unset}"
            """, at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["WEIR_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
            environment["WEIR_REAL_CLAUDE"] = stub.path
            environment["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = choice
            let shim = try ShimHarness.shim("claude")
            let process = try TestProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: [shim.path], environment: environment)
            try #require(process.ending == .exited && process.status == 0)
            #expect(process.stdoutText == (choice ?? "unset"))
        }
    }

}

extension ClaudeShimScriptTests {
    private enum RedirectedStream: CaseIterable, Sendable {
        case input, output

        var redirection: String {
            switch self {
            case .input: "</dev/null"
            case .output: ">/dev/null"
            }
        }
    }

    /// Runs the shim under a pty with tmux hosting switched on, and
    /// returns the argv tmux was handed and what the agent saw. The
    /// stand-in tmux starts the session as a server another pane started
    /// would (`ShimHarness.fakeTmux`). The hosting decision asks
    /// whether stdin and stdout are terminals, and the harness above runs
    /// the shim on the null device, so it can never reach this branch. The rule
    /// is shared (`weir_should_host_in_tmux` in `runtime-common.sh`), but
    /// each shim hands it its own lists, so Claude's are pinned here as
    /// Codex's are in its suite; what is Claude's alone besides is that
    /// our `--settings` survives the wrap.
    /// `underPTY: false` is the launch whose output is not a terminal.
    /// `files`, when given, are written into the temporary folder, and the
    /// shim then runs there, so a relative path in `args` or `environment`
    /// names one of them. `othersCanWrite` lets every user write to that
    /// folder, which is also the shim's TMPDIR. `prepare` runs in that
    /// folder first, and what it returns is laid over the environment.
    /// `losesSavedEnvironment` has the stand-in tmux delete the saved pane
    /// environment before the session reads it, and keep the session's
    /// stderr.
    private func runShimHosted(
        _ args: [String],
        environment: [String: String] = [:],
        files: [String: String] = [:],
        underPTY: Bool = true,
        othersCanWrite: Bool = false,
        losesSavedEnvironment: Bool = false,
        redirectedStream: RedirectedStream? = nil,
        prepare: ((URL) throws -> [String: String])? = nil
    ) throws -> HostedRun {
        try withTempDir { dir in
            if othersCanWrite {
                try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
            }
            let prepared = try prepare?(dir) ?? [:]
            for (name, contents) in files {
                try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let claudeArgv = dir.appendingPathComponent("claude.argv")
            let tmuxArgv = dir.appendingPathComponent("tmux.argv")
            let claudeStub = dir.appendingPathComponent("fake-claude")
            let tmuxStub = dir.appendingPathComponent("fake-tmux")
            /// Beside the argv, what each stub saw of the sheet's executable
            /// and the host mode, and the agent's whole environment.
            func seen(_ argvFile: URL) -> String {
                """
                printf '%s' "${WEIR_FOUND_CLAUDE-unset}" > "\(argvFile.path).found"
                printf '%s' "${WEIR_AGENT_TMUX_HOST_MODE-unset}" > "\(argvFile.path).mode"
                """
            }
            try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: claudeArgv, then: """
            \(seen(claudeArgv))
            /usr/bin/env -0 > "\(claudeArgv.path).env"
            exit 0
            """), at: claudeStub)
            let savedMode = dir.appendingPathComponent("snapshot-mode")
            let observeSavedFile = """
            previous=""
            for arg in "$@"; do
              if [ "$previous" = weir-env ]; then
                /usr/bin/stat -f %Lp "$arg" > "\(savedMode.path)"
                \(losesSavedEnvironment ? "rm -f -- \"$arg\"" : ":")
              fi
              previous=$arg
            done
            \(losesSavedEnvironment ? "exec 2>\"\(tmuxArgv.path).stderr\"" : ":")
            """
            try ShimHarness.writeExecutable(
                ShimHarness.fakeTmux(into: tmuxArgv, then: seen(tmuxArgv) + "\n" + observeSavedFile),
                at: tmuxStub
            )

            var shimEnvironment = ShimHarness.environment(in: dir)
            try shimEnvironment.merge([
                "WEIR_CLAUDE_SETTINGS_TEMPLATE": ShimHarness.claudeSettingsTemplate(),
                "WEIR_REAL_CLAUDE": claudeStub.path,
                "WEIR_AGENT_TMUX": tmuxStub.path,
                "WEIR_AGENT_TMUX_SOCKET": "weir-test.socket",
                "WEIR_PANE_ID": "547D688D-39DF-4A06-BD6F-316C3385532C"
            ]) { _, new in new }
            shimEnvironment.merge(environment) { _, new in new }
            shimEnvironment.merge(prepared) { _, new in new }
            let shim = try ShimHarness.shim("claude")
            let launch: (URL, [String])
            if let redirectedStream {
                let wrapper = dir.appendingPathComponent("redirect-one-tty")
                try ShimHarness.writeExecutable("""
                #!/bin/sh
                [ -t 0 ] && [ -t 1 ] || exit 97
                exec /bin/sh "$@" \(redirectedStream.redirection)
                """, at: wrapper)
                launch = (wrapper, [shim.path] + args)
            } else {
                launch = (shim, args)
            }
            let physical = try #require(realpath(dir.path, nil))
            defer { free(physical) }
            let workingDirectory = files.isEmpty ? nil : String(cString: physical)
            let process = try ShimHarness.run(
                launch.0,
                launch.1,
                environment: shimEnvironment,
                underPTY: underPTY,
                currentDirectory: workingDirectory.map { URL(fileURLWithPath: $0) }
            )

            func argv(_ url: URL) -> [String] {
                ShimHarness.recordedArgv(url, keepsEmptyArguments: true) ?? []
            }
            let leftEnvironmentFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.hasPrefix("weir-hosted-env.") } ?? []
            return HostedRun(
                tmux: argv(tmuxArgv),
                claude: argv(claudeArgv),
                tmuxSawFound: try? String(contentsOfFile: tmuxArgv.path + ".found", encoding: .utf8),
                claudeSawMode: try? String(contentsOfFile: claudeArgv.path + ".mode", encoding: .utf8),
                claudeEnvironment: ShimHarness.recordedEnvironment(claudeArgv.appendingPathExtension("env")) ?? [:],
                leftEnvironmentFiles: leftEnvironmentFiles,
                temporaryFolder: dir.path,
                workingDirectory: workingDirectory,
                snapshotMode: try? String(contentsOf: savedMode, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                sessionStderr: try? String(contentsOfFile: tmuxArgv.path + ".stderr", encoding: .utf8),
                exitStatus: process.terminationStatus
            )
        }
    }

    /// What `runShimHosted` saw: the argv tmux and the agent were each
    /// handed (empty for the one that did not run; a hosted agent runs in
    /// the stand-in tmux's session), what tmux saw of `WEIR_FOUND_CLAUDE`
    /// (`unset` when it had none), the host mode Claude was handed
    /// (`unset` when it had none), Claude's environment, and the saved
    /// pane environments left in the temporary folder.
    private struct HostedRun {
        let tmux: [String]
        let claude: [String]
        let tmuxSawFound: String?
        let claudeSawMode: String?
        let claudeEnvironment: [String: String]
        let leftEnvironmentFiles: [String]
        let temporaryFolder: String
        let workingDirectory: String?
        let snapshotMode: String?
        /// What the session wrote to stderr, kept only with
        /// `losesSavedEnvironment`.
        let sessionStderr: String?
        let exitStatus: Int32

        /// The saved pane environment the session was handed, read from
        /// tmux's argv: the argument after `weir-env`.
        var savedEnvironmentFile: String? {
            tmux.firstIndex(of: "weir-env").flatMap { tmux.indices.contains($0 + 1) ? tmux[$0 + 1] : nil }
        }

        /// Claude ran directly, with our settings and then the user's
        /// arguments.
        func ranDirectly(_ args: [String]) -> Bool {
            exitStatus == 0 && tmux.isEmpty && claude.count == args.count + 2 &&
                claude.first == "--settings" && claude.dropFirst(2) == args[...]
        }
    }

    /// The hooks are the reason the shim exists, so they have to survive
    /// being handed to tmux rather than exec'd directly. tmux runs
    /// multiple arguments as an argv, which is what keeps the settings
    /// JSON — quotes, braces and all — out of a shell.
    @Test("keeps our settings flag when the agent is hosted in tmux")
    func hostedInvocation_stillCarriesTheSettingsFlag() throws {
        let handover = try runShimHosted([])
        let prefix = [
            "-L", "weir-test.socket", "-f", "/dev/null",
            "set", "-s", "escape-time", "10", ";",
            "set", "-s", "default-terminal", "tmux-256color", ";",
            "set", "-sa", "terminal-overrides", ",*:RGB", ";",
            "set", "-g", "prefix", "None", ";",
            "new-session", "-s"
        ]
        #expect(handover.tmux.prefix(prefix.count) == prefix[...])
        let tail = Array(handover.tmux.dropFirst(prefix.count))
        try #require(tail.count == 9)
        #expect(tail[0].hasPrefix("weir-547D688D-"))
        #expect(Int(tail[0].dropFirst("weir-547D688D-".count)) != nil)
        #expect(tail[1...2] == ["/bin/sh", "-c"])
        #expect(tail[3].contains("the pane environment saved for this agent could not be read"))
        #expect(tail[4] == "weir-env")
        #expect(tail[5] == handover.savedEnvironmentFile)
        #expect(tail[6] == handover.temporaryFolder + "/fake-claude")
        #expect(Array(tail.dropFirst(7)) == handover.claude)
        #expect(try sessionStartCommand(handover.claude).hasSuffix("/weir-hook"))
        #expect(handover.claudeEnvironment["WEIR_AGENT_RUN_ID"]?.isEmpty == false)
        #expect(handover.claudeSawMode == "weirHosted")
        #expect(handover.exitStatus == 0)
    }

    /// The bug this guards: a session takes every variable it is not
    /// given from the tmux server's environment, which is that of the pane
    /// whose agent started the server. The agent sees this pane's
    /// variables, the person's own exports included, exactly as typed,
    /// none of the other pane's, and tmux's own for the terminal it draws
    /// on. The saved environment is gone once read.
    @Test("starts a hosted agent with the pane's environment, not the tmux server's")
    func hostedLaunch_getsThePanesEnvironmentNotTheServers() throws {
        let export = "it's \"quoted\" $HOME `x` \\\nsecond line\n"
        let handover = try runShimHosted([], environment: [
            "PERSON_EXPORT": export,
            "PANE_ONLY": "",
            // Named like the reader's own variables, which must not touch it.
            "lhe_file": "the person's",
            "TERM": "xterm-ghostty"
        ])
        #expect(!handover.tmux.isEmpty)
        let env = handover.claudeEnvironment
        #expect(env["PERSON_EXPORT"] == export)
        #expect(env["PANE_ONLY"] == "")
        #expect(env["lhe_file"] == "the person's")
        #expect(env["OTHER_PANE_ONLY"] == nil)
        #expect(env["HOME"] == handover.temporaryFolder)
        for (name, value) in ShimHarness.tmuxSessionVariables {
            #expect(env[name] == value, "\(name)")
        }
        #expect(env["WEIR_PANE_ID"] == "547D688D-39DF-4A06-BD6F-316C3385532C")
        #expect(handover.leftEnvironmentFiles.isEmpty)
        // Nothing of the environment travels on tmux's command line.
        #expect(!handover.tmux.contains { $0.contains("PERSON_EXPORT") || $0.contains(export) })
    }

    /// Bash refuses to assign `UID`, `EUID`, and `SHELLOPTS`, which it keeps
    /// read-only, so a pane exporting one would stop a reader in bash before
    /// the agent started, and leave the saved environment behind.
    @Test("starts a hosted agent with the variables bash keeps read-only")
    func hostedLaunch_keepsVariablesBashKeepsReadOnly() throws {
        let handover = try runShimHosted([], environment: ["UID": "501", "EUID": "501", "SHELLOPTS": "braceexpand"])
        #expect(handover.claudeEnvironment["UID"] == "501")
        #expect(handover.claudeEnvironment["EUID"] == "501")
        #expect(handover.claudeEnvironment["SHELLOPTS"]?.hasPrefix("braceexpand") == true)
        #expect(handover.leftEnvironmentFiles.isEmpty)
    }

    /// Another user who can write to TMPDIR could swap the saved
    /// environment for a file of their own, which the session would run,
    /// so the file goes to the folder macOS keeps for this user instead.
    @Test("saves the pane's environment outside a TMPDIR others can write to")
    func hostedLaunch_withATemporaryFolderOthersCanWrite_savesInTheUsersOwn() throws {
        try withTempDir { privateTemporary in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateTemporary.path)
            let handover = try runShimHosted([], environment: ["PERSON_EXPORT": "this pane's"], othersCanWrite: true) { dir in
                let bin = dir.appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try ShimHarness.writeExecutable(
                    "#!/bin/sh\nprintf '%s\\n' \"$TEST_PRIVATE_TEMP\"\n",
                    at: bin.appendingPathComponent("getconf")
                )
                return [
                    "PATH": "\(bin.path):\(ShimHarness.systemPath)",
                    "TEST_PRIVATE_TEMP": privateTemporary.path
                ]
            }
            let saved = try #require(handover.savedEnvironmentFile)
            #expect(URL(fileURLWithPath: saved).deletingLastPathComponent().path == privateTemporary.path)
            #expect(handover.snapshotMode == "600")
            #expect(!FileManager.default.fileExists(atPath: saved))
            #expect(handover.claudeEnvironment["PERSON_EXPORT"] == "this pane's")
            #expect(try FileManager.default.contentsOfDirectory(atPath: privateTemporary.path).isEmpty)
        }
    }

    /// A session that cannot read the saved environment starts nothing,
    /// rather than an agent with the server's environment or none, and says
    /// so in the pane before tmux closes it.
    @Test("starts nothing, and says so, when the session cannot read the pane's environment")
    func hostedLaunch_whoseSavedEnvironmentIsGone_startsNothing() throws {
        let handover = try runShimHosted([], losesSavedEnvironment: true)
        #expect(!handover.tmux.isEmpty)
        #expect(handover.claude.isEmpty)
        #expect(handover.sessionStderr?.contains("could not be read, so the agent did not start. Run the command again.") == true)
        #expect(handover.exitStatus != 0)
    }

    /// With nowhere private to save the pane's environment, the agent runs
    /// in the pane as with hosting off: in tmux it would take the server's.
    /// A TMPDIR others can write to and no folder of the user's from
    /// `getconf` leave nowhere.
    @Test("runs the agent directly when the pane's environment cannot be saved")
    func hostedLaunch_withNowhereToSave_runsDirectly() throws {
        let handover = try runShimHosted([], othersCanWrite: true) { dir in
            let bin = dir.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try ShimHarness.writeExecutable("#!/bin/sh\nexit 0\n", at: bin.appendingPathComponent("getconf"))
            return ["PATH": "\(bin.path):\(ShimHarness.systemPath)"]
        }
        #expect(handover.ranDirectly([]))
        #expect(handover.claudeSawMode == "unset")
        #expect(handover.leftEnvironmentFiles.isEmpty)
    }

    /// A file whose session never ran holds the person's secrets, so the
    /// next hosted launch removes it once it is a minute old; one younger
    /// may be another launch's, about to be read.
    @Test("removes a saved environment a session never read once it is a minute old")
    func hostedLaunch_removesALeftBehindEnvironment() throws {
        let handover = try runShimHosted([]) { dir in
            for (name, age) in [("weir-hosted-env.OLDOLDOLDOLD", 120.0), ("weir-hosted-env.NEWNEWNEWNEW", 0.0)] {
                let url = dir.appendingPathComponent(name)
                FileManager.default.createFile(atPath: url.path, contents: Data("export SECRET='hunter2'\n".utf8))
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
            }
            return [:]
        }
        #expect(!handover.tmux.isEmpty)
        #expect(handover.leftEnvironmentFiles == ["weir-hosted-env.NEWNEWNEWNEW"])
    }

    /// A server already running would otherwise start the agent on the
    /// `PATH` of the pane that started the server (`CodexShimScriptTests`
    /// pins what the agent's folder adds to it). The stub comes through
    /// `WEIR_REAL_CLAUDE`, an override that leaves the `PATH` as it was.
    @Test("starts a hosted agent on the pane's PATH")
    func hostedInvocation_passesThePanesPath() throws {
        let path = "/pane-only/bin:" + ShimHarness.systemPath
        let handover = try runShimHosted([], environment: ["PATH": path])
        #expect(handover.claudeSawMode == "weirHosted")
        #expect(handover.claudeEnvironment["PATH"] == path)
    }

    /// What the new workspace sheet found stays with the pane's shell: a
    /// tmux server started with it would hand it to every session after.
    /// Neither the tmux client nor the agent has it.
    @Test("keeps what the sheet found out of tmux")
    func hostedInvocation_keepsTheSheetsExecutableOutOfTmux() throws {
        let handover = try runShimHosted([], environment: ["WEIR_FOUND_CLAUDE": "/opt/tools/bin/claude"])
        #expect(!handover.tmux.isEmpty)
        #expect(handover.tmuxSawFound == "unset")
        #expect(!handover.tmux.contains { $0.contains("WEIR_FOUND_") })
        #expect(handover.claudeEnvironment["WEIR_FOUND_CLAUDE"] == nil)
    }

    /// A tmux session starts in a folder of its own, so a relative value
    /// would name another folder there, and one left out would be the tmux
    /// server's, the first pane's account rather than this pane's.
    @Test("starts a hosted agent on the pane's Claude account, made absolute")
    func hostedLaunch_passesTheAccountMadeAbsolute() throws {
        let handover = try runShimHosted(
            [],
            environment: ["CLAUDE_CONFIG_DIR": "relative/config"],
            files: ["placeholder": ""]
        )
        let value = try #require(handover.claudeEnvironment["CLAUDE_CONFIG_DIR"])
        let cwd = try #require(handover.workingDirectory)
        #expect(value == cwd + "/relative/config")

        let unset = try runShimHosted([])
        #expect(!unset.tmux.isEmpty)
        #expect(unset.claudeEnvironment["CLAUDE_CONFIG_DIR"] == nil)
    }

    /// The status line relay finds the person's own status line in the
    /// settings they launched with, which our flag replaced.
    @Test("hands a hosted agent the person's settings for the status line relay")
    func hostedLaunch_passesThePersonsSettings() throws {
        let file = try runShimHosted(
            ["--resume", "abc", "--settings", "mine.json"],
            files: ["mine.json": #"{"model":"opus"}"#]
        )
        let value = try #require(file.claudeEnvironment["WEIR_CLAUDE_USER_SETTINGS"])
        let cwd = try #require(file.workingDirectory)
        #expect(value == cwd + "/mine.json")
        #expect(file.claude.dropFirst(2) == ["--resume", "abc"])
        #expect(try settingsPayload(in: file.claude)?["model"] as? String == "opus")
        #expect(try sessionStartCommand(file.claude).hasSuffix("/weir-hook"))

        // Inline JSON is passed as written, blanks before it included, and
        // merged as JSON rather than read as a file of that name.
        let inline = "  \n {\"model\":\"opus\"}"
        let handover = try runShimHosted(["--resume", "abc", "--settings", inline])
        #expect(handover.claudeEnvironment["WEIR_CLAUDE_USER_SETTINGS"] == inline)
        #expect(handover.claude.dropFirst(2) == ["--resume", "abc"])
        #expect(try settingsPayload(in: handover.claude)?["model"] as? String == "opus")
        #expect(try sessionStartCommand(handover.claude).hasSuffix("/weir-hook"))
    }

    /// The status line relay takes the person's status line only from the
    /// settings files Claude Code reads for this launch, which it learns from
    /// what the shim writes: Claude Code's default, then each value as
    /// written, an empty line for `--restricted`, and `user` for
    /// `--project-config-root`.
    @Test("hands the agent the launch's setting sources for the status line relay")
    func launch_passesTheSettingSources() throws {
        let variable = try StatusLineContract.settingSourcesVariable()
        let every = StatusLineContract.everySource
        let plain = try runShimHosted([], underPTY: false)
        #expect(plain.claudeEnvironment[variable] == every)

        let chosen = try runShimHosted(
            ["--setting-sources", "user", "--setting-sources=project, local", "--restricted", "--project-config-root=x"],
            underPTY: false
        )
        #expect(chosen.claudeEnvironment[variable] == "\(every)\nuser\nproject, local\n\nuser")

        let hosted = try runShimHosted(["--resume", "abc", "--setting-sources", "user"])
        #expect(!hosted.tmux.isEmpty)
        #expect(hosted.claudeEnvironment[variable] == "\(every)\nuser")

        // A value an enclosing claude's shim wrote belongs to that launch.
        let nested = try runShimHosted([], environment: [variable: "\(every)\n"], underPTY: false)
        #expect(nested.claudeEnvironment[variable] == every)
    }

    @Test("starts a hosted agent with an emptied record directory empty")
    func hostedLaunch_passesEmptyRecordDirectories() throws {
        // A demo pane empties them; the session must not take the tmux
        // server's values, which are another build's directories.
        let handover = try runShimHosted([], environment: [
            "WEIR_AGENT_STATES_DIR": "",
            "WEIR_SESSIONS_DIR": ""
        ])
        #expect(handover.claudeEnvironment["WEIR_AGENT_STATES_DIR"] == "")
        #expect(handover.claudeEnvironment["WEIR_SESSIONS_DIR"] == "")
        // One the pane does not set stays unset.
        #expect(!handover.tmux.isEmpty)
        #expect(handover.claudeEnvironment["WEIR_CWD_EVENTS_DIR"] == nil)
    }

    /// The rest of Claude's allow list: a bare launch, and each spelling
    /// of the two ways back into a session.
    @Test("hosts each interactive entry point", arguments: [[], ["-r"], ["--resume"], ["--resume", "abc123"], ["-c"], ["--continue"]])
    func hostedInvocation_hostsTheInteractiveEntryPoints(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        let executable = try #require(handover.tmux.firstIndex(of: handover.temporaryFolder + "/fake-claude"))
        #expect(Array(handover.tmux.dropFirst(executable + 1)) == handover.claude)
        #expect(handover.claude.dropFirst(2) == args[...])
        #expect(try sessionStartCommand(handover.claude).hasSuffix("/weir-hook"))
        #expect(handover.claudeSawMode == "weirHosted")
        #expect(handover.exitStatus == 0)
    }

    /// A prompt and a subcommand look alike, and a flag the list does not
    /// name may come before either, so whatever does not start with an
    /// entry point runs directly; so does a one-shot flag anywhere, even
    /// after an entry point.
    @Test("runs anything it does not recognize directly", arguments: [
        ["fix the failing test"], ["mcp", "list"], ["--model", "opus"],
        ["-p", "hi"], ["--resume", "abc123", "--print"], ["-c", "-h"], ["--version"], ["--bg", "do a thing"]
    ])
    func hostedInvocation_runsWhatItDoesNotRecognizeDirectly(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.ranDirectly(args))
        #expect(handover.claudeSawMode == "unset")
    }

    /// Inside a session our folder is still on the PATH, so wrapping again
    /// would nest without bound. The tmux is then the person's own, which
    /// the host mode says, so a resume asks that tmux for its pane.
    @Test("does not wrap again once inside tmux, and names the tmux the person's")
    func insideTmux_handsOffDirectly_asManual() throws {
        let handover = try runShimHosted([], environment: ["TMUX": "/tmp/tmux-501/default,4242,0"])
        #expect(handover.ranDirectly([]))
        #expect(handover.claudeSawMode == "manual")
    }

    /// Hosting off, or a pane Weir did not name, leaves no host mode at
    /// all: neither ours nor the person's.
    @Test("does not host without a pane id or a tmux to run", arguments: [
        ["WEIR_PANE_ID": ""],
        ["WEIR_AGENT_TMUX": ""],
        ["WEIR_AGENT_TMUX": "/nonexistent/tmux"]
    ])
    func withoutPaneIDOrTmux_handsOffDirectly(_ environment: [String: String]) throws {
        let handover = try runShimHosted([], environment: environment)
        #expect(handover.ranDirectly([]))
        #expect(handover.claudeSawMode == "unset")
    }

    /// Hosting requires both streams to be terminals. Redirecting either
    /// under a PTY preserves the other as a terminal.
    @Test(arguments: RedirectedStream.allCases)
    private func withoutEitherTerminalStream_handsOffDirectly(_ stream: RedirectedStream) throws {
        let handover = try runShimHosted([], redirectedStream: stream)
        #expect(handover.ranDirectly([]))
        #expect(handover.claudeSawMode == "unset")
    }
}
