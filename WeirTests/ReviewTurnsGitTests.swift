// ReviewTurnsGitTests.swift
// Weir — a fixed range of turns read from Git, and the changes made outside every turn.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Review turns in Git", .tags(.smoke))
struct ReviewTurnsGitTests {
    /// Writes the files, stages everything, and answers the tree.
    private static func snapshot(_ files: [String: String], in repo: TempGitRepo) async throws -> String {
        for (path, text) in files {
            try repo.write(text, to: path)
        }
        try await repo.git(["add", "-A"])
        return try await repo.git(["write-tree"])
    }

    private static func turn(
        _ number: Int,
        begin: String,
        end: String?,
        root: URL,
        phase: String = "finished"
    ) throws -> TurnSummary {
        try TurnSummaryFixture.turn(
            "T\(number)",
            phase: phase,
            changes: TurnSummaryFixture.changedFiles,
            number: number,
            endTree: end.map { SnapshotTree(tree: $0, root: root.path) },
            extras: .init(beginTree: SnapshotTree(tree: begin, root: root.path))
        )
    }

    @Test func aRange_comparesItsTwoTrees_howeverTheWorktreeMovesOn() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let begin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let end = try await Self.snapshot(["a.swift": "one\ntwo\n"], in: repo)
        let range = try #require(try ReviewTurnRange(turns: [Self.turn(1, begin: begin, end: end, root: repo.url)]))
        let scope = ReviewScope.turns(range)

        // Later work, which the range does not show.
        try repo.write("one\ntwo\nthree\n", to: "a.swift")
        try repo.write("new\n", to: "b.swift")

