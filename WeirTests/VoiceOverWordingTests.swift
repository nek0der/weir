// VoiceOverWordingTests.swift
// Weir — localized accessibility text for counts, places, turns, and lines.

import Foundation
import Testing
@testable import Weir

/// The drawn forms keep their symbols ("4/4", "T7", "·", "→", "@@"), which
/// VoiceOver reads as a date, letter by letter, or as the symbol's name.
/// Each spoken form here is the one the labels hand VoiceOver instead.
struct VoiceOverWordingTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func tooltipFacts_andPlaces_areReadAsTheLocalesList() {
        #expect(AgentStatusText.spoken("Claude · Running", locale: Self.english) == "Claude, Running")
        #expect(AgentStatusText.spoken("Claude · 実行中", locale: Self.japanese) == "Claude、実行中")
        #expect(AgentStatusText.spokenPlace("alpha / feat/login", locale: Self.japanese) == "alpha、feat/login")
        #expect(AgentStatusText.spokenPlace("alpha", locale: Self.english) == "alpha")
    }

    @Test func aTurn_isReadAsTheWord_notItsLetter() {
        #expect(ReceiptText.spokenTurn(7, locale: Self.english) == "Turn 7")
        #expect(ReceiptText.spokenTurn(7, locale: Self.japanese) == "ターン 7")
        #expect(ReceiptText.spokenTurns(6...7, locale: Self.english) == "Turns 6 to 7")
        #expect(ReceiptText.spokenTurns(6...7, locale: Self.japanese) == "ターン 6 から 7")
        #expect(ReceiptText.spokenTurns(3...3, locale: Self.japanese) == "ターン 3")
    }

    @Test func pullRequestChecks_sayTheirCounts_inWords() {
        let failed = PRChecks(conclusion: .failure, counts: .init(passed: 3, total: 4))
        #expect(PRChecksText.make(failed, forge: .gitHub, locale: Self.english) == "Checks failed (3/4 passed)", "the card keeps its form")
        #expect(PRChecksText.spoken(failed, forge: .gitHub, locale: Self.english) == "Checks failed, 3 of 4 passed")
        #expect(PRChecksText.spoken(failed, forge: .gitHub, locale: Self.japanese) == "チェック失敗、4 件中 3 件成功")
        let passed = PRChecks(conclusion: .success, counts: .init(passed: 4, total: 4))
        #expect(PRChecksText.spoken(passed, forge: .gitHub, locale: Self.japanese) == "チェック成功、4 件中 4 件")
        let running = PRChecks(conclusion: .pending, counts: nil)
        #expect(PRChecksText.make(running, forge: .gitLab, locale: Self.english) == "Pipeline running")
        #expect(PRChecksText.spoken(running, forge: .gitLab, locale: Self.english) == "Pipeline running")
        #expect(PRChecksText.spoken(running, forge: .gitLab, locale: Self.japanese) == "パイプライン実行中")
    }

    @Test(arguments: [
        (Duration.zero, "0:00", ["0 seconds"], ["0秒"]),
        (.milliseconds(1), "0:01", ["1 second"], ["1秒"]),
        (.seconds(59), "0:59", ["59 seconds"], ["59秒"]),
        (.milliseconds(59001), "1:00", ["1 minute"], ["1分"]),
        (.seconds(60), "1:00", ["1 minute"], ["1分"]),
        (.seconds(522), "8:42", ["8 minutes", "42 seconds"], ["8分", "42秒"])
    ])
    func timeLeft_usesRoundedUnitsInAccessibilityText(
        remaining: Duration,
        clock: String,
        englishUnits: [String],
        japaneseUnits: [String]
    ) {
        func check(_ text: String, units: [String]) {
            var tail = text[...]
            for unit in units {
                guard let range = tail.range(of: unit) else {
                    Issue.record("Missing \(unit) in \(text)")
                    return
                }
                tail = tail[range.upperBound...]
            }
            #expect(!text.contains(":"))
        }

        #expect(ApprovalCardModel.clockText(for: remaining) == clock)
        let english = ApprovalCardModel.spokenTimeLeftText(for: remaining, locale: Self.english)
        #expect(english.hasSuffix("left"))
        let japanese = ApprovalCardModel.spokenTimeLeftText(for: remaining, locale: Self.japanese)
        #expect(japanese.hasPrefix("残り"))
        if englishUnits.count == 1 {
            #expect(english == "\(englishUnits[0]) left")
        }
        check(english, units: englishUnits)
        check(japanese, units: japaneseUnits)
    }

    @Test(arguments: [
        (ReviewLine(id: 1, kind: .added, text: "new value", oldLine: nil, newLine: 11), "Added, new line 11", "追加、変更後 11 行目"),
        (ReviewLine(id: 2, kind: .removed, text: "old value", oldLine: 10, newLine: nil), "Removed, old line 10", "削除、変更前 10 行目"),
        (ReviewLine(id: 3, kind: .context, text: "shared", oldLine: 12, newLine: 13), "Old line 12, new line 13", "変更前 12 行目、変更後 13 行目")
    ])
    func reviewLineAccessibilityText_namesItsSideAndKind(line: ReviewLine, english: String, japanese: String) {
        #expect(line.spokenPosition(locale: Self.english) == english)
        #expect(line.spokenPosition(locale: Self.japanese) == japanese)
    }

    private struct CommentSpan: Sendable {
        var oldStart: Int?
        var oldEnd: Int?
        var newStart: Int?
        var newEnd: Int?

        func text(in locale: Locale) -> String {
            ReviewComment.spokenPosition(oldStart: oldStart, oldEnd: oldEnd, newStart: newStart, newEnd: newEnd, locale: locale)
        }
    }

    @Test(arguments: [
        (CommentSpan(newStart: 12, newEnd: 18), "Lines 12 to 18", "12 から 18 行目"),
        (.init(oldStart: 10, oldEnd: 10, newStart: 12, newEnd: 12), "Old line 10, new line 12", "変更前 10 行目、変更後 12 行目"),
        (.init(oldStart: 9), "Line 9", "9 行目"),
        (
            .init(oldStart: 18, oldEnd: 12, newStart: 31, newEnd: 29),
            "Old line 12 to 18, new line 29 to 31",
            "変更前 12 から 18 行目、変更後 29 から 31 行目"
        )
    ])
    private func commentAccessibilityText_namesItsLineOrSpan(span: CommentSpan, english: String, japanese: String) {
        #expect(span.text(in: Self.english) == english)
        #expect(span.text(in: Self.japanese) == japanese)
    }

    @Test func aHunksComment_isNamedByItsLine_notItsHeader() throws {
        /// The header the parse reads off a hunk's `@@` line.
        func header(_ line: String, _ body: String) throws -> ReviewHunkHeader? {
            try ReviewDiffParser.parse("\(line)\n\(body)").first?.hunkHeader
        }
        #expect(try ReviewHunkCommentText.commentLabel(
            header: header("@@ -3,3 +5,4 @@ func foo()", " a\n b\n+c\n d"),
            locale: Self.english
        ) == "Comment on the Hunk at Line 5")
        #expect(
            try ReviewHunkCommentText.commentLabel(header: header("@@ -3 +5 @@", " a"), locale: Self.japanese)
                == "5 行目からのハンクにコメント"
        )
        #expect(ReviewHunkCommentText.commentLabel(header: nil, locale: Self.english) == "Comment")
        #expect(
            try ReviewHunkCommentText.commentLabel(header: header("@@ -1,3 +0,0 @@", "-a\n-b\n-c"), locale: Self.english)
                == "Comment on the Hunk at Line 1",
            "a deleted file's hunk is named by its old side"
        )
    }

    @Test func theFileListsProgress_isReadWithoutItsSlash() {
        let progress = ReviewReadingProgress(fileIDs: ["a", "b", "c"], viewed: ["a"])
        #expect(ReviewStackText.spokenProgress(progress, locale: Self.english) == "1 of 3 viewed")
        #expect(ReviewStackText.spokenProgress(progress, locale: Self.japanese) == "3 件中 1 件を確認済み")
    }

    @Test(arguments: [
        (String?.some("feat/pricing"), String?.none, "weir, feat/pricing", "weir、feat/pricing"),
        (nil, nil, "weir", "weir"),
        ("legacy-branch", "fix-tax", "weir, fix-tax", "weir、fix-tax"),
        ("legacy-branch", "weir", "weir", "weir")
    ])
    func cardPlaceAccessibilityText_usesCheckoutBeforeBranch(
        branch: String?,
        checkout: String?,
        english: String,
        japanese: String
    ) {
        #expect(AllProjectsText.spokenPlace(project: "weir", branch: branch, checkout: checkout, locale: Self.english) == english)
        #expect(AllProjectsText.spokenPlace(project: "weir", branch: branch, checkout: checkout, locale: Self.japanese) == japanese)
    }
}
