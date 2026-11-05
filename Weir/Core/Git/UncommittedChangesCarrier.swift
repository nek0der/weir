// UncommittedChangesCarrier.swift
// Weir — moves a worktree's uncommitted changes into a new worktree, and leaves them where they were on any failure.
//
// Why not `git stash`. A stash takes the changes out of the source first and
// puts them back if applying them fails. Between those two steps the
// changes are only in the stash, and putting them back is one more step
// that can fail: an agent writing a file in the source meanwhile makes the
// restore of an untracked file refuse, and the person's work is left in an
// entry of a stack every worktree shares, where another session may pop it.
//
// So we copy first and take away last, and the source is written once, at
// the very end, only if nothing in it changed:
//
// 1. Read. The index and the whole working tree, untracked files included,
//    are written as two trees through a copy of the index
//    (`GIT_INDEX_FILE`). The source's own index and files are not written.
// 2. Place. The two trees are merged onto the new worktree's start with
//    `git merge-tree --merge-base`, which writes no file either. A conflict
//    stops here, before the worktree is made.
// 3. Apply. The new worktree, fresh at its start, is moved to the merged
//    trees with `git read-tree -m -u`, which checks every path before it
//    writes any, then checked against them, and every file the changes
//    touch compared byte for byte with the source's (a line-ending setting
//    or a filter can make files Git calls equal differ on disk). A new
//    worktree whose checkout's hook changed a tracked file, or left a file
//    Git ignores where the changes add one, is not written at all, and a
//    failure puts back only the paths the changes wrote.
// 4. Take away. With the source's index locked as Git locks it, and HEAD
//    read again under the lock, the working tree is moved from the
//    snapshot back to HEAD with `git read-tree -m -u`: it refuses, writing
//    nothing, if any file differs from what was read in step 1, or an
//    untracked file stands where HEAD has one. Only then is the new index
//    put in place.
//
// What only the index can hold (skip-worktree, assume-unchanged,
// intent-to-add) and files Git ignores inside a folder that replaced a
// tracked file would be lost by step 4, so step 1 refuses those worktrees.
//
// Step 4 failing part way, on a disk that stops taking writes, is the one
// case left: the changes are in the new worktree, checked, and a copy is
// stored as a stash entry as well.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("git.carry")

enum UncommittedChangesCarrier {
    /// The worktree's uncommitted changes as read in step 1.
    struct Snapshot: Equatable, Sendable {
        let source: URL
        let head: String
        /// The branch HEAD names (`refs/heads/main`); `nil` when detached.
        let branch: String?
        /// The index, as a tree.
        let indexTree: String
        /// The whole working tree, untracked files included, ignored ones
        /// not, as a tree.
        let fullTree: String
        /// The untracked files among them.
        let untracked: [String]
        /// Every path the working tree changes from HEAD.
        let changedPaths: [String]
        /// The paths among them it deletes, which going back to HEAD writes.
        let deletedPaths: [String]
        /// How many files changed, as the sidebar counts them.
        let fileCount: Int
    }

    /// The snapshot merged onto the new worktree's start (step 2): what its
    /// index and its working tree become.
    struct Placement: Equatable, Sendable {
        let start: String
        let indexTree: String
        let fullTree: String
        /// The paths the start changes from the snapshot's HEAD, where the
        /// new worktree's files are the merge's rather than the source's.
        let startChanges: Set<String>
    }

    /// How a carry ended once the worktree was made.
    enum Outcome: Equatable, Sendable {
        /// In the new worktree, and taken out of the source.
        case moved(files: Int)
        /// The new worktree could not take them; what we wrote there is put
        /// back to its start where it is still as we wrote it (a file a hook
        /// wrote meanwhile, or one of ours Git cut short, stays as it is),
        /// and the source was not touched.
        case notApplied
        /// The new worktree could not take them, and what we wrote there
        /// could not all be put back, so some of the changes may be in it
        /// too; the source was not touched.
        case notPutBack
        /// In the new worktree, and still in the source, which changed, or
        /// whose index Git held, while they were moved.
        case leftInSource
        /// In the new worktree; the source could not be cleared all the
        /// way. `stash` is the copy kept, `nil` when none could be stored.
        case partlyCleared(stash: String?)
    }

    // MARK: - Counting

