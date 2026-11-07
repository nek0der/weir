// PersistedReadTests.swift
// Weir — pins which failed reads count as an absent file and which as an unreadable one.

import Foundation
import Testing
@testable import Weir

struct PersistedReadTests {
    @Test func read_missingFile_isAbsent() throws {
        try withTempDir { dir in
            let read = PersistedRead.read(dir.appendingPathComponent("state.json"))
            #expect(read.isAbsent)
            #expect(read.data == nil)
        }
    }

    @Test func read_readableFile_returnsItsBytes() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            try Data("{}".utf8).write(to: file)
            let read = PersistedRead.read(file)
            #expect(read.data == Data("{}".utf8))
            #expect(!read.isAbsent)
        }
    }

    @Test(.disabled(if: geteuid() == 0, "root reads files without read permission"))
    func read_fileWithoutReadPermission_isUnreadable() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("state.json")
            try Data("{}".utf8).write(to: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

            guard case .unreadable = PersistedRead.read(file) else {
                Issue.record("a file that is there but cannot be read is not absent")
                return
            }
        }
    }

    /// The case an existence check gets wrong: a folder that cannot be
    /// searched hides a file that is there.
    @Test(.disabled(if: geteuid() == 0, "root can search folders without search permission"))
    func read_fileInAFolderThatCannotBeSearched_isUnreadable() throws {
        try withTempDir { dir in
            let folder = dir.appendingPathComponent("Weir")
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("state.json")
            try Data("{}".utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

            try #require(!manager.fileExists(atPath: file.path), "the check this read replaces answers no here")
            guard case .unreadable = PersistedRead.read(file) else {
                Issue.record("a file hidden by its folder's permissions is not absent")
                return
            }
        }
    }
}
