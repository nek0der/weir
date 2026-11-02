// GitWorktreeList.swift
// Weir — parse `git worktree list --porcelain` into a structured
// list of worktrees. Each worktree appears as a block of attribute
// lines terminated by a blank line:
//
//   worktree /Users/me/repo
//   HEAD abc123...
//   branch refs/heads/main
//
//   worktree /Users/me/repo-feat
//   HEAD def456...
//   branch refs/heads/feat-x
//
//   worktree /Users/me/repo-detached
//   HEAD ghi789...
//   detached
//
// `bare`, `locked`, and `prunable` flags can also appear. The sync
// leaves out a bare repository's own entry, which is no checkout, and a
// prunable one, whose folder is gone.

import Foundation

struct GitWorktreeInfo: Equatable {
    var path: URL
    var headSHA: String?
    var branch: String? // short branch name ("main"), nil when detached
    var isDetached: Bool
    var isBare: Bool
    var isLocked: Bool
    var isPrunable: Bool
}

enum GitWorktreeList {
    /// Parse the output of `git worktree list --porcelain`.
    static func parse(_ porcelain: String) -> [GitWorktreeInfo] {
        var results: [GitWorktreeInfo] = []
        var current: PartialWorktree?

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                if let p = current?.finalized {
                    results.append(p)
                }
                current = nil
                continue
            }
            if line.hasPrefix("worktree ") {
                if let p = current?.finalized {
                    results.append(p)
                }
                let path = String(line.dropFirst("worktree ".count))
                current = PartialWorktree(path: URL(fileURLWithPath: path))
            } else if line.hasPrefix("HEAD ") {
                current?.headSHA = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                // Format: `branch refs/heads/main` — strip the prefix
                // for display, callers can re-add it if they need the
                // fully-qualified ref.
                let raw = String(line.dropFirst("branch ".count))
                current?.branch = raw.hasPrefix("refs/heads/")
                    ? String(raw.dropFirst("refs/heads/".count))
                    : raw
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "bare" {
                current?.isBare = true
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            }
            // Unknown lines are ignored — porcelain is forward-compatible.
        }
        if let p = current?.finalized {
            results.append(p)
        }
        return results
    }

    /// Run `git worktree list --porcelain` against `repoRoot` and
    /// parse the result. `[]` when `repoRoot` is in no repository; throws
    /// on launch failure and on any other non-zero exit.
    ///
    /// A listing that failed says nothing about the worktrees. Read as
    /// none, it marked every row missing, and Remove Missing then closed
    /// their tabs, when git had only refused the repository (an owner
    /// `safe.directory` does not trust, an extension an older git does not
    /// know, a `.git/config` it cannot parse).
    static func fetch(repoRoot: URL) async throws -> [GitWorktreeInfo] {
        let result = try await GitProcess.run(
            ["worktree", "list", "--porcelain"],
            cwd: repoRoot
        )
        guard result.succeeded else {
            if isOutsideRepository(result) {
                return []
            }
            throw GitProcessError.nonZeroExit(result)
        }
        return parse(result.stdout)
    }

    /// Whether git failed because `repoRoot` is in no repository: its
    /// words under the C locale `GitProcess` runs it in.
    static func isOutsideRepository(_ result: GitResult) -> Bool {
        !result.succeeded && result.stderr.contains("not a git repository")
    }
}

// MARK: - Private

private struct PartialWorktree {
    var path: URL
    var headSHA: String?
    var branch: String?
    var isDetached: Bool = false
    var isBare: Bool = false
    var isLocked: Bool = false
    var isPrunable: Bool = false

    var finalized: GitWorktreeInfo {
        GitWorktreeInfo(
            path: path,
            headSHA: headSHA,
            branch: branch,
            isDetached: isDetached,
            isBare: isBare,
            isLocked: isLocked,
            isPrunable: isPrunable
        )
    }
}
