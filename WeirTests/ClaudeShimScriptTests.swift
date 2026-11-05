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
            let process = try ShimHarness.run(shim, args, environment: environment)
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            return ShimHarness.recordedArgv(argvFile) ?? []
        }
    }

    /// The value of the single `--settings` the shim passed, decoded.
    private func settingsPayload(
        in argv: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any]? {
        let flags = argv.indices.filter { argv[$0] == "--settings" }
        #expect(
            flags.count == 1,
            "expected exactly one --settings, got \(flags.count)",
            sourceLocation: sourceLocation
        )
        guard let index = flags.first, index + 1 < argv.count else { return nil }
        let raw = argv[index + 1]
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func sessionStartGroups(_ payload: [String: Any]?) -> [[String: Any]] {
        let hooks = payload?["hooks"] as? [String: Any]
        return hooks?["SessionStart"] as? [[String: Any]] ?? []
    }

    private func sessionStartCommand(_ argv: [String]) throws -> String {
        let decodedPayload = try settingsPayload(in: argv)
        let payload = try #require(decodedPayload)
        let group = try #require(sessionStartGroups(payload).first)
        let hooks = try #require(group["hooks"] as? [[String: Any]])
        return try #require(hooks.first?["command"] as? String)
    }

    @Test("injects our settings when the user passes none")
    func noUserSettings_injectsOurs() throws {
        let argv = try runShim([])
        let payload = try settingsPayload(in: argv)
        #expect(sessionStartGroups(payload).count == 1)
    }

    /// The hook path is captured by a running Claude process. Separate stable
    /// names let a new invocation refresh its own build without redirecting a
    /// session launched by another installed build.
    @Test("namespaces the no-space hook link by build identity")
    func hookLink_separatesBuilds() throws {
        let releaseArguments = try runShim([], hookNamespace: "com.nekoder.Weir")
        let release = try sessionStartCommand(releaseArguments)
        let developmentArguments = try runShim([], hookNamespace: "com.nekoder.Weir.dev")
        let development = try sessionStartCommand(developmentArguments)

        #expect(release.hasSuffix("/weir-claude-shim-com.nekoder.Weir/weir-hook"))
        #expect(development.hasSuffix("/weir-claude-shim-com.nekoder.Weir.dev/weir-hook"))
        #expect(release != development)
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

    @Test("merges with the user's settings instead of losing to them")
    func userSettings_mergedRatherThanOverwritten() throws {
        let theirs = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/true"}]}]},"env":{"USER_KEY":"1"}}"#
        let argv = try runShim(["--settings", theirs])
        let payload = try settingsPayload(in: argv)
        // Both hook groups survive, and the user's unrelated keys come along.
        #expect(sessionStartGroups(payload).count == 2)
        #expect((payload?["env"] as? [String: Any])?["USER_KEY"] as? String == "1")
    }

    @Test("merges the --settings=value spelling too")
    func userSettingsEqualsForm_merged() throws {
        let theirs = #"{"env":{"USER_KEY":"1"}}"#
        let argv = try runShim(["--settings=\(theirs)"])
        let payload = try settingsPayload(in: argv)
        #expect(sessionStartGroups(payload).count == 1)
        #expect((payload?["env"] as? [String: Any])?["USER_KEY"] as? String == "1")
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
            #expect(shell.waitUntilExit(within: 10))
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
        let argv = try runShim(
            ["--version"],
            prepareTemporaryDirectory: { dir in
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("a\tb"),
                    withIntermediateDirectories: true
                )
            },
            temporaryDirectory: { $0.appendingPathComponent("a\tb") }
        )
        #expect(argv == ["--version"])
    }

    @Test("passes an unmergeable user value straight through")
    func unmergeableUserSettings_leftAlone() throws {
        let argv = try runShim(["--settings", "{bad"])
        let flags = argv.indices.filter { argv[$0] == "--settings" }
        #expect(flags.count == 1)
        #expect(flags.first.map { argv[$0 + 1] } == "{bad")
    }

    @Test("leaves Claude's status reports on: sets no title switch of its own")
    func terminalTitleSwitch_isLeftUnset() throws {
        try withTempDir { dir in
            let stub = dir.appendingPathComponent("fake-claude")
            // The switch also turns off Claude's OSC 7501 reports, which the
            // projection reads (`PaneProgramStatusStore`).
            try ShimHarness.writeExecutable("""
            #!/bin/sh
            [ -z "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE+set}" ]
            """, at: stub)

            var environment = ShimHarness.environment(in: dir)
            environment["WEIR_CLAUDE_SETTINGS_TEMPLATE"] = try ShimHarness.claudeSettingsTemplate()
            environment["WEIR_REAL_CLAUDE"] = stub.path
            environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_TERMINAL_TITLE")
            let process = try ShimHarness.run(ShimHarness.shim("claude"), [], environment: environment)

            #expect(process.terminationStatus == 0)
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
            let losesFile = losesSavedEnvironment ? """
            previous=""
            for arg in "$@"; do
              [ "$previous" = weir-env ] && rm -f -- "$arg"
              previous=$arg
            done
            exec 2>"\(tmuxArgv.path).stderr"
            """ : ""
            try ShimHarness.writeExecutable(
                ShimHarness.fakeTmux(into: tmuxArgv, then: seen(tmuxArgv) + "\n" + losesFile),
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
            let process = try ShimHarness.run(
                ShimHarness.shim("claude"),
                args,
                environment: shimEnvironment,
                underPTY: underPTY,
                currentDirectory: files.isEmpty ? nil : dir
            )

            func argv(_ url: URL) -> [String] {
                ShimHarness.recordedArgv(url) ?? []
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
            tmux.isEmpty && claude.contains("--settings") && claude.suffix(args.count) == args[...]
        }
    }

    /// The hooks are the reason the shim exists, so they have to survive
    /// being handed to tmux rather than exec'd directly. tmux runs
    /// multiple arguments as an argv, which is what keeps the settings
    /// JSON — quotes, braces and all — out of a shell.
    @Test("keeps our settings flag when the agent is hosted in tmux")
    func hostedInvocation_stillCarriesTheSettingsFlag() throws {
        let handover = try runShimHosted([])
        #expect(handover.tmux.prefix(4) == ["-L", "weir-test.socket", "-f", "/dev/null"])
        // The session's command reads the pane's environment back, then
        // starts the agent with our flag.
        let session = try #require(handover.tmux.firstIndex(of: "new-session"))
        #expect(handover.tmux[(session + 3)...].prefix(2) == ["/bin/sh", "-c"])
        #expect(handover.tmux[session + 6] == "weir-env")
        #expect(handover.tmux[session + 8].hasSuffix("/fake-claude"))
        #expect(handover.tmux[session + 9] == "--settings")
        let payload = try JSONSerialization.jsonObject(
            with: Data(handover.tmux[session + 10].utf8)
        ) as? [String: Any]
        #expect(payload?["hooks"] != nil)
        #expect(handover.claude.first == "--settings")
        #expect(handover.claudeEnvironment["WEIR_AGENT_RUN_ID"]?.isEmpty == false)
        #expect(handover.claudeSawMode == "weirHosted")
    }

    /// `--bg` prints a session id and returns, so hosting it would put
    /// that id on a screen tmux erases on the way out.
    @Test(
        "runs a one-shot invocation directly even when hosting is on",
        arguments: [["--version"], ["--bg", "do a thing"]]
    )
    func hostedInvocation_leavesOneShotsAlone(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.tmux.isEmpty)
        #expect(handover.claude.contains(args[0]))
    }

    /// `--resume` is one of the two ways back into an existing session,
    /// so it is on the allow list even though it carries arguments.
    @Test("hosts a resume")
    func hostedInvocation_hostsAResume() throws {
        let handover = try runShimHosted(["--resume", "abc123"])
        #expect(handover.tmux.suffix(2) == ["--resume", "abc123"])
        #expect(handover.claude.suffix(2) == ["--resume", "abc123"])
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
        #expect(env["HOME"] != ShimHarness.tmuxServerEnvironment["HOME"])
        for (name, value) in ShimHarness.tmuxSessionVariables {
            #expect(env[name] == value, "\(name)")
        }
        #expect(env["WEIR_PANE_ID"] == "547D688D-39DF-4A06-BD6F-316C3385532C")
        #expect(handover.leftEnvironmentFiles.isEmpty)
        // Nothing of the environment travels on tmux's command line.
        #expect(!handover.tmux.contains { $0.contains("PERSON_EXPORT") })
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
        let handover = try runShimHosted([], environment: ["PERSON_EXPORT": "this pane's"], othersCanWrite: true)
        let saved = try #require(handover.savedEnvironmentFile)
        #expect(!saved.hasPrefix(handover.temporaryFolder))
        #expect(!FileManager.default.fileExists(atPath: saved))
        #expect(handover.claudeEnvironment["PERSON_EXPORT"] == "this pane's")
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
        let handover = try runShimHosted([])
        #expect(handover.claudeEnvironment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
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
        #expect(value.hasPrefix("/"))
        #expect(value.hasSuffix("/relative/config"))

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
        #expect(value.hasPrefix("/"))
        #expect(value.hasSuffix("/mine.json"))

        // Inline JSON is passed as written, blanks before it included, and
        // merged as JSON rather than read as a file of that name.
        let inline = "  \n {\"model\":\"opus\"}"
        let handover = try runShimHosted(["--resume", "abc", "--settings", inline])
        #expect(handover.claudeEnvironment["WEIR_CLAUDE_USER_SETTINGS"] == inline)
        let settings = try #require(handover.tmux.firstIndex(of: "--settings"))
        let payload = try JSONSerialization.jsonObject(with: Data(handover.tmux[settings + 1].utf8)) as? [String: Any]
        #expect(payload?["model"] as? String == "opus")
        #expect(payload?["hooks"] != nil)
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
    @Test("hosts each interactive entry point", arguments: [[], ["-r"], ["--resume"], ["-c"], ["--continue"]])
    func hostedInvocation_hostsTheInteractiveEntryPoints(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.tmux.contains("new-session"))
        #expect(handover.tmux.suffix(args.count) == args[...])
    }

    /// A prompt and a subcommand look alike, and a flag the list does not
    /// name may come before either, so whatever does not start with an
    /// entry point runs directly; so does a one-shot flag anywhere, even
    /// after an entry point.
    @Test("runs anything it does not recognize directly", arguments: [
        ["fix the failing test"], ["mcp", "list"], ["--model", "opus"],
        ["-p", "hi"], ["--resume", "abc123", "--print"], ["-c", "-h"]
    ])
    func hostedInvocation_runsWhatItDoesNotRecognizeDirectly(_ args: [String]) throws {
        let handover = try runShimHosted(args)
        #expect(handover.ranDirectly(args))
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

    /// Output that is not a terminal is output someone means to keep,
    /// which a tmux client would take to a screen it erases.
    @Test("runs directly when its output is not a terminal")
    func withoutATerminal_handsOffDirectly() throws {
        let handover = try runShimHosted([], underPTY: false)
        #expect(handover.ranDirectly([]))
    }
}
