// OpenCodeShimTests.swift
// Weir — the opencode shim places its plugin, names the launch for it, and keeps the pane out of the shared service.

import Foundation
import Testing
import WeirDomain
@testable import Weir

@Suite("OpenCode shim")
struct OpenCodeShimTests {
    /// Runs the shim with a stub for `opencode` that writes its arguments and
    /// environment beside itself.
    private func runShim(
        root: URL,
        home: URL,
        args: [String] = [],
        states: String? = nil,
        environment: [String: String] = [:],
        limit: TimeInterval = 10
    ) throws -> Process {
        let stub = root.appendingPathComponent("real-opencode")
        try AgentCatalogFixture.makeExecutable(
            stub,
            script: """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(root.path)/args"
            env > "\(root.path)/env"
            """
        )
        return try ShimHarness.run(
            AgentCatalogFixture.shim(for: .opencode),
            args,
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "WEIR_REAL_OPENCODE": stub.path,
                "WEIR_OPENCODE_AGENT_STATES_DIR": states ?? root.appendingPathComponent("states").path
            ].merging(environment) { _, new in new },
            currentDirectory: root,
            limit: limit
        )
    }

    private func read(_ name: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// What the shim kept for the plugin, one `NAME=value` a line.
    private func paneEnvironment(in root: URL) throws -> String {
        let directory = root.appendingPathComponent("states/pane-env")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: #require(files.first))
        return try #require(String(bytes: data, encoding: .utf8)).replacingOccurrences(of: "\0", with: "\n")
    }

    private func exists(_ name: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func placed(in home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/plugins/weir")
    }

    @Test func shim_placesThePlugin_inOpenCodesFolder_andNamesTheHook() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: placed(in: home).appendingPathComponent("tui.js").path))
            #expect(FileManager.default.fileExists(atPath: placed(in: home).appendingPathComponent(".weir-managed").path))
            let kept = try paneEnvironment(in: root)
            #expect(kept.contains("WEIR_OPENCODE_HOOK_DIR="))
            #expect(kept.contains("WEIR_OPENCODE_PID="))
        }
    }

    @Test func shim_placesThePlugin_underTheFolderXDGNames() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let config = root.appendingPathComponent("elsewhere")
            _ = try runShim(root: root, home: home, environment: ["XDG_CONFIG_HOME": config.path])
            #expect(FileManager.default.fileExists(atPath: config.appendingPathComponent("opencode/plugins/weir/tui.js").path))
            #expect(!FileManager.default.fileExists(atPath: placed(in: home).path))
        }
    }

    /// OpenCode 2.2.5 reads its plugins from `OPENCODE_CONFIG_DIR` instead of
    /// the XDG folder when it is set, so the plugin goes there.
    @Test func shim_placesThePlugin_inTheFolderOpenCodeConfigDirNames() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let config = root.appendingPathComponent("custom")
            _ = try runShim(root: root, home: home, environment: ["OPENCODE_CONFIG_DIR": config.path])
            #expect(FileManager.default.fileExists(atPath: config.appendingPathComponent("plugins/weir/tui.js").path))
            #expect(!FileManager.default.fileExists(atPath: placed(in: home).path))
        }
    }

    @Test func shim_leavesAPluginThatIsNotOurs() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let theirs = placed(in: home)
            try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: theirs.appendingPathComponent("tui.js"))
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            #expect(try String(contentsOf: theirs.appendingPathComponent("tui.js"), encoding: .utf8) == "theirs")
        }
    }

    @Test func shim_replacesAnOlderVersionOfOurs_andLeavesNothingElse() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let ours = placed(in: home)
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            try Data("0\n".utf8).write(to: ours.appendingPathComponent(".weir-managed"))
            try Data("old".utf8).write(to: ours.appendingPathComponent("tui.js"))
            _ = try runShim(root: root, home: home)
            #expect(try String(contentsOf: ours.appendingPathComponent("tui.js"), encoding: .utf8) != "old")
            let left = try FileManager.default.contentsOfDirectory(atPath: ours.path).sorted()
            #expect(left == [".weir-managed", "tui.js"])
        }
    }

    /// The Debug and release apps share the folder; overwriting each other would
    /// reload the plugin in every running pane.
    @Test func shim_leavesAHigherMark() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let ours = placed(in: home)
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            try Data("9999\n".utf8).write(to: ours.appendingPathComponent(".weir-managed"))
            try Data("newer".utf8).write(to: ours.appendingPathComponent("tui.js"))
            _ = try runShim(root: root, home: home)
            #expect(try String(contentsOf: ours.appendingPathComponent("tui.js"), encoding: .utf8) == "newer")
        }
    }

    @Test func shim_finishesAPlacementCutShort() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let ours = placed(in: home)
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            try Data("placing\n".utf8).write(to: ours.appendingPathComponent(".weir-managed"))
            _ = try runShim(root: root, home: home)
            #expect(FileManager.default.fileExists(atPath: ours.appendingPathComponent("tui.js").path))
        }
    }

    @Test func shim_inADemoPane_placesNothing_andNamesNoHook() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, states: "")
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config").path))
            #expect(try !read("env", in: root).contains("WEIR_"))
        }
    }

    @Test(arguments: [["run", "hello"], ["serve"], ["session", "list"], ["--help"], ["-v"], ["--session", "s", "--version"]])
    func shim_passesThrough_whatStartsNoInterface(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let process = try runShim(root: root, home: home, args: args)
            #expect(process.terminationStatus == 0)
            #expect(try read("args", in: root) == args.joined(separator: "\n") + "\n")
            #expect(try !read("env", in: root).contains("WEIR_"))
            #expect(!FileManager.default.fileExists(atPath: placed(in: home).path))
        }
    }

    /// OpenCode hands the interface's environment to each session it shows, so these
    /// would reach every command the agent runs.
    @Test func shim_keepsThePanesEnvironmentForThePluginAlone() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let elsewhere = root.appendingPathComponent("other-shim")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try Data().write(to: elsewhere.appendingPathComponent("weir-hook"))
            _ = try runShim(
                root: root,
                home: home,
                environment: [
                    "WEIR_PANE_ID": "PANE",
                    "WEIR_AGENT_RUN_ID": "RUN",
                    "WEIR_MANY_LINES": "a\nb",
                    "ZDOTDIR": "/bundle/Contents/Resources/claude-shim/zdotdir",
                    "PATH": "\(elsewhere.path):/usr/bin:/bin"
                ]
            )
            let interface = try read("env", in: root)
            let weirNames = interface.split(separator: "\n").filter { $0.hasPrefix("WEIR_") }.map { $0.prefix { $0 != "=" } }
            #expect(weirNames == ["WEIR_OPENCODE_PANE_ENV"])
            #expect(!interface.contains("ZDOTDIR"))
            #expect(!interface.contains(elsewhere.path))
            #expect(interface.contains("PATH=/usr/bin:/bin"))
            let kept = try paneEnvironment(in: root)
            #expect(kept.contains("WEIR_PANE_ID=PANE\n"))
            #expect(kept.contains("WEIR_MANY_LINES=a\nb\n"))
            #expect(kept.contains("WEIR_OPENCODE_AGENT_STATES_DIR="))
        }
    }

    @Test func shim_leavesAZDOTDIROfThePersonsOwn() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, environment: ["ZDOTDIR": "/Users/me/.config/zsh"])
            #expect(try read("env", in: root).contains("ZDOTDIR=/Users/me/.config/zsh"))
        }
    }

    @Test(arguments: [":/usr/bin:/bin", "/usr/bin::/bin", "/usr/bin:/bin:"])
    func shim_keepsAnEmptyPATHEntryThatIsNotIt(path: String) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, environment: ["PATH": path])
            #expect(try read("env", in: root).split(separator: "\n").contains("PATH=\(path)"))
        }
    }

    @Test func shim_namesEachLaunchsFileApart_notByItsPID() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home)
            _ = try runShim(root: root, home: home)
            let directory = root.appendingPathComponent("states/pane-env")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files.count == 2)
            #expect(files.allSatisfy { Int($0.replacingOccurrences(of: ".env", with: "")) == nil })
        }
    }

    @Test(arguments: [["--prompt="], ["--prompt", ""]])
    func shim_anEmptyPromptIsNoPrompt(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, args: args)
            #expect(try paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PROMPT=0"))
        }
    }

    @Test func shim_withAPrivateServer_staysWatched() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, args: ["--standalone"])
            #expect(try paneEnvironment(in: root).contains("WEIR_OPENCODE_HOOK_DIR="))
        }
    }

    @Test(arguments: [["--server", "http://far:1234"], ["--server=http://far:1234"]])
    func shim_withAServerElsewhere_goesUnwatched(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, args: args)
            #expect(try read("args", in: root) == args.joined(separator: "\n") + "\n")
            #expect(try !read("env", in: root).contains("WEIR_"))
        }
    }

    @Test(arguments: [["--session", "ses_1"], ["--session=ses_1"], ["-s", "ses_1"], ["--auto", "-s", "ses_1"]])
    func shim_namesTheSessionALaunchResumes(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, args: args)
            #expect(try paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_SESSION=ses_1"))
        }
    }

    @Test(arguments: [["--prompt", "fix it"], ["--prompt=fix it"]])
    func shim_saysALaunchCarriesAPrompt(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, args: args)
            #expect(try paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PROMPT=1"))
        }
    }

    /// A Hook Helper that keeps what a hook call is given and notes whether
    /// `opencode` already ran, then exits with `status`, or never ends when `hangs`.
    private func stubHelper(in root: URL, status: Int32 = 0, hangs: Bool = false) throws -> URL {
        let helper = root.appendingPathComponent("helper")
        try AgentCatalogFixture.makeExecutable(
            helper,
            script: """
            #!/bin/sh
            [ "$1" = hook ] || exit 0
            cat > "\(root.path)/hook-body"
            printf '%s\\n' "$*" "${WEIR_HOOK_TIME_LIMIT_MS:-}" "${WEIR_AGENT_RUN_ID:-}" > "\(root.path)/hook-call"
            [ -e "\(root.path)/args" ] && touch "\(root.path)/ran-after-opencode"
            \(hangs ? "exec sleep 600" : "exit \(status)")
            """
        )
        return helper
    }

    private func hookBody(in root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("hook-body"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// OpenCode sends a `--prompt` input by itself as its interface comes up, with
    /// no Enter for the plugin's gate to hold, so the shim saves the turn's start
    /// before OpenCode runs and names it to the plugin.
    @Test(arguments: [["--prompt", "fix it"], ["--prompt=fix it"]])
    func shim_savesTheStartOfALaunchPromptsTurn_beforeOpenCodeRuns(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let helper = try stubHelper(in: root)
            _ = try runShim(root: root, home: home, args: args, environment: ["WEIR_HOOK_HELPER": helper.path])
            let body = try hookBody(in: root)
            #expect(body["hook_event_name"] as? String == "weir.prepare")
            let generation = try #require(body["preparation"] as? String)
            #expect(!generation.isEmpty)
            let cwd = try #require(body["cwd"] as? String)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
            // Saved under the launch's run, the one the plugin's first turn takes.
            let run = try #require(
                try paneEnvironment(in: root).split(separator: "\n")
                    .first { $0.hasPrefix("WEIR_AGENT_RUN_ID=") }?
                    .dropFirst("WEIR_AGENT_RUN_ID=".count)
            )
            #expect(try read("hook-call", in: root) == "hook opencode\n8000\n\(run)\n")
            #expect(!exists("ran-after-opencode", in: root))
            #expect(try paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION=\(generation)"))
            #expect(try !read("env", in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION"))
        }
    }

    /// OpenCode's folder is its one positional argument, before or after the
    /// options, so the shim passes over each option's value to find it.
    @Test(arguments: [
        ["FOLDER", "--prompt", "fix it"],
        ["--prompt", "fix it", "FOLDER"],
        ["--auto", "--prompt", "fix it", "FOLDER"],
        ["--auto", "true", "--prompt=fix it", "FOLDER"],
        ["--session", "ses_1", "FOLDER", "--prompt", "fix it"],
        ["--log-level", "info", "--prompt", "fix it", "FOLDER"],
        ["--prompt", "fix it", "--", "FOLDER"]
    ])
    func shim_savesALaunchPromptsStart_inTheFolderTheLaunchNames(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let project = root.appendingPathComponent("project \"quoted\"")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let helper = try stubHelper(in: root)
            _ = try runShim(
                root: root,
                home: home,
                args: args.map { $0 == "FOLDER" ? project.lastPathComponent : $0 },
                environment: ["WEIR_HOOK_HELPER": helper.path]
            )
            let cwd = try #require(try hookBody(in: root)["cwd"] as? String)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == project.resolvingSymlinksInPath())
        }
    }

    /// A value is no folder: the start is saved where the interface starts, here.
    @Test(arguments: [["--auto", "false", "--prompt", "fix it"], ["-s", "ses_1", "--prompt", "fix it"]])
    func shim_savesALaunchPromptsStart_inTheCurrentFolder_whenNoneIsNamed(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let helper = try stubHelper(in: root)
            _ = try runShim(root: root, home: home, args: args, environment: ["WEIR_HOOK_HELPER": helper.path])
            let cwd = try #require(try hookBody(in: root)["cwd"] as? String)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        }
    }

    @Test(arguments: [[], ["--prompt="], ["--prompt", "fix it", "--server", "http://far:1234"]])
    func shim_savesNoStart_withoutAPromptItSends(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let helper = try stubHelper(in: root)
            _ = try runShim(root: root, home: home, args: args, environment: ["WEIR_HOOK_HELPER": helper.path])
            #expect(!exists("hook-body", in: root))
        }
    }

    /// A start the hook did not save is named to no turn, which then says it has none.
    @Test func shim_namesNoStart_whenTheHookFails() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let helper = try stubHelper(in: root, status: 1)
            let process = try runShim(
                root: root,
                home: home,
                args: ["--prompt", "fix it"],
                environment: ["WEIR_HOOK_HELPER": helper.path]
            )
            #expect(process.terminationStatus == 0)
            #expect(exists("hook-body", in: root))
            #expect(try !paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION"))
            #expect(exists("args", in: root))
        }
    }

    /// A hook that never ends, as one waiting on a worktree lock past its limit
    /// can, holds OpenCode up for no longer than the plugin's own preparation would.
    @Test func shim_startsOpenCode_whenTheHookOutlastsTheLimit() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let helper = try stubHelper(in: root, hangs: true)
            let started = ContinuousClock.now
            let process = try runShim(
                root: root,
                home: home,
                args: ["--prompt", "fix it"],
                environment: ["WEIR_HOOK_HELPER": helper.path],
                limit: 30
            )
            #expect(ContinuousClock.now - started < .seconds(30))
            #expect(process.terminationStatus == 0)
            #expect(exists("args", in: root))
            #expect(try !paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION"))
        }
    }

    @Test func aPluginWithoutAManagedMark_isNotShipped() throws {
        let plugin = try AgentCatalogFixture.shimFolder("opencode-plugin")
        let files = try FileManager.default.contentsOfDirectory(atPath: plugin.path).sorted()
        // A `server` or `index` file would load in the shared service too, where
        // no pane's environment reaches it.
        #expect(files == [".weir-managed", "tui.js"])
    }
}
