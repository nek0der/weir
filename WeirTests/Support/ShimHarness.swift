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
        #expect(
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
