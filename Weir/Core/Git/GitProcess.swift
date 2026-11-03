// GitProcess.swift
// Weir — thin async wrapper around the `git` CLI. We shell
// out rather than linking libgit2 because:
//   1. The user already has git installed and configured (creds,
//      hooks, signing). We benefit from the same behavior.
//   2. The surface we need (`git worktree list`, `git status`,
//      `git worktree add`) is small and stable.
//   3. Avoids a heavy native dependency on a still-evolving build.
//
// All calls run on a background queue and return a Sendable result.

import Foundation
import OSLog

private let log = Logger.weir("git.process")

struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool {
        exitCode == 0
    }
}

enum GitProcessError: WeirLocalizedError {
    case launchFailed(String)
    /// `git` exited with a non-zero status. `result.stderr` is
    /// included as a hint.
    case nonZeroExit(GitResult)
    /// `git` was still running at its deadline and was ended.
    /// `hasProcessesLeft`: something it started outlived SIGKILL, and may
    /// still write where git ran.
    case timedOut(seconds: Int, hasProcessesLeft: Bool = false)

    /// What the worktree alerts show. An error with no message of its own
    /// would reach them as the `String(describing:)` synthesis
    /// (`"GitProcessError(launchFailed: posix_spawn failed: …)"`), which is
    /// readable to a maintainer and opaque to a user. git's own stderr
    /// follows our sentence, in English as git wrote it.
    var message: DisplayText {
        switch self {
        case let .launchFailed(message):
            .localized(LocalizedStringResource(
                "Couldn’t launch git: \(message). Check that git is installed.",
                comment: "Worktree-operation error — git binary failed to launch"
            ))
        case let .nonZeroExit(result):
            if result.stderr.isEmpty {
                .localized(LocalizedStringResource(
                    // Widened to `Int`: an `Int32` would make the key `%d`,
                    // which the catalog's `%lld` entry does not match.
                    "git exited with code \(Int(result.exitCode)).",
                    comment: "Worktree-operation error — git exited with non-zero code (no stderr)"
                ))
            } else {
                .localized(LocalizedStringResource(
                    "git exited with code \(Int(result.exitCode)): \(result.stderr)",
                    comment: "A git command failed; its exit code, then Git’s own message, in English"
                ))
            }
        case let .timedOut(seconds, _):
            .localized(LocalizedStringResource(
                "git didn’t finish within \(seconds) seconds.",
                comment: "Worktree-operation error — git ran past its deadline and was stopped; the number is seconds"
            ))
        }
    }
}

/// The program a git run starts: the git this app found once a launch
/// (`located`), or a test's stand-in.
struct GitExecutable: Sendable {
    let url: URL
    let leadingArguments: [String]

    /// The git that `GitProcess` and the review run. Opened from the Dock,
    /// the app has launchd's `PATH`, where `env git` finds the one in
    /// `/usr/bin` and never a Homebrew one, while the agents in the panes
    /// and the person use the newer git their shell finds. A repository that
    /// git wrote can be unreadable to an older one, so we look in the
    /// well-known install folders first in that case. Opened from a
    /// terminal, the app has that terminal's `PATH`, and its order wins, as
    /// `LoginShellPath.merged` decides for a setup step. Found without a
    /// login shell, so the first sync does not wait on one; a git that only
    /// a login shell's `PATH` names is not found.
    static let located = GitExecutable(
        url: locate(inheritedPath: ProcessInfo.processInfo.environment["PATH"] ?? ""),
        leadingArguments: []
    )

    /// The git `located` picks for an app whose `PATH` is `inheritedPath`:
    /// the first in `wellKnownDirectories` and then on the `PATH` when the
    /// `PATH` is launchd's own, the first on the `PATH` and then in those
    /// folders otherwise, and `/usr/bin/git` when there is none.
    static func locate(inheritedPath: String, wellKnownDirectories: [String] = ToolLocator.wellKnownDirectories) -> URL {
        let entries = inheritedPath.split(separator: ":").map(String.init)
        let isLaunchdDefault = entries.allSatisfy(LoginShellPath.launchdDefault.contains)
        let directories = isLaunchdDefault ? wellKnownDirectories + entries : entries + wellKnownDirectories
        return ToolLocator.firstExecutable(named: "git", in: directories) ?? URL(fileURLWithPath: "/usr/bin/git")
    }
}

