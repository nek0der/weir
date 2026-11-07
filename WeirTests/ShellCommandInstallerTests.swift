// ShellCommandInstallerTests.swift
// Weir — the link the shell command is installed as, and the bundled script.

import Foundation
import Synchronization
import Testing
@testable import Weir

struct ShellCommandInstallerTests {
    private final class Recorder: Sendable {
        private let calls = Mutex<[[String]]>([])

        var recorded: [[String]] {
            calls.withLock(\.self)
        }

        func record(_ arguments: [String]) {
            calls.withLock { $0.append(arguments) }
        }
    }

    /// A fake app holding a script, and a link path beside it in `bin`.
    private func installer(
        in directory: URL,
        recorder: Recorder = Recorder(),
        result: ToolResult? = ToolResult(exitCode: 0, stdout: "", stderr: "")
    ) throws -> ShellCommandInstaller {
        let manager = FileManager.default
        let script = directory.appendingPathComponent("Weir.app/Contents/Resources/cli/weir")
        try manager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: script)
        return ShellCommandInstaller(
            script: script,
            link: directory.appendingPathComponent("bin/weir"),
            runOsascript: { arguments in
                recorder.record(arguments)
                return result
            }
        )
    }

    @Test func install_writableFolder_linksWithoutAskingForAnAdministrator() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            #expect(subject.status() == .notInstalled)

            try await subject.install(prompt: "prompt")

            #expect(subject.status() == .installed)
            #expect(recorder.recorded.isEmpty)
        }
    }

    @Test func uninstall_ownLink_removesIt() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            let script = try Data(contentsOf: subject.script)
            try await subject.install(prompt: "prompt")
            try #require(FileManager.default.destinationOfSymbolicLink(atPath: subject.link.path) == subject.script.path)

            try await subject.uninstall(prompt: "prompt")

            #expect(subject.status() == .notInstalled)
            #expect(try !hasEntry(at: subject.link))
            #expect(try Data(contentsOf: subject.script) == script)
            #expect(try itemType(at: subject.script) == .typeRegular)
            #expect(recorder.recorded.isEmpty)
        }
    }

    enum LinkTarget: CaseIterable {
        case dangling
        case existing
    }

    @Test(arguments: LinkTarget.allCases)
    func install_replacesLinksToOtherCopiesOfWeir(_ target: LinkTarget) async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            let manager = FileManager.default
            let other = directory.appendingPathComponent("Other/Weir.app").appendingPathComponent(ShellCommandInstaller.bundledPath)
            let original = Data("script in the other copy".utf8)
            if target == .existing {
                try manager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: other)
            }
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: subject.link, withDestinationURL: other)
            #expect(try manager.destinationOfSymbolicLink(atPath: subject.link.path) == other.path)
            #expect(manager.fileExists(atPath: other.path) == (target == .existing))

            #expect(subject.status() == .staleLink)
            try await subject.install(prompt: "prompt")

            #expect(subject.status() == .installed)
            #expect(try manager.destinationOfSymbolicLink(atPath: subject.link.path) == subject.script.path)
            #expect(recorder.recorded.isEmpty)
            if target == .existing {
                #expect(try Data(contentsOf: other) == original)
                #expect(try itemType(at: other) == .typeRegular)
            } else {
                #expect(try !hasEntry(at: other))
            }
        }
    }

    @Test func install_someoneElsesFile_refusesAndKeepsIt() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            let manager = FileManager.default
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: subject.link)
            #expect(subject.status() == .occupied)

            await #expect(throws: ShellCommandError.installFailed) {
                try await subject.install(prompt: "prompt")
            }
            await #expect(throws: ShellCommandError.uninstallFailed) {
                try await subject.uninstall(prompt: "prompt")
            }

            #expect(try Data(contentsOf: subject.link) == Data("theirs".utf8))
            #expect(try itemType(at: subject.link) == .typeRegular)
            #expect(recorder.recorded.isEmpty)
        }
    }

    @Test(arguments: LinkTarget.allCases)
    func status_linksToOtherToolsAreOccupied(_ target: LinkTarget) throws {
        try withTempDir { directory in
            let subject = try installer(in: directory)
            let manager = FileManager.default
            let tool = directory.appendingPathComponent("other-tool")
            if target == .existing {
                try Data().write(to: tool)
            }
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: subject.link, withDestinationURL: tool)
            #expect(manager.fileExists(atPath: tool.path) == (target == .existing))

            #expect(subject.status() == .occupied)
            #expect(try manager.destinationOfSymbolicLink(atPath: subject.link.path) == tool.path)
        }
    }

    private func itemType(at url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    /// Checks the directory entry, including a symlink whose target is absent.
    private func hasEntry(at url: URL) throws -> Bool {
        do {
            _ = try itemType(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    /// A folder that refuses the link stands in for a root-owned
    /// `/usr/local/bin`.
    private func withReadOnlyLinkFolder(of subject: ShellCommandInstaller, _ body: () async throws -> Void) async throws {
        let manager = FileManager.default
        let folder = subject.link.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try await body()
    }

    private func administratorArguments(command: String, paths: [URL], prompt: String) -> [String] {
        [
            "-e", "on run argv",
            "-e", "do shell script \(command) with prompt item -1 of argv with administrator privileges",
            "-e", "end run"
        ] + paths.map(\.path) + [prompt]
    }

    private func linkArguments(for subject: ShellCommandInstaller, flags: String, prompt: String) -> [String] {
        administratorArguments(
            command: "\"/bin/mkdir -p \" & quoted form of item 1 of argv & \" && /bin/ln \(flags) \" & "
                + "quoted form of item 2 of argv & \" \" & quoted form of item 3 of argv",
            paths: [subject.link.deletingLastPathComponent(), subject.script, subject.link],
            prompt: prompt
        )
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func install_folderRefusesLink_passesPathsAsArgumentsToTheAdministratorStep() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            let prompt = "Authorize Weir's link"

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: prompt)
            }

            #expect(recorder.recorded == [linkArguments(for: subject, flags: "-sn", prompt: prompt)])
            #expect(try !hasEntry(at: subject.link))
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func install_promptDismissed_returnsWithoutAFailure() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(
                in: directory,
                recorder: recorder,
                result: ToolResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
            )

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }
            #expect(recorder.recorded.count == 1)
            #expect(subject.status() == .notInstalled)
        }
    }

    enum AdministratorFailure: CaseIterable {
        case rejected
        case noResult
        case unrelatedDigitsInPath
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"), arguments: AdministratorFailure.allCases)
    func install_administratorStepFails_throws(_ failure: AdministratorFailure) async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let root = directory.appendingPathComponent("Weir-128", isDirectory: true)
            let result: ToolResult? = switch failure {
            case .rejected:
                ToolResult(exitCode: 1, stdout: "", stderr: "execution error: not allowed (1)")
            case .noResult:
                nil
            case .unrelatedDigitsInPath:
                ToolResult(exitCode: 1, stdout: "", stderr: "ln: \(root.path)/bin/weir: File exists (1)")
            }
            let subject = try installer(
                in: root,
                recorder: recorder,
                result: result
            )

            try await withReadOnlyLinkFolder(of: subject) {
                await #expect(throws: ShellCommandError.installFailed) {
                    try await subject.install(prompt: "prompt")
                }
            }
            #expect(recorder.recorded == [linkArguments(for: subject, flags: "-sn", prompt: "prompt")])
            #expect(try !hasEntry(at: subject.link))
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func install_overStaleLink_forcesOnlyThatLink() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            let manager = FileManager.default
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let oldScript = directory.appendingPathComponent("Old Weir.app").appendingPathComponent(ShellCommandInstaller.bundledPath)
            try manager.createSymbolicLink(at: subject.link, withDestinationURL: oldScript)
            try #require(subject.status() == .staleLink)

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }

            #expect(recorder.recorded == [linkArguments(for: subject, flags: "-sfn", prompt: "prompt")])
            #expect(try manager.destinationOfSymbolicLink(atPath: subject.link.path) == oldScript.path)
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func uninstall_folderRefuses_asksAnAdministratorToRemoveTheLink() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            try await subject.install(prompt: "prompt")
            try #require(FileManager.default.destinationOfSymbolicLink(atPath: subject.link.path) == subject.script.path)
            let original = try Data(contentsOf: subject.script)

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.uninstall(prompt: "prompt")
            }

            #expect(recorder.recorded == [administratorArguments(
                command: #""/bin/rm -f " & quoted form of item 1 of argv"#,
                paths: [subject.link],
                prompt: "prompt"
            )])
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: subject.link.path) == subject.script.path)
            #expect(try Data(contentsOf: subject.script) == original)
            #expect(try itemType(at: subject.script) == .typeRegular)
        }
    }

    /// Runs the real AppleScript without its administrator clause, so that a
    /// syntax slip or a quoting hole shows on paths built to expose one.
    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func administratorScript_hostilePaths_linksExactlyThosePaths() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let hostile = directory.appendingPathComponent("it's $(touch pwned) \"x\"")
            let subject = try installer(in: hostile, recorder: recorder)

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }
            let arguments = try #require(recorder.recorded.first)
            let clause = " with prompt item -1 of argv with administrator privileges"
            #expect(arguments.contains { $0.contains(clause) })
            let unprivileged = arguments.map { $0.replacingOccurrences(of: clause, with: "") }
            #expect(!unprivileged.contains { $0.contains("administrator") })

            let result = try #require(await runTool(
                executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: unprivileged,
                workingDirectory: directory,
                timeout: .seconds(30)
            ))

            #expect(result.isSuccess, "\(result.stderr)")
            #expect(subject.status() == .installed)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
        }
    }

}

