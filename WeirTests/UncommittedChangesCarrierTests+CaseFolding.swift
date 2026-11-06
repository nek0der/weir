// UncommittedChangesCarrierTests+CaseFolding.swift
// Weir — moving a case-only rename on a case-insensitive volume, where the old name also finds the renamed file.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension UncommittedChangesCarrierTests {
    /// Whether the temporary folder is on a case-insensitive volume, the
    /// default on macOS. On a case-sensitive volume `a` never finds `A`, so
    /// these tests do not apply.
    static let foldsCase = (try? FileManager.default.temporaryDirectory
        .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        .volumeSupportsCaseSensitiveNames) == false

    /// Whether the run must include these tests, as CI's does: a runner
    /// whose temporary folder is case-sensitive would otherwise skip them
    /// without a word.
    /// CI sets `TEST_RUNNER_WEIR_REQUIRE_CASE_FOLDING_TESTS`, which
    /// xcodebuild passes to the test process without its prefix.
    static let requiresCaseFolding = ProcessInfo.processInfo.environment["WEIR_REQUIRE_CASE_FOLDING_TESTS"] == "1"

    /// Whether these tests run: on a case-insensitive volume, or when the
    /// run requires them, where they fail on a case-sensitive one.
    static let runsCaseFoldingTests = foldsCase || requiresCaseFolding

    /// Renames a file or folder in `root` to a name that differs only in
    /// case or Unicode normalization, through a temporary name, so the
    /// rename does not depend on how the volume treats a direct `a` to `A`
    /// rename. The names go to the system as their exact bytes, which
    /// Foundation's file paths may decompose.
    static func renameOnDisk(_ path: String, to newPath: String, in root: URL) throws {
        let between = "\(root.path)/weir-rename-\(UUID().uuidString)"
        for (from, to) in [("\(root.path)/\(path)", between), (between, "\(root.path)/\(newPath)")] where rename(from, to) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Writes `text` to the file at `path` in `root`, its name given to the
    /// system as its exact bytes.
    static func writeExactly(_ text: String, to path: String, in root: URL) throws {
        let descriptor = open("\(root.path)/\(path)", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        guard write(descriptor, bytes, bytes.count) == bytes.count else { throw POSIXError(.EIO) }
    }

    @Test(.enabled(if: requiresCaseFolding, "The run does not require the case-folding tests"))
    func theTemporaryFolder_isCaseInsensitive_whenTheRunRequiresIt() {
        #expect(Self.foldsCase, "WEIR_REQUIRE_CASE_FOLDING_TESTS is set, but the temporary folder is on a case-sensitive volume")
    }

    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func pathsThatNameOneEntry_areFound_andSpelledAsTheDiskSpellsThem() throws {
        try withTempDir { root in
            try ScratchFile.write("x\n", to: "Dir/File.txt", in: root)
            try ScratchFile.write("y\n", to: "Dir/Other.txt", in: root)

            #expect(UncommittedChangesCarrier.spellingOnDisk("dir/file.txt", in: root) == "Dir/File.txt")
            #expect(UncommittedChangesCarrier.spellingOnDisk("DIR/none.txt", in: root) == "Dir/none.txt")
            #expect(UncommittedChangesCarrier.spellingOnDisk("none/x.txt", in: root) == "none/x.txt")
            let shared = UncommittedChangesCarrier.sharedEntries(
                among: ["Dir/File.txt", "dir/file.txt", "DIR/FILE.TXT", "Dir/Other.txt", "dir/missing.txt", "DIR/MISSING.TXT"],
                in: root
            )
            #expect(shared.count == 1)
            #expect(shared.first.map { Set($0.paths) } == ["Dir/File.txt", "dir/file.txt", "DIR/FILE.TXT"])
            #expect(shared.first?.isUnchanged(in: root) == true)
        }
    }

    /// After `git mv a.txt A.txt`, the old name finds the renamed file.
    /// That file is not one Git ignores, so the rename moves like any other.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aRenameThatChangesOnlyCase_moves_andTheSourceIsBackAtTheOldName() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["mv", "a.txt", "A.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: 1))
        #expect(try await Self.status(target) == "R  a.txt -> A.txt")
        #expect(UncommittedChangesCarrier.spellingOnDisk("A.txt", in: target) == "A.txt")
        #expect(try ScratchFile.read("A.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(repo.url).isEmpty)
        #expect(UncommittedChangesCarrier.spellingOnDisk("a.txt", in: repo.url) == "a.txt")
    }

    /// A tracked file renamed on disk only in case and then edited, with
    /// no `git mv`: Git reads it under the name it tracks, so it is the
    /// tracked file's edit and moves as one.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func anEditedFileWhoseCaseDiffersOnDiskOnly_moves() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.renameOnDisk("a.txt", to: "A.txt", in: repo.url)
        try repo.write("a\nB\nc\n", to: "A.txt")
        #expect(try await Self.status(repo.url) == "M a.txt")
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: 1))
        #expect(try await Self.status(target) == "M a.txt")
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nB\nc\n")
        #expect(try await Self.status(repo.url).isEmpty)
        #expect(try repo.read("a.txt") == "a\nb\nc\n")
    }

    /// A folder renamed to a name that differs only in case, with its file
    /// staged under the new name, moves too.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aFolderRenameThatChangesOnlyCase_moves() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("read me\n", to: "Docs/readme.txt")
        try await repo.git(["add", "Docs/readme.txt"])
        try await repo.git(["commit", "-q", "-m", "docs"])
        try Self.renameOnDisk("Docs", to: "docs", in: repo.url)
        try await repo.git(["rm", "-q", "--cached", "Docs/readme.txt"])
        try await repo.git(["add", "docs/readme.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: 1))
        #expect(try await Self.status(target) == "R  Docs/readme.txt -> docs/readme.txt")
        #expect(UncommittedChangesCarrier.spellingOnDisk("docs/readme.txt", in: target) == "docs/readme.txt")
        #expect(try await Self.status(repo.url).isEmpty)
        #expect(UncommittedChangesCarrier.spellingOnDisk("Docs/readme.txt", in: repo.url) == "Docs/readme.txt")
    }

    /// The same folder rename, when the new worktree's check fails after
    /// Git wrote it: the file goes back under the folder's old spelling.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aFolderRenameThatChangesOnlyCase_isPutBack_underTheOldSpelling_whenTheNewWorktreeFailsItsCheck() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("read me\n", to: "Docs/readme.txt")
        try await repo.git(["add", "Docs/readme.txt"])
        try await repo.git(["commit", "-q", "-m", "docs"])
        try Self.renameOnDisk("Docs", to: "docs", in: repo.url)
        try await repo.git(["rm", "-q", "--cached", "Docs/readme.txt"])
        try await repo.git(["add", "docs/readme.txt"])
        let before = try await Self.status(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("changed by a hook\n", to: "x.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try await Self.status(target) == "M x.txt")
        #expect(UncommittedChangesCarrier.spellingOnDisk("docs/readme.txt", in: target) == "Docs/readme.txt")
        #expect(try ScratchFile.read("Docs/readme.txt", in: target) == "read me\n")
        #expect(try await Self.status(repo.url) == before)
    }

    /// `git mv dir/a DIR/a` beside `dir/b`: the folder keeps its name on
    /// disk, so the old and new paths have the same spelling there and name
    /// one entry, which Git moves like any other rename.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aFileMovedToAFolderNameInAnotherCase_besideAFileThatStays_moves() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\n", to: "dir/a")
        try repo.write("b\n", to: "dir/b")
        try await repo.git(["add", "dir"])
        try await repo.git(["commit", "-q", "-m", "dir"])
        try await repo.git(["mv", "dir/a", "DIR/a"])
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: 1))
        #expect(try await Self.status(target) == "R  dir/a -> DIR/a")
        #expect(try ScratchFile.read("dir/a", in: target) == "a\n")
        #expect(try await Self.status(repo.url).isEmpty)
        #expect(try repo.read("dir/a") == "a\n")
    }

    /// The same move, when the new worktree's check fails after Git wrote
    /// it: the file goes back to its old path there, and the source keeps
    /// the change.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aFileMovedToAFolderNameInAnotherCase_isPutBack_whenTheNewWorktreeFailsItsCheck() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("a\n", to: "dir/a")
        try repo.write("b\n", to: "dir/b")
        try await repo.git(["add", "dir"])
        try await repo.git(["commit", "-q", "-m", "dir"])
        try await repo.git(["mv", "dir/a", "DIR/a"])
        let before = try await Self.status(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("changed by a hook\n", to: "x.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try await Self.status(target) == "M x.txt")
        #expect(try ScratchFile.read("dir/a", in: target) == "a\n")
        #expect(try await Self.status(repo.url) == before)
    }

    /// A rename that changes only a name's Unicode normalization, with
    /// `core.precomposeunicode` off: the volume takes both names for one
    /// entry, and Git, which does not, refuses to write the new name over
    /// it. Nothing is moved, nothing is lost, and the reason is not a file
    /// Git ignores.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aRenameThatChangesOnlyNormalization_isNotApplied_andTheSourceKeepsIt() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["config", "core.precomposeunicode", "false"])
        let composed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        try Self.writeExactly("accent\n", to: composed, in: repo.url)
        try await repo.git(["add", "--", composed])
        try await repo.git(["commit", "-q", "-m", "accent"])
        try await repo.git(["rm", "-q", "--cached", "--", composed])
        try Self.renameOnDisk(composed, to: decomposed, in: repo.url)
        try await repo.git(["add", "--", decomposed])
        let before = try await Self.status(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try await Self.status(target).isEmpty)
        #expect(try await Self.status(repo.url) == before)
        #expect(try ScratchFile.read(decomposed, in: repo.url) == "accent\n")
    }

    /// When the new worktree's check fails after Git wrote the rename (a
    /// hook changed a tracked file there), the renamed file is removed and
    /// the file under the old name is put back.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aRenameThatChangesOnlyCase_isPutBack_whenTheNewWorktreeFailsItsCheck() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["mv", "a.txt", "A.txt"])
        let before = try await Self.status(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            try? ScratchFile.write("changed by a hook\n", to: "x.txt", in: target)
        })

        #expect(outcome == .notApplied)
        #expect(try await Self.status(target) == "M x.txt")
        #expect(UncommittedChangesCarrier.spellingOnDisk("a.txt", in: target) == "a.txt")
        #expect(try ScratchFile.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(repo.url) == before)
    }

    /// When a file in the source changes while the source is cleared, Git
    /// refuses and writes nothing. The renamed file has the old file's
    /// bytes, but that does not make the old name look put back, so the
    /// changes stay in the source and no stash is kept.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func aRenameThatChangesOnlyCase_isLeftInTheSource_whenAFileChangesMeanwhile() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["mv", "a.txt", "A.txt"])
        try repo.write("keep\nmore\n", to: "x.txt")
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, clearing: {
            try? repo.write("keep\nmore\nlater\n", to: "x.txt")
        })

        #expect(outcome == .leftInSource)
        #expect(try await Self.status(repo.url) == "R  a.txt -> A.txt\n M x.txt")
        #expect(UncommittedChangesCarrier.spellingOnDisk("A.txt", in: repo.url) == "A.txt")
        #expect(try await repo.git(["stash", "list"]).isEmpty)
    }

    /// When a tracked file is taken out of Git and a file Git ignores has
    /// its name in another case, going back to HEAD would write over the
    /// ignored file. The refusal names that file as the disk spells it.
    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"))
    func anIgnoredFileAtADeletedFilesNameInAnotherCase_isRefused_underItsOwnName() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try repo.write("A.txt\n", to: ".gitignore")
        try await repo.git(["add", ".gitignore"])
        try await repo.git(["commit", "-q", "-m", "ignore"])
        try await repo.git(["rm", "-q", "--cached", "a.txt"])
        try Self.renameOnDisk("a.txt", to: "A.txt", in: repo.url)

        await #expect(throws: UncommittedCarryRefusal.ignoredFileWritten("A.txt")) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try repo.read("A.txt") == "a\nb\nc\n")
    }
}
