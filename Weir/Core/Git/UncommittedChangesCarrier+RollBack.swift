// UncommittedChangesCarrier+RollBack.swift
// Weir — puts a new worktree back at its start after the carry's write or its check fails, touching only what the carry wrote.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("git.carry")

extension UncommittedChangesCarrier {
    /// Puts the new worktree back at its start where the placement wrote,
    /// and nowhere else, after a `read-tree` that failed or a placement
    /// that failed its checks; `false` when not all of it could be, so
    /// some of the changes may be left there. A reset of the whole worktree
    /// would also take back what anything else wrote there meanwhile, as a
    /// hook's job still running does, and that is not ours to undo.
    ///
    /// An index entry goes back to the start's only where it is still the
    /// placement's, which touches no file. A file goes back only where it
    /// is ours (`ownPaths`): Git's exit does not tell a refusal, which wrote
    /// nothing, from a write stopped part way, and a hook may write the
    /// same paths meanwhile. Every other path is left as it is; a file of
    /// ours Git cut short stays too, which loses nothing, since the source
    /// keeps the changes. The files go back even when the index could not
    /// (another Git holding its lock), as they need none of it.
    /// `sharedEntries` are the start's files that a path the write adds
    /// also named before Git wrote, as a case-only rename's new name names
    /// the old file on a case-insensitive volume.
    static func rollBack(
        _ placement: Placement,
        in target: URL,
        madeFolders: Set<String>,
        sharedEntries: [SharedEntry]
    ) async -> Bool {
        let written: [String]
        let carried: Set<String>
        do {
            (written, carried) = try await carriedPaths(of: placement, in: target)
        } catch {
            log.error("carry: what the new worktree holds could not be read: \(String(describing: error), privacy: .private)")
            return false
        }
        guard !carried.isEmpty else { return true }
        var isPutBack = true
        do {
            let staged = try await ownIndexEntries(of: placement, among: carried, in: target)
            if !staged.isEmpty {
                try await withPathList(staged) { list in
                    try await output(
                        ["reset", "-q", "--pathspec-from-file=\(list)", "--pathspec-file-nul"],
                        in: target,
                        environment: literalPaths
                    )
                }
            }
        } catch {
            log.error("carry: the new worktree's index could not be put back: \(String(describing: error), privacy: .private)")
            isPutBack = false
        }
        do {
            let added = try await Set(changedNames(from: placement.start, to: placement.fullTree, filter: "A", in: target))
            let deleted = try await Set(changedNames(from: placement.start, to: placement.fullTree, filter: "D", in: target))
            guard let ours = try await ownPaths(
                of: placement,
                written: written,
                deleted: deleted,
                sharedEntries: sharedEntries,
                in: target
            ) else {
                log.error("carry: what Git wrote in the new worktree could not be told; nothing of it is put back")
                return false
            }
            if !ours.isEmpty {
                log.info("carry: putting back \(ours.count) of \(written.count) paths in the new worktree")
                try await putBack(ours, added: added, madeFolders: madeFolders, in: target)
            }
        } catch {
            log.error("carry: the new worktree's files could not be put back: \(String(describing: error), privacy: .private)")
            isPutBack = false
        }
        return isPutBack
    }