struct ShellCommandRowTests {
    private func row(_ status: ShellCommandStatus, readOnly: Bool) -> ShellCommandRow {
        ShellCommandRow(status: status, path: "/usr/local/bin/weir", isAppOnReadOnlyVolume: readOnly)
    }

    @Test(arguments: [false, true])
    func actions_followTheStatus(readOnly: Bool) {
        let english = Locale(identifier: "en")
        let absent = row(.notInstalled, readOnly: readOnly)
        let installed = row(.installed, readOnly: readOnly)
        let stale = row(.staleLink, readOnly: readOnly)
        let occupied = row(.occupied, readOnly: readOnly)

        #expect(absent.actions == (readOnly ? [] : [.install]))
        let absentText = readOnly ? "Move Weir to Applications to install the shell command." : "Not installed"
        #expect(absent.statusText.resolved(in: english) == absentText)
        #expect(installed.actions == [.uninstall])
        #expect(installed.statusText.resolved(in: english) == "Installed at /usr/local/bin/weir")
        #expect(stale.actions == (readOnly ? [.uninstall] : [.repair, .uninstall]))
        #expect(stale.statusText.resolved(in: english) == "The link at /usr/local/bin/weir doesn’t lead to this copy of Weir.")
        #expect(occupied.actions == [.showInFinder])
        #expect(occupied.statusText.resolved(in: english) == "Another file is already at /usr/local/bin/weir. Weir leaves it as it is.")
    }
}

