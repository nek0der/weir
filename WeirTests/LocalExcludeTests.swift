// LocalExcludeTests.swift
// Weir — the block Weir adds to a repository's `.git/info/exclude`, and the rules already there.

import Foundation
import Testing
@testable import Weir

@Suite("Local exclude file")
@MainActor
struct LocalExcludeTests {
    /// The repository's `.git/info/exclude` holds the person's own ignore
    /// rules. One that is not UTF-8 is left as it is rather than replaced
    /// by Weir's block alone.
    @Test func anExcludeFileThatIsNotUTF8_isLeftAsItIs() throws {
        try withTempDir { root in
            let info = root.appendingPathComponent(".git/info")
            try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
            let exclude = info.appendingPathComponent("exclude")
            let latin1 = Data([0x2F, 0x63, 0x61, 0x66, 0xE9, 0x0A]) // "/caf\u{E9}" in Latin-1
            try latin1.write(to: exclude)

            ensureLocalExcludeCoversWorktreesDir(repoRoot: root)

            #expect(try Data(contentsOf: exclude) == latin1)
        }
    }

    /// One that cannot be read is left as it is too.
    @Test func anExcludeFileThatCannotBeRead_isLeftAsItIs() throws {
        try withTempDir { root in
            let info = root.appendingPathComponent(".git/info")
            let manager = FileManager.default
            try manager.createDirectory(at: info, withIntermediateDirectories: true)
            let exclude = info.appendingPathComponent("exclude")
            let rules = Data("/build/\n".utf8)
            try rules.write(to: exclude)
            try manager.setAttributes([.posixPermissions: 0o200], ofItemAtPath: exclude.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exclude.path) }

            ensureLocalExcludeCoversWorktreesDir(repoRoot: root)

            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exclude.path)
            #expect(try Data(contentsOf: exclude) == rules)
        }
    }

    /// A readable file keeps its rules and gains the block; a missing one
    /// is made with the block alone.
    @Test func aReadableOrMissingExcludeFile_gainsTheBlock() throws {
        try withTempDir { root in
            let info = root.appendingPathComponent(".git/info")
            try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
            let exclude = info.appendingPathComponent("exclude")
            let block = "# >>> weir worktrees >>>\n/.worktrees/\n# <<< weir worktrees <<<\n"
            ensureLocalExcludeCoversWorktreesDir(repoRoot: root)
            #expect(try String(contentsOf: exclude, encoding: .utf8) == block)

            try "/build/".write(to: exclude, atomically: true, encoding: .utf8)
            ensureLocalExcludeCoversWorktreesDir(repoRoot: root)
            #expect(try String(contentsOf: exclude, encoding: .utf8) == "/build/\n" + block)

            ensureLocalExcludeCoversWorktreesDir(repoRoot: root)
            #expect(try String(contentsOf: exclude, encoding: .utf8) == "/build/\n" + block)
        }
    }
}
