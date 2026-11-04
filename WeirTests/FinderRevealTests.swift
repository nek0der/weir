// FinderRevealTests.swift
// Weir — what every "Show in Finder" selects, for an item there and one gone.

import Foundation
import Testing
@testable import Weir

struct FinderRevealTests {
    @Test func anExistingFile_isSelectedItself() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notes.txt")
            try Data().write(to: file)

            let target = FinderReveal.target(for: file, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == file.standardizedFileURL.path)
        }
    }

    @Test func aMissingFile_selectsItsFolder() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("gone.txt")

            let target = FinderReveal.target(for: file, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == dir.standardizedFileURL.path)
        }
    }

    /// A worktree yet to be made, or a file whose folder went with it:
    /// the nearest folder above that is still there.
    @Test func aMissingFolderChain_selectsTheNearestFolderThatExists() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a/b/c/gone.txt")

            let target = FinderReveal.target(for: file, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == dir.standardizedFileURL.path)
        }
    }

    /// A link whose target is gone is still an item Finder can select.
    @Test func aDanglingLink_isSelectedItself() throws {
        try withTempDir { dir in
            let link = dir.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: dir.appendingPathComponent("nowhere")
            )

            let target = FinderReveal.target(for: link, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == link.standardizedFileURL.path)
        }
    }

    /// A reviewed file whose folders are gone shows its repository, and
    /// never what holds the repository.
    @Test func withinARoot_theWalkStopsAtTheRoot() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("a/b/gone.swift")

            let target = FinderReveal.target(for: file, within: root, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == root.standardizedFileURL.path)
        }
    }

    @Test func withinARootThatIsGone_selectsNothing() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("repo")
            let file = root.appendingPathComponent("a.swift")

            let target = FinderReveal.target(for: file, within: root, exists: FinderReveal.itemExists(atPath:))

            #expect(target == nil)
        }
    }

    @Test func withinARoot_aFileThere_isSelectedItself() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("a.swift")
            try Data().write(to: file)

            let target = FinderReveal.target(for: file, within: dir, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == file.standardizedFileURL.path)
        }
    }

    @Test func withinARoot_aPathOutsideIt_selectsNothing() {
        let target = FinderReveal.target(
            for: URL(fileURLWithPath: "/elsewhere/a.swift"),
            within: URL(fileURLWithPath: "/repo"),
            exists: { _ in true }
        )

        #expect(target == nil)
    }

    @Test func nothingAtAll_selectsNothing() {
        let target = FinderReveal.target(for: URL(fileURLWithPath: "/a/b"), exists: { _ in false })

        #expect(target == nil)
    }

    @Test func severalFiles_selectOnlyThoseThere() throws {
        try withTempDir { dir in
            let present = dir.appendingPathComponent("present.json")
            try Data().write(to: present)
            let gone = dir.appendingPathComponent("gone.json")

            let targets = FinderReveal.targets(for: [gone, present], exists: FinderReveal.itemExists(atPath:))

            #expect(targets == [present])
        }
    }

    /// Moved out by hand, as the saving notice asks: their folder instead.
    @Test func severalFiles_noneThere_selectTheFirstOnesFolder() throws {
        try withTempDir { dir in
            let first = dir.appendingPathComponent("one.json")
            let second = dir.appendingPathComponent("two.json")

            let targets = FinderReveal.targets(for: [first, second], exists: FinderReveal.itemExists(atPath:))

            #expect(targets.map(\.path) == [dir.standardizedFileURL.path])
        }
    }

    @Test func noFiles_selectNothing() {
        #expect(FinderReveal.targets(for: [], exists: { _ in true }).isEmpty)
    }
}