    /// How many files the worktree at `root` has uncommitted, as the
    /// sidebar counts them; `nil` when Git did not answer. Asks for no
    /// lock, so it never stands in the way of the person's own Git.
    static func changedFileCount(in root: URL) async -> Int? {
        guard let result = try? await GitProcess.run(
            ["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            cwd: root
        ), result.succeeded else { return nil }
        return UncommittedCarryRules.changedFileCount(porcelain: result.stdout)
    }

    // MARK: - 1. Read

    /// The worktree at `root`'s uncommitted changes, or `nil` when it has
    /// none. Writes nothing in the worktree: the trees are made through a
    /// copy of its index.
    static func snapshot(of root: URL) async throws -> Snapshot? {
        let resolved = try await gitPaths(["index"] + UncommittedCarryRules.operationMarkers, in: root)
        let head = await headCommit(in: root)
        if let refusal = await UncommittedCarryRules.refusal(
            hasCommit: head != nil,
            isOperationInProgress: resolved.dropFirst().contains { FileManager.default.fileExists(atPath: $0.path) },
            usesSparseCheckout: isOn("core.sparseCheckout", in: root),
            usesSplitIndex: isOn("core.splitIndex", in: root)
        ) {
            throw refusal
        }
        guard let head, let index = resolved.first else {
            throw UncommittedCarryRefusal.git("HEAD or the index could not be read")
        }
        let branch = await headBranch(in: root)

        return try await withScratch { scratch in
            let copy = scratch.appendingPathComponent("index")
            let indexTree = try await Self.indexTree(copying: index, to: copy, in: root)
            let environment = ["GIT_INDEX_FILE": copy.path]
            try await refuseIndexOnlyState(in: root, indexTree: indexTree)
            try await output(["add", "-A", "--", ":/"], in: root, environment: environment)
            let fullTree = try await output(["write-tree"], in: root, environment: environment)
            let headTree = try await output(["rev-parse", "\(head)^{tree}"], in: root)
            guard indexTree != headTree || fullTree != headTree else { return nil }
            for tree in [indexTree, fullTree] {
                let raw = try await output(["diff-tree", "-r", "-z", "--no-renames", head, tree], in: root, trims: false)
                if UncommittedCarryRules.touchesGitlinks(rawDiff: raw) {
                    throw UncommittedCarryRefusal.submodules
                }
            }
            let deleted = try await changedNames(from: head, to: fullTree, filter: "D", in: root)
            try await refuseIgnoredFilesInTheWay(in: root, deleted: deleted)
            let untracked = try await changedNames(from: indexTree, to: fullTree, filter: "A", in: root)
            let changedPaths = try await changedNames(from: head, to: fullTree, in: root)
            return await Snapshot(
                source: root,
                head: head,
                branch: branch,
                indexTree: indexTree,
                fullTree: fullTree,
                untracked: untracked,
                changedPaths: changedPaths,
                deletedPaths: deleted,
                fileCount: changedFileCount(in: root) ?? 0
            )
        }
    }

    /// The commit HEAD is at, `nil` when there is none or Git did not
    /// answer.
    private static func headCommit(in root: URL) async -> String? {
        try? await output(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root)
    }

    /// The branch HEAD names, `nil` on a detached HEAD: a checkout made
    /// meanwhile changes it even where the commit stays.
    private static func headBranch(in root: URL) async -> String? {
        try? await output(["symbolic-ref", "--quiet", "HEAD"], in: root)
    }

    /// What only the index holds of a file, and no tree can (skip-worktree,
    /// assume-unchanged, intent-to-add): taking the changes away replaces
    /// the index, which would drop it, so such a worktree is refused.
    private static func refuseIndexOnlyState(in root: URL, indexTree: String) async throws {
        let entries = try await output(["ls-files", "-v", "-z"], in: root, trims: false).split(separator: "\0")
        let tree = try await output(["ls-tree", "-r", "-z", "--name-only", "--full-tree", indexTree], in: root, trims: false)
            .split(separator: "\0")
        if UncommittedCarryRules
            .hasIndexOnlyState(tags: entries.compactMap(\.first), indexEntries: entries.count, treeEntries: tree.count)
        {
            throw UncommittedCarryRefusal.indexOnlyState
        }
    }

    /// Something Git ignores where going back to HEAD writes a tracked
    /// file: a folder holding ignored files, or an ignored file, where the
    /// file was, or an ignored file where its folder was. Git would remove
    /// it to write the file, and it is carried nowhere.
    private static func refuseIgnoredFilesInTheWay(in root: URL, deleted: [String]) async throws {
        if let refusal = try await ignoredFileInTheWay(in: root, at: deleted) {
            throw refusal
        }
    }

    /// The first of `paths`, each one Git is about to write a tracked file
    /// at, where something Git ignores is on disk now: a file of that name
    /// the person keeps out of Git (`.env`, untracked and ignored after it
    /// was committed), a folder holding ignored files, or an ignored file
    /// or link where the path needs a folder (`build` for `build/out`).
    /// `read-tree -u` takes ignored files as its own to replace, so Git
    /// writes the tracked file over it, and nothing carries it. For the
    /// paths the changes delete, a file Git does not ignore there is no
    /// deletion: it is in the snapshot; for the paths a placement adds, it
    /// is one `read-tree` refuses to write over, so either way we stop.
    /// Answered as the refusal that names it.
    private static func ignoredFileInTheWay(in root: URL, at paths: [String]) async throws -> UncommittedCarryRefusal? {
        // The folders above a path already found to hold nothing in the
        // way, each asked about once.
        var cleared: Set<String> = []
        for path in paths {
            if let folder = try await ignoredFileAbove(path, in: root, cleared: &cleared) {
                return .ignoredFileInTheWay(folder)
            }
            switch FileBytes(at: root.appendingPathComponent(path)).kind {
            case .missing:
                continue
            case .unreadable:
                guard isFolder(root.appendingPathComponent(path)) else { return .ignoredFileWritten(path) }
                if try await !ignoredFiles(at: "\(path)/", in: root).isEmpty {
                    return .ignoredFilesInTheWay(path)
                }
            case .link, .file:
                return .ignoredFileWritten(path)
            }
        }
        return nil
    }

    /// The first folder `path` is in that is no folder on disk but a file
    /// or a link Git ignores. Git writes `path` by putting a folder in its
    /// place. A tracked file there is the changes' own to replace, and an
    /// untracked one `read-tree` refuses to write over.
    private static func ignoredFileAbove(_ path: String, in root: URL, cleared: inout Set<String>) async throws -> String? {
        let parts = path.split(separator: "/").dropLast()
        for count in parts.indices.map({ $0 + 1 }) {
            let folder = parts.prefix(count).joined(separator: "/")
            guard !cleared.contains(folder) else { continue }
            var info = stat()
            guard lstat(root.appendingPathComponent(folder).path, &info) == 0 else {
                // Nothing there, and so nothing below it: Git makes the folder.
                if errno == ENOENT || errno == ENOTDIR {
                    return nil
                }
                return folder
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                if try await !ignoredFiles(at: folder, in: root).isEmpty {
                    return folder
                }
                cleared.insert(folder)
                return nil
            }
            cleared.insert(folder)
        }
        return nil
    }

    /// The files Git ignores at `pathspec`, taken as the path it is.
    private static func ignoredFiles(at pathspec: String, in root: URL) async throws -> String {
        try await output(
            ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--", pathspec],
            in: root,
            environment: literalPaths
        )
    }

    /// Whether a folder is at `url`, links not followed.
    static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether something other than a folder stands above `path` in the
    /// worktree at `root`: a link, a file, or what cannot be looked at.
    static func hasNonFolderAbove(_ path: String, in root: URL) -> Bool {
        let parts = path.split(separator: "/").dropLast()
        for count in parts.indices.map({ $0 + 1 }) {
            var info = stat()
            guard lstat(root.appendingPathComponent(parts.prefix(count).joined(separator: "/")).path, &info) == 0 else {
                return errno != ENOENT
            }
            if info.st_mode & S_IFMT != S_IFDIR {
                return true
            }
        }
        return false
    }

    /// Whether something other than a folder is at `url`, links not
    /// followed. What cannot be looked at counts as something.
    static func hasNonFolder(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno != ENOENT && errno != ENOTDIR }
        return info.st_mode & S_IFMT != S_IFDIR
    }

