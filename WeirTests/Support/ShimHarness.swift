// ShimHarness.swift
// Weir — runs an agent shim from the source tree against stubs that record what it handed on.

import Foundation
import Testing

/// What the shim suites share: where a shim and its settings template are in
/// the source tree, the stub that records its argv, the environment it runs
/// in, and running it directly or under a pty.
///
/// One copy for every shim suite, so each waits for the shim with a deadline
/// and a shim stuck on input fails its test rather than stopping the run.
enum ShimHarness {
    /// The PATH a shim runs with: the system's own folders, so nothing the
    /// developer installed (a real `claude`, a real `tmux`) is found.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The shim script for `agent` (`claude`, `codex`) in the source tree.
    static func shim(_ agent: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try root(sourceLocation: sourceLocation).appendingPathComponent("Weir/Resources/\(agent)-shim/\(agent)")
    }

    /// The Claude settings template. It lives in the provider crate and the
    /// build copies it into the bundle beside the shim; a test runs the shim
    /// from the source tree, where there is no bundle, so it points the shim
    /// at the source instead.
    static func claudeSettingsTemplate(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try root(sourceLocation: sourceLocation)
            .appendingPathComponent("rust/weir-provider-claude/resources/settings.template.json").path
    }

    /// A copy of the shim folders laid out as the app bundle holds them, in
    /// `dir`: each agent's `<id>-shim` and plugin folder beside `agent-shim`
    /// under `Weir.app/Contents/Resources`, and Claude's settings template
    /// beside its shim, where the build puts it. A shim in a bundle takes
    /// none of the test overrides, so this is how a test runs one there.
    /// With `isAppBundle` false the folder is named `Weir` instead: the same
    /// layout, outside a bundle. Returns the `Contents` folder.
    static func bundleContents(
        in dir: URL,
        isAppBundle: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> URL {
        let source = try root(sourceLocation: sourceLocation).appendingPathComponent("Weir/Resources")
        let contents = dir.appendingPathComponent(isAppBundle ? "Weir.app/Contents" : "Weir/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path)
            where name == "agent-shim" || name.hasSuffix("-shim") || name.hasSuffix("-plugin")
        {
            try fileManager.copyItem(at: source.appendingPathComponent(name), to: resources.appendingPathComponent(name))
        }
        try fileManager.copyItem(
            at: URL(fileURLWithPath: claudeSettingsTemplate(sourceLocation: sourceLocation)),
            to: resources.appendingPathComponent("claude-shim/settings.template.json")
        )
        return contents
    }

    /// The environment every shim run starts from, with `dir` as its home
    /// and temporary folder so nothing it writes lands outside the test's.
    static func environment(in dir: URL) -> [String: String] {
        ["PATH": systemPath, "HOME": dir.path, "TMPDIR": dir.path]
    }

    /// `environment(in:)` with `extra` laid over it, `extra` winning, for what a
    /// shim needs on top: a home of the test's own inside `dir`, say, or the
    /// variables that point the shim at its stubs and its states folder.
    static func environment(in dir: URL, merging extra: [String: String]) -> [String: String] {
        environment(in: dir).merging(extra) { _, extra in extra }
    }

    /// A stand-in agent at `url` that records how it was started in three files
    /// in `dir`: its arguments in `args`, as `argvRecorder` writes them; its `$0`
    /// and `PATH`, one a line, in `launched`; and its environment, as
    /// `/usr/bin/env` prints it, in `env`. Stubs that record into one folder share
    /// these files, so a test of which of two agents a shim started reads one record.
    static func recordingStub(at url: URL, recordingIn dir: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let launched = launchRecord(in: dir).path
        let environment = dir.appendingPathComponent("env").path
        try writeExecutable(
            argvRecorder(
                into: argvRecord(in: dir),
                // By its full path: the `PATH` a test hands the shim need
                // not lead to `env`.
                then: "printf '%s\\n%s\\n' \"$0\" \"$PATH\" > \"\(launched)\"\n/usr/bin/env > \"\(environment)\""
            ),
            at: url
        )
    }

    /// `recordingStub(at:recordingIn:)` for a stub named `name` in `dir`,
    /// recording into `dir` too; answers the stub's path.
    static func recordingStub(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try recordingStub(at: url, recordingIn: dir)
        return url
    }

    /// Where a recording stub in `dir` writes its arguments.
    static func argvRecord(in dir: URL) -> URL {
        dir.appendingPathComponent("args")
    }

    /// Where a recording stub in `dir` writes its `$0` and `PATH`.
    static func launchRecord(in dir: URL) -> URL {
        dir.appendingPathComponent("launched")
    }

    /// The `$0` and `PATH` a recording stub in `dir` was started with, empty
    /// when none ran.
    static func launched(in dir: URL) -> [String] {
        ((try? String(contentsOf: launchRecord(in: dir), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A shell script that records its arguments in `argvFile`, then runs
    /// `then`. NUL-separated, so an argument carrying spaces or newlines (a
    /// settings payload, a `-c` value, a prompt) stays one argument.
    static func argvRecorder(into argvFile: URL, then: String = "exit 0") -> String {
        """
        #!/bin/sh
        : > "\(argvFile.path)"
        for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
        \(then)
        """
    }

    /// The environment of the tmux server a hosted session lands on when
    /// another pane's agent started that server: another `PATH`, account,
    /// and record directories, and a variable that pane's person exported.
    /// A hosted agent must see none of it.
    static let tmuxServerEnvironment: [String: String] = [
        "PATH": "/other-pane/bin:/usr/bin:/bin",
        "HOME": "/Users/other",
        "OTHER_PANE_ONLY": "1",
        "PERSON_EXPORT": "the other pane's",
        "CLAUDE_CONFIG_DIR": "/Users/other/.claude-work",
        "CODEX_HOME": "/Users/other/.codex-work",
        "WEIR_SESSIONS_DIR": "/Release/sessions",
        "WEIR_AGENT_STATES_DIR": "/Release/agent-states",
        "WEIR_CWD_EVENTS_DIR": "/Release/cwd-events",
        "WEIR_CODEX_SESSIONS_DIR": "/Release/codex-sessions",
        "WEIR_CODEX_AGENT_STATES_DIR": "/Release/codex-agent-states",
        "TERM": "xterm-ghostty"
    ]

    /// What tmux 3.8 sets in a session for the terminal it is, over the
    /// server's environment (measured: `env` in a new session).
    static let tmuxSessionVariables: [String: String] = [
        "TERM": "tmux-256color",
        "TERM_PROGRAM": "tmux",
        "TERM_PROGRAM_VERSION": "3.8",
        "COLORTERM": "truecolor",
        "TMUX": "/private/tmp/tmux-501/weir-test.socket,4242,1",
        "TMUX_PANE": "%1"
    ]

    /// A stand-in tmux that records its arguments in `argvFile`, runs
    /// `then`, and then starts the session's command as tmux does on a
    /// server another pane started: in that server's environment
    /// (`tmuxServerEnvironment`) with tmux's own variables over it, and
    /// none of the client's.
    static func fakeTmux(into argvFile: URL, then: String = "") -> String {
        let assignments = tmuxServerEnvironment
            .merging(tmuxSessionVariables) { _, own in own }
            .sorted { $0.key < $1.key }
            .map { "'" + "\($0.key)=\($0.value)".replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return argvRecorder(into: argvFile, then: """
        \(then)
        while [ "$#" -gt 0 ] && [ "$1" != new-session ]; do shift; done
        [ "$#" -ge 3 ] || exit 1
        shift
        [ "$1" = -s ] || exit 1
        shift 2
        exec /usr/bin/env -i \(assignments) "$@"
        """)
    }

    /// The environment a stub recorded with `/usr/bin/env -0`; nil when it
    /// never ran.
    static func recordedEnvironment(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var environment: [String: String] = [:]
        for entry in text.split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    /// Writes `script` to `url` and makes it executable.
    static func writeExecutable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The arguments an `argvRecorder` stub recorded; nil when it never ran,
    /// since it truncates its file before recording. With
    /// `keepsEmptyArguments`, an empty argument stays in the list.
    static func recordedArgv(_ url: URL, keepsEmptyArguments: Bool = false) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard keepsEmptyArguments else {
            return text.split(separator: "\0").map(String.init)
        }
        return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// Runs `shim` with `arguments` and waits for it, at most `limit` seconds.
    ///
    /// `underPTY` runs it through `script`, so its stdin and stdout are a
    /// terminal: the tmux hosting decision asks whether they are. Without
    /// it they are the null device, so only a pty reaches that branch.
    @discardableResult
    static func run(
        _ shim: URL,
        _ arguments: [String],
        environment: [String: String],
        underPTY: Bool = false,
        currentDirectory: URL? = nil,
        limit: TimeInterval = 10,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Process {
        let process = Process()
        if underPTY {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", shim.path] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path] + arguments
            // Left alone, the shim inherits the test runner's, which are a
            // terminal when the run was started from one, and the hosting
            // branch would be reached after all.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
        }
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        try process.run()
        try #require(
            process.waitUntilExit(within: limit),
            "the shim did not exit within \(limit) seconds",
            sourceLocation: sourceLocation
        )
        return process
    }

    private static func root(sourceLocation: SourceLocation) throws -> URL {
        try #require(RepoFixture.weirRoot, sourceLocation: sourceLocation)
    }
}
