// ReviewParsingTests.swift
// Weir — what the review reads out of Git's patch, name, and numstat output.

import Foundation
import Testing
@testable import Weir

struct ReviewParsingTests {
    @Test func unifiedDiffPreservesBothSides() throws {
        let patch = "@@ -2,2 +2,3 @@\n same\n-old\n+new\n+日本語\n\\ No newline at end of file\n"
        let lines = try ReviewDiffParser.parse(patch)
        try #require(lines.map(\.oldLine) == [nil, 2, 3, nil, nil, nil], "Old-side line mapping")
        #expect(lines.map(\.newLine) == [nil, 2, nil, 3, 4, nil], "New-side line mapping")
        #expect(lines[4].text == "日本語", "UTF-8 line content")
        #expect(lines[0].kind == .hunk, "Hunk header is its own kind")
    }

    @Test func fileMetadataIsSeparableFromHunkHeaders() throws {
        let metadata = try ReviewDiffParser.parse("diff --git a/a b/a\nindex 1..2 100644\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(
            metadata.map(\.kind) == [.fileHeader, .fileHeader, .hunk, .removed, .added],
            "File metadata is separable from hunk headers"
        )
    }

    @Test(arguments: ["@@ -1,2 +1,2 @@\n x\n", "@@@ -1 -1 +1 @@@\n", "@@ -999999999999999999999 +1 @@\n"])
    func malformedPatchesAreRefused(_ patch: String) {
        #expect(throws: ReviewError.invalidDiff) { try ReviewDiffParser.parse(patch) }
    }

    @Test func nonTextModesAreReadFromTheLinesThatCarryAMode() throws {
        func refuses(_ header: String) throws -> Bool {
            try ReviewDiffParser.hasNonTextMode(ReviewDiffParser.parse(header + "@@ -1 +1 @@\n-a\n+b\n"))
        }
        // The path ends in the number, and the file is text.
        #expect(try !refuses("diff --git a/notes 120000 b/notes 120000\nindex 1..2 100644\n--- a/notes 120000\n+++ b/notes 120000\n"))
        #expect(try !refuses("diff --git a/pin 160000 b/pin 160000\nrename from x 120000\nrename to pin 160000\n"))
        for header in [
            "diff --git a/l b/l\nindex 1..2 120000\n",
            "diff --git a/s b/s\nindex 1..2 160000\n",
            "diff --git a/l b/l\nnew file mode 120000\nindex 0..2\n",
            "diff --git a/l b/l\ndeleted file mode 160000\nindex 1..0\n",
            "diff --git a/l b/l\nold mode 100644\nnew mode 120000\n"
        ] {
            #expect(try refuses(header), "Not refused: \(header)")
        }
        #expect(try !refuses("diff --git a/x b/x\nold mode 100644\nnew mode 100755\nindex 1..2\n"))
    }

    @Test func nameStatusKeepsUnusualPathsAndRenames() throws {
        let names = Data("R100\0old\tname\0new\nname\0M\0日本語\0".utf8)
        let files = try ReviewGit.parseNames(names, layer: .staged)
        try #require(files.count == 2, "NUL-delimited rename")
        #expect(files[0].oldPath == "old\tname" && files[0].path == "new\nname", "NUL-delimited rename")
        #expect(files[1].path == "日本語", "UTF-8 path")
        // The similarity score is dropped where the output is read, so nothing
        // downstream has to know that a rename's status is two fields glued
        // together.
        #expect(files[0].status == .renamed, "Rename status kept its score")
    }

    @Test func aNameThatIsNotUTF8_keepsTheOthersAndIsMarked() throws {
        let latin1 = Data("caf".utf8) + Data([0xE9])
        let names = try ReviewGit.parseNames(
            Data("M\0a.txt\0A\0".utf8) + latin1 + Data("\0R090\0".utf8) + latin1 + Data("\0b.txt\0".utf8),
            layer: .unstaged
        )
        try #require(names.count == 3)
        #expect(names[0].path == "a.txt" && !names[0].isNameUndecodable)
        #expect(names[1].path == "caf\u{FFFD}" && names[1].isNameUndecodable)
        // A rename from an undecodable name cannot be asked about either.
        #expect(names[2].path == "b.txt" && names[2].oldPath == "caf\u{FFFD}" && names[2].isNameUndecodable)
        let stats = try ReviewGit.parseNumstat(Data("1\t0\t".utf8) + latin1 + Data("\u{0}2\t1\ta.txt\0".utf8))
        #expect(stats.map(\.0) == ["caf\u{FFFD}", "a.txt"])
        #expect(stats.map(\.1) == [ReviewFileStat(added: 1, removed: 0), ReviewFileStat(added: 2, removed: 1)])
    }

    /// Not persisted, so a stored comment's file reads back the same as one
    /// written before the flag existed.
    @Test func theUndecodableMarkIsNotStored() throws {
        let file = ReviewFile(path: "x", layer: .staged, status: .modified, isNameUndecodable: true)
        let encoded = try JSONEncoder().encode(file)
        #expect(!(String(data: encoded, encoding: .utf8) ?? "").contains("Undecodable"))
        #expect(try !JSONDecoder().decode(ReviewFile.self, from: encoded).isNameUndecodable)
    }

    @Test func filePatchKeepsARenameApartFromAnotherFile() throws {
        let renamed = ReviewFile(path: "new name", oldPath: "old name", layer: .staged, status: .renamed)
        let rename = "diff --git a/old name b/new name\nrename from old name\nrename to new name"
        let combined = rename + "\ndiff --git a/old name b/old name\n@@ -0,0 +1 @@\n+unrelated\n"
        let selected = try ReviewGit.filePatch(combined, file: renamed)
        #expect(selected == rename)
    }

    /// `--numstat -z` writes the path inline, except for renames, where the
    /// field is empty and the old and new paths follow as separate records.
    @Test func numstatParsesRenamesAndBinaryCounts() throws {
        let data = Data("3\t1\ta.swift\0-\t-\tlogo.png\0".utf8)
            + Data("2\t4\t\0old.swift\0new.swift\0".utf8)
            + Data("5\t6\ta\tname.swift\0".utf8)
        let parsed = try ReviewGit.parseNumstat(data)
        #expect(parsed.map(\.0) == ["a.swift", "logo.png", "new.swift", "a\tname.swift"])
        #expect(parsed.map(\.1) == [
            ReviewFileStat(added: 3, removed: 1),
            ReviewFileStat(added: -1, removed: -1),
            ReviewFileStat(added: 2, removed: 4),
            ReviewFileStat(added: 5, removed: 6)
        ])
        #expect(parsed.map(\.1.isBinary) == [false, true, false, false])
        #expect(throws: ReviewError.invalidDiff) { try ReviewGit.parseNumstat(Data("3\ta.swift\0".utf8)) }
    }
}
