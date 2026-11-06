// ReviewCommentExcerptTests.swift
// Weir — a comment's quote cut at the excerpt budget: where the cut falls, what the prompt says about it, and how the
// checks against Git read it.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Review comment excerpt")
struct ReviewCommentExcerptTests {
    private static let file = FakeReviewRepository.unstagedFile
    private static let budget = ReviewSession.maxCodeExcerpt

    private static func added(_ texts: [String]) -> [ReviewLine] {
        texts.enumerated().map { index, text in
            ReviewLine(id: index, kind: .added, text: text, oldLine: nil, newLine: index + 1)
        }
    }

    /// A session showing `lines` as one file's diff, with a comment added
    /// on all of them.
    private static func comment(on lines: [ReviewLine]) async throws -> (ReviewSession, ReviewComment) {
        let repository = FakeReviewRepository()
        repository.files = [file]
        repository.diffs[file.id] = ReviewDiff(file: file, fingerprint: "f1", lines: lines)
        let store = fakeReviewSession(git: repository)
        await store.refreshAsTheAppDoes()
        await store.load(file)
        #expect(store.add(lines: lines, side: nil, body: "Extract this."))
        return try (store, #require(store.comments.first))
    }

    @Test func aRunWithinTheBudget_isQuotedWholeAndNotMarkedCut() async throws {
        let (store, comment) = try await Self.comment(on: Self.added(["let a = 1", "let b = 2"]))
        #expect(comment.code == "let a = 1\nlet b = 2")
        #expect(comment.codeCut == nil)
        let prompt = try ReviewPromptBuilder.build(root: store.root, comments: [comment], locale: Locale(identifier: "en"))
        #expect(prompt.text.contains("<code>\n+let a = 1\n+let b = 2\n</code>"))
        #expect(!prompt.text.contains("truncated"))
    }

    /// Forty lines of a hundred fit. The comment still names all hundred,
    /// so the prompt has to say its code stops early, or the agent reads
    /// forty lines as the whole selection.
    @Test func aRunLongerThanTheBudget_keepsWholeLinesAndTellsTheAgentItIsCut() async throws {
        let texts = (1...100).map { String(format: "let value%03d = %@", $0, String(repeating: "x", count: 36)) }
        let (store, comment) = try await Self.comment(on: Self.added(texts))
        let kept = comment.code.components(separatedBy: "\n")

        #expect(comment.code.utf8.count <= Self.budget)
        #expect(kept.count < texts.count)
        #expect(kept == Array(texts.prefix(kept.count)), "whole lines, in order")
        #expect(comment.codeMarkers?.count == kept.count)
        #expect(comment.codeCut == .betweenLines)
        #expect(comment.promptSpan == "1-100", "the comment names the run the reader chose")

        let prompt = try ReviewPromptBuilder.build(root: store.root, comments: [comment], locale: Locale(identifier: "en"))
        #expect(prompt.text.contains("lines=\"1-100\""))
        #expect(prompt.text.contains("<code truncated=\"true\">\n+let value001"))
    }

    /// A cut that fell between the scalars of a character sent half of it:
    /// a letter without its accent, one flag's first regional indicator.
    @Test(arguments: ["e\u{0301}", "\u{1F1EF}\u{1F1F5}", "\u{1F469}\u{200D}\u{1F4BB}"])
    func aLongLineIsCutBetweenCharacters(_ character: String) async throws {
        let head = String(repeating: "a", count: Self.budget - 1)
        let (_, comment) = try await Self.comment(on: Self.added([head + character + "tail"]))
        #expect(comment.code == head)
        #expect(comment.codeCut == .withinLine)
    }

    /// A character larger than the whole budget is the one cut between
    /// scalars, since a cut between characters would quote nothing.
    @Test func aCharacterLargerThanTheBudget_isCutBetweenItsScalars() async throws {
        let text = "a" + String(repeating: "\u{0301}", count: 10000)
        let (_, comment) = try await Self.comment(on: Self.added([text]))
        #expect(!comment.code.isEmpty)
        #expect(comment.code.utf8.count <= Self.budget)
        #expect(comment.codeCut == .withinLine)
        #expect(ReviewCommentRelocation.quotesCurrentCode(comment, current: [text]))
    }

    /// A comment on a minified line quotes its start. Compared whole, that
    /// start matched no line in any file, so the comment was held back as
    /// moved every time a range was inserted, and never moved into a scope.
    @Test func aCutLine_isFoundByItsStart() async throws {
        let line = String(repeating: "m", count: Self.budget * 3)
        let (_, comment) = try await Self.comment(on: Self.added(["before", line]))
        #expect(comment.code == "before")
        #expect(comment.codeCut == .betweenLines)
        let (_, minified) = try await Self.comment(on: Self.added([line]))
        #expect(minified.code.utf8.count == Self.budget)

        #expect(ReviewCommentRelocation.quotesCurrentCode(minified, current: [line]))
        #expect(!ReviewCommentRelocation.quotesCurrentCode(minified, current: [String(repeating: "n", count: Self.budget * 3)]))
        let target = ReviewFile(path: Self.file.path, layer: .turns, status: .modified)
        let diff = ReviewDiff(file: target, fingerprint: "new", lines: [
            ReviewLine(id: 0, kind: .context, text: "keep", oldLine: 1, newLine: 1),
            ReviewLine(id: 1, kind: .added, text: line, oldLine: nil, newLine: 2)
        ])
        guard case let .placed(moved) = ReviewCommentRelocation.placement(of: minified, in: diff, scopeID: "s") else {
            Issue.record("the cut line is in the diff once")
            return
        }
        #expect(moved.anchor.newLine == 2)
        #expect(moved.codeCut == .withinLine)
    }

    /// Only a line the quote cut in its middle matches by its start. A
    /// quote of whole lines with later lines left out compares each one
    /// whole: an empty last line would otherwise match any line at all.
    @Test func onlyALineCutInItsMiddle_matchesByItsStart() async throws {
        let long = String(repeating: "m", count: Self.budget * 2)
        let (_, comment) = try await Self.comment(on: Self.added(["before", "", long]))
        #expect(comment.code == "before\n")
        #expect(comment.codeCut == .betweenLines)
        #expect(ReviewCommentRelocation.quotesCurrentCode(comment, current: ["before", ""]))
        #expect(!ReviewCommentRelocation.quotesCurrentCode(comment, current: ["before", "changed"]))

        let whole = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            code: "let a\nlet b",
            codeMarkers: "++",
            codeCut: .betweenLines,
            body: "Why?"
        )
        #expect(!ReviewCommentRelocation.quotesCurrentCode(whole, current: ["let a", "let b = 2"]))
        var cut = whole
        cut.codeCut = .withinLine
        #expect(ReviewCommentRelocation.quotesCurrentCode(cut, current: ["let a", "let b = 2"]))
        #expect(!ReviewCommentRelocation.quotesCurrentCode(cut, current: ["let a = 1", "let b"]))
    }

