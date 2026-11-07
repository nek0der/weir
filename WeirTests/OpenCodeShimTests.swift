// OpenCodeShimTests.swift
// Weir — the opencode shim places its plugin, names the launch for it, and keeps the pane out of the shared service.

import Foundation
import Testing
import WeirDomain
@testable import Weir

@Suite("OpenCode shim")
struct OpenCodeShimTests {
    /// Runs the shim with a recording stub for `opencode`, which writes its
    /// arguments and environment beside itself.
    private func runShim(
        root: URL,
        home: URL,
        args: [String] = [],
        states: String? = nil,
        environment: [String: String] = [:],
        limit: TimeInterval = 10
    ) throws -> Process {
        let stub = try ShimHarness.recordingStub(named: "real-opencode", in: root)
        return try ShimHarness.run(
            AgentCatalogFixture.shim(for: .opencode),
            args,
            environment: ShimHarness.environment(in: root, merging: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "WEIR_REAL_OPENCODE": stub.path,
                "WEIR_OPENCODE_AGENT_STATES_DIR": states ?? root.appendingPathComponent("states").path
            ].merging(environment) { _, new in new }),
            currentDirectory: root,
            limit: limit
        )
    }

    private func paneEnvironmentFile(in root: URL) throws -> URL {
        let entries = try ScratchFile.read("env", in: root).split(separator: "\n")
        let prefix = "WEIR_OPENCODE_PANE_ENV="
        let matches = entries.filter { $0.hasPrefix(prefix) }
        try #require(matches.count == 1)
        let path = try String(#require(matches.first).dropFirst(prefix.count))
        try #require(path.hasPrefix("/"))
        let file = URL(fileURLWithPath: path)
        #expect(file.deletingLastPathComponent().resolvingSymlinksInPath() == root.appendingPathComponent("states/pane-env")
            .resolvingSymlinksInPath())
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        return file
    }

    private func paneEnvironmentValues(in root: URL) throws -> [String: String] {
        let file = try paneEnvironmentFile(in: root)
        let data = try Data(contentsOf: file)
        try #require(data.last == 0)
        let text = try #require(String(data: data, encoding: .utf8))
        var values: [String: String] = [:]
        for entry in text.split(separator: "\0") {
            let equals = try #require(entry.firstIndex(of: "="))
            let name = String(entry[..<equals])
            try #require(values[name] == nil)
            values[name] = String(entry[entry.index(after: equals)...])
        }
        return values
    }

    /// A line-oriented view for assertions whose values contain no newlines.
    private func paneEnvironment(in root: URL) throws -> String {
        try paneEnvironmentValues(in: root).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n"
    }

    private func exists(_ name: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func placed(in home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/plugins/weir")
    }

    private func expectShippedPlugin(at destination: URL) throws {
        let source = try AgentCatalogFixture.shim(for: .opencode)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("opencode-plugin")
        let names = [".weir-managed", "tui.js"]
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == names)
        for name in names {
            #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == Data(contentsOf: source.appendingPathComponent(name)))
        }
        let mark = try String(contentsOf: destination.appendingPathComponent(".weir-managed"), encoding: .utf8)
        #expect(Int(mark.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    enum PluginFolder: CaseIterable {
        case home
        case xdg
        case explicit
    }

    @Test(arguments: PluginFolder.allCases)
    func shim_placesThePlugin_inTheSelectedFolder(_ folder: PluginFolder) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let xdg = root.appendingPathComponent("xdg")
            let custom = root.appendingPathComponent("custom")
            let candidates = [
                placed(in: home),
                xdg.appendingPathComponent("opencode/plugins/weir"),
                custom.appendingPathComponent("plugins/weir")
            ]
            let environment: [String: String]
            let selected: Int
            switch folder {
            case .home: (environment, selected) = ([:], 0)
            case .xdg: (environment, selected) = (["XDG_CONFIG_HOME": xdg.path], 1)
            case .explicit: (environment, selected) = (["XDG_CONFIG_HOME": xdg.path, "OPENCODE_CONFIG_DIR": custom.path], 2)
            }
            let process = try runShim(root: root, home: home, environment: environment)
            try #require(process.terminationStatus == 0)
            try expectShippedPlugin(at: candidates[selected])
            for index in candidates.indices where index != selected {
                #expect(!FileManager.default.fileExists(atPath: candidates[index].path))
            }
            let kept = try paneEnvironment(in: root)
            let hook = try AgentCatalogFixture.shim(for: .opencode).deletingLastPathComponent().path
            #expect(kept.split(separator: "\n").contains("WEIR_OPENCODE_HOOK_DIR=\(hook)"))
            #expect(kept.split(separator: "\n").contains("WEIR_OPENCODE_PID=\(process.processIdentifier)"))
        }
    }

    @Test func shim_leavesAPluginThatIsNotOurs() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let theirs = placed(in: home)
            try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: theirs.appendingPathComponent("tui.js"))
            try Data("private settings".utf8).write(to: theirs.appendingPathComponent("settings.json"))
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            #expect(try Data(contentsOf: theirs.appendingPathComponent("tui.js")) == Data("theirs".utf8))
            #expect(try Data(contentsOf: theirs.appendingPathComponent("settings.json")) == Data("private settings".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: theirs.path).sorted() == ["settings.json", "tui.js"])
        }
    }

    @Test(arguments: [false, true])
    func shim_replacesAnOlderVersionOfOurs_andLeavesNothingElse(wasInterrupted: Bool) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let ours = placed(in: home)
            try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
            try Data((wasInterrupted ? "placing\n" : "0\n").utf8).write(to: ours.appendingPathComponent(".weir-managed"))
            if !wasInterrupted {
                try Data("old".utf8).write(to: ours.appendingPathComponent("tui.js"))
            }
            let process = try runShim(root: root, home: home)
            try #require(process.terminationStatus == 0)
            try expectShippedPlugin(at: ours)
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
            let process = try runShim(root: root, home: home)
            #expect(process.terminationStatus == 0)
            #expect(try Data(contentsOf: ours.appendingPathComponent("tui.js")) == Data("newer".utf8))
            #expect(try Data(contentsOf: ours.appendingPathComponent(".weir-managed")) == Data("9999\n".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: ours.path).sorted() == [".weir-managed", "tui.js"])
        }
    }

    @Test func shim_inADemoPane_placesNothing_andNamesNoHook() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, states: "")
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config").path))
            #expect(try !ScratchFile.read("env", in: root).contains("WEIR_"))
        }
    }

    @Test(arguments: [["run", "hello"], ["serve"], ["session", "list"], ["--help"], ["-v"], ["--session", "s", "--version"]])
    func shim_passesThrough_whatStartsNoInterface(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let process = try runShim(root: root, home: home, args: args)
            #expect(process.terminationStatus == 0)
            #expect(ShimHarness.recordedArgv(ShimHarness.argvRecord(in: root)) == args)
            #expect(try !ScratchFile.read("env", in: root).contains("WEIR_"))
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
                    "WEIR_MANY_LINES": "a\nb=with=equals",
                    "ZDOTDIR": "/bundle/Contents/Resources/claude-shim/zdotdir",
                    "PATH": "\(elsewhere.path):/usr/bin:/bin"
                ]
            )
            let interface = try ScratchFile.read("env", in: root)
            let weirNames = interface.split(separator: "\n").filter { $0.hasPrefix("WEIR_") }.map { $0.prefix { $0 != "=" } }
            #expect(weirNames == ["WEIR_OPENCODE_PANE_ENV"])
            #expect(!interface.contains("ZDOTDIR"))
            #expect(!interface.contains(elsewhere.path))
            #expect(interface.contains("PATH=/usr/bin:/bin"))
            let kept = try paneEnvironmentValues(in: root)
            #expect(kept["WEIR_PANE_ID"] == "PANE")
            #expect(kept["WEIR_AGENT_PARENT_RUN_ID"] == "RUN")
            let runID = try #require(kept["WEIR_AGENT_RUN_ID"])
            #expect(UUID(uuidString: runID) != nil)
            #expect(runID != "RUN")
            #expect(kept["WEIR_MANY_LINES"] == "a\nb=with=equals")
            #expect(kept["WEIR_OPENCODE_AGENT_STATES_DIR"] == root.appendingPathComponent("states").path)
        }
    }

    @Test func shim_leavesAZDOTDIROfThePersonsOwn() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, environment: ["ZDOTDIR": "/Users/me/.config/zsh"])
            #expect(try ScratchFile.read("env", in: root).contains("ZDOTDIR=/Users/me/.config/zsh"))
        }
    }

    @Test(arguments: [":/usr/bin:/bin", "/usr/bin::/bin", "/usr/bin:/bin:"])
    func shim_keepsAnEmptyPATHEntryThatIsNotIt(path: String) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            _ = try runShim(root: root, home: home, environment: ["PATH": path])
            #expect(try ScratchFile.read("env", in: root).split(separator: "\n").contains("PATH=\(path)"))
        }
    }

    @Test func shim_namesEachLaunchsFileApart_notByItsPID() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let first = try runShim(root: root, home: home)
            try #require(first.terminationStatus == 0)
            let firstFile = try paneEnvironmentFile(in: root)
            let firstData = try Data(contentsOf: firstFile)
            let second = try runShim(root: root, home: home)
            try #require(second.terminationStatus == 0)
            let secondFile = try paneEnvironmentFile(in: root)
            #expect(firstFile != secondFile)
            #expect(try Data(contentsOf: firstFile) == firstData)
            #expect(try !Data(contentsOf: secondFile).isEmpty)
            #expect(Int(firstFile.lastPathComponent) == nil)
            #expect(Int(secondFile.lastPathComponent) == nil)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("states/pane-env").path)
            #expect(Set(files) == Set([firstFile.lastPathComponent, secondFile.lastPathComponent]))
        }
    }

    @Test(arguments: [["--prompt="], ["--prompt", ""], ["--prompt", "fix=it"], ["--prompt=fix=it"]])
    func shim_namesWhetherTheLaunchCarriesAPrompt(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let process = try runShim(root: root, home: home, args: args)
            try #require(process.terminationStatus == 0)
            #expect(ShimHarness.recordedArgv(ShimHarness.argvRecord(in: root), keepsEmptyArguments: true) == args)
            let expected = args == ["--prompt="] || args == ["--prompt", ""] ? "0" : "1"
            #expect(try paneEnvironmentValues(in: root)["WEIR_OPENCODE_LAUNCH_PROMPT"] == expected)
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
            #expect(ShimHarness.recordedArgv(ShimHarness.argvRecord(in: root)) == args)
            #expect(try !ScratchFile.read("env", in: root).contains("WEIR_"))
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

    /// A Hook Helper that keeps what a hook call is given and notes whether
    /// `opencode` already ran, then exits with `status`, or exceeds the watchdog when `hangs`.
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
            \(hangs ? "echo $$ > \"\(root.path)/helper-pid\"; exec sleep 20" : "exit \(status)")
            """
        )
        return helper
    }

    private func hookBody(in root: URL) throws -> [String: Any] {
        try JSONObjectFixture.object(Data(contentsOf: root.appendingPathComponent("hook-body")))
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
            #expect(try ScratchFile.read("hook-call", in: root) == "hook opencode\n8000\n\(run)\n")
            #expect(!exists("ran-after-opencode", in: root))
            #expect(try paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION=\(generation)"))
            #expect(try !ScratchFile.read("env", in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION"))
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
        ["--prompt", "fix it", "--", "FOLDER"],
        ["--auto", "false", "--prompt", "fix it"],
        ["-s", "ses_1", "--prompt", "fix it"]
    ])
    func shim_savesALaunchPromptsStart_inTheFolderTheLaunchNames(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let project = root.appendingPathComponent("project \"quoted\"")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let helper = try stubHelper(in: root)
            let actualArgs = args.map { $0 == "FOLDER" ? project.lastPathComponent : $0 }
            let process = try runShim(
                root: root,
                home: home,
                args: actualArgs,
                environment: ["WEIR_HOOK_HELPER": helper.path]
            )
            try #require(process.terminationStatus == 0)
            #expect(ShimHarness.recordedArgv(ShimHarness.argvRecord(in: root)) == actualArgs)
            let expected = args.contains("FOLDER") ? project : root
            let cwd = try #require(try hookBody(in: root)["cwd"] as? String)
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == expected.resolvingSymlinksInPath())
        }
    }

    @Test(arguments: [[], ["--prompt="], ["--prompt", "fix it", "--server", "http://far:1234"]])
    func shim_savesNoStart_withoutAPromptItSends(args: [String]) throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home")
            let helper = try stubHelper(in: root)
            let process = try runShim(root: root, home: home, args: args, environment: ["WEIR_HOOK_HELPER": helper.path])
            try #require(process.terminationStatus == 0)
            #expect(ShimHarness.recordedArgv(ShimHarness.argvRecord(in: root), keepsEmptyArguments: true) == args)
            #expect(!exists("hook-body", in: root))
            #expect(!exists("hook-call", in: root))
            if !args.contains("--server") {
                #expect(try paneEnvironmentValues(in: root)["WEIR_OPENCODE_LAUNCH_PREPARATION"] == nil)
            } else {
                #expect(!exists("states/pane-env", in: root))
            }
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
            defer {
                if let raw = try? ScratchFile.read("helper-pid", in: root),
                   let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
                {
                    _ = kill(pid, SIGKILL)
                }
            }
            let started = ContinuousClock.now
            let process = try runShim(
                root: root,
                home: home,
                args: ["--prompt", "fix it"],
                environment: ["WEIR_HOOK_HELPER": helper.path],
                limit: 18
            )
            #expect(ContinuousClock.now - started < .seconds(15))
            #expect(process.terminationStatus == 0)
            let raw = try ScratchFile.read("helper-pid", in: root)
            let pid = try #require(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            try #require(pid > 0)
            #expect(kill(pid, 0) == -1 && errno == ESRCH)
            #expect(try hookBody(in: root)["hook_event_name"] as? String == "weir.prepare")
            #expect(!exists("ran-after-opencode", in: root))
            #expect(ShimHarness.recordedArgv(ShimHarness.argvRecord(in: root)) == ["--prompt", "fix it"])
            #expect(exists("args", in: root))
            #expect(try !paneEnvironment(in: root).contains("WEIR_OPENCODE_LAUNCH_PREPARATION"))
        }
    }

    @Test func sourcePlugin_hasOnlyTheInterfaceAndANumericManagedMark() throws {
        let plugin = try AgentCatalogFixture.shimFolder("opencode-plugin")
        let files = try FileManager.default.contentsOfDirectory(atPath: plugin.path).sorted()
        // A `server` or `index` file would load in the shared service too, where
        // no pane's environment reaches it.
        #expect(files == [".weir-managed", "tui.js"])
        let mark = try String(contentsOf: plugin.appendingPathComponent(".weir-managed"), encoding: .utf8)
        #expect(Int(mark.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
        #expect(try !Data(contentsOf: plugin.appendingPathComponent("tui.js")).isEmpty)
    }
}