enum GitProcess {
    /// How long a git run that reads (status, a listing, a ref) may take.
    static let readTimeout: Duration = .seconds(10)
    /// How long adding or removing a worktree may take: git runs the
    /// repository's `post-checkout` hook, which can install dependencies,
    /// and a checkout of a large repository on a slow disk takes minutes on
    /// its own. Only a run that hangs should reach it: one ended part way
    /// leaves a half-made worktree for the caller to clear.
    static let worktreeTimeout: Duration = .seconds(600)

    /// What every run starts with. A repository's own `core.fsmonitor`
    /// names a program git would start, and a folder opened from an
    /// archive brings its `.git/config` along; the review turns it off
    /// the same way (`ReviewGitCommand`).
    static let commonOptions = ["-c", "core.fsmonitor=false"]

    /// Run `git <args>` with cwd = `cwd`. Throws when the launch
    /// itself fails, and `timedOut` when git is still running at
    /// `timeout` (it is then ended with its process group, SIGKILL after a
    /// grace for what ignores SIGTERM; a process that left the group is
    /// not reached); non-zero exit codes are returned in `GitResult`
    /// (callers usually treat them as data, e.g. "not a git repo").
    static func run(
        _ args: [String],
        cwd: URL,
        timeout: Duration = readTimeout,
        environment: [String: String] = [:],
        executable: GitExecutable = .located
    ) async throws -> GitResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(args, cwd: cwd, timeout: timeout, environment: environment, executable: executable)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous variant — only call from a background queue.
    /// `environment` is laid over Weir's own, without the variables that
    /// name a repository, the locale included.
    static func runSync(
        _ args: [String],
        cwd: URL,
        timeout: Duration = readTimeout,
        environment: [String: String] = [:],
        executable: GitExecutable = .located
    ) throws -> GitResult {
        let env = Self.environment(inherited: ProcessInfo.processInfo.environment, given: environment)

        let stdoutPipe = Pipe.forChildProcess()
        let stderrPipe = Pipe.forChildProcess()
        // We start git in a process group of its own: a run past its deadline is ended
        // with the hooks it started, which would otherwise go on writing in
        // a worktree the caller clears and may make again at the same path.
        let process: GroupedProcess
        do {
            process = try GroupedProcess.launch(
                executable.url,
                arguments: executable.leadingArguments + commonOptions + args,
                environment: env,
                in: cwd,
                stdout: stdoutPipe,
                stderr: stderrPipe
            )
        } catch {
            throw GitProcessError.launchFailed(error.localizedDescription)
        }

        // See `drainAndWait` for why the pipes must be read while the
        // child is still running rather than after it exits, and how the
        // deadline is held.
        let output = drainAndWait(process, stdout: stdoutPipe, stderr: stderrPipe, timeout: timeout)
        guard output.ending == .exited else {
            log.error("git \(args.first ?? "", privacy: .public) ran past its deadline and was ended")
            if output.hasProcessesLeft {
                log.fault("git \(args.first ?? "", privacy: .public) left processes that outlived SIGKILL")
            }
            throw GitProcessError.timedOut(seconds: Int(timeout.components.seconds), hasProcessesLeft: output.hasProcessesLeft)
        }

        let result = GitResult(
            exitCode: process.terminationStatus,
            stdout: String(data: output.stdout, encoding: .utf8) ?? "",
            stderr: String(data: output.stderr, encoding: .utf8) ?? ""
        )
        if !result.succeeded {
            log
                .debug(
                    """
                    git \(args.joined(separator: " "), privacy: .private) \
                    exited \(result.exitCode, privacy: .public): \
                    \(result.stderr, privacy: .private)
                    """
                )
        }
        return result
    }

