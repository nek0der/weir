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

    /// Runs the shim with `home` as the home folder and a stub for `agy` that
    /// writes its arguments and environment beside itself.
    private func runShim(root: URL, home: URL, args: [String] = [], states: String = "/tmp/states") throws -> Process {
        let stub = root.appendingPathComponent("real-agy")
        try AgentCatalogFixture.makeExecutable(
            stub,
            script: "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(root.path)/args\"\nenv > \"\(root.path)/env\"\n"
        )
        return try ShimHarness.run(
            AgentCatalogFixture.shim(for: .antigravity),
            args,
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "WEIR_REAL_ANTIGRAVITY": stub.path,
                "WEIR_ANTIGRAVITY_AGENT_STATES_DIR": states
            ],
            currentDirectory: root
        )
    }

    /// Runs the shim with a stub helper, and returns what it sent the hook:
    /// `nil` when it reported no launch.
    private func launchReport(
        root: URL,
        home: URL,
        args: [String],
        states: String = "/tmp/states"
    ) throws -> [String: Any]? {
        let report = root.appendingPathComponent("report")
        let helper = root.appendingPathComponent("helper")
        try AgentCatalogFixture.makeExecutable(
            helper,
            script: "#!/bin/sh\n[ \"$1\" = hook ] && cat > \"\(report.path)\"\nexit 0\n"
        )
        let stub = root.appendingPathComponent("real-agy")
        try AgentCatalogFixture.makeExecutable(
            stub,
            script: "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(root.path)/args\"\n"
        )
        let process = try ShimHarness.run(
            AgentCatalogFixture.shim(for: .antigravity),
            args,
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "WEIR_HOOK_HELPER": helper.path,
                "WEIR_REAL_ANTIGRAVITY": stub.path,
                "WEIR_ANTIGRAVITY_AGENT_STATES_DIR": states
            ],
            currentDirectory: root
        )
        #expect(process.terminationStatus == 0)
        guard let data = try? Data(contentsOf: report) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func dispatch(
        _ arguments: [String],
        input: String,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = try [plugin().appendingPathComponent("scripts/weir-dispatch").path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try (process.terminationStatus, #require(String(bytes: data, encoding: .utf8)))
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
            #expect(environment.contains("WEIR_ANTIGRAVITY_HOOK_DIR="))
            #expect(environment.contains("WEIR_ANTIGRAVITY_PID="))
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
            let process = try runShim(root: root, home: root.appendingPathComponent("home"), args: ["--conversation", "a"])
            #expect(process.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("args").path))
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
