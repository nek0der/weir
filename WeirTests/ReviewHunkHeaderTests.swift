// ReviewHunkHeaderTests.swift
// Weir — the hunk headers Git writes, read once by the parse for every reader of their numbers.

import Foundation
import Testing
@testable import Weir

/// Every hunk header Git writes is read once, by the parse, and the numbers
/// it stores are the ones the expansion and the Comment button's VoiceOver
/// label read: a one-line side's omitted count, a new file's empty old side,
/// a deleted file's empty new side, and the function name Git writes after
/// the second `@@`.
@Suite("Hunk headers from git diff", .tags(.smoke))
struct ReviewHunkHeaderTests {
    /// The hunk headers of `patch`, in order.
    private static func headers(_ patch: String) throws -> [ReviewHunkHeader?] {
        try ReviewDiffParser.parse(patch).filter { $0.kind == .hunk }.map(\.hunkHeader)
    }

    @Test func gitsOwnHeaders_areReadWithTheirCounts() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        // Lines that start with a digit, so Git names the hunk by the one
        // line that starts with a letter (its default function pattern).
        let lines = (1...20).map { $0 == 3 ? "func foo() {" : "\($0) text" }
        try repo.write(lines.joined(separator: "\n") + "\n", to: "long.txt")
        try repo.write("one\n", to: "single.txt")
        try repo.write("gone\n", to: "gone.txt")
        try await repo.git(["add", "."])
        try await repo.git(["commit", "-q", "-m", "seed"])

        var changed = lines
        changed[11] = "12 changed"
        try repo.write(changed.joined(separator: "\n") + "\n", to: "long.txt")
        try repo.write("two\n", to: "single.txt")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("gone.txt"))
        try repo.write("new\n", to: "added.txt")
        try await repo.git(["add", "-N", "added.txt"])

        let added = try await repo.git(["diff", "--no-color", "--no-ext-diff", "-U3", "--", "added.txt"])
        #expect(added.contains("\n@@ -0,0 +1 @@\n"))
        #expect(try Self.headers(added) == [ReviewHunkHeader(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1)])

        let single = try await repo.git(["diff", "--no-color", "--no-ext-diff", "-U3", "--", "single.txt"])
        #expect(single.contains("\n@@ -1 +1 @@\n"))
        #expect(try Self.headers(single) == [ReviewHunkHeader(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)])

        let gone = try await repo.git(["diff", "--no-color", "--no-ext-diff", "-U3", "--", "gone.txt"])
        #expect(gone.contains("\n@@ -1 +0,0 @@\n"))
        let goneHeaders = try Self.headers(gone)
        #expect(goneHeaders == [ReviewHunkHeader(oldStart: 1, oldCount: 1, newStart: 0, newCount: 0)])
        let goneHeader = try #require(goneHeaders.first ?? nil)
        #expect(goneHeader.firstLine == 1, "a deleted file's hunk is named by its old side")

        let long = try await repo.git(["diff", "--no-color", "--no-ext-diff", "-U3", "--", "long.txt"])
        #expect(long.contains("\n@@ -9,7 +9,7 @@ func foo() {\n"), "the function context follows the second @@")
        let longHeaders = try Self.headers(long)
        #expect(longHeaders == [ReviewHunkHeader(oldStart: 9, oldCount: 7, newStart: 9, newCount: 7)])
        let longHeader = try #require(longHeaders.first ?? nil)
        #expect(longHeader.firstLine == 9)

        // The expansion places its gaps by the same numbers: lines 1 to 8
        // above the hunk, and 16 to 20 after it.
        let gaps = try ReviewExpansionPlan.gaps(in: ReviewDiffParser.parse(long), sourceCount: 20)
        #expect(gaps.map(\.range) == [1...8, 16...20])
        #expect(gaps.map(\.delta) == [0, 0])
    }

    /// A line that is not a hunk header carries none.
    @Test func onlyAHunkLine_carriesAHeader() throws {
        let lines = try ReviewDiffParser.parse("diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(lines.map(\.hunkHeader) == [nil, ReviewHunkHeader(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1), nil, nil])
    }

    @Test func closedFileHunk_keepsItsHeaderAndCommentLabelAfterOffset() throws {
        let lines = try ReviewDiffParser.parse("@@ -10,1 +12,1 @@\n-old\n+new\n")
        let original = try #require(lines.first { $0.kind == .hunk })
        let file = ReviewFile(path: "file.txt", layer: .turns, status: .modified)
        let diff = ReviewDiff(file: file, fingerprint: "current", lines: lines)
        let offset = ReviewStackIDs.offset(forSlot: 1)
        let piece = ReviewStackPiece.closed(diff, offset: offset, comments: [], staleCommentIDs: [], layout: .unified)
        let shifted = try #require(piece.hunkHeaders.first)

        #expect(shifted.id == original.id + offset)
        #expect(piece.commentableHunks.contains(shifted.id))
        #expect(shifted.hunkHeader == ReviewHunkHeader(oldStart: 10, oldCount: 1, newStart: 12, newCount: 1))
        #expect(shifted.hunkHeader?.firstLine == 12)
        #expect(
            ReviewHunkCommentText.commentLabel(header: shifted.hunkHeader, locale: Locale(identifier: "en"))
                == "Comment on the Hunk at Line 12"
        )
    }
}
