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

    @Test(arguments: ["gone.txt", "a/b/c/gone.txt"])
    func aMissingFile_selectsItsNearestExistingFolder(relativePath: String) throws {
        try withTempDir { dir in
            let nearest = dir.appendingPathComponent("nearest", isDirectory: true)
            try FileManager.default.createDirectory(at: nearest, withIntermediateDirectories: false)
            let file = nearest.appendingPathComponent(relativePath)

            let target = FinderReveal.target(for: file, exists: FinderReveal.itemExists(atPath:))

            #expect(target?.path == nearest.standardizedFileURL.path)
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

    @Test(arguments: ["/elsewhere/a.swift", "/repo-other/a.swift"])
    func withinARoot_aPathOutsideIt_selectsNothing(path: String) {
        let target = FinderReveal.target(
            for: URL(fileURLWithPath: path),
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
            let alsoPresent = dir.appendingPathComponent("also-present.json")
            try Data().write(to: alsoPresent)

            let targets = FinderReveal.targets(for: [present, gone, alsoPresent], exists: FinderReveal.itemExists(atPath:))

            #expect(targets == [present, alsoPresent])
        }
    }

    /// Moved out by hand, as the saving notice asks: their folder instead.
    @Test func severalFiles_noneThere_selectTheFirstOnesFolder() throws {
        try withTempDir { dir in
            let firstFolder = dir.appendingPathComponent("first")
            let secondFolder = dir.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: false)
            let first = firstFolder.appendingPathComponent("one.json")
            let second = secondFolder.appendingPathComponent("two.json")

            let targets = FinderReveal.targets(for: [first, second], exists: FinderReveal.itemExists(atPath:))

            #expect(targets.map(\.path) == [firstFolder.standardizedFileURL.path])
        }
    }

    @Test func noFiles_selectNothing() {
        #expect(FinderReveal.targets(for: [], exists: { _ in true }).isEmpty)
    }
}
