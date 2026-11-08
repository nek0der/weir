// LoginShellPathTests.swift
// Weir — the login shell's PATH: reading and merging it, and waiting for it across canceled callers.

import Foundation
import Testing
@testable import Weir

@Suite(.timeLimit(.minutes(1)))
struct LoginShellPathTests {
    @Test func theReadsValue_reachesTheCaller() async throws {
        let shell = LoginShellPath { "/opt/bin:/usr/bin" }
        #expect(try await shell.path() == "/opt/bin:/usr/bin")
    }

    @Test(arguments: [
        ("/opt/company tools/bin:/usr/bin" as String?, "/opt/company tools/bin:/usr/bin:/bin"),
        (nil, "/usr/bin:/bin")
    ])
    func loginPath_comesFromTheShellsExportedEnvironment(exportedPath: String?, expected: String) async throws {
        try await withTempDir { root in
            let shell = root.appendingPathComponent("login-shell")
            let setPath = exportedPath.map { "export PATH='\($0)'" } ?? "unset PATH"
            // Like Nushell, the stand-in leaves "$PATH" literal in the old command.
            try ShimHarness.writeExecutable(
                """
                #!/bin/sh
                [ "$1" = -lc ] || exit 1
                printf 'Welcome back\\n'
                \(setPath)
                case "$2" in
                  printf\\ *) printf '__WEIR_PATH__%s__WEIR_PATH__\\n' '$PATH' ;;
                  *) /bin/sh -c "$2" || exit ;;
                esac
                printf 'Goodbye\\n'
                """,
                at: shell
            )
            let path = await LoginShellPath.readLoginShell(shell: shell.path, inherited: "/usr/bin:/bin")
            #expect(path == expected)
        }
    }

    private struct Read {
        let task: Task<Void, Never>
        let completion: Recorded<Result<String?, any Error>?>

        init(_ shell: LoginShellPath, cancelBeforeWaiting: Bool = false) {
            let completion = Recorded<Result<String?, any Error>?>(nil)
            self.completion = completion
            task = Task {
                if cancelBeforeWaiting {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                do {
                    completion.value = try await .success(shell.path())
                } catch {
                    completion.value = .failure(error)
                }
            }
        }

        func result() async throws -> Result<String?, any Error> {
            await pollUntil { completion.value != nil }
            return try #require(completion.value, "the caller must finish while the shared read is held")
        }
    }

    @Test func aCallerCancelledWhileWaiting_stopsAtOnce_andTheNextOneGetsTheRead() async throws {
        let gate = Gate<String?>()
        defer { gate.open(with: nil) }
        let shell = LoginShellPath {
            let value = await gate.wait()
            return Task.isCancelled ? nil : value
        }
        let waiting = Read(shell)
        try await gate.waitUntilRequested()
        waiting.task.cancel()
        let canceled = try await waiting.result()
        #expect(throws: CancellationError.self) { try canceled.get() }

        let next = Read(shell)
        gate.open(with: "/opt/bin")
        #expect(try await next.result().get() == "/opt/bin")
        #expect(gate.requests == 1, "both callers share one read")
    }

    @Test func aCallerCancelledBeforeItWaits_stopsAtOnce() async throws {
        let gate = Gate<String?>()
        defer { gate.open(with: nil) }
        let shell = LoginShellPath {
            let value = await gate.wait()
            return Task.isCancelled ? nil : value
        }
        let waiting = Read(shell, cancelBeforeWaiting: true)
        let canceled = try await waiting.result()
        #expect(throws: CancellationError.self) { try canceled.get() }
    }

    @Test func cancelingOneCaller_preservesTheReadForAnother() async throws {
        let gate = Gate<String?>()
        defer { gate.open(with: nil) }
        let shell = LoginShellPath {
            let value = await gate.wait()
            return Task.isCancelled ? nil : value
        }
        let first = Read(shell)
        let second = Read(shell)
        try await gate.waitUntilRequested()
        first.task.cancel()
        let canceled = try await first.result()
        #expect(throws: CancellationError.self) { try canceled.get() }
        gate.open(with: "/opt/bin")
        #expect(try await second.result().get() == "/opt/bin")
        #expect(gate.requests == 1)
    }

    @Test(arguments: [
        (
            "Welcome back\n__WEIR_PATH__/opt/homebrew/bin:/usr/bin:/my/nvm/bin__WEIR_PATH__\nbye from .zlogout",
            "/opt/homebrew/bin:/usr/bin:/my/nvm/bin" as String?
        ),
        ("no marker at all", nil),
        ("__WEIR_PATH__/opt/homebrew/bin", nil),
        ("__WEIR_PATH__ \n __WEIR_PATH__", nil)
    ])
    func markedPath_isExtractedFromProfileOutput(output: String, expected: String?) {
        #expect(LoginShellPath.loginPath(in: output) == expected)
    }

    @Test(arguments: [
        (
            "/usr/bin:/bin:/usr/sbin:/sbin",
            "/opt/homebrew/bin:/usr/bin" as String?,
            "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" as String?
        ),
        ("/usr/bin", "$PATH:.", "/usr/bin"),
        ("/my/nvm/bin:/usr/bin", "/opt/homebrew/bin:/usr/bin:/my/nvm/bin", "/my/nvm/bin:/usr/bin:/opt/homebrew/bin"),
        ("/usr/bin:/bin", nil, "/usr/bin:/bin"),
        ("", nil, nil)
    ])
    func loginPath_isMergedWithInheritedOrder(inherited: String, login: String?, expected: String?) {
        #expect(LoginShellPath.merged(inherited: inherited, login: login) == expected)
    }
}