/// Runs the script the app ships, in a fake bundle, with `open` replaced by
/// one that records what it was given.
struct WeirShellScriptTests {
    private struct Run {
        let exitCode: Int32
        let opened: [String]?
        let stdout: String
        let stderr: String
    }

    private func run(
        _ arguments: [String],
        from workingDirectory: URL,
        in directory: URL
    ) async throws -> (Run, app: URL) {
        let manager = FileManager.default
        let app = directory.appendingPathComponent("My Weir.app")
        let script = app.appendingPathComponent(ShellCommandInstaller.bundledPath)
        try manager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        let packagedScript = try #require(ShellCommandInstaller.forThisApp).script
        try manager.copyItem(at: packagedScript, to: script)
        let fakeBin = directory.appendingPathComponent("fake-bin")
        let record = directory.appendingPathComponent("open-argv")
        try manager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeOpen = fakeBin.appendingPathComponent("open")
        try Data("#!/bin/sh\nprintf '%s\\0' \"$@\" >> \"$WEIR_OPEN_RECORD\"\n".utf8).write(to: fakeOpen)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        // Through a link, as the command is run once installed.
        let link = directory.appendingPathComponent("weir-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: script)
        let result = try #require(await runTool(
            executable: link,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: ["PATH": "\(fakeBin.path):/usr/bin:/bin", "WEIR_OPEN_RECORD": record.path],
            timeout: .seconds(30)
        ))
        let opened: [String]?
        if manager.fileExists(atPath: record.path) {
            let data = try Data(contentsOf: record)
            try #require(data.last == 0)
            opened = try data.dropLast().split(separator: 0, omittingEmptySubsequences: false).map {
                try #require(String(bytes: $0, encoding: .utf8))
            }
        } else {
            opened = nil
        }
        return (Run(exitCode: result.exitCode, opened: opened, stdout: result.stdout, stderr: result.stderr), app)
    }

    enum Folders: CaseIterable {
        case none
        case dot
        case relative
        case afterDoubleDash
        case multipleInOrder
    }

    @Test(arguments: Folders.allCases)
    func opensThePackagedAppWithAbsoluteFoldersInOrder(_ folders: Folders) async throws {
        try await withTempDir { directory in
            let working = directory.appendingPathComponent("project")
            let relative = working.appendingPathComponent("relative folder")
            let dashed = working.appendingPathComponent("-odd")
            let second = working.appendingPathComponent("two lines\nin one folder")
            for folder in [relative, dashed, second] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let arguments: [String]
            let expected: [URL]
            switch folders {
            case .none:
                (arguments, expected) = ([], [])
            case .dot:
                (arguments, expected) = (["."], [working])
            case .relative:
                (arguments, expected) = ([relative.lastPathComponent], [relative])
            case .afterDoubleDash:
                (arguments, expected) = (["--", dashed.lastPathComponent], [dashed])
            case .multipleInOrder:
                (arguments, expected) = ([second.lastPathComponent, ".", relative.lastPathComponent], [second, working, relative])
            }

            let (run, app) = try await run(arguments, from: working, in: directory)

            #expect(run.exitCode == 0)
            let opened = try #require(run.opened)
            #expect(opened.first == "-a")
            let paths = opened.dropFirst()
            #expect(paths.allSatisfy { $0.hasPrefix("/") })
            #expect(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == ([app] + expected).map { $0.resolvingSymlinksInPath().path })
            #expect(run.stdout.isEmpty)
            #expect(run.stderr.isEmpty)
        }
    }

    enum BadArgument: CaseIterable {
        case missing
        case file
        case unknownOption
        case missingAfterValidFolder
    }

    private let usage = """
    Usage: weir-link [folder ...]

    Opens each folder in Weir as a project. With no folder, brings Weir forward.

    """

    @Test(arguments: BadArgument.allCases)
    func badArgument_failsWithoutOpeningAnything(_ badArgument: BadArgument) async throws {
        try await withTempDir { directory in
            try Data().write(to: directory.appendingPathComponent("a-file"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("valid-folder"),
                withIntermediateDirectories: false
            )
            let arguments: [String]
            let stderr: String
            switch badArgument {
            case .missing:
                (arguments, stderr) = (["missing-folder"], "weir-link: no such folder: missing-folder\n")
            case .file:
                (arguments, stderr) = (["a-file"], "weir-link: not a folder: a-file\n")
            case .unknownOption:
                (arguments, stderr) = (["--nonsense"], usage + "weir-link: unknown option: --nonsense\n")
            case .missingAfterValidFolder:
                (arguments, stderr) = (["valid-folder", "missing-folder"], "weir-link: no such folder: missing-folder\n")
            }

            let (run, _) = try await run(arguments, from: directory, in: directory)

            #expect(run.exitCode == 1)
            #expect(run.opened == nil)
            #expect(run.stdout.isEmpty)
            #expect(run.stderr == stderr)
        }
    }

    @Test(arguments: ["--help", "-h"])
    func help_printsUsageWithoutOpeningAnything(_ flag: String) async throws {
        try await withTempDir { directory in
            let (run, _) = try await run([flag], from: directory, in: directory)

            #expect(run.exitCode == 0)
            #expect(run.opened == nil)
            #expect(run.stdout == usage)
            #expect(run.stderr.isEmpty)
        }
    }
}
