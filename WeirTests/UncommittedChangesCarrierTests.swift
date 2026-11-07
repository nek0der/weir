// UncommittedChangesCarrierTests.swift
// Weir — moving a worktree's uncommitted changes into a new one with real git, and that no failure loses or alters them.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite(.timeLimit(.minutes(1)))
struct UncommittedChangesCarrierTests {

    // MARK: - Fixture

    /// A repository with a few committed files of each kind (text, binary,
    /// script, symlink) and nothing uncommitted.
    static func makeRepository() async throws -> TempGitRepo {
        let repo = try await TempGitRepo.make()
        try repo.write("a\nb\nc\n", to: "a.txt")
        try repo.write("keep\n", to: "x.txt")
        try repo.write("gone\n", to: "deleted.txt")
        try repo.write(Data([0, 1, 2, 255]), to: "image.bin")
        try repo.write("#!/bin/sh\n", to: "run.sh")
        try FileManager.default.createSymbolicLink(atPath: repo.url.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-q", "-m", "files"])
        return repo
    }

    /// Every kind of change: staged, then changed again unstaged; a staged
    /// rename; a binary change; a deletion; a mode change; a symlink
    /// removed; untracked files, one in a new folder.
    private static func makeChanges(in root: URL) async throws {
        try ScratchFile.write("a\nB\nc\n", to: "a.txt", in: root)
        try await TempGitRepo.git(["add", "a.txt"], in: root)
        try ScratchFile.write("a\nB\nc\nd\n", to: "a.txt", in: root)
        try await TempGitRepo.git(["mv", "x.txt", "y.txt"], in: root)
        try ScratchFile.write(Data([0, 9, 9, 255]), to: "image.bin", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try await TempGitRepo.git(["update-index", "--chmod=+x", "run.sh"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try ScratchFile.write("new\n", to: "notes.txt", in: root)
        try ScratchFile.write("deep\n", to: "dir/inner.txt", in: root)
    }

    static func status(_ root: URL) async throws -> String {
        try await TempGitRepo.git(["status", "--porcelain=v1", "--untracked-files=all"], in: root)
    }

    /// What a worktree holds, beyond `status`: the index as a tree, and the
    /// bytes of every file `status` lists.
    static func state(_ root: URL) async throws -> [String] {
        let tree = try await TempGitRepo.git(["write-tree"], in: root)
        var state = try await [tree, status(root)]
        for path in ["a.txt", "y.txt", "image.bin", "notes.txt", "dir/inner.txt", "later.txt"] {
            let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path)
            state.append("\(path): \(data.map { Array($0).description } ?? "none")")
        }
        return state
    }

    /// A worktree beside the repository on a new branch from `start`, as
    /// the sheet makes one.
    static func addTarget(_ repo: TempGitRepo, branch: String, start: String = "HEAD") async throws -> URL {
        let target = repo.url.deletingLastPathComponent().appendingPathComponent("\(repo.url.lastPathComponent)-\(branch)")
        try await repo.git(["worktree", "add", "-q", "-b", branch, target.path, start])
        return target
    }

    static func carry(_ repo: TempGitRepo, onto start: String = "HEAD", target: URL) async throws
        -> (UncommittedChangesCarrier.Snapshot, UncommittedChangesCarrier.Outcome)
    {
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: start, repoRoot: repo.url)
        return await (snapshot, UncommittedChangesCarrier.move(snapshot, placement: placement, into: target))
    }

    // MARK: - Moving

    /// Onto the same commit, the new worktree ends up exactly as the source
    /// was, the staged and the unstaged kept apart, and the source is clean.
    @Test func everyKindOfChange_moves_stagedAndUnstagedApart_andTheSourceIsClean() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("someone else's\n", to: "a.txt")
        try await repo.git(["stash", "push", "-q", "-m", "another-session"])
        let stashes = try await repo.git(["stash", "list", "--format=%H %gs"])
        try #require(stashes.hasSuffix("On main: another-session"))
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")

        let (snapshot, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: snapshot.fileCount))
        #expect(snapshot.fileCount == 8)
        #expect(try await Self.state(target) == before)
        #expect(try await TempGitRepo.git(["ls-files", "-s", "run.sh"], in: target).hasPrefix("100755"))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("link").path))
        // The source is back at its commit: the symlink and the deleted file
        // are there again, the new folder is gone.
        #expect(try await Self.status(repo.url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("dir").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: repo.url.appendingPathComponent("link").path)) == "a.txt")
        #expect(try repo.read("deleted.txt") == "gone\n")
        #expect(try await repo.git(["stash", "list", "--format=%H %gs"]) == stashes)
    }