    /// The paths among `paths` whose index entries are the placement's,
    /// which only our write put there (`read-tree -u` writes its working
    /// tree's, `isHolding` then its index's; a `read-tree` that failed
    /// writes none). An entry a hook
    /// staged meanwhile is not, and stays, as does any path with one above
    /// or below it.
    private static func ownIndexEntries(of placement: Placement, among paths: Set<String>, in target: URL) async throws -> [String] {
        let sorted = paths.sorted()
        let ancestors = Set(paths.flatMap(folders(above:)))
        var staged: [String: String] = [:]
        for batch in batches(of: sorted + ancestors.subtracting(paths).sorted()) {
            // `<mode> <object> <stage>\t<path>`
            for entry in try await output(["ls-files", "-s", "-z", "--"] + batch, in: target, environment: literalPaths, trims: false)
                .split(separator: "\0")
            {
                guard let tab = entry.firstIndex(of: "\t") else { continue }
                let meta = entry[..<tab].split(separator: " ")
                guard meta.count == 3 else { continue }
                staged[String(entry[entry.index(after: tab)...]), default: ""] += "\(meta[0]) \(meta[1]) \(meta[2]);"
            }
        }
        /// Each tree's entries for the paths asked about, as `ls-files -s`
        /// writes them.
        func entries(of tree: String) async throws -> [String: String] {
            var placed: [String: String] = [:]
            // `<mode> <type> <object>\t<path>`
            for entry in try await output(["ls-tree", "-r", "-z", "--full-tree", tree], in: target, trims: false).split(separator: "\0") {
                guard let tab = entry.firstIndex(of: "\t") else { continue }
                let path = String(entry[entry.index(after: tab)...])
                let meta = entry[..<tab].split(separator: " ")
                guard meta.count == 3, staged[path] != nil || paths.contains(path) || ancestors.contains(path) else { continue }
                placed[path] = "\(meta[0]) \(meta[2]) 0;"
            }
            return placed
        }
        // `read-tree -u` leaves the index at the placement's working tree,
        // and the check then puts its index in place, so an entry of either
        // is ours, whichever step stopped.
        let written = try await entries(of: placement.fullTree)
        let staging = try await entries(of: placement.indexTree)
        let isOurs = { (path: String) in staged[path] == written[path] || staged[path] == staging[path] }
        // `git reset` on a path takes the entries below it too (a folder a
        // hook made where the changes delete a file, with its own staged
        // file in it), and an entry above it gives way to it (a file a hook
        // staged where the changes have a folder), so each of those must be
        // ours as well.
        return sorted.filter { path in
            isOurs(path)
                && folders(above: path).allSatisfy(isOurs)
                && staged.keys.allSatisfy { !$0.hasPrefix(path + "/") || isOurs($0) }
        }
    }

    /// The folders `path` is in, outermost first: `a` and `a/b` for `a/b/c`.
    static func folders(above path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        return parts.indices.map { parts.prefix($0 + 1).joined(separator: "/") }
    }

