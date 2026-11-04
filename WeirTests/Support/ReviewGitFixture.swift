// ReviewGitFixture.swift
// Weir — Git commands for the review suites' repositories, apart from the developer's configuration.

import Foundation
import Testing
@testable import Weir

/// Git for the review suites, kept apart from `TempGitRepo.git` on purpose.
///
/// The two isolate a command from the developer's setup in different ways
/// because their code under test reads Git differently. The review reads a
/// repository with every inherited `GIT_*` variable dropped
/// (`ReviewGitCommand`), and what it parses is Git's printed diff, which the
/// developer's global `diff.*` settings (a `noprefix`, say) change. So a review
/// fixture runs with no global or system configuration at all, and a review
/// test sets the one setting it means to check in the repository itself.
/// `TempGitRepo` serves code that runs Git through `GitProcess`, which keeps
/// the inherited variables that do not name a repository and with them the
/// global configuration (a fetch needs the developer's `GIT_SSH`, a worktree
/// add their `GIT_CONFIG_GLOBAL`), so its repositories override only the
/// settings that trip a test and leave the rest as that code meets them.
/// Merged into one, either set of tests would run under a setup its code
/// never sees. The review suites still make their repositories with
/// `TempGitRepo`, so each carries its local identity and signing settings,
/// and a commit run here needs no `-c user.*` of its own.
enum ReviewGitFixture {
    /// Runs `git` in `cwd` with no inherited `GIT_*` variable and no global or
    /// system configuration, in the C locale, leaving the developer's own
    /// environment untouched.
    static func run(
        _ arguments: [String],
        cwd: URL
    ) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let process = Process()
                    // The git the review runs, so a repository is written
                    // and read by the same one.
                    let git = GitExecutable.located
                    process.executableURL = git.url
                    process.arguments = git.leadingArguments + arguments
                    process.currentDirectoryURL = cwd
                    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                    environment["GIT_CONFIG_NOSYSTEM"] = "1"
                    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                    environment["LC_ALL"] = "C"
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice
                    let stdout = Pipe.forChildProcess()
                    let stderr = Pipe.forChildProcess()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    let output = drainAndWait(process, stdout: stdout, stderr: stderr)
                    return GitResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: output.stdout, encoding: .utf8) ?? "",
                        stderr: String(data: output.stderr, encoding: .utf8) ?? ""
                    )
                })
            }
        }
    }

    /// `run`, for a command the fixture cannot go on without.
    @discardableResult
    static func checked(
        _ arguments: [String],
        cwd: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> GitResult {
        let result = try await run(arguments, cwd: cwd)
        try #require(
            result.succeeded,
            "Git fixture command failed: \(arguments.joined(separator: " ")): \(result.stderr)",
            sourceLocation: sourceLocation
        )
        return result
    }
}