    /// A later start keeps its own file and its nonoverlapping edit to
    /// the carried file, in both the index and working tree.
    @Test func ontoAnotherStart_theChangesAreMergedOntoIt() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nb\nc\nd\ne\nf\ng\nh\n", to: "a.txt")
        try await repo.commit("separate lines")
        let ahead = try await Self.addTarget(repo, branch: "ahead")
        try ScratchFile.write("theirs\n", to: "other.txt", in: ahead)
        try ScratchFile.write("a\nb\nc\nd\ne\nf\ng\nTHEIRS\n", to: "a.txt", in: ahead)
        try await TempGitRepo.git(["add", "a.txt", "other.txt"], in: ahead)
        try await TempGitRepo.git(["commit", "-q", "-m", "ahead"], in: ahead)
        let start = try await TempGitRepo.git(["rev-parse", "HEAD"], in: ahead)
        try repo.write("a\nB\nc\nd\ne\nf\ng\nh\n", to: "a.txt")
        try await repo.git(["add", "a.txt"])
        try repo.write("A\nB\nc\nd\ne\nf\ng\nh\n", to: "a.txt")
        let target = try await Self.addTarget(repo, branch: "carried", start: start)

        let (_, outcome) = try await Self.carry(repo, onto: start, target: target)

        guard case .moved = outcome else {
            Issue.record("not moved: \(outcome)")
            return
        }
        #expect(try ScratchFile.read("other.txt", in: target) == "theirs\n")
        #expect(try ScratchFile.read("a.txt", in: target) == "A\nB\nc\nd\ne\nf\ng\nTHEIRS\n")
        #expect(try await TempGitRepo.git(["show", ":a.txt"], in: target) == "a\nB\nc\nd\ne\nf\ng\nTHEIRS")
        #expect(try await TempGitRepo.git(["rev-parse", "HEAD"], in: target) == start)
        #expect(try await Self.status(repo.url).isEmpty)
    }

    /// A start that changed the same lines stops the carry before anything
    /// is made, naming the file; the source is as it was.
    @Test func aConflictWithTheStart_stopsBeforeAnything_andTheSourceIsAsItWas() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let ahead = try await Self.addTarget(repo, branch: "ahead")
        try ScratchFile.write("a\nTHEIRS\nc\n", to: "a.txt", in: ahead)
        try await TempGitRepo.git(["commit", "-q", "-am", "theirs"], in: ahead)
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))

        await #expect(throws: UncommittedCarryRefusal.conflicts(["a.txt"])) {
            try await UncommittedChangesCarrier.place(snapshot, onto: "ahead", repoRoot: repo.url)
        }
        #expect(try await Self.state(repo.url) == before)
    }

    // MARK: - The source changing meanwhile

    /// A file changed after the changes were read: the new worktree's copy
    /// is not the source's any more, and the source keeps
    /// everything, the late edit included.
    @Test func aFileChangedMeanwhile_leavesTheSourceAsItIsNow() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        try repo.write("a\nB\nc\nd\nlater\n", to: "a.txt")
        let now = try await Self.state(repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target)

        // The new worktree no longer has the source's bytes, so it is put
        // back; an edit in the moment after that check stops the clearing
        // instead (`aCommitMadeWhileTheIndexIsHeld_isKept` goes that far).
        #expect(outcome == .notApplied)
        #expect(try await Self.state(repo.url) == now)
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await TempGitRepo.git(["status", "--porcelain"], in: target).isEmpty)
    }

    /// A file deleted in the changes comes back as an untracked one (an
    /// agent wrote it): taking the deletion away would overwrite it.
    @Test func anUntrackedFileWhereADeletionWas_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["rm", "-q", "deleted.txt"])
        try repo.write("new\n", to: "notes.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        try repo.write("agent wrote this\n", to: "deleted.txt")

        let before = try await Self.status(repo.url)
        try #require(before.split(separator: "\n").contains("D  deleted.txt"))
        try #require(before.split(separator: "\n").contains("?? deleted.txt"))
        let index = try Data(contentsOf: repo.url.appendingPathComponent(".git/index"))
        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .notApplied)
        #expect(try repo.read("deleted.txt") == "agent wrote this\n")
        #expect(try repo.read("notes.txt") == "new\n")
        #expect(try Data(contentsOf: repo.url.appendingPathComponent(".git/index")) == index)
        #expect(try await Self.status(repo.url) == before)
        #expect(try ScratchFile.read("deleted.txt", in: target) == "gone\n")
        #expect(try await Self.status(target).isEmpty)
    }

    /// A commit made meanwhile: going back to the old HEAD would undo it.
    @Test func aCommitMadeMeanwhile_leavesTheSourceAlone() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        try await repo.git(["commit", "-q", "-m", "meanwhile"])
        let committed = try await repo.git(["rev-parse", "HEAD"])
        let now = try await Self.state(repo.url)

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .leftInSource)
        #expect(try await Self.state(repo.url) == now)
        #expect(try await repo.git(["rev-parse", "HEAD"]) == committed)
        #expect(try await TempGitRepo.git(["write-tree"], in: target) == snapshot.indexTree)
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nB\nc\nd\n")
        #expect(try ScratchFile.read("notes.txt", in: target) == "new\n")
    }

    /// Another Git holds the source's index: the source is left as it is,
    /// and the other's lock is not ours to remove.
    @Test func anIndexAnotherGitHolds_isLeftAlone_withItsLock() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        let lock = repo.url.appendingPathComponent(".git/index.lock")
        let lockBytes = Data("other process".utf8)
        try lockBytes.write(to: lock)
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBytes = try Data(contentsOf: index)
        defer { try? FileManager.default.removeItem(at: lock) }
        let now = try repo.read("a.txt")

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .leftInSource)
        #expect(try Data(contentsOf: lock) == lockBytes)
        #expect(try Data(contentsOf: index) == indexBytes)
        #expect(try await TempGitRepo.git(["write-tree"], in: target) == snapshot.indexTree)
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nB\nc\nd\n")
        #expect(try ScratchFile.read("notes.txt", in: target) == "new\n")
        #expect(try repo.read("a.txt") == now)
        #expect(try repo.read("notes.txt") == "new\n")
    }

    /// The new worktree cannot take the changes (its checkout made a file
    /// where one goes): it is left with what it had, and the source is not
    /// touched.
    @Test func aTargetThatRefuses_isNotApplied_andTheSourceIsUntouched() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        try ScratchFile.write("made by a hook\n", to: "notes.txt", in: target)

        let targetBefore = try await Self.state(target)
        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try await Self.state(repo.url) == before)
        #expect(try await Self.state(target) == targetBefore)
        #expect(try ScratchFile.read("notes.txt", in: target) == "made by a hook\n")
    }

    /// The new worktree's checkout hook changed a tracked file the changes
    /// do not touch: the carry writes nothing there, so the hook's change
    /// is kept rather than taken back with a failed check.
    @Test func aTrackedFileTheHookChanged_isKept_andNothingIsWritten() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nB\nc\n", to: "a.txt")
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        try ScratchFile.write("made by a hook\n", to: "x.txt", in: target)

        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        let reachedWrite = Recorded(false)
        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, checked: {
            reachedWrite.value = true
        })

        #expect(outcome == .notApplied)
        #expect(!reachedWrite.value)
        #expect(try ScratchFile.read("x.txt", in: target) == "made by a hook\n")
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(target) == "M x.txt")
        #expect(try await Self.state(repo.url) == before)
    }

    /// A check that fails after the changes were written puts back only
    /// the paths they wrote: the files they added go, and an untracked
    /// file of the new worktree's own stays.
    @Test func aFailedCheck_putsBackOnlyWhatTheChangesWrote() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("* text=auto\n", to: ".gitattributes")
        try await repo.git(["add", ".gitattributes"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try repo.write("a\r\nCRLF\r\n", to: "a.txt")
        try repo.write("new\n", to: "notes.txt")
        try await repo.git(["add", "notes.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")
        try ScratchFile.write("installed by a hook\n", to: "vendor/lib.txt", in: target)

        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        let sourceBefore = try await Self.state(repo.url)
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBytes = try Data(contentsOf: index)
        let written = Recorded<[Data?]>([])
        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            written.value = ["a.txt", "notes.txt"].map {
                try? Data(contentsOf: target.appendingPathComponent($0))
            }
        })

        #expect(written.value == [Data("a\nCRLF\n".utf8), Data("new\n".utf8)])
        #expect(outcome == .notApplied)
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("a.txt")) == Data("a\r\nCRLF\r\n".utf8))
        #expect(try Data(contentsOf: index) == indexBytes)
        #expect(try await Self.state(repo.url) == sourceBefore)
        #expect(try ScratchFile.read("vendor/lib.txt", in: target) == "installed by a hook\n")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.txt").path))
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(target) == "?? vendor/lib.txt")
    }

    /// An ignored checkout file may obstruct either the added path itself
    /// or a directory needed by the added path.
    @Test(arguments: [false, true])
    func anIgnoredTargetObstruction_isKept(needsFolder: Bool) async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let obstruction = needsFolder ? "build" : ".env"
        let carried = needsFolder ? "build/out.txt" : ".env"
        try repo.write(obstruction + "\n", to: ".gitignore")
        try await repo.commit("ignore", paths: [".gitignore"])
        try repo.write("carried\n", to: carried)
        try await repo.git(["add", "--force", carried])
        let target = try await Self.addTarget(repo, branch: "carried")
        try ScratchFile.write("made by a hook\n", to: obstruction, in: target)
        let sourceTree = try await repo.git(["write-tree"])
        let targetTree = try await TempGitRepo.git(["write-tree"], in: target)
        try #require(try await Self.status(target).isEmpty)
        try await TempGitRepo.git(["check-ignore", "--", obstruction], in: target)

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read(obstruction, in: target) == "made by a hook\n")
        #expect(try repo.read(carried) == "carried\n")
        #expect(try await Self.status(target).isEmpty)
        #expect(try await repo.git(["write-tree"]) == sourceTree)
        #expect(try await TempGitRepo.git(["write-tree"], in: target) == targetTree)
    }

    /// Git stops part way through writing the new worktree (a folder its
    /// hook made that may not be written in): what it wrote is put back,
    /// and the hook's own file stays. The first file goes where an empty
    /// folder was, which Git replaces, so a path that held something before
    /// may be ours too.
    @Test(.enabled(if: geteuid() != 0))
    func aWriteThatStopsPartWay_inTheNewWorktree_isPutBack() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("first\n", to: "a-new.txt")
        try repo.write("second\n", to: "locked/new.txt")
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        try ScratchFile.write("made by a hook\n", to: "locked/hook.txt", in: target)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("a-new.txt"), withIntermediateDirectories: false)
        let locked = target.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let probe = locked.appendingPathComponent("probe")
        try #require(throws: (any Error).self) { try Data("probe".utf8).write(to: probe) }
        let targetTree = try await TempGitRepo.git(["write-tree"], in: target)
        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("a-new.txt").path))
        #expect(try ScratchFile.read("locked/hook.txt", in: target) == "made by a hook\n")
        #expect(try await Self.status(target) == "?? locked/hook.txt")
        #expect(!FileManager.default.fileExists(atPath: locked.appendingPathComponent("new.txt").path))
        #expect(try repo.read("a-new.txt") == "first\n")
        #expect(try repo.read("locked/new.txt") == "second\n")
        #expect(try await TempGitRepo.git(["write-tree"], in: target) == targetTree)
        #expect(try await Self.state(repo.url) == before)
    }

    /// Git stops part way through taking the changes out of the source (a
    /// folder that may not be written in), after it put one file back: the
    /// source is cleared part way, not left as it was, and a copy is kept.
    @Test(.enabled(if: geteuid() != 0))
    func aClearThatStopsPartWay_isPartlyCleared_withACopyKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("inner\n", to: "locked/inner.txt")
        try await repo.git(["add", "locked/inner.txt"])
        try await repo.git(["commit", "-q", "-m", "locked"])
        try repo.write("a\nB\nc\n", to: "a.txt")
        try repo.write("changed\n", to: "locked/inner.txt")
        let locked = repo.url.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        try #require(throws: (any Error).self) { try Data().write(to: locked.appendingPathComponent("probe")) }
        let originalTree = try await repo.git(["write-tree"])
        let target = try await Self.addTarget(repo, branch: "carried")

        let (snapshot, outcome) = try await Self.carry(repo, target: target)

        guard case let .partlyCleared(stash?) = outcome else {
            Issue.record("expected a partly cleared source with a copy kept, got \(outcome)")
            return
        }
        let entries = try await repo.git(["stash", "list", "--format=%gs"])
        #expect(entries.contains(stash))
        #expect(try await repo.git(["rev-parse", "stash@{0}^{tree}"]) == snapshot.fullTree)
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nB\nc\n")
        #expect(try ScratchFile.read("locked/inner.txt", in: target) == "changed\n")
        #expect(try repo.read("a.txt") == "a\nb\nc\n")
        #expect(try repo.read("locked/inner.txt") == "changed\n")
        #expect(try await repo.git(["write-tree"]) == originalTree)
        #expect(try await TempGitRepo.git(["write-tree"], in: target) == snapshot.indexTree)
    }

}