    /// Stored only when the quote is cut, so a draft that holds none reads
    /// and writes as it did, and a draft from before the key reads as whole.
    /// A cut a later build adds is still read as a cut.
    @Test func theCutIsStoredOnlyWhenThereIsOne() throws {
        let whole = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            code: "x",
            codeMarkers: "+",
            body: "Why?"
        )
        var cut = whole
        cut.codeCut = .withinLine
        let encoder = JSONEncoder()
        let wholeJSON = try #require(String(data: encoder.encode(whole), encoding: .utf8))
        #expect(!wholeJSON.contains("codeCut"))
        #expect(try JSONDecoder().decode(ReviewComment.self, from: Data(wholeJSON.utf8)).codeCut == nil)
        let cutJSON = try #require(String(data: encoder.encode(cut), encoding: .utf8))
        #expect(cutJSON.contains("\"codeCut\":\"withinLine\""))
        #expect(try JSONDecoder().decode(ReviewComment.self, from: Data(cutJSON.utf8)).codeCut == .withinLine)
        let later = cutJSON.replacingOccurrences(of: "withinLine", with: "somewhereNew")
        #expect(try JSONDecoder().decode(ReviewComment.self, from: Data(later.utf8)).codeCut == .betweenLines)
    }

    /// A comment saved before the cut was recorded, on a minified line: the
    /// build that saved it cut the line between scalars and stored no
    /// `codeCut`. Its quote is found by its start, so it is inserted and
    /// moves into a scope rather than being held back on every insert, and
    /// the prompt still says nothing it cannot know.
    @Test func aDraftFromBeforeTheCutWasRecorded_findsItsCutLineByItsStart() throws {
        let line = String(repeating: "\u{1F600}", count: Self.budget)
        let saved = String(line.unicodeScalars.prefix(Self.budget / 4 - 1).map(Character.init))
        let quoteBytes = saved.utf8.count + 3
        #expect(quoteBytes > Self.budget - 4 && quoteBytes <= Self.budget)
        let draft = """
        {"id":"\(UUID().uuidString)","scopeIDs":["turns:r"],\
        "file":{"path":"min.js","layer":"turns","status":"M"},"fingerprint":"f1",\
        "anchor":{"lineID":1,"newLine":2},"code":"abc\(saved)","codeMarkers":"+","body":"Split this."}
        """
        let comment = try JSONDecoder().decode(ReviewComment.self, from: Data(draft.utf8))
        #expect(comment.codeCut == nil)
        #expect(comment.comparedCut == .withinLine)
        #expect(!comment.isQuoteCut, "the prompt says only a recorded cut")

        let current = ["start", "abc" + line]
        #expect(ReviewCommentRelocation.quotesCurrentCode(comment, current: current))
        #expect(!ReviewCommentRelocation.quotesCurrentCode(comment, current: ["start", "abd" + line]))
        let target = ReviewFile(path: "min.js", layer: .turns, status: .modified)
        let diff = ReviewDiff(file: target, fingerprint: "new", lines: [
            ReviewLine(id: 0, kind: .context, text: "start", oldLine: 1, newLine: 1),
            ReviewLine(id: 1, kind: .added, text: "abc" + line, oldLine: nil, newLine: 2)
        ])
        guard case let .placed(moved) = ReviewCommentRelocation.placement(of: comment, in: diff, scopeID: "s") else {
            Issue.record("the cut line is in the diff once")
            return
        }
        #expect(moved.anchor.newLine == 2)
        #expect(moved.codeCut == nil, "nothing is recorded that the draft did not")
    }

    /// A short quote with no recorded cut is whole, and a line that only
    /// starts with it is another line.
    @Test func aShortQuoteWithNoRecordedCut_isComparedWhole() {
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            code: String(repeating: "a", count: Self.budget - 4),
            codeMarkers: "+",
            body: "Why?"
        )
        #expect(comment.comparedCut == nil)
        #expect(!ReviewCommentRelocation.quotesCurrentCode(comment, current: [comment.code + "b"]))
    }

    /// A comment moved into another scope names only the lines its quote
    /// kept, so a quote that left later lines out is whole there; a line cut
    /// in its middle is still cut.
    @Test func aMovedComment_keepsOnlyACutWithinItsLine() {
        let target = ReviewFile(path: Self.file.path, layer: .turns, status: .modified)
        let diff = ReviewDiff(file: target, fingerprint: "new", lines: [
            ReviewLine(id: 0, kind: .added, text: "let a", oldLine: nil, newLine: 1),
            ReviewLine(id: 1, kind: .added, text: "let b = 2", oldLine: nil, newLine: 2)
        ])
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            code: "let a",
            codeMarkers: "+",
            codeCut: .betweenLines,
            body: "Why?"
        )
        guard case let .placed(whole) = ReviewCommentRelocation.placement(of: comment, in: diff, scopeID: "s") else {
            Issue.record("the kept line is in the diff once")
            return
        }
        #expect(whole.codeCut == nil)
        #expect(whole.end == nil, "it names the one line it kept")

        let lineCut = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            code: "let a\nlet b",
            codeMarkers: "++",
            codeCut: .withinLine,
            body: "Why?"
        )
        guard case let .placed(cut) = ReviewCommentRelocation.placement(of: lineCut, in: diff, scopeID: "s") else {
            Issue.record("the quote is in the diff once")
            return
        }
        #expect(cut.codeCut == .withinLine)
    }
}
