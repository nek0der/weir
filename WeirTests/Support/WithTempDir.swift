// WithTempDir.swift
// Weir — scratch folders a test makes, removed even when it throws, and the one way a fixture writes and reads a file in them.

import Foundation

/// Runs `body` on the caller's actor (`isolation`), so a main-actor test
/// can hand it main-actor state.
func withTempDir<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (URL) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("weir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("weir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// `withTempDir` with a short name, for a folder that holds a Unix socket:
/// `sun_path` caps a socket's path at 104 bytes, which the temporary
/// directory plus `withTempDir`'s whole UUID and a socket's name inside can
/// exceed. Eight characters of a UUID keep two runs apart all the same. The
/// folder is the owner's alone, as a socket's folder should be.
func withShortTempDir<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (URL) async throws -> T
) async throws -> T {
    let url = try makeShortTempDir()
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

func withShortTempDir<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeShortTempDir()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

/// Writing and reading a test's files by their path in a folder, the one way
/// a fixture does it: in a scratch folder, a repository (`TempGitRepo`'s own
/// `write` and `read` forward here), or a worktree beside one.
enum ScratchFile {
    /// Writes `text` to `path` in `directory`, making the folders on the way.
    static func write(_ text: String, to path: String, in directory: URL) throws {
        try write(Data(text.utf8), to: path, in: directory)
    }

    /// Writes `data` to `path` in `directory`, making the folders on the way.
    static func write(_ data: Data, to path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// What `path` in `directory` holds, as UTF-8 text. Throws when it is
    /// missing, so an expectation on it fails rather than seeing empty text.
    static func read(_ path: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8)
    }
}

private func makeShortTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}
