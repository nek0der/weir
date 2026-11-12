// KiroShimTests.swift
// Weir — the kiro-cli shim places its hook file, keeps the person's edits, reports a v3 launch, and its hooks never hold a turn open.

import Foundation
import Testing
import WeirDomain
@testable import Weir

@Suite("Kiro shim")
struct KiroShimTests {
    private func bundledHooks() throws -> URL {
        try AgentCatalogFixture.shimFolder("kiro-hooks").appendingPathComponent("weir.json")
    }

    private func placedHooks(in home: URL) -> URL {
        home.appendingPathComponent(".kiro/hooks/weir.json")
    }

    /// Runs the shim with `home` as the home folder and a stub for `kiro-cli`
    /// that writes its arguments and environment beside itself.
    @discardableResult
    private func runShim(
        root: URL,
        home: URL,
        args: [String] = [],
        states: String = "/tmp/states",
        environment: [String: String] = [:],
        helper: URL? = nil,
        underPTY: Bool = false
    ) throws -> Process {
        let stub = root.appendingPathComponent("real-kiro")
        try AgentCatalogFixture.makeExecutable(
            stub,
            script: """
            #!/bin/sh
            printf '%s\\n' "$@" > \(ShellQuote.single(root.appendingPathComponent("args").path))
            env > \(ShellQuote.single(root.appendingPathComponent("env").path))
            """
        )
        var base = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "WEIR_REAL_KIRO": stub.path,
            "WEIR_KIRO_AGENT_STATES_DIR": states
        ]
        if let helper {
            base["WEIR_HOOK_HELPER"] = helper.path
        }
        return try ShimHarness.run(
            AgentCatalogFixture.shim(for: .kiro),
            args,
            environment: base.merging(environment) { _, new in new },
            underPTY: underPTY,
            currentDirectory: root
        )
    }

    /// Runs the shim with a stub helper, and returns what it sent the hook:
    /// `nil` when it reported no launch. `underPTY` makes its stdin a
    /// terminal, as an interactive chat's is.
    private func launchReport(
        root: URL,
        home: URL,
        args: [String],
        states: String = "/tmp/states",
        environment: [String: String] = [:],
        underPTY: Bool = false
    ) throws -> [String: Any]? {
        let report = root.appendingPathComponent("report")
        // A report left by an earlier launch in the same folder must not
        // answer for this one.
        try? FileManager.default.removeItem(at: report)
        let helper = root.appendingPathComponent("helper")
        try AgentCatalogFixture.makeExecutable(
            helper,
            script: "#!/bin/sh\n[ \"$1\" = hook ] && printf '%s\\0' \"$@\" > \(ShellQuote.single(report.path))\nexit 0\n"
        )
        let process = try runShim(
            root: root, home: home, args: args, states: states, environment: environment, helper: helper, underPTY: underPTY
        )
        #expect(process.terminationStatus == 0)
        guard let data = try? Data(contentsOf: report) else { return nil }
        return try HookReportFixture.object(data)
    }

    // MARK: - The hook file

    @Test func shim_placesTheHookFile_inKirosFolder_andNamesTheHook() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            #expect(try Data(contentsOf: placedHooks(in: home)) == Data(contentsOf: bundledHooks()))
            let environment = try String(contentsOf: root.appendingPathComponent("env"), encoding: .utf8)
            #expect(environment.contains("WEIR_KIRO_HOOK_DIR="))
            #expect(environment.contains("WEIR_KIRO_PID="))
            // Nothing staged is left behind.
            let left = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".kiro/hooks").path)
            #expect(Set(left) == ["weir.json", ".weir.json.cksum"])
            // The checksum kept is the placed file's, so the next launch knows
            // the file as ours.
            #expect(try storedChecksum(in: home) == Self.cksum(of: placedHooks(in: home)))
        }
    }

    private func storedChecksum(in home: URL) throws -> String {
        try String(contentsOf: home.appendingPathComponent(".kiro/hooks/.weir.json.cksum"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func shim_leavesAHookFileThatIsNotOurs() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let theirs = placedHooks(in: home)
            try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: theirs)
            try runShim(root: root, home: home)
            #expect(try String(contentsOf: theirs, encoding: .utf8) == "theirs")
        }
    }

    /// A file of ours the person has edited since (a hook turned off, say) is
    /// theirs from then on.
    @Test func shim_leavesOurHookFile_onceThePersonEditedIt() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            try runShim(root: root, home: home)
            let placed = placedHooks(in: home)
            let edited = try String(contentsOf: placed, encoding: .utf8)
                .replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false")
            try Data(edited.utf8).write(to: placed)
            try runShim(root: root, home: home)
            #expect(try String(contentsOf: placed, encoding: .utf8) == edited)
        }
    }

    /// An older file of ours, left as we wrote it, is replaced by this build's.
    @Test func shim_replacesAnOlderVersionOfOurs() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let placed = placedHooks(in: home)
            try FileManager.default.createDirectory(at: placed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"version\":\"v1\",\"hooks\":[]}\n".utf8).write(to: placed)
            let sum = try Self.cksum(of: placed)
            try Data("\(sum)\n".utf8).write(to: placed.deletingLastPathComponent().appendingPathComponent(".weir.json.cksum"))
            try runShim(root: root, home: home)
            #expect(try Data(contentsOf: placed) == Data(contentsOf: bundledHooks()))
            #expect(try storedChecksum(in: home) == Self.cksum(of: placed))
        }
    }

    @Test func shim_leavesALink() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let placed = placedHooks(in: home)
            let target = root.appendingPathComponent("elsewhere.json")
            try Data("elsewhere".utf8).write(to: target)
            try FileManager.default.createDirectory(at: placed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: placed, withDestinationURL: target)
            try runShim(root: root, home: home)
            #expect(try String(contentsOf: target, encoding: .utf8) == "elsewhere")
            // The link itself is left, not replaced by a file of ours.
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: placed.path) == target.path)
        }
    }

    @Test func shim_inADemoPane_placesNothing() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            try runShim(root: root, home: home, states: "")
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".kiro").path))
        }
    }

    // MARK: - The launch report

    @Test func shim_reportsAV3Launch_withItsFolderAndTrust() throws {
        try withTempDir { root in
            let report = try #require(try launchReport(root: root, home: root.appendingPathComponent("home"), args: ["--v3", "-a"]))
            #expect(report["hook_event_name"] as? String == "WeirLaunch")
            #expect(report["session_id"] as? String == "")
            // The shim names its folder by `pwd -P`; the temporary folder lies
            // under `/private`, which Foundation leaves off.
            #expect(["/private" + root.path, root.path].contains(report["cwd"] as? String ?? ""))
            #expect(report["trust_all_tools"] as? Bool == true)
            #expect(try String(contentsOf: root.appendingPathComponent("args"), encoding: .utf8) == "--v3\n-a\n")
        }
    }

    /// `-a` written together with another short flag still trusts every tool.
    @Test func shim_readsTrustFromShortFlagsWrittenTogether() throws {
        try withTempDir { root in
            let report = try #require(try launchReport(root: root, home: root.appendingPathComponent("home"), args: ["--v3", "-ra"]))
            #expect(report["trust_all_tools"] as? Bool == true)
        }
    }

    @Test(arguments: [["--v3", "--resume-id", #"a"b\c"#], ["chat", "--v3", #"--resume-id=a"b\c"#]])
    func shim_reportsTheSessionOfAResume_escaped(args: [String]) throws {
        try withTempDir { root in
            let report = try #require(try launchReport(root: root, home: root.appendingPathComponent("home"), args: args))
            #expect(report["session_id"] as? String == #"a"b\c"#)
            #expect(report["trust_all_tools"] as? Bool == false)
        }
    }

    /// Kiro's own engine choice, which the shim never changes: v3 by an
    /// argument, the variable, or the person's settings, and with none of
    /// them v3 for an interactive chat (kiro-cli 3.2.0). These runs' stdin is
    /// not a terminal, so with nothing chosen they are not interactive.
    @Test func shim_reportsALaunch_onlyWhenItRunsV3() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            #expect(try launchReport(root: root, home: home, args: []) == nil)
            // Kiro runs v3 without a terminal only when it trusts every tool.
            #expect(try launchReport(root: root, home: home, args: ["-a"]) != nil)
            #expect(try launchReport(root: root, home: home, args: ["--agent-engine", "v2"]) == nil)
            #expect(try launchReport(root: root, home: home, args: ["--v3", "--v2"]) == nil)
            #expect(try launchReport(root: root, home: home, args: ["--agent-engine=v3"]) != nil)
            #expect(try launchReport(root: root, home: home, args: [], environment: ["KIRO_AGENT_ENGINE": "v3"]) != nil)
            let settings = home.appendingPathComponent(".kiro/settings/cli.json")
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"chat.agentEngine": "v3"}"#.utf8).write(to: settings)
            #expect(try launchReport(root: root, home: home, args: []) != nil)
            // The value may sit on a line of its own.
            try Data("{\"chat.agentEngine\":\r\n  \"v3\"}\n".utf8).write(to: settings)
            #expect(try launchReport(root: root, home: home, args: []) != nil)
            // The folder's own settings come before the person's.
            let folderSettings = root.appendingPathComponent(".kiro/settings/cli.json")
            try FileManager.default.createDirectory(at: folderSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"chat.agentEngine": "v2"}"#.utf8).write(to: folderSettings)
            #expect(try launchReport(root: root, home: home, args: []) == nil)
            try FileManager.default.removeItem(at: folderSettings)
            // The shim adds no engine of its own: the stub prints one empty line
            // for no arguments.
            #expect(try String(contentsOf: root.appendingPathComponent("args"), encoding: .utf8) == "\n")
        }
    }

    /// With nothing that chooses an engine, an interactive chat runs v3, and
    /// one Kiro runs without its interface runs v2 unless it trusts every tool
    /// (kiro-cli 3.2.0).
    @Test(arguments: [
        ([String](), true), (["chat"], true), (["--agent-engine", "v2"], false),
        (["chat", "--no-interactive"], false), (["chat", "--output-format", "stream-json"], false),
        (["chat", "--output-format=stream-json"], false), (["chat", "--output-format=stream-json", "-a"], true)
    ])
    func shim_inATerminal_reportsALaunch_whenKiroDefaultsToV3(args: [String], isReported: Bool) throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: args, underPTY: true)
            #expect((report != nil) == isReported)
        }
    }

    /// A flag's value is not the subcommand, so `--agent` still starts a chat.
    @Test func shim_reportsALaunch_whenAFlagTakesAValue() throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: ["--v3", "--agent", "reviewer"])
            #expect(report != nil)
        }
    }

    @Test(arguments: [
        ["login"], ["--v3", "--help"], ["--v3", "-V"], ["chat", "--v3", "--list-sessions"], ["settings", "list"],
        ["--v3", "settings", "list"], ["--v3", "--agent", "reviewer", "mcp", "list"],
        // A cloud session runs where no hook of ours runs (kiro-cli 3.2.0).
        ["--v3", "--cloud", "--repo", "owner/name"], ["--v3", "crew"]
    ])
    func shim_reportsNoLaunch_forWhatRunsNoHookOfOurs(args: [String]) throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: args)
            #expect(report == nil)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("args").path))
        }
    }

    @Test(arguments: ["project\n", "tab\tquote\"backslash\\end\n"])
    func shim_preservesControlCharactersInTheLaunchFolder(name: String) throws {
        try withTempDir { root in
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report = try #require(try launchReport(root: folder, home: root.appendingPathComponent("home"), args: ["--v3"]))
            // The temporary folder lies under `/private`, which Foundation
            // leaves off and the shell's own folder keeps.
            #expect(["/private" + folder.path, folder.path].contains(report["cwd"] as? String ?? ""))
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("args").path))
        }
    }

    @Test func shim_inADemoPane_reportsNoLaunch() throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: ["--v3"], states: "")
            #expect(report == nil)
        }
    }

    /// With a hook file that is not ours, or ours edited, no hook may follow.
    @Test func shim_withAHookFileThatIsNotOurs_reportsNoLaunch() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let theirs = placedHooks(in: home)
            try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: theirs)
            #expect(try launchReport(root: root, home: home, args: ["--v3"]) == nil)
        }
    }

    @Test func shim_withABrokenHook_stillStartsKiro() throws {
        try withTempDir { root in
            let process = try runShim(root: root, home: root.appendingPathComponent("home"), args: ["--v3"])
            #expect(process.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("args").path))
        }
    }

    /// Inside an app bundle, `WEIR_REAL_KIRO` never picks the agent the shim
    /// starts.
    @Test func shim_inABundle_ignoresTheRealKiroOverride() throws {
        try withTempDir { root in
            let contents = try ShimHarness.bundleContents(in: root)
            let override = root.appendingPathComponent("override")
            try AgentCatalogFixture.makeExecutable(override, script: "#!/bin/sh\ntouch \"\(root.path)/overridden\"\n")
            let bin = root.appendingPathComponent("bin")
            try AgentCatalogFixture.makeExecutable(
                bin.appendingPathComponent("kiro-cli"),
                script: "#!/bin/sh\ntouch \"\(root.path)/onpath\"\n"
            )
            try ShimHarness.run(
                contents.appendingPathComponent("Resources/kiro-shim/kiro-cli"),
                [],
                environment: [
                    "HOME": root.path,
                    "PATH": "\(bin.path):/usr/bin:/bin",
                    "WEIR_REAL_KIRO": override.path
                ]
            )
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("onpath").path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("overridden").path))
        }
    }

    // MARK: - The hooks' commands

    /// The bundled file's hooks, by name.
    private func bundledHookEntries() throws -> [String: [String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: bundledHooks())) as? [String: Any]
        let hooks = try #require(object?["hooks"] as? [[String: Any]])
        var entries: [String: [String: Any]] = [:]
        for hook in hooks {
            let name = try #require(hook["name"] as? String)
            entries[name] = hook
        }
        return entries
    }

    /// Each hook's command, by name, from the bundled file.
    private func hookCommands() throws -> [String: String] {
        try bundledHookEntries().compactMapValues { ($0["action"] as? [String: Any])?["command"] as? String }
    }

    /// Runs a hook's command as Kiro does, through `sh -c`, with a stand-in
    /// `weir-hook` that exits `status`.
    private func runHookCommand(_ command: String, hookStatus status: Int32?, root: URL) throws -> Int32 {
        var environment = ["PATH": "/usr/bin:/bin"]
        if let status {
            try AgentCatalogFixture.makeExecutable(
                root.appendingPathComponent("weir-hook"),
                script: "#!/bin/sh\ncat > /dev/null\ntouch \"\(root.path)/called\"\nexit \(status)\n"
            )
            environment["WEIR_KIRO_HOOK_DIR"] = root.path
        }
        let run = try TestProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: environment)
        #expect(run.ending == .exited)
        return run.status
    }

    /// The hooks we subscribe, each on its trigger and tools, and turned on:
    /// a hook on the wrong trigger or matcher reports nothing, and Kiro skips
    /// one turned off.
    @Test func theHooks_areTheOnesWeSubscribe() throws {
        let entries = try bundledHookEntries()
        let expected: [String: (trigger: String, matcher: String?)] = [
            "weir-session-start": ("SessionStart", nil),
            "weir-tool-start": ("PreToolUse", "*"),
            "weir-worktree-route": ("PreToolUse", "shell"),
            "weir-tool-end": ("PostToolUse", "*"),
            "weir-worktree-setup": ("PostToolUse", "shell"),
            "weir-stop": ("Stop", nil)
        ]
        #expect(Set(entries.keys) == Set(expected.keys))
        for (name, hook) in entries {
            #expect(hook["trigger"] as? String == expected[name]?.trigger, "\(name)")
            #expect(hook["matcher"] as? String == expected[name]?.matcher, "\(name)")
            #expect(hook["enabled"] as? Bool == true, "\(name)")
        }
    }

    /// Outside a launch through the shim, every hook does nothing and passes.
    @Test func everyHook_outsideWeir_passesAndCallsNothing() throws {
        try withTempDir { root in
            for (name, command) in try hookCommands() {
                #expect(try runHookCommand(command, hookStatus: nil, root: root) == 0, "\(name)")
            }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("called").path))
        }
    }

    /// Kiro continues a turn whose `Stop` hook exits 1, and refuses a tool on
    /// 2, so a hook that fails (a missing helper exits 1) must still pass.
    /// Only the worktree route's refusal, before the tool, gets through.
    @Test(arguments: [Int32(1), 2, 75])
    func aHookThatFails_stillPasses_butTheRoutesRefusalGetsThrough(status: Int32) throws {
        try withTempDir { root in
            let called = root.appendingPathComponent("called")
            for (name, command) in try hookCommands() {
                try? FileManager.default.removeItem(at: called)
                let expected: Int32 = name == "weir-worktree-route" && status == 2 ? 2 : 0
                #expect(try runHookCommand(command, hookStatus: status, root: root) == expected, "\(name)")
                // Every hook reached `weir-hook`, not only some.
                #expect(FileManager.default.fileExists(atPath: called.path), "\(name)")
            }
        }
    }

    private static func cksum(of url: URL) throws -> String {
        let run = try TestProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cksum < \"$1\"", "sh", url.path])
        return run.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
