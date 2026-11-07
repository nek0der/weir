// ReviewGitNameTests.swift
// Weir — names that are not UTF-8, modes read from their own lines, and line endings, in a real repository.

import Foundation
import Testing
@testable import Weir

struct ReviewGitNameTests {
    /// `résumé.txt` in Latin-1. APFS will not hold a name that is not UTF-8,
    /// so it goes straight into the index, the way a checkout on another file
    /// system would have put it there.
    private static let latin1Name = Data("r".utf8) + Data([0xE9]) + Data("sum".utf8) + Data([0xE9]) + Data(".txt".utf8)

    @Test func aNameThatIsNotUTF8_isListedAndRefused_whileTheRestStayReviewable() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let root = try await ReviewGit.root(at: repo.url)
        try "plain\n".write(to: root.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        try await repo.git(["add", "--", "plain.txt"])
        let blob = try await ReviewGit.command(["hash-object", "-w", "--stdin"], root: root, input: Data("text\n".utf8))
        let id = try #require(String(data: blob, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await ReviewGit.command(
            ["update-index", "-z", "--index-info"],
            root: root,
            input: Data("100644 \(id)\t".utf8) + Self.latin1Name + Data([0])
        )

        let files = try await ReviewGit.files(at: root)
        let plain = try #require(files.first { $0.path == "plain.txt" }, "One name took the whole list down")
        #expect(!plain.isNameUndecodable)
        let named = files.filter { $0.path == "r\u{FFFD}sum\u{FFFD}.txt" }
        // Staged as added, and unstaged as deleted, since no file holds it.
        try #require(named.count == 2, "The undecodable name was not listed with its likeness")
        let areAllMarked = named.allSatisfy(\.isNameUndecodable)
        #expect(areAllMarked)

        for file in named {
            let diff = try await ReviewGit.diff(file, root: root)
            #expect(diff.lines.isEmpty)
            #expect(diff.notice != nil, "An undecodable name was opened as if Git knew it")
            #expect(try await ReviewGit.fingerprint(file, root: root) == diff.fingerprint)
            #expect(await ReviewGit.source(file, root: root).isEmpty)
        }
        #expect(try await ReviewGit.diff(plain, root: root).lines.contains { $0.kind == .added })
        let stats = try await ReviewGit.stats(at: root)
        #expect(stats["staged:r\u{FFFD}sum\u{FFFD}.txt"] == ReviewFileStat(added: 1, removed: 0))

        // The changes panel's totals read the same names.
        let tree = try await repo.git(["write-tree"])
        let head = try await repo.git(["rev-parse", "HEAD^{tree}"])
        #expect(try await ReviewGit.counts(from: head, to: tree, root: root) == .changed(files: 2, added: 2, removed: 0))
        #expect(try await ReviewGit.pathsChanged(from: head, to: tree, at: root) == ["plain.txt", "r\u{FFFD}sum\u{FFFD}.txt"])
    }

    @Test func aPathEndingInAModeNumber_isStillText() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let root = try await ReviewGit.root(at: repo.url)
        let names = ["notes 120000", "pin 160000"]
        for name in names {
            try repo.write("before \(name)\n", to: name)
        }
        try await repo.git(["add", "--"] + names)
        try await repo.git(["commit", "-q", "-m", "named"])
        for name in names {
            try repo.write("after \(name)\n", to: name)
        }

        let files = try await ReviewGit.files(at: root)
        #expect(files.map(\.id) == names.map { "unstaged:\($0)" })
        for file in files {
            let diff = try await ReviewGit.diff(file, root: root)
            #expect(diff.notice == nil, "\(file.path) was refused as a symlink or a submodule")
            #expect(diff.lines.filter { $0.kind == .removed }.map(\.text) == ["before \(file.path)"])
            #expect(diff.lines.filter { $0.kind == .added }.map(\.text) == ["after \(file.path)"])
        }
    }

    @Test func aSymlink_isRefusedFromItsModeLine() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let root = try await ReviewGit.root(at: repo.url)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first")
        try await repo.git(["add", "--", "link"])
        let staged = try #require(try await ReviewGit.files(at: root).first { $0.path == "link" })
        // `new file mode 120000`.
        #expect(try await ReviewGit.diff(staged, root: root).lines.isEmpty)
        try await repo.git(["commit", "-q", "-m", "link"])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second")

        let retargeted = try #require(try await ReviewGit.files(at: root).first { $0.path == "link" })
        // `index <old>..<new> 120000`.
        let diff = try await ReviewGit.diff(retargeted, root: root)
        #expect(diff.lines.isEmpty)
        #expect(diff.notice != nil)
    }

    @MainActor
    @Test func aChangeOfLineEndingsAlone_marksTheLinesThatGainedTheReturn() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let root = try await ReviewGit.root(at: repo.url)
        let url = root.appendingPathComponent("windows.txt")
        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        try await repo.git(["add", "--", "windows.txt"])
        try await repo.git(["commit", "-q", "-m", "lf"])
        try "one\r\ntwo\r\n".write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(try await ReviewGit.files(at: root).first)
        let diff = try await ReviewGit.diff(file, root: root)
        let added = diff.lines.filter { $0.kind == .added }
        let removed = diff.lines.filter { $0.kind == .removed }
        try #require(added.count == 2 && removed.count == 2)
        // The text is the same on both sides; the flag is the only difference.
        #expect(added.map(\.text) == removed.map(\.text))
        let haveGainedTheReturn = added.allSatisfy(\.endsInCarriageReturn)
        #expect(haveGainedTheReturn && removed.allSatisfy { !$0.endsInCarriageReturn })

        let highlights = ReviewIntralineDiff.compute(ReviewIntralineDiff.pairs(for: diff.lines))
        #expect(highlights.lineEndingIDs == Set(added.map(\.id)))
        #expect(removed.allSatisfy { !highlights.marksLineEnding(of: $0.id) })
    }
}