    /// The paths among `written` that hold what only our write puts
    /// there: a file byte for byte as Git checks it out from the placement
    /// (its line-ending conversion and filters applied, its mode, a link's
    /// target), or nothing where the placement deletes one. A folder where
    /// a deleted file was is ours only when the placement adds paths in it
    /// and every file in it, ignored ones too, is one of ours. A path with
    /// anything else on disk is not ours, and neither is a path above or
    /// below it (`UncommittedCarryRules.ownPaths`); a path Git never wrote,
    /// with nothing there, is neither. Paths that named one of the start's
    /// files before Git wrote (`sharedEntries`) name that file still, while
    /// it is the same entry. `nil` when Git could not check out the
    /// placement to compare with.
    private static func ownPaths(
        of placement: Placement,
        written: [String],
        deleted: Set<String>,
        sharedEntries: [SharedEntry],
        in target: URL
    ) async throws -> [String]? {
        let files = written.filter { !deleted.contains($0) }
        let placed = try await withScratch { scratch -> Set<String>? in
            let checkedOut = scratch.appendingPathComponent("placed", isDirectory: true)
            let environment = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path]
            try await output(["read-tree", placement.fullTree], in: target, environment: environment)
            for batch in batches(of: files) {
                // Its attributes from the placement, as `read-tree` took
                // them, never from a `.gitattributes` changed on disk since.
                let result = try await run(
                    ["--attr-source=\(placement.fullTree)", "checkout-index", "--prefix=\(checkedOut.path)/", "--"] + batch,
                    in: target,
                    environment: environment
                )
                // Nothing can be told ours without it.
                guard result.succeeded else {
                    log.error("carry: checking out the placement to compare failed: \(result.stderr, privacy: .private)")
                    return nil
                }
            }
            return Set(files.filter { path in
                let now = FileBytes(at: target.appendingPathComponent(path))
                return now.kind != .missing && now == FileBytes(at: checkedOut.appendingPathComponent(path))
            })
        }
        guard let placed else { return nil }
        return UncommittedCarryRules.ownPaths(written) { path in
            let url = target.appendingPathComponent(path)
            // A link above it leads out of the worktree, where nothing is
            // ours, and a file above it is not ours to make a folder of.
            guard !hasNonFolderAbove(path, in: target) else { return .foreign }
            if let shared = sharedEntries.first(where: { $0.contains(path) }) {
                return sharedState(of: path, in: shared, deleted: deleted, placed: placed, target: target)
            }
            guard deleted.contains(path) else {
                if placed.contains(path) {
                    return .ours
                }
                return FileBytes(at: url).kind == .missing && !isFolder(url) ? .absent : .foreign
            }
            guard !hasNonFolder(at: url) else { return .foreign }
            guard isFolder(url) else { return .ours }
            let below = path + "/"
            guard files.contains(where: { $0.hasPrefix(below) }),
                  let inside = filesBelow(url),
                  inside.allSatisfy({ placed.contains(below + $0) })
            else { return .foreign }
            return .ours
        }
    }

    /// What is on disk, for the put-back, at `path`, which named one of the
    /// start's files with other paths before Git wrote. While the entry is
    /// the same one, Git did not write there: the file is the start's, and a
    /// path the write adds has nothing of its own. With nothing left there,
    /// a deleted path is ours to put back, as any deletion is. Once Git
    /// replaced the file, the entry is what Git wrote for an added path, so
    /// a deleted path that finds it is ours exactly when that added path is.
    private static func sharedState(
        of path: String,
        in shared: SharedEntry,
        deleted: Set<String>,
        placed: Set<String>,
        target: URL
    ) -> UncommittedCarryRules.WrittenPath {
        let isDeleted = { (candidate: String) in deleted.contains { $0.utf8.elementsEqual(candidate.utf8) } }
        let now = DiskEntry(at: target.appendingPathComponent(path))
        if now == shared.entry {
            return isDeleted(path) ? .foreign : .absent
        }
        guard now != nil else { return isDeleted(path) ? .ours : .absent }
        guard isDeleted(path) else { return placed.contains(path) ? .ours : .foreign }
        let isAddedPathOurs = shared.paths.contains { other in
            !isDeleted(other) && placed.contains { $0.utf8.elementsEqual(other.utf8) }
        }
        return isAddedPathOurs ? .ours : .foreign
    }

    /// The files in the folder at `url`, ignored ones and links included,
    /// as paths relative to it. A folder it cannot read is passed over:
    /// a file in it keeps the folder from being emptied, and `putBack`
    /// then leaves the path alone.
    private static func filesBelow(_ url: URL) -> [String]? {
        guard let walk = FileManager.default.enumerator(atPath: url.path) else { return nil }
        var files: [String] = []
        while let path = walk.nextObject() as? String {
            if walk.fileAttributes?[.type] as? FileAttributeType != .typeDirectory {
                files.append(path)
            }
        }
        return files
    }

    /// Our own paths in the new worktree put back to the start, whose index
    /// entries are the start's already: an added file removed, with the
    /// folders that leaves empty among `madeFolders`, those the write made
    /// (an empty folder a hook made stays), then every other file written
    /// from HEAD.
    /// A folder standing where a file goes back is not ours to remove, and
    /// that path stays as it is.
    private static func putBack(_ ours: [String], added: Set<String>, madeFolders: Set<String>, in target: URL) async throws {
        var emptied: Set<String> = []
        for path in ours where added.contains(path) {
            let url = target.appendingPathComponent(path)
            // Again just before: a folder above it a hook made a link since
            // would take the removal out of the worktree.
            guard hasNonFolder(at: url), !hasNonFolderAbove(path, in: target) else { continue }
            try FileManager.default.removeItem(at: url)
            emptied.formUnion(folders(above: path).filter(madeFolders.contains))
        }
        // Deepest first; `rmdir` removes only a folder that is empty.
        for folder in emptied.sorted(by: { $0.count > $1.count }) {
            _ = rmdir(target.appendingPathComponent(folder).path)
        }
        let restoring = ours.filter { !added.contains($0) && !isFolder(target.appendingPathComponent($0)) }
        guard !restoring.isEmpty else { return }
        try await withPathList(restoring) { list in
            try await output(
                ["restore", "--source=HEAD", "--worktree", "--pathspec-from-file=\(list)", "--pathspec-file-nul"],
                in: target,
                environment: literalPaths
            )
        }
    }

    /// `body` with `paths` written NUL-separated to a file of its own, for
    /// Git's `--pathspec-from-file`, so no command line passes what the
    /// system takes.
    private static func withPathList(_ paths: [String], _ body: (String) async throws -> Void) async throws {
        try await withScratch { scratch in
            let list = scratch.appendingPathComponent("paths")
            try Data(paths.joined(separator: "\0").utf8).write(to: list)
            try await body(list.path)
        }
    }
}
