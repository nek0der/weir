// UncommittedChangesCarrierTests+Rollback.swift
// Weir — putting a new worktree back after the carry's write fails or its check does, with a hook writing there meanwhile.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension UncommittedChangesCarrierTests {
    /// A file a hook still running makes where the changes add one, after
    /// the new worktree was checked: Git refuses to write over it, and the
    /// hook's file is not taken for ours and removed.
    @Test func aFileAHookMakesWhileTheChangesGoIn_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("new\n", to: "notes.txt")
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, checked: {
            try? ScratchFile.write("made by a hook\n", to: "notes.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read("notes.txt", in: target) == "made by a hook\n")
        #expect(try await Self.status(target) == "?? notes.txt")
        #expect(try await Self.state(repo.url) == before)
    }

    /// A hook still running changes a tracked file the changes change too,
    /// after the new worktree was checked: Git refuses to write over it,
    /// and the hook's edit is not put back to the start as if it were ours.
    @Test func aTrackedFileAHookChangesWhileTheChangesGoIn_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nB\nc\n", to: "a.txt")
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, checked: {
            try? ScratchFile.write("made by a hook\n", to: "a.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read("a.txt", in: target) == "made by a hook\n")
        #expect(try await Self.state(repo.url) == before)
    }

    /// The changes turn a file into a folder (`conf` into `conf/b.txt`),
    /// and Git stops part way at a folder its hook made that may not be
    /// written in: the file comes back as the start has it, the folder Git
    /// made goes, and the hook's own file stays.
    @Test func aFileTurnedFolder_whoseWriteStopsPartWay_isPutBackToTheStart() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("file\n", to: "conf")
        try await repo.git(["add", "conf"])
        try await repo.git(["commit", "-q", "-m", "conf"])
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("conf"))
        try repo.write("inner\n", to: "conf/b.txt")
        try repo.write("second\n", to: "z-locked/new.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        try ScratchFile.write("made by a hook\n", to: "z-locked/hook.txt", in: target)
        let locked = target.appendingPathComponent("z-locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read("conf", in: target) == "file\n")
        #expect(try ScratchFile.read("z-locked/hook.txt", in: target) == "made by a hook\n")
        #expect(try await Self.status(target) == "?? z-locked/hook.txt")
        #expect(try repo.read("conf/b.txt") == "inner\n")
    }

    /// A file a hook writes in the new worktree after Git wrote the
    /// changes, at a path they write too: the checks fail on it, and it is
    /// not taken for ours and removed.
    @Test func aFileAHookWritesOverTheChanges_afterTheyWentIn_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("new\n", to: "notes.txt")
        try repo.write("a\nB\nc\n", to: "a.txt")
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("made by a hook\n", to: "notes.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read("notes.txt", in: target) == "made by a hook\n")
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(target) == "?? notes.txt")
        #expect(try await Self.state(repo.url) == before)
    }

    /// A hook writes, after Git wrote the changes, a file that differs from
    /// ours only in its line endings, which Git stores the same: it is not
    /// what Git checked out, so it is not taken for ours and put back.
    @Test func aHooksFileThatGitWouldStoreAsOurs_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("* text=auto\n", to: ".gitattributes")
        try await repo.git(["add", ".gitattributes"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try repo.write("a\r\nCRLF\r\n", to: "a.txt")
        try repo.write("new\n", to: "notes.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("new\r\n", to: "notes.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try Data(contentsOf: target.appendingPathComponent("notes.txt")) == Data("new\r\n".utf8))
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
    }

    /// A hook, after Git wrote the changes, turns a folder they wrote in
    /// into a link to a folder outside the worktree holding a file just
    /// like ours: nothing is removed through the link.
    @Test func aFolderAHookTurnsIntoALink_isNotFollowed() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nB\nc\n", to: "a.txt")
        try repo.write("new\n", to: "dir/new.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let outside = repo.scratch.appendingPathComponent("outside", isDirectory: true)
        try ScratchFile.write("new\n", to: "new.txt", in: outside)
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            let dir = target.appendingPathComponent("dir")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createSymbolicLink(at: dir, withDestinationURL: outside)
            // The check fails on this one, so the changes are put back.
            try? ScratchFile.write("made by a hook\n", to: "a.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read("new.txt", in: outside) == "new\n")
    }

    /// A hook, after Git wrote the changes, changes `.gitattributes` and
    /// writes a carried file again with the line endings that now asks
    /// for: Git's own bytes are still the placement's, and the hook's file
    /// stays.
    @Test func aHooksFileUnderAttributesItChanged_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("*.txt text eol=lf\n", to: ".gitattributes")
        try await repo.git(["add", ".gitattributes"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try repo.write("new\n", to: "notes.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("*.txt text eol=crlf\n", to: ".gitattributes", in: target)
            try? ScratchFile.write("new\r\n", to: "notes.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try Data(contentsOf: target.appendingPathComponent("notes.txt")) == Data("new\r\n".utf8))
    }

    /// A file turned into a folder, and a hook's file put in that folder
    /// after Git wrote the changes, which then fail their check on a line
    /// ending: what Git wrote with its own conversion is ours and goes
    /// back, while the folder holding the hook's file, and the change in
    /// it, stay.
    @Test func aHooksFileInAFolderTheChangesMade_keepsThatFolder() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("* text=auto\n", to: ".gitattributes")
        try repo.write("file\n", to: "conf")
        try await repo.git(["add", ".gitattributes", "conf"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try repo.write("a\r\nCRLF\r\n", to: "a.txt")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("conf"))
        try repo.write("inner\n", to: "conf/b.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("made by a hook\n", to: "conf/c.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try ScratchFile.read("conf/c.txt", in: target) == "made by a hook\n")
        #expect(try ScratchFile.read("conf/b.txt", in: target) == "inner\n")
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("a.txt")) == Data("a\r\nCRLF\r\n".utf8))
    }

    /// A hook stages its own content for a file the changes write, and
    /// changes the file again, after the new worktree was checked: Git
    /// refuses, and the hook's staged entry is not put back to the start
    /// as if it were ours.
    @Test func anEntryAHookStagesWhileTheChangesGoIn_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nB\nc\n", to: "a.txt")
        try await repo.git(["add", "a.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, checked: {
            try? ScratchFile.write("staged by a hook\n", to: "a.txt", in: target)
            _ = try? await TempGitRepo.git(["add", "a.txt"], in: target)
            try? ScratchFile.write("written by a hook\n", to: "a.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try await TempGitRepo.git(["show", ":a.txt"], in: target) == "staged by a hook")
        #expect(try ScratchFile.read("a.txt", in: target) == "written by a hook\n")
    }

    /// A hook turns a file the changes delete into a folder and stages a
    /// file in it, after the new worktree was checked: Git refuses, and
    /// the staged file below the deleted path is not put back with it.
    @Test func anEntryAHookStagesBelowADeletedFile_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("deleted.txt"))
        try repo.write("a\nB\nc\n", to: "a.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, checked: {
            try? FileManager.default.removeItem(at: target.appendingPathComponent("deleted.txt"))
            try? ScratchFile.write("staged by a hook\n", to: "deleted.txt/hook.txt", in: target)
            _ = try? await TempGitRepo.git(["add", "deleted.txt/hook.txt"], in: target)
            try? ScratchFile.write("written by a hook\n", to: "deleted.txt/hook.txt", in: target)
            try? ScratchFile.write("made by a hook\n", to: "a.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try await TempGitRepo.git(["show", ":deleted.txt/hook.txt"], in: target) == "staged by a hook")
        #expect(try ScratchFile.read("deleted.txt/hook.txt", in: target) == "written by a hook\n")
    }

    /// A hook turns a folder the changes delete a file in into a file of
    /// its own and stages it, after the new worktree was checked: Git
    /// refuses, and putting the deleted file back neither makes a folder
    /// of the hook's file nor drops its staged entry.
    @Test func aFileAHookStagesAboveADeletedFile_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("inner\n", to: "dir/a.txt")
        try await repo.git(["add", "dir/a.txt"])
        try await repo.git(["commit", "-q", "-m", "dir"])
        try await repo.git(["rm", "-q", "dir/a.txt"])
        try repo.write("a\nB\nc\n", to: "a.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, checked: {
            _ = try? await TempGitRepo.git(["rm", "-q", "-r", "dir"], in: target)
            try? ScratchFile.write("staged by a hook\n", to: "dir", in: target)
            _ = try? await TempGitRepo.git(["add", "dir"], in: target)
            try? ScratchFile.write("written by a hook\n", to: "dir", in: target)
            try? ScratchFile.write("made by a hook\n", to: "a.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try await TempGitRepo.git(["show", ":dir"], in: target) == "staged by a hook")
        #expect(try ScratchFile.read("dir", in: target) == "written by a hook\n")
    }

    /// A folder the new worktree's checkout hook made, empty, where the
    /// changes add a file, and a write Git stops part way: the file goes,
    /// and the hook's folder stays.
    @Test func anEmptyFolderAHookMade_staysAfterThePutBack() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("log line\n", to: "a-log/x.txt")
        try repo.write("second\n", to: "z-locked/new.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("a-log"), withIntermediateDirectories: false)
        try ScratchFile.write("made by a hook\n", to: "z-locked/hook.txt", in: target)
        let locked = target.appendingPathComponent("z-locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("a-log/x.txt").path))
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("a-log").path, isDirectory: &isFolder))
        #expect(isFolder.boolValue)
    }

    /// An agent edits a file the changes touch in the source, under the
    /// lock, just before Git writes there: Git refuses, writing nothing, so
    /// the source is left with its changes, the edit included, and no copy
    /// is kept.
    @Test func aRefusalInTheSource_isLeftInSource_withNoCopy() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\nB\nc\n", to: "a.txt")
        try repo.write("changed\n", to: "x.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        let source = repo.url

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, clearing: {
            try? ScratchFile.write("an agent's edit\n", to: "a.txt", in: source)
        })

        #expect(outcome == .leftInSource)
        #expect(try repo.read("a.txt") == "an agent's edit\n")
        #expect(try repo.read("x.txt") == "changed\n")
        #expect(try await repo.git(["stash", "list"]).isEmpty)
    }

    /// Another Git holds the new worktree's index once the changes went in,
    /// and a carried file changed there, so the check fails: the files we
    /// wrote go back and the changed one stays, but the index, which Git
    /// left with the changes' entries, cannot be put back while the lock
    /// is held, and the outcome says some of the changes may be left.
    @Test func anIndexHeldWhenTheCheckFails_putsTheFilesBack() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("new\n", to: "notes.txt")
        try repo.write("a\nB\nc\n", to: "a.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let lock = try await URL(fileURLWithPath: TempGitRepo.git(
            ["rev-parse", "--path-format=absolute", "--git-path", "index.lock"],
            in: target
        ))
        defer { try? FileManager.default.removeItem(at: lock) }
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            FileManager.default.createFile(atPath: lock.path, contents: Data())
            try? ScratchFile.write("made by a hook\n", to: "a.txt", in: target)
        })

        #expect(outcome == .notPutBack)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.txt").path))
        #expect(try ScratchFile.read("a.txt", in: target) == "made by a hook\n")
    }

    /// A required filter whose smudge fails: Git writes the files before
    /// the filtered one, then stops, and Git cannot check out the changes
    /// to compare with either, so nothing is taken for ours, and the
    /// outcome says some of the changes may be left in the new worktree.
    @Test func aFilterThatFails_isNotPutBack_andSaysSo() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["config", "filter.boom.clean", "cat"])
        try await repo.git(["config", "filter.boom.smudge", "false"])
        try await repo.git(["config", "filter.boom.required", "true"])
        try repo.write("*.boom filter=boom\n", to: ".gitattributes")
        try await repo.git(["add", ".gitattributes"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try repo.write("first\n", to: "a-new.txt")
        try repo.write("filtered\n", to: "x.boom")
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notPutBack)
        #expect(try ScratchFile.read("a-new.txt", in: target) == "first\n")
        #expect(try await Self.state(repo.url) == before)
    }
}