        let files = try await ReviewGit.files(at: repo.url, scope: scope)
        #expect(files == [ReviewFile(path: "a.swift", layer: .turns, status: .modified)])
        let file = try #require(files.first)
        let diff = try await ReviewGit.diff(file, root: repo.url, scope: scope)
        #expect(diff.lines.contains { $0.kind == .added && $0.text == "two" })
        #expect(!diff.lines.contains { $0.text == "three" })
        #expect(await ReviewGit.source(file, root: repo.url, scope: scope) == ["one", "two"])
        #expect(try await ReviewGit.stats(at: repo.url, scope: scope)[file.id] == ReviewFileStat(added: 1, removed: 0))
        #expect(try await !ReviewGit.hasChanges(at: repo.url, scope: scope, comparedTo: files, currentDiff: diff))
    }

    /// What changed outside every turn, counted as the changes panel and
    /// the review tab count it.
    @MainActor
    private static func outsideTurns(_ turns: [TurnSummary], in repo: TempGitRepo) async -> Set<String> {
        let owner = WorktreeChanges(git: .live)
        await owner.refresh(root: repo.url, turns: turns)
        return owner.outsideTurns[repo.url.path] ?? []
    }

    @MainActor
    @Test func changesBetweenTurnsAndAfterTheLast_areOutsideTurns() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let firstBegin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let firstEnd = try await Self.snapshot(["a.swift": "one\ntwo\n"], in: repo)
        // A person's edit while no agent worked.
        let secondBegin = try await Self.snapshot(["b.swift": "by hand\n"], in: repo)
        let secondEnd = try await Self.snapshot(["a.swift": "one\ntwo\nthree\n"], in: repo)
        let turns = try [
            Self.turn(1, begin: firstBegin, end: firstEnd, root: repo.url),
            Self.turn(2, begin: secondBegin, end: secondEnd, root: repo.url)
        ]
        // And one after the last turn ended.
        try repo.write("later\n", to: "c.swift")

        let outside = await Self.outsideTurns(turns, in: repo)

        #expect(outside == ["b.swift", "c.swift"])
    }

    @Test func aRangeWhoseSnapshotIsGone_saysItsRecordIsIncomplete() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let begin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let range = try #require(try ReviewTurnRange(turns: [Self.turn(
            1,
            begin: begin,
            end: TurnSummaryFixture.tree("e", 1),
            root: repo.url
        )]))

        do {
            _ = try await ReviewGit.files(at: repo.url, scope: .turns(range))
            Issue.record("a range with a missing end was read")
        } catch ReviewError.rangeSnapshotsMissing {
            // Expected: the record is incomplete.
        }
    }

    @Test func aRangeOfAnotherWorkTree_isRefused() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let begin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let end = try await Self.snapshot(["a.swift": "two\n"], in: repo)
        let elsewhere = URL(fileURLWithPath: "/tmp/weir-elsewhere-\(UUID().uuidString)")
        let range = try #require(try ReviewTurnRange(turns: [Self.turn(1, begin: begin, end: end, root: elsewhere)]))

        do {
            _ = try await ReviewGit.files(at: repo.url, scope: .turns(range))
            Issue.record("another work tree's range was read here")
        } catch ReviewError.rangeInAnotherWorktree {
            // Expected.
        }
    }

    @MainActor
    @Test func whileATurnRuns_onlyTheGapBeforeItIsOutsideTurns() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let firstBegin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let firstEnd = try await Self.snapshot(["a.swift": "one\ntwo\n"], in: repo)
        let runningBegin = try await Self.snapshot(["b.swift": "by hand\n"], in: repo)
        // The agent of the running turn writes this.
        try repo.write("agent\n", to: "c.swift")
        let turns = try [
            Self.turn(1, begin: firstBegin, end: firstEnd, root: repo.url),
            Self.turn(2, begin: runningBegin, end: nil, root: repo.url, phase: "started")
        ]

        let outside = await Self.outsideTurns(turns, in: repo)
        #expect(outside == ["b.swift"])
    }

    @MainActor
    @Test(arguments: [true, false])
    func aGapWithAMissingSnapshot_isUnknown_notAFailure(_ hasLatestEnd: Bool) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let begin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        // A missing begin leaves the gap unknown. A surviving end can still
        // anchor the changes made afterward.
        let missing = TurnSummaryFixture.tree("b", 2)
        await #expect(throws: TempGitRepo.GitFailure.self) { try await repo.git(["cat-file", "-e", missing + "^{tree}"]) }
        let latestEnd = hasLatestEnd ? begin : TurnSummaryFixture.tree("e", 2)
        let turns = try [
            Self.turn(1, begin: begin, end: begin, root: repo.url),
            Self.turn(2, begin: missing, end: latestEnd, root: repo.url)
        ]
        try repo.write("after both turns\n", to: "outside.swift")

        let owner = WorktreeChanges(git: .live)
        await owner.refresh(root: repo.url, turns: turns)

        let expected: Set<String> = hasLatestEnd ? ["outside.swift"] : []
        #expect(owner.outsideTurns[repo.url.path] == expected)
        #expect(owner.incompleteOutsideTurns.contains(repo.url.path), "a.swift is uncommitted and may be in the gap")
    }

    @MainActor
    @Test func aChangeBetweenTurnsSinceCommitted_isNotOutsideTurns() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let firstBegin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let firstEnd = try await Self.snapshot(["a.swift": "one\ntwo\n"], in: repo)
        let secondBegin = try await Self.snapshot(["b.swift": "by hand\n"], in: repo)
        let secondEnd = try await Self.snapshot(["a.swift": "one\ntwo\nthree\n"], in: repo)
        let turns = try [
            Self.turn(1, begin: firstBegin, end: firstEnd, root: repo.url),
            Self.turn(2, begin: secondBegin, end: secondEnd, root: repo.url)
        ]
        // The person commits the work, then edits once more.
        try await repo.git(["commit", "-q", "-m", "work"])
        try repo.write("later\n", to: "c.swift")

        let outside = await Self.outsideTurns(turns, in: repo)
        #expect(outside == ["c.swift"], "history is not something to look at before a pull request")
    }

    @MainActor
    @Test func anUntrackedFileTheLastTurnLeft_countsOnlyOnceEdited_andNothingIsWritten() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let begin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        // The hook's snapshot takes untracked files in.
        // Links, which `hash-object` would follow: one to a file, one to a
        // directory.
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: repo.url.appendingPathComponent("link.txt").path,
            withDestinationPath: "kept.txt"
        )
        try FileManager.default.createSymbolicLink(atPath: repo.url.appendingPathComponent("docs-link").path, withDestinationPath: "docs")
        let end = try await Self.snapshot([
            "a.swift": "one\ntwo\n",
            "kept.txt": "same\n",
            "edited.txt": "old\n",
            "docs/guide.txt": "guide\n"
        ], in: repo)
        try await repo.git(["rm", "-q", "--cached", "kept.txt", "edited.txt", "link.txt", "docs-link"])
        try repo.write("new\n", to: "edited.txt")
        let turns = try [Self.turn(1, begin: begin, end: end, root: repo.url)]
        let objects = try await repo.git(["count-objects"])

        let outside = await Self.outsideTurns(turns, in: repo)

        #expect(outside == ["edited.txt"])
        #expect(try await repo.git(["count-objects"]) == objects, "a count every few seconds writes no objects")
    }

    /// An untracked file untouched since the last count is not hashed again:
    /// what it hashed to then is handed back with its stat, and holds while
    /// the stat does.
    @Test func anUntrackedFileUntouched_keepsItsHash_untilItIsTouched() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let tree = try await Self.snapshot(["a.swift": "one\n", "kept.txt": "same\n"], in: repo)
        try await repo.git(["rm", "-q", "--cached", "kept.txt"])

        let first = try await ReviewGit.pathsChanged(since: tree, at: repo.url)
        #expect(first.paths.isEmpty)
        let held = try #require(first.untrackedHashes["kept.txt"])

        // A hash it could not have had: taken as given, so not hashed again.
        let other = ReviewGit.ContentFingerprint(contents: String(repeating: "0", count: 40), stat: held.stat)
        let kept = try await ReviewGit.pathsChanged(since: tree, at: repo.url, known: ["kept.txt": other])
        #expect(kept.paths == ["kept.txt"])
        #expect(kept.untrackedHashes["kept.txt"] == other)

        // Touched: hashed again, and the same contents as the tree held.
        let path = repo.url.appendingPathComponent("kept.txt").path
        let oldTime = try #require(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: oldTime.addingTimeInterval(-60)], ofItemAtPath: path)
        let newTime = try #require(FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        try #require(newTime != oldTime)
        let touched = try await ReviewGit.pathsChanged(since: tree, at: repo.url, known: ["kept.txt": other])
        let rehashed = try #require(touched.untrackedHashes["kept.txt"])
        #expect(touched.paths.isEmpty)
        #expect(rehashed.contents == held.contents)
        #expect(rehashed.stat != held.stat)
    }

    @Test func anUntrackedFileTheLastTurnLeft_madeExecutable_countsAsChanged() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let begin = try await Self.snapshot(["a.swift": "one\n"], in: repo)
        let end = try await Self.snapshot(["a.swift": "one\n", "script.sh": "echo hi\n"], in: repo)
        try await repo.git(["rm", "-q", "--cached", "script.sh"])
        let turns = try [Self.turn(1, begin: begin, end: end, root: repo.url)]
        #expect(await Self.outsideTurns(turns, in: repo).isEmpty)

        // Its contents as the turn left them, its mode not: git's diff shows it.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.url.appendingPathComponent("script.sh").path)

        #expect(await Self.outsideTurns(turns, in: repo) == ["script.sh"])
    }

    @Test func contentFingerprints_differWithTheContents_andWriteNothing() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("one\n", to: "a.txt")
        try FileManager.default.createSymbolicLink(atPath: repo.url.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        let objects = try await repo.git(["count-objects"])

        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let paths: Set = ["a.txt", "link", "gone.txt", "sub"]
        let before = try await ReviewGit.contentFingerprints(of: paths, at: repo.url)
        try repo.write("two\n", to: "a.txt")
        let after = try await ReviewGit.contentFingerprints(of: paths, at: repo.url)

        #expect(before["a.txt"]?.contents != after["a.txt"]?.contents)
        #expect(after["link"]?.contents == "link:a.txt", "a link is its target, not what it points at")
        #expect(after["gone.txt"]?.contents == "gone")
        #expect(after["sub"]?.contents == "other")
        #expect(try await repo.git(["count-objects"]) == objects)

        // A file whose size, time, and inode match keeps what was known.
        let known = try #require(after["a.txt"])
        let kept = try await ReviewGit.contentFingerprints(
            of: ["a.txt"],
            at: repo.url,
            known: ["a.txt": ReviewGit.ContentFingerprint(contents: "blob:known", stat: known.stat)]
        )
        #expect(kept["a.txt"]?.contents == "blob:known")

        // Made executable with the same contents: what was viewed is not
        // what the diff shows now (chmod changes the time, so it is read
        // again).
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.url.appendingPathComponent("a.txt").path)
        let executable = try await ReviewGit.contentFingerprints(of: ["a.txt"], at: repo.url, known: ["a.txt": known])
        #expect(executable["a.txt"]?.contents == known.contents + ":executable")
        // Back again: the mark viewed before matches once more.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo.url.appendingPathComponent("a.txt").path)
        let plain = try await ReviewGit.contentFingerprints(of: ["a.txt"], at: repo.url, known: ["a.txt": executable["a.txt"] ?? known])
        #expect(plain["a.txt"]?.contents == known.contents)
    }
}