    /// The variables that name a repository, its index, or its objects, or
    /// change how its paths and config are read: the list the agent hook's
    /// `clear_repository_variables` drops for the same reason.
    static let repositoryVariables: Set<String> = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
        "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS",
        "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"
    ]

    /// What git runs with: `given` laid over `inherited`, the locale
    /// pinned. Pinned to the C locale so error messages we pattern-match
    /// on (e.g. "not a working tree" in `deleteGitWorktree`) stay in
    /// English regardless of the user's LANG / LC_MESSAGES. The rest is
    /// inherited so HOME, credential helpers, and proxies work, but none
    /// of `repositoryVariables`: the repository is the one at `cwd`, never
    /// one a `GIT_DIR` or `GIT_INDEX_FILE` of the shell that opened Weir
    /// names. A caller gives the ones it means. Unlike the review, which
    /// only reads and drops every `GIT_*` variable, we keep the rest: a
    /// fetch needs the person's `GIT_SSH` or `GIT_SSL_CAINFO`, and a
    /// worktree add their `GIT_CONFIG_GLOBAL`.
    static func environment(inherited: [String: String], given: [String: String]) -> [String: String] {
        var env = inherited.filter { !repositoryVariables.contains($0.key) }
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        env.merge(given) { _, given in given }
        return env
    }

    /// List local branch names ("main", "feat-x", …) for the repo.
    static func listLocalBranches(repoRoot: URL) async throws -> [String] {
        let result = try await run(
            ["branch", "--format=%(refname:short)"],
            cwd: repoRoot
        )
        guard result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Current branch name, or nil when HEAD is detached.
    static func currentBranch(repoRoot: URL) async throws -> String? {
        let result = try await run(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            cwd: repoRoot
        )
        guard result.succeeded else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "HEAD") ? nil : name
    }

    /// The checked-out commit, short, as `git rev-parse --short HEAD` names
    /// it: what names a detached HEAD, which has no branch. `nil` when git
    /// cannot say (no commit yet, not a repository).
    static func shortHead(repoRoot: URL) async throws -> String? {
        let result = try await run(["rev-parse", "--short", "HEAD"], cwd: repoRoot)
        guard result.succeeded else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Create a new worktree. When `newBranchName` is non-nil, runs
    /// `git worktree add -b <new> <path> <base>`, otherwise checks out
    /// the existing branch.
    @discardableResult
    static func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String? = nil
    ) async throws -> GitResult {
        var args = ["worktree", "add"]
        if let name = newBranchName, !name.isEmpty {
            args.append(contentsOf: ["-b", name])
        }
        // `--` forces git to parse the remaining tokens as positional
        // args. Defends against pathological paths or branch names that
        // start with `-` (git refname rules forbid them, but the
        // separator costs nothing and removes a class of CLI parsing
        // surprises).
        args.append("--")
        args.append(path.path)
        args.append(baseBranch)
        return try await run(args, cwd: repoRoot, timeout: worktreeTimeout)
    }

    /// Remove a worktree on disk. Wraps `git worktree remove`.
    /// `force` adds `--force` so unclean worktrees or worktrees with
    /// submodules can be removed too — callers should confirm with the
    /// user first because local work may be lost. Git requires two
    /// `--force` flags for locked worktrees, which this Boolean API does
    /// not request.
    @discardableResult
    static func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult {
        var args = ["worktree", "remove"]
        if force {
            args.append("--force")
        }
        args.append("--")
        args.append(path.path)
        return try await run(args, cwd: repoRoot, timeout: worktreeTimeout)
    }

    /// `git worktree prune`: forgets worktrees whose folders are gone, as
    /// one a stopped `git worktree add` registered and left without one.
    @discardableResult
    static func pruneWorktrees(repoRoot: URL) async throws -> GitResult {
        try await run(["worktree", "prune"], cwd: repoRoot, timeout: worktreeTimeout)
    }

    /// If `url` is a linked worktree of a larger git repo, return
    /// the main checkout's working-tree root. Used at "Add Project"
    /// time so the Project's `rootURL` doesn't end up listed inside
    /// its own `git worktree list` output — a self-reference that
    /// confused both the sidebar's worktree rows and any container column logic
    /// that compares container paths.
    ///
    /// Non-git folders, main checkouts, bare repos, arbitrary
    /// subdirectories under any working tree, and lookup failures
    /// all fall through to `url` unchanged. Promotion only triggers
    /// when the user pointed at an *exact* linked-worktree root —
    /// staying anchored at `/repo/subdir` (where the user explicitly
    /// picked a deeper anchor) is intentional.
    static func resolveMainCheckout(of url: URL) async -> URL {
        guard let worktrees = try? await GitWorktreeList.fetch(repoRoot: url),
              let main = worktrees.first,
              !main.isBare
        else { return url }
        let standardized = url.standardizedFileURL
        let isLinked = worktrees.dropFirst().contains {
            $0.path.standardizedFileURL == standardized
        }
        return isLinked ? main.path.standardizedFileURL : url
    }

    /// Quick check: does `git` find a repository rooted at `url`?
    /// Returns false for non-git folders and on launch errors.
    static func isGitRepository(_ url: URL) async -> Bool {
        // `git -C <url> rev-parse --is-inside-work-tree` exits 0 only
        // when inside a working tree. Using `--git-dir` instead would
        // be wrong — submodules and bare repos would answer "yes" to
        // the existence check but aren't usable as Weir roots.
        guard let result = try? await run(
            ["-C", url.path, "rev-parse", "--is-inside-work-tree"],
            cwd: url
        ) else { return false }
        return result.succeeded
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
