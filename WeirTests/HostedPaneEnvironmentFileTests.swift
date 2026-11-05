// HostedPaneEnvironmentFileTests.swift
// Weir — a saved pane environment whose tmux session never read it is removed at launch.

import Foundation
import Testing
@testable import Weir

struct HostedPaneEnvironmentFileTests {
    /// The file holds the person's secrets, so one a session never read goes
    /// once it is past a launch still under way; a fresh one may be about to
    /// be read, and nothing that is not the shim's file is touched.
    @Test func removeOrphans_removesOnlyStaleSavedEnvironments() throws {
        try withTempDir { dir in
            let fm = FileManager.default
            func file(_ name: String, age: TimeInterval) throws -> URL {
                let url = dir.appendingPathComponent(name)
                fm.createFile(atPath: url.path, contents: Data("export SECRET='hunter2'\n".utf8))
                try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
                return url
            }
            let stale = 2 * HostedPaneEnvironmentFile.staleAfter
            let leftBehind = try file("weir-hosted-env.AAAAAAAAAAAA", age: stale)
            let beingRead = try file("weir-hosted-env.BBBBBBBBBBBB", age: 0)
            let someoneElses = try file("other-tool.CCCCCCCCCCCC", age: stale)
            // A link with the shim's name is no file the shim wrote, however
            // old. `setAttributes` would age what it points to, so the link
            // itself is aged with `lutimes`.
            let link = dir.appendingPathComponent("weir-hosted-env.DDDDDDDDDDDD")
            try fm.createSymbolicLink(at: link, withDestinationURL: someoneElses)
            let then = timeval(tv_sec: time(nil) - Int(stale), tv_usec: 0)
            var times = [then, then]
            #expect(lutimes(link.path, &times) == 0)

            HostedPaneEnvironmentFile.removeOrphans(in: [dir])

            #expect(!fm.fileExists(atPath: leftBehind.path))
            #expect(fm.fileExists(atPath: beingRead.path))
            #expect(fm.fileExists(atPath: someoneElses.path))
            #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
        }
    }

    /// The folders the shim writes to: TMPDIR as a pane inherits it, and the
    /// one macOS keeps for this user, each once.
    @Test func defaultDirectories_holdTheUsersTemporaryFolderOnce() {
        let directories = HostedPaneEnvironmentFile.defaultDirectories.map(\.path)
        #expect(!directories.isEmpty)
        #expect(Set(directories).count == directories.count)
    }
}
