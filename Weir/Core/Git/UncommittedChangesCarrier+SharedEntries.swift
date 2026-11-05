// UncommittedChangesCarrier+SharedEntries.swift
// Weir — tells which of the carry's paths name one entry on disk, as a case-only rename's old and new names do.

import Foundation
import WeirDomain

/// One entry on disk, identified by its device and inode, links not
/// followed.
struct DiskEntry: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// Creates the identity of the entry at `url`, or returns `nil` when
    /// nothing is there or it cannot be looked at.
    init?(at url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Paths that named one entry on disk, and that entry when they were
/// looked up.
struct SharedEntry: Equatable, Sendable {
    let paths: [String]
    let entry: DiskEntry

    /// Whether `path` is one of the paths, compared byte for byte: Swift
    /// takes two spellings that differ only in Unicode normalization as
    /// equal, while Git and the carry keep them apart.
    func contains(_ path: String) -> Bool {
        paths.contains { $0.utf8.elementsEqual(path.utf8) }
    }

    /// Whether the entry the paths name in the folder at `root` is still
    /// the one they shared. Git replaces a file it writes with a new entry.
    func isUnchanged(in root: URL) -> Bool {
        paths.allSatisfy { DiskEntry(at: root.appendingPathComponent($0)) == entry }
    }
}

extension UncommittedChangesCarrier {
    /// Returns whether the volume holding `root` ignores case. When it cannot
    /// be told, the answer is `true`, which only adds lookups that the disk
    /// then settles.
    static func foldsCase(at root: URL) -> Bool {
        let isCaseSensitive = try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        return isCaseSensitive != true
    }

    /// Returns the groups of `paths` that name one entry in the folder at
    /// `root`. A case-only rename's old and new names do on a
    /// case-insensitive volume, and so do two names that differ only in
    /// Unicode normalization. We look up only the paths that
    /// `UncommittedCarryRules.possiblySharedPaths` puts together, so a
    /// change with no such pair reads nothing on disk.
    static func sharedEntries(among paths: [String], in root: URL) -> [SharedEntry] {
        UncommittedCarryRules.possiblySharedPaths(paths, foldsCase: foldsCase(at: root)).flatMap { group in
            var byEntry: [DiskEntry: [String]] = [:]
            for path in group {
                if let entry = DiskEntry(at: root.appendingPathComponent(path)) {
                    byEntry[entry, default: []].append(path)
                }
            }
            return byEntry.filter { $0.value.count > 1 }.map { SharedEntry(paths: $0.value, entry: $0.key) }
        }
    }

    /// Returns `path` spelled as the names on disk are, as far as they
    /// exist. On a case-insensitive volume, `a/b` also finds `A/b`, and the
    /// disk keeps the spelling each name was created with. The part of
    /// `path` below the first missing name comes back unchanged.
    static func spellingOnDisk(_ path: String, in root: URL) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var spelled: [String] = []
        for part in parts {
            // The name key describes the entry itself and does not follow a link.
            let url = root.appendingPathComponent((spelled + [part]).joined(separator: "/"))
            guard let name = try? url.resourceValues(forKeys: [.nameKey]).name else {
                return (spelled + parts.dropFirst(spelled.count)).joined(separator: "/")
            }
            spelled.append(name)
        }
        return spelled.joined(separator: "/")
    }
}
