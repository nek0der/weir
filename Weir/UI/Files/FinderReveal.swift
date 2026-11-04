// FinderReveal.swift
// Weir — the one way every "Show in Finder" selects an item.

import AppKit
import WeirDomain

/// Selects items in Finder. Every "Show in Finder" in the app comes here,
/// so an item that is gone reveals the same thing wherever it was asked
/// for: the nearest folder above it that is still there, rather than
/// nothing. The action's name and symbol are `MenuItemLabel.showInFinder`.
enum FinderReveal {
    /// Whether something is at `path`. Read with `lstat` semantics: a
    /// dangling symbolic link is an item Finder can select, where
    /// `fileExists` would say nothing is there and send us to its folder.
    nonisolated static func itemExists(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Selects `url`, or the nearest folder above it that exists.
    @MainActor
    static func select(_ url: URL) {
        guard let target = target(for: url, exists: itemExists(atPath:)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Selects `url`, or the nearest folder above it that exists, never
    /// one above `root`: a reviewed file reveals its repository, not
    /// whatever holds it. Nothing, when `root` itself is gone.
    @MainActor
    static func select(_ url: URL, within root: URL) {
        let target = target(
            for: url.resolvingSymlinksInPath(),
            within: root.standardizedFileURL.resolvingSymlinksInPath(),
            exists: itemExists(atPath:)
        )
        guard let target else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Selects every one of `urls` that is there; when none is, the
    /// nearest folder above the first of them that exists.
    @MainActor
    static func select(_ urls: [URL]) {
        let targets = targets(for: urls, exists: itemExists(atPath:))
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    /// Selects `url` itself, never a folder in its place. A terminal link
    /// to a file that can run code is shown instead of opened, and showing
    /// its folder would not say which file the link named.
    @MainActor
    static func selectExactly(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The item `select(_:)` selects for `url`: itself when it exists,
    /// else the nearest ancestor that does. `nil` only when not even `/`
    /// answers `exists`.
    nonisolated static func target(for url: URL, exists: (String) -> Bool) -> URL? {
        var candidate = url.standardizedFileURL
        while !exists(candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        return candidate
    }

    /// The item `select(_:within:)` selects: as `target(for:exists:)`, but
    /// the walk stops at `root`. `nil` when `url` is not inside `root`, or
    /// when nothing on the way up to it, `root` included, exists.
    nonisolated static func target(for url: URL, within root: URL, exists: (String) -> Bool) -> URL? {
        let rootPath = root.standardizedFileURL.path
        var candidate = url.standardizedFileURL
        while candidate.path == rootPath || RepositoryPath.isStrictDescendant(candidate.path, of: rootPath) {
            if exists(candidate.path) {
                return candidate
            }
            guard candidate.path != rootPath else { return nil }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// The items `select(_ urls:)` selects: those of `urls` that exist,
    /// or the first one's target when none does.
    nonisolated static func targets(for urls: [URL], exists: (String) -> Bool) -> [URL] {
        let present = urls.filter { exists($0.standardizedFileURL.path) }
        if !present.isEmpty {
            return present
        }
        return urls.first.flatMap { target(for: $0, exists: exists) }.map { [$0] } ?? []
    }
}
