// ReviewFileAction.swift
// Weir — resolves reviewed worktree paths for actions outside the app.

import Foundation
import WeirDomain

/// The boundary between Review's Git-relative paths and macOS file actions.
/// Opening goes through `FileOpener`, shared with terminal links, and the UI
/// shows a file in Finder itself.
enum ReviewFileAction {
    /// Resolves a Git-relative or absolute file path only when its canonical
    /// location remains under the canonical repository root. Resolving both
    /// sides closes the parent-symlink escape that lexical prefix checks miss.
    static func fileURL(for path: String, in repositoryRoot: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let candidate = if path.hasPrefix("/") {
            URL(fileURLWithPath: path)
        } else {
            repositoryRoot.appendingPathComponent(path)
        }

        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard RepositoryPath.isStrictDescendant(resolved.path, of: root.path) else { return nil }
        return resolved
    }
}
