// GitBranchRef.swift
// Weir — the full ref a branch name stands for, so Git is never handed a bare name a tag can take.

import Foundation

/// How a branch's name becomes what Git is given.
///
/// Git reads a bare name as a tag before a branch (gitrevisions(7)), so
/// `main` was the tag `main` wherever one existed: the review and the
/// sidebar's count compared against its commit, and a new worktree could
/// not start from the branch. The review, the sidebar's count, and New
/// Worktree give Git the full ref from here, and keep the name for what
/// they show.
enum GitBranchRef {
    /// The local branch `name` (`refs/heads/<name>`).
    static func local(_ name: String) -> String {
        "refs/heads/" + name
    }

    /// The remote-tracking branch `name`, remote first (`origin/main` is
    /// `refs/remotes/origin/main`).
    static func remote(_ name: String) -> String {
        "refs/remotes/" + name
    }

    /// The refs a branch name may stand for, in the order `resolve` takes
    /// them: the local branch, then the remote's, as Git reads a bare name,
    /// but never a tag. Earlier builds named origin's default by Git's short
    /// form, `remotes/origin/main` where a tag `origin/main` existed, and
    /// comments keep that name in their scope (`branch:<base>`), so that
    /// form still reads as the remote branch it named.
    static func candidates(for name: String) -> [String] {
        let candidates = [local(name), remote(name)]
        return name.hasPrefix("remotes/") ? candidates + ["refs/" + name] : candidates
    }

    /// The first of `candidates(for: name)` among `existing`; `nil` when
    /// `name` is no branch.
    static func resolve(_ name: String, among existing: Set<String>) -> String? {
        candidates(for: name).first { existing.contains($0) }
    }
}
