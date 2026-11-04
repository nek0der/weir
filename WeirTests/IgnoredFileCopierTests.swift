// IgnoredFileCopierTests.swift
// Weir — copying ignored files into a new worktree: folders, links, never over a file or out of a folder, the limit.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct IgnoredFileCopierTests {
    /// The project's folder and the new worktree's, side by side in `dir`.
    private static func folders(in dir: URL) throws -> (source: URL, worktree: URL) {
        let source = dir.appendingPathComponent("project")
        let worktree = dir.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        return (source, worktree)
    }

    /// Called from the main actor, the copy still runs off it: the
    /// copier's own precondition stops a debug build otherwise.
    @Test func filesAndFolders_areCopied_offTheMainActor() async throws {
        try await withTempDir { dir in
            let (source, worktree) = try Self.folders(in: dir)
            try ScratchFile.write("KEY=1", to: ".env", in: source)
            try ScratchFile.write("module", to: "node_modules/a/index.js", in: source)
            let report = await IgnoredFileCopier.copy([".env", "node_modules", "missing.key"], from: source, to: worktree)
            #expect(report.copied == [".env", "node_modules"])
            #expect(report.failed.isEmpty)
            #expect(try ScratchFile.read(".env", in: worktree) == "KEY=1")
            #expect(try ScratchFile.read("node_modules/a/index.js", in: worktree) == "module")
        }
    }

    @Test func aFileTheWorktreeHas_isNeverWrittenOver() async throws {
        try await withTempDir { dir in
            let (source, worktree) = try Self.folders(in: dir)
            try ScratchFile.write("main", to: ".env", in: source)
            try ScratchFile.write("mine", to: ".env", in: worktree)
            let report = await IgnoredFileCopier.copy([".env"], from: source, to: worktree)
            #expect(report.kept == [".env"])
            #expect(try ScratchFile.read(".env", in: worktree) == "mine")
        }
    }

    @Test func aLink_isCopiedAsTheLink() async throws {
        try await withTempDir { dir in
            let (source, worktree) = try Self.folders(in: dir)
            try ScratchFile.write("shared", to: "shared.env", in: dir)
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent(".env").path,
                withDestinationPath: "../shared.env"
            )
            let report = await IgnoredFileCopier.copy([".env"], from: source, to: worktree)
            #expect(report.copied == [".env"])
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent(".env").path)
            #expect(link == "../shared.env")
        }
    }

    /// A folder on the way that is a link out of the project is not read
    /// through, nor one in the worktree written through.
    @Test func aPathThroughALinkOutOfEitherFolder_isNotCopied() async throws {
        try await withTempDir { dir in
            let (source, worktree) = try Self.folders(in: dir)
            let outside = dir.appendingPathComponent("outside")
            try ScratchFile.write("secret", to: "key", in: outside)
            try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("config"), withDestinationURL: outside)
            let read = await IgnoredFileCopier.copy(["config/key"], from: source, to: worktree)
            #expect(read.failed == ["config/key"])
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("config/key").path))

            try ScratchFile.write("x", to: "certs/a.pem", in: source)
            try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent("certs"), withDestinationURL: outside)
            let written = await IgnoredFileCopier.copy(["certs/a.pem"], from: source, to: worktree)
            #expect(written.failed == ["certs/a.pem"])
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("a.pem").path))

            // Two folders down the link: no folder is made out there either.
            try ScratchFile.write("y", to: "certs/sub/b.pem", in: source)
            let deeper = await IgnoredFileCopier.copy(["certs/sub/b.pem"], from: source, to: worktree)
            #expect(deeper.failed == ["certs/sub/b.pem"])
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("sub").path))
        }
    }

    /// One path too big is left out; the small ones after it still go.
    @Test func aPathOverTheLimit_isLeftOut_andTheRestStillGo() async throws {
        try await withTempDir { dir in
            let (source, worktree) = try Self.folders(in: dir)
            try ScratchFile.write("small", to: ".env", in: source)
            try ScratchFile.write(String(repeating: "x", count: 100), to: "big/blob", in: source)
            try ScratchFile.write("later", to: "z.key", in: source)
            let report = await IgnoredFileCopier.copy([".env", "big", "z.key"], from: source, to: worktree, byteLimit: 50)
            #expect(report.copied == [".env", "z.key"])
            #expect(report.overLimit == ["big"])
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("big").path))
            #expect(try ScratchFile.read("z.key", in: worktree) == "later")
        }
    }

    /// A canceled copy copies nothing more, and a worktree gone meanwhile
    /// is not made again.
    @Test func aCanceledCopy_orAWorktreeGone_copiesNothing() async throws {
        try await withTempDir { dir in
            let (source, worktree) = try Self.folders(in: dir)
            try ScratchFile.write("KEY=1", to: ".env", in: source)
            let task = Task.detached {
                // Waits for the cancel below before it starts.
                while !Task.isCancelled {
                    await Task.yield()
                }
                return await IgnoredFileCopier.copy([".env"], from: source, to: worktree)
            }
            task.cancel()
            let canceled = await task.value
            #expect(canceled.isCanceled)
            #expect(canceled.copied.isEmpty)

            try FileManager.default.removeItem(at: worktree)
            let gone = await IgnoredFileCopier.copy([".env"], from: source, to: worktree)
            #expect(gone.isDestinationGone)
            #expect(!FileManager.default.fileExists(atPath: worktree.path))
        }
    }
}
