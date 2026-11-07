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

    enum CaseOnlyRename: Sendable, CaseIterable {
        case file, folder, besideSibling

        var oldPath: String {
            switch self {
            case .file: "a.txt"
            case .folder: "Docs/readme.txt"
            case .besideSibling: "dir/a"
            }
        }

        var newPath: String {
            switch self {
            case .file: "A.txt"
            case .folder: "docs/readme.txt"
            case .besideSibling: "DIR/a"
            }
        }

        var contents: String {
            switch self {
            case .file: "a\nb\nc\n"
            case .folder: "read me\n"
            case .besideSibling: "a\n"
            }
        }

        var physicalOldEntry: String {
            switch self {
            case .file: "a.txt"
            case .folder: "Docs"
            case .besideSibling: "dir"
            }
        }

        var physicalNewEntry: String {
            switch self {
            case .file: "A.txt"
            case .folder: "docs"
            case .besideSibling: "dir"
            }
        }

        var renameStatus: String {
            "R  \(oldPath) -> \(newPath)"
        }

        func stage(in repo: TempGitRepo) async throws {
            switch self {
            case .file:
                try await repo.git(["mv", oldPath, newPath])
            case .folder:
                try repo.write(contents, to: oldPath)
                try await repo.commit("docs", paths: [oldPath])
                try UncommittedChangesCarrierTests.renameOnDisk(physicalOldEntry, to: physicalNewEntry, in: repo.url)
                try await repo.git(["rm", "-q", "--cached", oldPath])
                try await repo.git(["add", newPath])
            case .besideSibling:
                try repo.write(contents, to: oldPath)
                try repo.write("b\n", to: "dir/b")
                try await repo.commit("dir", paths: ["dir"])
                try await repo.git(["mv", oldPath, newPath])
            }
        }

        func expectTree(at root: URL, hasRename: Bool) async throws {
            let wanted = hasRename ? newPath : oldPath
            let unwanted = hasRename ? oldPath : newPath
            let listed = try await UncommittedChangesCarrierTests.indexPaths(at: root)
            #expect(listed.contains(Array(wanted.utf8)))
            #expect(!listed.contains(Array(unwanted.utf8)))

            let physical = hasRename ? physicalNewEntry : physicalOldEntry
            let alternate = hasRename ? physicalOldEntry : physicalNewEntry
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(entries.contains(physical))
            if physical != alternate {
                #expect(!entries.contains(alternate))
            }
            #expect(try ScratchFile.read(wanted, in: root) == contents)
            if self == .besideSibling {
                #expect(listed.contains(Array("dir/b".utf8)))
                #expect(try ScratchFile.read("dir/b", in: root) == "b\n")
            }
        }

    }

    private static func indexPaths(at root: URL) async throws -> Set<[UInt8]> {
        let output = try await TempGitRepo.git(["ls-files", "-z"], in: root)
        return Set(output.utf8.split(separator: 0).map(Array.init))
    }

    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"), arguments: CaseOnlyRename.allCases)
    func aCaseOnlyRename_movesAndRestoresTheSourcesOriginalSpelling(shape: CaseOnlyRename) async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await shape.stage(in: repo)
        try #require(try await Self.status(repo.url) == shape.renameStatus)
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: 1))
        #expect(try await Self.status(target) == shape.renameStatus)
        try await shape.expectTree(at: target, hasRename: true)
        #expect(try await Self.status(repo.url).isEmpty)
        try await shape.expectTree(at: repo.url, hasRename: false)
    }

    @Test(.enabled(if: runsCaseFoldingTests, "The temporary folder is on a case-sensitive volume"), arguments: CaseOnlyRename.allCases)
    func aCaseOnlyRename_rollsBackWhenTheTargetCheckFails(shape: CaseOnlyRename) async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await shape.stage(in: repo)
        try #require(try await Self.status(repo.url) == shape.renameStatus)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target, placed: {
            do {
                try #require(try await Self.status(target) == shape.renameStatus)
                try await shape.expectTree(at: target, hasRename: true)
                try ScratchFile.write("changed by a hook\n", to: "x.txt", in: target)
            } catch {
                Issue.record(error)
            }
        })

        #expect(outcome == .notApplied)
        #expect(try await Self.status(target) == "M x.txt")
        #expect(try ScratchFile.read("x.txt", in: target) == "changed by a hook\n")
        try await shape.expectTree(at: target, hasRename: false)
        #expect(try await Self.status(repo.url) == shape.renameStatus)
        try await shape.expectTree(at: repo.url, hasRename: true)
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

    private static let foldsNormalization = (try? withTempDir { root in
        try writeExactly("accent", to: "caf\u{E9}.txt", in: root)
        var identity = stat()
        return stat("\(root.path)/cafe\u{301}.txt", &identity) == 0
    }) == true

    /// A rename that changes only a name's Unicode normalization, with
    /// `core.precomposeunicode` off: the volume takes both names for one
    /// entry, and Git, which does not, refuses to write the new name over
    /// it. Nothing is moved, nothing is lost, and the reason is not a file
    /// Git ignores.
    @Test(.enabled(if: foldsNormalization, "The temporary volume distinguishes NFC and NFD names"))
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
        let sourceIndex = try await Self.indexPaths(at: repo.url)
        try #require(sourceIndex.contains(Array(decomposed.utf8)))
        try #require(!sourceIndex.contains(Array(composed.utf8)))
        let target = try await Self.addTarget(repo, branch: "carried")
        let targetIndex = try await Self.indexPaths(at: target)
        try #require(targetIndex.contains(Array(composed.utf8)))
        try #require(!targetIndex.contains(Array(decomposed.utf8)))
        try #require(try Self.hasSameEntry(composed, decomposed, in: target))
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        let checked = Recorded(false)
        let placed = Recorded(false)

        let outcome = await UncommittedChangesCarrier.move(
            snapshot, placement: placement, into: target,
            checked: { checked.value = true }, placed: { placed.value = true }
        )

        #expect(checked.value)
        #expect(!placed.value)
        #expect(outcome == .notApplied)
        #expect(try await Self.status(target).isEmpty)
        #expect(try await Self.indexPaths(at: target) == targetIndex)
        #expect(try ScratchFile.read(composed, in: target) == "accent\n")
        #expect(try await Self.status(repo.url) == before)
        #expect(try await Self.indexPaths(at: repo.url) == sourceIndex)
        #expect(try ScratchFile.read(decomposed, in: repo.url) == "accent\n")
    }

    private static func hasSameEntry(_ first: String, _ second: String, in root: URL) throws -> Bool {
        var firstIdentity = stat()
        var secondIdentity = stat()
        try #require(stat("\(root.path)/\(first)", &firstIdentity) == 0)
        try #require(stat("\(root.path)/\(second)", &secondIdentity) == 0)
        return firstIdentity.st_dev == secondIdentity.st_dev && firstIdentity.st_ino == secondIdentity.st_ino
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
            do {
                try repo.write("keep\nmore\nlater\n", to: "x.txt")
            } catch {
                Issue.record(error)
            }
        })

        #expect(outcome == .leftInSource)
        #expect(try await Self.status(repo.url) == "R  a.txt -> A.txt\n M x.txt")
        try await CaseOnlyRename.file.expectTree(at: repo.url, hasRename: true)
        #expect(try repo.read("x.txt") == "keep\nmore\nlater\n")
        #expect(try await Self.status(target) == "R  a.txt -> A.txt\n M x.txt")
        try await CaseOnlyRename.file.expectTree(at: target, hasRename: true)
        #expect(try ScratchFile.read("x.txt", in: target) == "keep\nmore\n")
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
