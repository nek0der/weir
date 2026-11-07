// StatusLineRelayTests.swift
// Weir — the Hook Helper's status line relay and the shim that installs it, run for real.
//
// The relay sits between Claude Code and the person's own status line. What
// they see must not change, so these pin that their command gets the very
// bytes Claude Code wrote and its output comes back as it was, while the
// plan usage lands where the usage panel reads it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// The status line values the shim, the Hook Helper, and the Rust side each
/// spell for themselves (`rust/fixtures/contract/shared-values.json`).
enum StatusLineContract {
    static func value(_ key: String) throws -> String {
        let root = try #require(RepoFixture.weirRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("rust/fixtures/contract/shared-values.json"))
        let shared = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(shared[key] as? String)
    }

    /// The variable the shim writes the launch's setting sources into.
    static func settingSourcesVariable() throws -> String {
        try value("claudeSettingSourcesVariable")
    }

    /// What the shim writes there for a launch with no `--setting-sources`.
    static let everySource = "user,project,local"
}

@Suite(
    "Status line relay",
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(1))
)
struct StatusLineRelayTests {
    private let input = Data(#"""
    {"model":{"display_name":"Opus"},"workspace":{"project_dir":"/nonexistent/project"},
     "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1793247600},
                    "seven_day":{"used_percentage":83,"resets_at":1793822400}}}
    """#.utf8)

    /// Runs the helper with `arguments`, `stdin` as its input, in `dir`.
    private func runHelper(
        _ arguments: [String],
        stdin: Data,
        environment: [String: String],
        in dir: URL
    ) throws -> TestProcess.Output {
        let helper = try #require(HookHelperFixture.helperURL)
        let output = try TestProcess.run(helper, arguments: arguments, environment: environment, stdin: stdin, cwd: dir)
        #expect(output.ending == .exited, "the helper did not exit within ten seconds")
        return output
    }

    /// The environment of a status line the shim launched with
    /// `settingSources` as the launch's sources (`nil`: a launch the shim did
    /// not describe).
    private func environment(
        in dir: URL,
        settingSources: String? = StatusLineContract.everySource
    ) throws -> [String: String] {
        var environment = ShimHarness.environment(in: dir, merging: [
            "CLAUDE_CONFIG_DIR": dir.appendingPathComponent("config").path,
            "WEIR_USAGE_DIR": dir.appendingPathComponent("usage").path
        ])
        let variable = try StatusLineContract.settingSourcesVariable()
        environment[variable] = settingSources
        return environment
    }

    /// `input` with `dir` as its project.
    private func projectInput(in dir: URL) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
        object["workspace"] = ["project_dir": dir.path]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func writeProjectSettings(_ settings: [String: Any], in dir: URL) throws {
        let folder = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: folder.appendingPathComponent("settings.json"))
    }

    private func writeUserSettings(_ settings: [String: Any], in dir: URL) throws {
        let config = dir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: config.appendingPathComponent("settings.json"))
    }

    @Test("runs the person's status line on the same input and keeps the usage")
    func relay_handsTheInputOnAndKeepsTheUsage() throws {
        try withTempDir { dir in
            // `cat` echoes what it was given, so the output shows the input
            // reached it byte for byte.
            try writeUserSettings(["statusLine": ["type": "command", "command": "printf 'mine:'; cat"]], in: dir)
            let output = try runHelper(["statusline", "claude"], stdin: input, environment: environment(in: dir), in: dir)

            #expect(output.status == 0)
            #expect(output.stdout == Data("mine:".utf8) + input)
            let record = try Data(contentsOf: PlanUsageRecordDirectory.recordURL(
                for: .claude,
                in: dir.appendingPathComponent("usage")
            ))
            let usage = try PlanUsage.decode(record)
            #expect(usage.windows.map(\.kind) == [PlanUsageWindow.fiveHour, PlanUsageWindow.sevenDay])
            #expect(usage.windows.map(\.usedPercent) == [42, 83])
        }
    }

    /// `claude --setting-sources user` keeps Claude Code from reading the
    /// project's settings, so the command a repository sets there must not
    /// run through the relay either.
    @Test("runs no project command for a launch that leaves the project's settings out")
    func relay_leavesOutTheSettingsTheLaunchLeftOut() throws {
        try withTempDir { dir in
            try writeProjectSettings(["statusLine": ["type": "command", "command": "echo project"]], in: dir)
            let project = try projectInput(in: dir)

            let everySource = try runHelper(["statusline", "claude"], stdin: project, environment: environment(in: dir), in: dir)
            #expect(everySource.status == 0)
            #expect(everySource.stdout == Data("project\n".utf8))

            let userOnly = try runHelper(
                ["statusline", "claude"],
                stdin: project,
                environment: environment(in: dir, settingSources: StatusLineContract.everySource + "\nuser"),
                in: dir
            )
            #expect(userOnly.status == 0)
            #expect(userOnly.stdout.isEmpty)

            try writeUserSettings(["statusLine": ["type": "command", "command": "echo mine"]], in: dir)
            let withTheirOwn = try runHelper(
                ["statusline", "claude"],
                stdin: project,
                environment: environment(in: dir, settingSources: StatusLineContract.everySource + "\nuser"),
                in: dir
            )
            #expect(withTheirOwn.status == 0)
            #expect(withTheirOwn.stdout == Data("mine\n".utf8))
        }
    }

    /// Started without the shim's word on which settings the launch reads,
    /// the relay cannot tell whether Claude Code reads the project's, so it
    /// runs no command from a settings file.
    @Test("runs no settings file's command when it cannot tell what the launch reads")
    func relay_withoutTheLaunchsSources_runsNoFilesCommand() throws {
        try withTempDir { dir in
            try writeProjectSettings(["statusLine": ["type": "command", "command": "echo project"]], in: dir)
            try writeUserSettings(["statusLine": ["type": "command", "command": "echo mine"]], in: dir)
            for settingSources in [nil, StatusLineContract.everySource + "\nbogus"] {
                let output = try runHelper(
                    ["statusline", "claude"],
                    stdin: projectInput(in: dir),
                    environment: environment(in: dir, settingSources: settingSources),
                    in: dir
                )
                #expect(output.status == 0)
                #expect(output.stdout.isEmpty, "\(settingSources ?? "unset")")
            }
        }
    }

    @Test("prints nothing when the person has no status line of their own")
    func relay_withoutAStatusLine_printsNothing() throws {
        try withTempDir { dir in
            let output = try runHelper(["statusline", "claude"], stdin: input, environment: environment(in: dir), in: dir)
            #expect(output.status == 0)
            #expect(output.stdout.isEmpty)
        }
    }

    @Test("passes on the person's exit status")
    func relay_passesOnTheExitStatus() throws {
        try withTempDir { dir in
            try writeUserSettings(["statusLine": ["type": "command", "command": "echo shown; exit 3"]], in: dir)
            let output = try runHelper(["statusline", "claude"], stdin: input, environment: environment(in: dir), in: dir)
            #expect(output.status == 3)
            #expect(output.stdout == Data("shown\n".utf8))
        }
    }

    @Test("writes the relay into the settings with the person's options")
    func settings_carryThePersonsOptions() throws {
        try withTempDir { dir in
            try writeUserSettings(["statusLine": ["type": "command", "command": "mine.sh", "padding": 0]], in: dir)
            let document = try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": []]])
            let output = try runHelper(
                ["statusline", "claude", "settings", "/links/helper statusline claude"],
                stdin: document,
                environment: environment(in: dir),
                in: dir
            )
            #expect(output.status == 0)
            let settings = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
            #expect(settings["hooks"] as? [String: [String]] == ["Stop": []])
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            #expect(statusLine["type"] as? String == "command")
            // The command names the sources the launch loads itself, which a
            // settings file's `env` block cannot widen.
            let variable = try StatusLineContract.settingSourcesVariable()
            #expect(statusLine["command"] as? String == "\(variable)=user,project,local /links/helper statusline claude")
            #expect(statusLine["padding"] as? Int == 0)
        }
    }

    @Test("leaves the status line slot empty when the person has none")
    func settings_withoutAStatusLine_leaveTheSlotEmpty() throws {
        try withTempDir { dir in
            let document = Data(#"{"hooks":{}}"#.utf8)
            let output = try runHelper(
                ["statusline", "claude", "settings", "/links/helper statusline claude"],
                stdin: document,
                environment: environment(in: dir),
                in: dir
            )
            #expect(output.status == 0)
            #expect(output.stdout == document)
        }
    }

    @Test("leaves the settings alone when they are not a document")
    func settings_unreadable_failWithoutOutput() throws {
        try withTempDir { dir in
            let output = try runHelper(
                ["statusline", "claude", "settings", "/links/helper statusline claude"],
                stdin: Data("not json".utf8),
                environment: environment(in: dir),
                in: dir
            )
            #expect(output.status != 0)
            #expect(output.stdout.isEmpty)
        }
    }
}

/// The relay's answer is read with a type now, as it was read with a
/// dictionary before: a command that is not a string is none, and an answer
/// that is not an object is no answer.
@Suite("RustStatusLineBridge answer")
struct StatusLineAnswerTests {
    @Test(arguments: [
        (#"{"command":"echo hi"}"#, "echo hi"),
        (#"{}"#, nil),
        (#"{"command":null}"#, nil),
        (#"{"command":42}"#, nil)
    ] as [(String, String?)])
    func commandAnswer_readsOnlyAString(answer: String, command: String?) throws {
        #expect(try RustStatusLineBridge.command(fromAnswer: Data(answer.utf8)) == command)
    }

    @Test(arguments: ["[]", "{", "\"text\""])
    func commandAnswer_thatIsNotAnObject_isInvalid(answer: String) {
        let error = #expect(throws: AgentIntegrationError.self) {
            try RustStatusLineBridge.command(fromAnswer: Data(answer.utf8))
        }
        #expect(error?.description == AgentIntegrationError.invalidResponse.description)
    }
}

@Suite(
    "Claude shim status line",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(1))
)
struct ClaudeShimStatusLineTests {
    /// The shim run from a bundle's layout, which it needs to find the
    /// helper (`Contents/MacOS` beside `Contents/Resources`), with a stub in
    /// place of the real claude. A bundle takes no override of the real
    /// claude, so the stub is the one on the PATH. Returns the settings it
    /// passed.
    private func shimSettings(
        _ arguments: [String],
        userStatusLine: [String: Any]? = nil,
        projectStatusLine: [String: Any]? = nil,
        in dir: URL
    ) throws -> [String: Any] {
        if let projectStatusLine {
            let folder = dir.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["statusLine": projectStatusLine])
                .write(to: folder.appendingPathComponent("settings.json"))
        }
        if let userStatusLine {
            let config = dir.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["statusLine": userStatusLine])
                .write(to: config.appendingPathComponent("settings.json"))
        }
        let contents = try ShimHarness.bundleContents(in: dir)
        let shimFolder = contents.appendingPathComponent("Resources/claude-shim")
        try FileManager.default.createSymbolicLink(
            at: contents.appendingPathComponent("MacOS/AgentIntegrationHookHelper"),
            withDestinationURL: #require(HookHelperFixture.helperURL)
        )

        let argvFile = dir.appendingPathComponent("argv.txt")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try ShimHarness.writeExecutable(ShimHarness.argvRecorder(into: argvFile), at: bin.appendingPathComponent("claude"))
        var environment = ShimHarness.environment(in: dir)
        environment["PATH"] = "\(bin.path):\(ShimHarness.systemPath)"
        environment["CLAUDE_CONFIG_DIR"] = dir.appendingPathComponent("config").path
        let process = try ShimHarness.run(
            shimFolder.appendingPathComponent("claude"),
            arguments,
            environment: environment,
            currentDirectory: dir
        )
        #expect(process.terminationStatus == 0)

        let argv = try #require(ShimHarness.recordedArgv(argvFile))
        let flag = try #require(argv.firstIndex(of: "--settings"))
        #expect(argv.count(where: { $0 == "--settings" }) == 1)
        let data = Data(argv[flag + 1].utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The relay's arguments as the Rust side recognizes its own relay by
    /// them (`rust/fixtures/contract/shared-values.json`).
    private static func relayArguments() throws -> String {
        try StatusLineContract.value("claudeStatusLineRelayArguments")
    }

    @Test("puts the relay in the status line slot beside the hooks")
    func shim_installsTheRelay() throws {
        try withTempDir { dir in
            let settings = try shimSettings([], userStatusLine: ["type": "command", "command": "mine.sh"], in: dir)
            #expect(settings["hooks"] != nil)
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            let command = try #require(statusLine["command"] as? String)
            #expect(try command.hasSuffix("/AgentIntegrationHookHelper \(Self.relayArguments())"))
            #expect(!command.contains(" Weir.app"))
        }
    }

    @Test("leaves the slot empty when the person has no status line")
    func shim_withoutAStatusLine_setsNone() throws {
        try withTempDir { dir in
            let settings = try shimSettings([], in: dir)
            #expect(settings["hooks"] != nil)
            #expect(settings["statusLine"] == nil)
        }
    }

    /// The shim launches Claude Code with the status line it finds the way
    /// Claude Code would. A launch that leaves the project's settings out
    /// takes none from them, so a repository's status line does not reach
    /// the slot through ours; the person's own still does, with its options.
    @Test("takes no status line from settings the launch leaves out", arguments: [
        ["--setting-sources", "user"],
        ["--setting-sources=local"],
        ["--setting-sources", "project,local", "--setting-sources", "user"],
        ["--restricted"],
        // Moves the project's files to a folder the relay does not follow.
        ["--project-config-root", "elsewhere"]
    ])
    func shim_leavesOutTheSettingsTheLaunchLeftOut(_ arguments: [String]) throws {
        let project = ["type": "command", "command": "project.sh"]
        try withTempDir { dir in
            let without = try shimSettings(arguments, projectStatusLine: project, in: dir)
            #expect(without["statusLine"] == nil)
        }
        try withTempDir { dir in
            let read = try shimSettings([], projectStatusLine: project, in: dir)
            #expect(read["statusLine"] != nil)
        }
    }

    @Test("keeps the relay when the person passes a status line of their own")
    func shim_userSettings_keepTheRelay() throws {
        try withTempDir { dir in
            let theirs = #"{"statusLine":{"type":"command","command":"theirs.sh","padding":2}}"#
            let settings = try shimSettings(["--settings", theirs], in: dir)
            let statusLine = try #require(settings["statusLine"] as? [String: Any])
            #expect(try (statusLine["command"] as? String)?.hasSuffix(" \(Self.relayArguments())") == true)
            // Their options carry over; their command runs inside the relay.
            #expect(statusLine["padding"] as? Int == 2)
        }
    }
}