    /// The paths `git <arguments>` lists with `-z`.
    private static func names(in arguments: [String], _ root: URL) async throws -> [String] {
        try await output(arguments, in: root, trims: false).split(separator: "\0").map(String.init)
    }

    /// The paths `to` changes from `from`, both trees or commits, renames
    /// read as a deletion and an addition; only those of `git diff
    /// --diff-filter` kind `filter` when one is given.
    static func changedNames(from: String, to: String, filter: String? = nil, in root: URL) async throws -> [String] {
        let filtering = filter.map { ["--diff-filter=\($0)"] } ?? []
        return try await names(in: ["diff-tree", "-r", "-z", "--name-only", "--no-renames"] + filtering + [from, to], root)
    }

    // MARK: - 2. Place

    /// The snapshot merged onto `start`, read in the repository at
    /// `repoRoot`, which shares its objects with every worktree. Throws
    /// `.conflicts` with the paths when the changes do not apply there.
    static func place(_ snapshot: Snapshot, onto start: String, repoRoot: URL) async throws -> Placement {
        let startCommit = try await output(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(start)^{commit}"], in: repoRoot)
        // Putting a new worktree back reads attributes with `--attr-source`
        // (Git 2.41), so an older Git is refused here, before anything is
        // made, rather than found out there, where nothing could be told
        // ours.
        let probe = try await run(["--attr-source=\(startCommit)", "version"], in: repoRoot)
        guard probe.succeeded else {
            if UncommittedCarryRules.isUnknownOption(exitCode: probe.exitCode, stderr: probe.stderr) {
                throw UncommittedCarryRefusal.unsupportedGit
            }
            throw UncommittedCarryRefusal.git(probe.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard startCommit != snapshot.head else {
            return Placement(start: startCommit, indexTree: snapshot.indexTree, fullTree: snapshot.fullTree, startChanges: [])
        }
        let fullTree = try await merge(snapshot.fullTree, from: snapshot.head, onto: startCommit, in: repoRoot)
        let indexTree = try await merge(snapshot.indexTree, from: snapshot.head, onto: startCommit, in: repoRoot)
        let startChanges = try await changedNames(from: snapshot.head, to: startCommit, in: repoRoot)
        return Placement(start: startCommit, indexTree: indexTree, fullTree: fullTree, startChanges: Set(startChanges))
    }

    /// `tree`, a change from `base`, merged onto `start`: the tree the
    /// merge makes. Git merges commits, so `tree` is given one on `base`
    /// first; it stays out of every ref, as the trees do.
    private static func merge(_ tree: String, from base: String, onto start: String, in repoRoot: URL) async throws -> String {
        let commit = try await output(
            ["commit-tree", "--no-gpg-sign", "-p", base, "-m", "weir-carry", tree],
            in: repoRoot,
            environment: internalIdentity
        )
        let result = try await run(
            ["merge-tree", "--write-tree", "--name-only", "--no-messages", "--merge-base=\(base)", start, commit],
            in: repoRoot
        )
        switch result.exitCode {
        case 0:
            return result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        case 1:
            throw UncommittedCarryRefusal.conflicts(UncommittedCarryRules.conflictPaths(mergeTreeOutput: result.stdout))
        default:
            if UncommittedCarryRules.isUnknownOption(exitCode: result.exitCode, stderr: result.stderr) {
                throw UncommittedCarryRefusal.unsupportedGit
            }
            throw UncommittedCarryRefusal.git(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - 3 and 4. Apply, then take away

    /// Puts `placement` into the new worktree at `target`, checks it there,
    /// then takes the snapshot out of its source. Never throws: each way it
    /// can end is an `Outcome`, and none of them loses a change.
    /// `checked` runs once the new worktree was checked, before Git writes
    /// in it, and `placed` once Git wrote the placement, before it is
    /// checked: a test writes there, as a hook still running would.
    /// `clearing` runs under the source's lock, once it was found as read,
    /// just before Git writes there: a test edits a file, as an agent
    /// would.
    /// `headChecked` runs once the source's HEAD was found unmoved, before
    /// its index is locked: a test moves HEAD there, so only the check
    /// under the lock can see it.
    static func move(
        _ snapshot: Snapshot,
        placement: Placement,
        into target: URL,
        checked: @Sendable () async -> Void = {},
        placed: @Sendable () async -> Void = {},
        headChecked: @Sendable () async -> Void = {},
        clearing: @Sendable () async -> Void = {}
    ) async -> Outcome {
        if let failure = await apply(placement, of: snapshot, to: target, checked: checked, placed: placed) {
            return failure
        }
        return await clear(snapshot, headChecked: headChecked, clearing: clearing)
    }

    /// Step 3. `nil` once the new worktree holds the placement, checked;
    /// else what we wrote is put back to its start, and the outcome says
    /// whether all of it could be. A worktree
    /// with tracked changes of its own, or a file Git ignores where the
    /// changes add one, is refused before we write and left as it is.
    private static func apply(
        _ placement: Placement,
        of snapshot: Snapshot,
        to target: URL,
        checked: @Sendable () async -> Void,
        placed: @Sendable () async -> Void
    ) async -> Outcome? {
        // The new worktree is at the start it was made from; anything else
        // and the merge was for another commit.
        guard let head = await headCommit(in: target),
              head == placement.start
        else { return .notApplied }
        // Nothing in it but its start, before we write: a `post-checkout`
        // hook may have changed or staged a tracked file, and the checks
        // below compare the whole worktree with the placement, so that
        // change would fail them and be taken back as ours. Files Git does
        // not track may stay: `read-tree` refuses to write over one it does
        // not ignore, and the ignored ones are looked for next.
        guard await hasNoTrackedChanges(target) else {
            log.info("carry: the new worktree has changes of its own; it is left as it is")
            return .notApplied
        }
        // A file Git ignores where the changes add one (a hook's `.env`, or
        // the folder it installs into): `read-tree` would write over it.
        let added: [String]
        do {
            added = try await changedNames(from: placement.start, to: placement.fullTree, filter: "A", in: target)
            if let refusal = try await ignoredFileInTheWay(in: target, at: added) {
                let what = String(describing: refusal)
                log.info("carry: the new worktree has an ignored file in the way (\(what, privacy: .private)); it is left as it is")
                return .notApplied
            }
        } catch {
            log.error("carry: the new worktree could not be checked for ignored files: \(String(describing: error), privacy: .private)")
            return .notApplied
        }
        // The folders the write would make, in place of nothing or of a
        // file it deletes, which putting it back may remove again once
        // empty; a folder that was there stays.
        let madeFolders = Set(added.flatMap(folders(above:)).filter { !isFolder(target.appendingPathComponent($0)) })
        await checked()
        // Checks every path before writing any: a file the checkout's hook
        // made where a change goes stops it with nothing written, and the
        // worktree keeps that file.
        do {
            let result = try await run(["read-tree", "-m", "-u", "HEAD", placement.fullTree], in: target)
            guard result.succeeded else {
                // A refusal wrote nothing; a write stopped part way, as at
                // a folder Git may not write in, exits the same way.
                log.error("carry: the new worktree did not take the changes: \(result.stderr, privacy: .private)")
                return await rollBack(placement, in: target, madeFolders: madeFolders) ? .notApplied : .notPutBack
            }
        } catch {
            log.error("carry: the new worktree did not take the changes: \(String(describing: error), privacy: .private)")
            return await rollBack(placement, in: target, madeFolders: madeFolders) ? .notApplied : .notPutBack
        }
        await placed()
        let isPlaced = await isHolding(placement, in: target)
            && hasSameBytes(snapshot, placement: placement, in: target)
        guard isPlaced else {
            log.error("carry: the new worktree does not hold the changes as the source has them")
            return await rollBack(placement, in: target, madeFolders: madeFolders) ? .notApplied : .notPutBack
        }
        return nil
    }

    /// The index set to the placement's (its working tree is already the
    /// placement's), and both checked: the index as a tree, and every file
    /// against the placement's working tree.
    private static func isHolding(_ placement: Placement, in target: URL) async -> Bool {
        guard await (try? output(["read-tree", placement.indexTree], in: target)) != nil,
              let index = try? await gitPaths(["index"], in: target).first
        else { return false }
        // Stat data for the index just read; the files that differ from it
        // are the unstaged changes, so its exit says nothing here.
        _ = try? await run(["update-index", "-q", "--refresh"], in: target)
        return await (try? withScratch { scratch in
            let indexTree = try await Self.indexTree(copying: index, to: scratch.appendingPathComponent("index"), in: target)
            guard indexTree == placement.indexTree else { return false }
            return try await matches(placement.fullTree, in: target, seed: index, scratch: scratch)
        }) ?? false
    }

    /// Whether every file the changes touch is in the new worktree byte
    /// for byte as in the source. Git compares files as it stores them, so
    /// a line-ending conversion or a filter could make two files Git calls
    /// the same differ on disk; the source would then lose its own bytes.
    /// A path the start changed too is the merge's, and only Git can say
    /// what it should be.
    private static func hasSameBytes(_ snapshot: Snapshot, placement: Placement, in target: URL) -> Bool {
        snapshot.changedPaths.allSatisfy { path in
            placement.startChanges.contains(path)
                || FileBytes(at: snapshot.source.appendingPathComponent(path)) == FileBytes(at: target.appendingPathComponent(path))
        }
    }

    /// Whether every file of `tree` is on disk in the worktree at `root`
    /// as `tree` has it, through a copy of the index at `seed` made into
    /// `tree`'s: the entries `tree` shares with the index keep their stat
    /// data, so only the files that differ are read again.
    private static func matches(_ tree: String, in root: URL, seed: URL, scratch: URL) async throws -> Bool {
        let check = scratch.appendingPathComponent("check-\(UUID().uuidString)")
        try copyIndex(seed, to: check)
        let environment = ["GIT_INDEX_FILE": check.path]
        try await output(["read-tree", "--reset", tree], in: root, environment: environment)
        return try await run(["update-index", "--refresh"], in: root, environment: environment).succeeded
    }

    /// Whether the worktree at `root` has no change to a tracked file,
    /// staged or not; `false` when Git cannot say.
    private static func hasNoTrackedChanges(_ root: URL) async -> Bool {
        guard let result = try? await run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=none"],
            in: root
        ) else { return false }
        return result.succeeded && result.stdout.isEmpty
    }

    /// The paths the placement changes from its start: `written`, those
    /// whose files it writes, and `all`, those with its index's changes
    /// besides.
    static func carriedPaths(of placement: Placement, in target: URL) async throws -> (written: [String], all: Set<String>) {
        let written = try await changedNames(from: placement.start, to: placement.fullTree, in: target)
        let staged = try await changedNames(from: placement.start, to: placement.indexTree, in: target)
        return (written, Set(written).union(staged))
    }

    /// Step 4: the snapshot taken out of its source, only as it was read.
    private static func clear(
        _ snapshot: Snapshot,
        headChecked: @Sendable () async -> Void,
        clearing: @Sendable () async -> Void
    ) async -> Outcome {
        let root = snapshot.source
        guard await isAtSnapshotHead(snapshot), let index = try? await gitPaths(["index"], in: root).first else { return .leftInSource }
        await headChecked()
        // Git's own lock on the index: while we hold it, no other Git
        // writes the index, and every Git that would waits or gives up.
        guard let lock = await IndexLock.acquire(for: index) else {
            log.info("carry: the source's index is locked; its changes stay")
            return .leftInSource
        }
        defer { lock.release() }
        // Again under the lock: `git commit -m` moves HEAD while it holds
        // the lock, and going back to the old HEAD would then undo that
        // commit. A `git commit` waiting on its message editor holds no lock
        // and has not moved HEAD yet; that one we cannot see
        // (docs/known-limitations.md).
        guard await isAtSnapshotHead(snapshot) else { return .leftInSource }
        return await (try? withScratch { scratch -> Outcome in
            guard let next = try await nextIndexIfUnchanged(snapshot, index: index, scratch: scratch) else { return .leftInSource }
            await clearing()
            return await writeBack(snapshot, index: index, next: next, lock: lock, scratch: scratch)
        }) ?? .leftInSource
    }

    /// Step 4's check that the source is still as read, under the lock: the
    /// next index, the snapshot's checked against every file on disk, or
    /// `nil` when anything changed since.
    private static func nextIndexIfUnchanged(_ snapshot: Snapshot, index: URL, scratch: URL) async throws -> URL? {
        let root = snapshot.source
        // The index as read: nothing staged or unstaged since.
        let indexTree = try await Self.indexTree(copying: index, to: scratch.appendingPathComponent("index"), in: root)
        guard indexTree == snapshot.indexTree else { return nil }
        // The next index starts as the snapshot's, checked against every
        // file on disk; then the working tree goes back to HEAD through
        // it, which refuses, writing nothing, if a file changed since.
        let next = scratch.appendingPathComponent("next")
        try copyIndex(index, to: next)
        let environment = ["GIT_INDEX_FILE": next.path]
        try await output(["read-tree", "--reset", snapshot.fullTree], in: root, environment: environment)
        guard try await run(["update-index", "--refresh"], in: root, environment: environment).succeeded else {
            return nil
        }
        // Again just before Git writes: an ignored file a build made
        // since the snapshot, where the changes delete a tracked one,
        // would be written over, and Git takes ignored files as its own
        // to replace.
        guard try await ignoredFileInTheWay(in: root, at: snapshot.deletedPaths) == nil else { return nil }
        return next
    }

    /// Step 4's write: the working tree moved back to HEAD through the
    /// index at `next`, then that index put in place through `lock`.
    private static func writeBack(_ snapshot: Snapshot, index: URL, next: URL, lock: IndexLock, scratch: URL) async -> Outcome {
        let environment = ["GIT_INDEX_FILE": next.path]
        do {
            let cleared = try await run(
                ["read-tree", "-m", "-u", snapshot.fullTree, snapshot.head],
                in: snapshot.source,
                environment: environment
            )
            guard cleared.succeeded else {
                return await failedClear(snapshot, scratch: scratch, reason: cleared.stderr)
            }
        } catch {
            return await failedClear(snapshot, scratch: scratch, reason: String(describing: error))
        }
        // HEAD moved by a command that takes no lock on the index
        // (`update-ref`, `reset --soft`): the new index would be for the
        // old one.
        guard await isAtSnapshotHead(snapshot), lock.commit(contentsOf: next) else {
            log.error("carry: the source's new index could not be put in place")
            return await .partlyCleared(stash: keepAsStash(snapshot))
        }
        return .moved(files: snapshot.fileCount)
    }

    /// Step 4 after a `read-tree` that failed. A refusal, as for a file
    /// that changed since the check, wrote nothing; a run that failed
    /// while writing (a folder it may not write in, a disk that stops
    /// taking writes) or did not finish may have written part of it. Git's
    /// exit tells neither apart, so the source does: left as it was when no
    /// file the changes touch was put back to HEAD, else cleared part way,
    /// with a copy of the changes kept.
    private static func failedClear(_ snapshot: Snapshot, scratch: URL, reason: String) async -> Outcome {
        if await isUntouched(snapshot, scratch: scratch) {
            log.info("carry: the source changed; its changes stay: \(reason, privacy: .private)")
            return .leftInSource
        }
        log.error("carry: the source was cleared part way: \(reason, privacy: .private)")
        return await .partlyCleared(stash: keepAsStash(snapshot))
    }

    /// Whether the source's HEAD is the commit and the branch it was when
    /// the changes were read.
    private static func isAtSnapshotHead(_ snapshot: Snapshot) async -> Bool {
        let head = await headCommit(in: snapshot.source)
        let branch = await headBranch(in: snapshot.source)
        return head == snapshot.head && branch == snapshot.branch
    }

    /// Whether no file the changes touch was put back to HEAD in the
    /// source, which only our write does: a changed path whose file is now
    /// byte for byte what Git checks out from HEAD (under HEAD's own
    /// attributes), or, for a file HEAD does not have, gone. Git checks
    /// every path before it writes any, so a refusal, as for a file an agent
    /// changed since the check, wrote nothing and leaves none of them so; a
    /// write stopped part way has put one back. When Git cannot say, we take
    /// the source as touched and keep a copy, the side that loses nothing.
    private static func isUntouched(_ snapshot: Snapshot, scratch: URL) async -> Bool {
        let root = snapshot.source
        guard let added = try? await Set(changedNames(from: snapshot.head, to: snapshot.fullTree, filter: "A", in: root)) else {
            return false
        }
        let inHead = snapshot.changedPaths.filter { !added.contains($0) }
        let checkedOut = scratch.appendingPathComponent("head", isDirectory: true)
        let environment = ["GIT_INDEX_FILE": scratch.appendingPathComponent("head-index").path]
        guard await (try? output(["read-tree", snapshot.head], in: root, environment: environment)) != nil else { return false }
        for batch in batches(of: inHead) {
            let result = try? await run(
                ["--attr-source=\(snapshot.head)", "checkout-index", "--prefix=\(checkedOut.path)/", "--"] + batch,
                in: root,
                environment: environment
            )
            guard result?.succeeded == true else { return false }
        }
        return !snapshot.changedPaths.contains { path in
            let url = root.appendingPathComponent(path)
            guard !added.contains(path) else { return !hasNonFolder(at: url) }
            let now = FileBytes(at: url)
            return now.kind != .missing && now == FileBytes(at: checkedOut.appendingPathComponent(path))
        }
    }

    // MARK: - The copy kept

    /// The snapshot stored as a stash entry, shaped as `git stash push
    /// --include-untracked` makes one, so `git stash apply --index` takes
    /// it back: its name, or `nil` when it could not be stored.
    static func keepAsStash(_ snapshot: Snapshot) async -> String? {
        let root = snapshot.source
        let name = "weir-carry-\(UUID().uuidString.prefix(8).lowercased())"
        return await (try? withScratch { scratch -> String in
            let indexCommit = try await output(
                ["commit-tree", "--no-gpg-sign", "-p", snapshot.head, "-m", "index on \(name)", snapshot.indexTree],
                in: root,
                environment: internalIdentity
            )
            // The working tree without the untracked files, which the third
            // parent holds on their own.
            let tracked = ["GIT_INDEX_FILE": scratch.appendingPathComponent("tracked").path]
            try await output(["read-tree", snapshot.fullTree], in: root, environment: tracked)
            var parents = ["-p", snapshot.head, "-p", indexCommit]
            if !snapshot.untracked.isEmpty {
                for batch in batches(of: snapshot.untracked) {
                    try await output(["update-index", "--force-remove", "--"] + batch, in: root, environment: tracked)
                }
                let untracked = ["GIT_INDEX_FILE": scratch.appendingPathComponent("untracked").path]
                let entries = try await output(["ls-tree", "-r", "-z", "--full-tree", snapshot.fullTree], in: root, trims: false)
                let isUntracked = Set(snapshot.untracked)
                let cacheInfo = entries.split(separator: "\0").compactMap { Self.cacheInfo($0, keeping: isUntracked) }
                for batch in batches(of: cacheInfo) {
                    try await output(["update-index", "--add"] + batch.flatMap { ["--cacheinfo", $0] }, in: root, environment: untracked)
                }
                let untrackedTree = try await output(["write-tree"], in: root, environment: untracked)
                let untrackedCommit = try await output(
                    ["commit-tree", "--no-gpg-sign", "-m", "untracked files on \(name)", untrackedTree],
                    in: root,
                    environment: internalIdentity
                )
                parents += ["-p", untrackedCommit]
            }
            let workTree = try await output(["write-tree"], in: root, environment: tracked)
            let stash = try await output(
                ["commit-tree", "--no-gpg-sign"] + parents + ["-m", "On \(name): Weir kept these changes", workTree],
                in: root,
                environment: internalIdentity
            )
            try await output(["stash", "store", "-m", name, stash], in: root)
            return name
        })
    }

    /// `ls-tree`'s `<mode> <type> <object>\t<path>` as `--cacheinfo`'s
    /// `<mode>,<object>,<path>`, for a path among `paths`.
    private static func cacheInfo(_ entry: Substring, keeping paths: Set<String>) -> String? {
        guard let tab = entry.firstIndex(of: "\t") else { return nil }
        let path = String(entry[entry.index(after: tab)...])
        let meta = entry[..<tab].split(separator: " ")
        guard meta.count == 3, paths.contains(path) else { return nil }
        return "\(meta[0]),\(meta[2]),\(path)"
    }

    /// Paths a few hundred at a time, so no command line passes what the
    /// system takes.
    static func batches(of items: [String]) -> [[String]] {
        stride(from: 0, to: items.count, by: 256).map { Array(items[$0..<min($0 + 256, items.count)]) }
    }

    // MARK: - Running Git

    /// Git takes the paths we name as they are, never as patterns: a file
    /// named `*.txt` is that file alone.
    static let literalPaths = ["GIT_LITERAL_PATHSPECS": "1"]

    /// Who the carry's own commits are by. They are in no branch, only in
    /// the trees merged and the stash kept, and must not stop on a person
    /// who set no name: `commit-tree` refuses without one.
    private static let internalIdentity = [
        "GIT_AUTHOR_NAME": "Weir", "GIT_AUTHOR_EMAIL": "weir@localhost",
        "GIT_COMMITTER_NAME": "Weir", "GIT_COMMITTER_EMAIL": "weir@localhost"
    ]

    /// Each run may take as long as adding a worktree may: reading every
    /// file of a large worktree, or writing back what changed, takes far
    /// longer than a read's ten seconds, and a run ended part way is the
    /// one way the carry could leave a worktree half written.
    static func run(_ arguments: [String], in root: URL, environment: [String: String] = [:]) async throws -> GitResult {
        do {
            return try await GitProcess.run(arguments, cwd: root, timeout: GitProcess.worktreeTimeout, environment: environment)
        } catch {
            throw UncommittedCarryRefusal.git(DisplayText(error: error).resolved(in: Locale(identifier: "en")))
        }
    }

    /// What `git <arguments>` printed, trimmed unless `trims` is off;
    /// throws its words when it fails.
    @discardableResult
    static func output(
        _ arguments: [String],
        in root: URL,
        environment: [String: String] = [:],
        trims: Bool = true
    ) async throws -> String {
        let result = try await run(arguments, in: root, environment: environment)
        guard result.succeeded else {
            throw UncommittedCarryRefusal.git(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return trims ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.stdout
    }

    /// Where `names` are in the worktree's Git folder (`index`,
    /// `MERGE_HEAD`), as absolute paths. Git answers relative to its own
    /// working folder unless asked otherwise; resolved here, a relative
    /// answer would land beside the worktree rather than in it, and the
    /// lock taken on an index that is not the worktree's would guard
    /// nothing.
    private static func gitPaths(_ names: [String], in root: URL) async throws -> [URL] {
        let paths = try await output(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] }, in: root)
            .split(separator: "\n")
            .map(String.init)
        guard paths.count == names.count, paths.allSatisfy({ $0.hasPrefix("/") }) else {
            throw UncommittedCarryRefusal.git(paths.joined(separator: " "))
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    private static func isOn(_ key: String, in root: URL) async -> Bool {
        await (try? output(["config", "--type=bool", "--get", key], in: root)) == "true"
    }

    /// A copy of the index at `index`. A worktree with a commit and no
    /// index is one Git checked nothing out in: read as empty, every file
    /// would look deleted, so it is refused instead.
    private static func copyIndex(_ index: URL, to copy: URL) throws {
        guard FileManager.default.fileExists(atPath: index.path) else {
            throw UncommittedCarryRefusal.git("\(index.path): no index")
        }
        try FileManager.default.copyItem(at: index, to: copy)
    }

    /// The tree the index at `index` makes, written through a copy of it at
    /// `copy`, so the index itself is not written. An index with unmerged
    /// paths makes no tree, and is refused as such.
    private static func indexTree(copying index: URL, to copy: URL, in root: URL) async throws -> String {
        try copyIndex(index, to: copy)
        do {
            return try await output(["write-tree"], in: root, environment: ["GIT_INDEX_FILE": copy.path])
        } catch let UncommittedCarryRefusal.git(said) where said.contains("unmerged") {
            throw UncommittedCarryRefusal.unmergedPaths
        }
    }

    /// `body` with a folder of its own under the temporary folder, removed
    /// after it.
    static func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("weir-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await body(scratch)
    }
}

/// What is on disk at a path, as the carry compares two worktrees: nothing,
/// a symbolic link and where it points, or a file's bytes and whether it
/// runs. A folder is no file of a change.
struct FileBytes: Equatable {
    enum Kind: Equatable {
        case missing
        case link(String)
        case file(Data, isExecutable: Bool)
        case unreadable
    }

    let kind: Kind

    init(at url: URL) {
        // `lstat`, so a link is read as the link rather than what it names.
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            kind = errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            kind = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map(Kind.link) ?? .unreadable
        case S_IFREG:
            let isExecutable = info.st_mode & S_IXUSR != 0
            kind = (try? Data(contentsOf: url)).map { .file($0, isExecutable: isExecutable) } ?? .unreadable
        default:
            kind = .unreadable
        }
    }

    /// Two that could not be read are not the same.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.kind, rhs.kind) {
        case (.unreadable, _), (_, .unreadable): false
        default: lhs.kind == rhs.kind
        }
    }
}