extension UncommittedChangesCarrierTests {

    // MARK: - What stops it first

    @Test func nothingToCarry_isNone() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        #expect(try await UncommittedChangesCarrier.snapshot(of: repo.url) == nil)
    }

    @Test func aBranchWithNoCommit_isRefused() async throws {
        try await withTempDir { dir in
            try await TempGitRepo.initialize(dir)
            try ScratchFile.write("x\n", to: "x.txt", in: dir)
            await #expect(throws: UncommittedCarryRefusal.noCommit) {
                try await UncommittedChangesCarrier.snapshot(of: dir)
            }
        }
    }

    @Test func aMergeUnderWay_isRefused_andItsStateIsLeft() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let other = try await Self.addTarget(repo, branch: "other")
        try ScratchFile.write("a\nOTHER\nc\n", to: "a.txt", in: other)
        try await TempGitRepo.git(["commit", "-q", "-am", "other"], in: other)
        try repo.write("a\nMINE\nc\n", to: "a.txt")
        try await repo.git(["commit", "-q", "-am", "mine"])
        await #expect(throws: TempGitRepo.GitFailure.self) { try await repo.git(["merge", "-q", "other"]) }
        let mergeHead = repo.url.appendingPathComponent(".git/MERGE_HEAD")
        let headBytes = try Data(contentsOf: mergeHead)
        let before = try await Self.status(repo.url)
        let unmerged = try await repo.git(["ls-files", "-u"])
        try #require(!unmerged.isEmpty)
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBytes = try Data(contentsOf: index)

        await #expect(throws: UncommittedCarryRefusal.operationInProgress) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try Data(contentsOf: mergeHead) == headBytes)
        #expect(try Data(contentsOf: index) == indexBytes)
        #expect(try await repo.git(["ls-files", "-u"]) == unmerged)
        #expect(try await Self.status(repo.url) == before)
    }

    @Test func aRepositoryInsideTheWorktree_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let inner = repo.url.appendingPathComponent("vendor/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try await TempGitRepo.initialize(inner)
        try await TempGitRepo.git(["commit", "-q", "--allow-empty", "-m", "inner"], in: inner)

        await #expect(throws: UncommittedCarryRefusal.submodules) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
    }

    @Test func aSparseCheckout_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["config", "core.sparseCheckout", "true"])
        try repo.write("x\n", to: "a.txt")
        await #expect(throws: UncommittedCarryRefusal.unsupportedCheckout) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
    }

    /// Reading the changes writes nothing in the source, its index included.
    @Test func readingTheChanges_writesNothingInTheSource() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        // The state first: its own `git status` may refresh the index.
        let before = try await Self.state(repo.url)
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)

        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))

        #expect(snapshot.fileCount == 8)
        #expect(try Data(contentsOf: index) == indexBefore)
        #expect(try await Self.state(repo.url) == before)
    }

    /// Neither skip-worktree nor intent-to-add is represented by the
    /// trees the carry would put back.
    @Test(arguments: [false, true])
    func anIndexOnlyFlag_isRefused(intentToAdd: Bool) async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        if intentToAdd {
            try repo.write("later\n", to: "later.txt")
            try await repo.git(["add", "-N", "later.txt"])
        } else {
            try await repo.git(["update-index", "--skip-worktree", "x.txt"])
            try repo.write("x\n", to: "a.txt")
        }
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBytes = try Data(contentsOf: index)
        await #expect(throws: UncommittedCarryRefusal.indexOnlyState) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try Data(contentsOf: index) == indexBytes)
    }

    /// A tracked file turned into a folder that holds a file Git ignores:
    /// going back to the file would remove the ignored one, which nothing
    /// carries.
    @Test func aFileTurnedFolder_withAnIgnoredFileInIt_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("*.log\n", to: ".gitignore")
        try await repo.git(["add", ".gitignore"])
        try await repo.git(["commit", "-q", "-m", "ignore"])
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("x.txt"))
        try repo.write("tracked later\n", to: "x.txt/y.txt")
        try repo.write("keep me\n", to: "x.txt/keep.log")

        await #expect(throws: UncommittedCarryRefusal.ignoredFilesInTheWay("x.txt")) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try repo.read("x.txt/keep.log") == "keep me\n")
    }

    /// A file taken out of Git and ignored since (`.env` with real values),
    /// where HEAD still has it: going back to HEAD would write the
    /// committed one over it.
    @Test func anIgnoredFileWhereADeletionIs_isRefused_andKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("SECRET=template\n", to: ".env")
        try await repo.git(["add", ".env"])
        try await repo.git(["commit", "-q", "-m", "env"])
        try await repo.git(["rm", "-q", "--cached", ".env"])
        try repo.write(".env\n", to: ".gitignore")
        try repo.write("SECRET=real\n", to: ".env")

        await #expect(throws: UncommittedCarryRefusal.ignoredFileWritten(".env")) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try repo.read(".env") == "SECRET=real\n")
    }

    /// A folder HEAD has a file in, deleted, and a file Git ignores made at
    /// its name since (`build` for `build/out.txt`): going back to HEAD
    /// would put the folder in its place.
    @Test func anIgnoredFileWhereADeletedFilesFolderWas_isRefused_andKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("committed\n", to: "build/out.txt")
        try await repo.git(["add", "build/out.txt"])
        try await repo.git(["commit", "-q", "-m", "build"])
        try repo.write("build\n", to: ".gitignore")
        try await repo.git(["add", ".gitignore"])
        try await repo.git(["commit", "-q", "-m", "ignore"])
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("build"))
        try repo.write("mine\n", to: "build")

        await #expect(throws: UncommittedCarryRefusal.ignoredFileInTheWay("build")) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try repo.read("build") == "mine\n")
    }

    /// A commit made while the carry waits for the index (an agent's
    /// `git commit` holds the lock): going back to the old HEAD would undo
    /// it, so the source is left with it.
    @Test func aCommitMadeWhileTheIndexIsHeld_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nB\nc\n", to: "a.txt")
        try await repo.git(["add", "a.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        // Another Git holds the index; meanwhile HEAD moves to a commit of
        // what is staged, which is how `git commit` leaves it.
        let tree = try await repo.git(["write-tree"])
        let commit = try await repo.git(["commit-tree", "-p", "HEAD", "-m", "agent", tree])
        let lock = repo.url.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBytes = try Data(contentsOf: index)
        let movedHead = Recorded(false)
        let beganClearing = Recorded(false)
        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, headChecked: {
            do {
                try await repo.git(["update-ref", "HEAD", commit])
                try FileManager.default.removeItem(at: lock)
                movedHead.value = true
            } catch {
                Issue.record(error)
            }
        }, clearing: {
            beganClearing.value = true
        })

        try #require(movedHead.value)
        #expect(!beganClearing.value)
        #expect(outcome == .leftInSource)
        #expect(try await repo.git(["rev-parse", "HEAD"]) == commit)
        #expect(try Data(contentsOf: index) == indexBytes)
        #expect(try repo.read("a.txt") == "a\nB\nc\n")
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nB\nc\n")
        #expect(try await TempGitRepo.git(["write-tree"], in: target) == snapshot.indexTree)
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
    }

    /// A linked worktree is a source as the project's folder is: its index
    /// and its lock are in `.git/worktrees/<name>`.
    @Test func aLinkedWorktree_isASourceToo() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let source = try await repo.addLinkedWorktree(branch: "source")
        try ScratchFile.write("linked\n", to: "a.txt", in: source)
        try ScratchFile.write("new\n", to: "notes.txt", in: source)
        let target = try await Self.addTarget(repo, branch: "carried", start: "source")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: source))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "source", repoRoot: repo.url)

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .moved(files: 2))
        #expect(try ScratchFile.read("a.txt", in: target) == "linked\n")
        #expect(try ScratchFile.read("notes.txt", in: target) == "new\n")
        #expect(try await Self.status(source).isEmpty)
    }

    // MARK: - The stash stack

    /// The copy kept when the source cannot be cleared all the way is a
    /// stash entry `git stash apply --index` takes back exactly.
    @Test func theCopyKept_isAStashThatGivesTheChangesBack() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))

        let name = try #require(await UncommittedChangesCarrier.keepAsStash(snapshot))

        let entries = try await repo.git(["stash", "list", "--format=%gs"])
        #expect(entries.contains(name))
        try await repo.git(["reset", "-q", "--hard"])
        try await repo.git(["clean", "-q", "-f", "-d"])
        try await repo.git(["stash", "apply", "-q", "--index", "stash@{0}"])
        #expect(try await Self.state(repo.url) == before)
    }

    // MARK: - Counting

    @Test func theCount_isTheSidebars_aRenameOnce() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        #expect(await UncommittedChangesCarrier.changedFileCount(in: repo.url) == 0)
        try await repo.git(["config", "status.renames", "true"])
        try await Self.makeChanges(in: repo.url)
        let status = try await repo.git(["status", "--porcelain=v2"])
        try #require(status.split(separator: "\n").filter { $0.hasPrefix("2 ") }.count == 1)
        guard case let .facts(facts) = await ReviewGit.facts(at: repo.url) else {
            Issue.record("expected sidebar Git facts")
            return
        }
        #expect(facts.uncommittedFiles == 8)
        #expect(await UncommittedChangesCarrier.changedFileCount(in: repo.url) == 8)
    }
}
