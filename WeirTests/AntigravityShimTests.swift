// AntigravityShimTests.swift
// Weir — the agy shim places its plugin and the plugin's hook never fails a tool call.

import Foundation
import Testing
import WeirDomain
@testable import Weir

@Suite("Antigravity shim")
struct AntigravityShimTests {
    private func plugin() throws -> URL {
        try AgentCatalogFixture.shimFolder("antigravity-plugin")
    }

    /// Runs the shim with `home` as the home folder and a recording stub for
    /// `agy`, which writes its arguments and environment beside itself. The
    /// states folder is `states` when given (an empty string stands for a demo
    /// pane, which has none) and the test's own otherwise.
    private func runShim(
        root: URL,
        home: URL,
        args: [String] = [],
        states: String? = nil,
        environment: [String: String] = [:]
    ) throws -> Process {
        let stub = try ShimHarness.recordingStub(named: "real-agy", in: root)
        return try ShimHarness.run(
            AgentCatalogFixture.shim(for: .antigravity),
            args,
            environment: ShimHarness.environment(in: root, merging: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "WEIR_REAL_ANTIGRAVITY": stub.path,
                "WEIR_ANTIGRAVITY_AGENT_STATES_DIR": states ?? root.appendingPathComponent("states").path
            ].merging(environment) { _, new in new }),
            currentDirectory: root
        )
    }

    /// Runs the shim with a stub helper, and returns what it sent the hook:
    /// `nil` when it reported no launch.
    private func launchReport(
        root: URL,
        home: URL,
        args: [String],
        states: String? = nil
    ) throws -> [String: Any]? {
        let report = root.appendingPathComponent("report")
        let helper = root.appendingPathComponent("helper")
        try AgentCatalogFixture.makeExecutable(
            helper,
            script: "#!/bin/sh\n[ \"$1\" = hook ] && cat > \"\(report.path)\"\nexit 0\n"
        )
        let process = try runShim(root: root, home: home, args: args, states: states, environment: [
            "WEIR_HOOK_HELPER": helper.path
        ])
        #expect(process.terminationStatus == 0)
        guard let data = try? Data(contentsOf: report) else { return nil }
        return try JSONObjectFixture.object(data)
    }

    private func dispatch(
        _ arguments: [String],
        input: String,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let output = try TestProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: [plugin().appendingPathComponent("scripts/weir-dispatch").path] + arguments,
            environment: ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new },
            stdin: Data(input.utf8)
        )
        #expect(output.ending == .exited, "the dispatcher did not exit within ten seconds")
        return try (output.status, #require(String(bytes: output.stdout, encoding: .utf8)))
    }

    @Test func shim_placesThePlugin_inAgysFolder_andNamesTheHook() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            let placed = home.appendingPathComponent(".gemini/config/plugins/weir")
            #expect(FileManager.default.fileExists(atPath: placed.appendingPathComponent("hooks.json").path))
            #expect(FileManager.default.fileExists(atPath: placed.appendingPathComponent("scripts/weir-dispatch").path))
            let environment = try String(contentsOf: root.appendingPathComponent("env"), encoding: .utf8)
            let hook = try #require(environment.split(separator: "\n").first { $0.hasPrefix("WEIR_ANTIGRAVITY_HOOK_DIR=") })
            let directory = String(hook.dropFirst("WEIR_ANTIGRAVITY_HOOK_DIR=".count))
            let expectedDirectory = try AgentCatalogFixture.shimFolder("antigravity-shim")
            #expect(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path == expectedDirectory.resolvingSymlinksInPath().path)
            let pid = try #require(environment.split(separator: "\n").first { $0.hasPrefix("WEIR_ANTIGRAVITY_PID=") })
            #expect(Int32(pid.dropFirst("WEIR_ANTIGRAVITY_PID=".count)) == process.processIdentifier)
        }
    }

    @Test func shim_leavesAPluginThatIsNotOurs() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let theirs = home.appendingPathComponent(".gemini/config/plugins/weir")
            try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: theirs.appendingPathComponent("plugin.json"))
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            #expect(try String(contentsOf: theirs.appendingPathComponent("plugin.json"), encoding: .utf8) == "theirs")
        }
    }

    @Test func shim_replacesAnOlderVersionOfOurs() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let ours = home.appendingPathComponent(".gemini/config/plugins/weir")
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            try Data("0\n".utf8).write(to: ours.appendingPathComponent(".weir-managed"))
            _ = try runShim(root: root, home: home)
            #expect(FileManager.default.fileExists(atPath: ours.appendingPathComponent("hooks.json").path))
            let left = try FileManager.default.contentsOfDirectory(atPath: ours.deletingLastPathComponent().path)
            #expect(left == ["weir"])
        }
    }

    @Test func shim_inADemoPane_placesNothing() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, states: "")
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path))
        }
    }

    @Test func shim_reportsALaunch_withItsFolder() throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: [])
            #expect(report?["hook_event_name"] as? String == "WeirLaunch")
            #expect(report?["conversationId"] as? String == "")
            let folders = report?["workspacePaths"] as? [String]
            // By its last part: the temporary folder is reached through a link.
            #expect(folders?.first?.hasSuffix(root.lastPathComponent) == true)
        }
    }

    @Test(arguments: [["--conversation", #"a"b\c"#], [#"--conversation=a"b\c"#], ["--model", "m", "--conversation", #"a"b\c"#]])
    func shim_reportsTheConversationOfAResume_escaped(args: [String]) throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: args)
            #expect(report?["conversationId"] as? String == #"a"b\c"#)
        }
    }

    @Test(arguments: [["plugin", "list"], ["--help"], ["-v"], ["--model", "m", "--version"]])
    func shim_reportsNoLaunch_forWhatStartsNoAgent(args: [String]) throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: args)
            #expect(report == nil)
        }
    }

    @Test func shim_inADemoPane_reportsNoLaunch() throws {
        try withTempDir { root in
            let report = try launchReport(root: root, home: root.appendingPathComponent("home"), args: [], states: "")
            #expect(report == nil)
        }
    }

    @Test func shim_withAPluginThatIsNotOurs_reportsNoLaunch() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let theirs = home.appendingPathComponent(".gemini/config/plugins/weir")
            try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            let report = try launchReport(root: root, home: home, args: [])
            #expect(report == nil)
        }
    }

    /// The report comes before the shim's own `--settings`, and a helper that
    /// fails leaves `agy` to start.
    @Test func shim_withABrokenHook_stillStartsAgy() throws {
        try withTempDir { root in
            let called = root.appendingPathComponent("failed-hook")
            let helper = root.appendingPathComponent("helper")
            try AgentCatalogFixture.makeExecutable(
                helper,
                script: "#!/bin/sh\ncat > \"\(called.path)\"\nexit 3\n"
            )
            let process = try runShim(
                root: root,
                home: root.appendingPathComponent("home"),
                args: ["--conversation", "a"],
                environment: ["WEIR_HOOK_HELPER": helper.path]
            )
            let report = try JSONObjectFixture.object(Data(contentsOf: called))
            #expect(report["hook_event_name"] as? String == "WeirLaunch")
            #expect(report["conversationId"] as? String == "a")
            #expect(process.terminationStatus == 0)
            #expect(ShimHarness.recordedArgv(root.appendingPathComponent("args")) == ["--conversation", "a"])
        }
    }

    @Test func dispatch_outsideWeir_allowsAndDoesNothingElse() throws {
        let tool = try dispatch(["PreToolUse"], input: #"{"conversationId":"a"}"#)
        #expect(tool.status == 0)
        #expect(tool.output == "{\"decision\":\"allow\"}\n")
        let stop = try dispatch(["Stop"], input: #"{"conversationId":"a"}"#)
        #expect(stop.status == 0)
        #expect(stop.output == "{}\n")
    }

    /// `agy` fails the tool on any other result, so a hook that dies must
    /// still answer.
    @Test func dispatch_withABrokenHook_stillAllows() throws {
        try withTempDir { root in
            try AgentCatalogFixture.makeExecutable(root.appendingPathComponent("weir-hook"), script: "#!/bin/sh\nexit 3\n")
            let result = try dispatch(
                ["PreToolUse"],
                input: #"{"conversationId":"a"}"#,
                environment: ["WEIR_ANTIGRAVITY_HOOK_DIR": root.path]
            )
            #expect(result.status == 0)
            #expect(result.output == "{\"decision\":\"allow\"}\n")
        }
    }

    @Test func dispatch_addsTheEventName_andPassesTheHooksReplyThrough() throws {
        try withTempDir { root in
            let seen = root.appendingPathComponent("seen")
            let arguments = root.appendingPathComponent("arguments")
            try AgentCatalogFixture.makeExecutable(
                root.appendingPathComponent("weir-hook"),
                script: "#!/bin/sh\n"
                    + "printf '%s' \"$*\" > \"\(arguments.path)\"\n"
                    + "cat > \"\(seen.path)\"\nprintf '%s' '{\"decision\":\"deny\",\"reason\":\"routed\"}'\n"
            )
            let result = try dispatch(
                ["PreToolUse", "worktree"],
                input: #"{"conversationId":"a"}"#,
                environment: ["WEIR_ANTIGRAVITY_HOOK_DIR": root.path]
            )
            #expect(result.status == 0)
            #expect(result.output == "{\"decision\":\"deny\",\"reason\":\"routed\"}\n")
            let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: seen)) as? [String: String]
            #expect(payload == ["hook_event_name": "PreToolUse", "conversationId": "a"])
            // What sends the call to the worktree hook rather than the lifecycle one.
            #expect(try String(contentsOf: arguments, encoding: .utf8) == "worktree")
        }
    }
}
