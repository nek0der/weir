// RepoFixture.swift
// Weir — locates the source checkout the test bundle was built from.

import Foundation

/// Anchors smoke-test discovery to the source tree the test bundle was
/// compiled from, independently of the runner's working directory.
enum RepoFixture {
    /// Walks up from this file to find a `.git` directory or a linked
    /// worktree's `.git` file. Returns nil if no marker is present.
    static let weirRoot: URL? = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url
            }
        }
        return nil
    }()

    /// True when the source checkout has a Git marker.
    static var hasLocalRepo: Bool {
        weirRoot != nil
    }
}
