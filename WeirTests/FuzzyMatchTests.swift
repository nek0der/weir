// FuzzyMatchTests.swift
// Weir — the palette's fuzzy match: what matches, at which characters, and which match ranks higher.

import Foundation
import Testing
@testable import Weir

@Suite("FuzzyMatch")
struct FuzzyMatchTests {
    /// The first query's match of `candidate` outranks the second's: an
    /// exact substring over scattered characters, word starts over the
    /// middle of a word, consecutive characters over spread ones.
    @Test("a better match scores higher", arguments: [
        ("New", "Nwa", "New Tab"),
        ("nt", "ew", "New Tab"),
        ("Sp", "St", "Split Right")
    ])
    func aBetterMatch_scoresHigher(better: String, worse: String, candidate: String) throws {
        let high = try #require(FuzzyMatch.score(query: better, candidate: candidate))
        let low = try #require(FuzzyMatch.score(query: worse, candidate: candidate))
        #expect(high.score > low.score)
    }

    @Test("empty query matches everything with score 0", arguments: ["anything", ""])
    func emptyQuery_matchesAll(candidate: String) throws {
        let result = try #require(FuzzyMatch.score(query: "", candidate: candidate))
        #expect(result.score == 0)
        #expect(result.matchedIndices.isEmpty)
    }

    @Test("no match returns nil")
    func noMatch_returnsNil() {
        #expect(FuzzyMatch.score(query: "xyz", candidate: "New Tab") == nil)
        #expect(FuzzyMatch.score(query: "x", candidate: "") == nil)
    }

    @Test("case insensitive matching works")
    func caseInsensitive() throws {
        let match = try #require(FuzzyMatch.score(query: "new tab", candidate: "New Tab"))
        let exactCase = try #require(FuzzyMatch.score(query: "New Tab", candidate: "New Tab"))
        #expect(match.matchedIndices == Array(0..<7))
        #expect(exactCase.score > match.score)
    }

    @Test("matched indices are the characters matched")
    func matchedIndices_areTheCharactersMatched() throws {
        let result = try #require(FuzzyMatch.score(query: "NT", candidate: "New Tab"))
        // N and T.
        #expect(result.matchedIndices == [0, 4])
    }

    /// Every query that is a subsequence of the candidate matches it, at
    /// characters that spell the query in order. A long gap only lowers the
    /// score: a query's last character standing alone at a word start
    /// before the rest once outscored the real match and lost it.
    @Test("a subsequence always matches", arguments: [
        ("ab", "B axxxxxxxxxxxxxxxxxxxxxxxb"),
        ("nt", "Tx nxxxxxxxxxxxxxxxxxxxxxxt"),
        ("ab", "axxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxb"),
        ("fix", "feature/x-indexing-for-the-review-and-fix"),
        ("wr", "Weir"),
        ("éz", "👩🏽‍💻 e\u{0301}Z")
    ])
    func aSubsequence_alwaysMatches(query: String, candidate: String) throws {
        let result = try #require(FuzzyMatch.score(query: query, candidate: candidate))
        let characters = Array(candidate.lowercased())
        #expect(result.matchedIndices.count == query.count)
        #expect(result.matchedIndices == result.matchedIndices.sorted())
        try #require(result.matchedIndices.allSatisfy(characters.indices.contains))
        #expect(String(result.matchedIndices.map { characters[$0] }) == query.lowercased())
    }

    /// A long gap costs: the same two characters close together outrank
    /// the pair far apart.
    @Test func aLongGap_scoresLower() throws {
        let near = try #require(FuzzyMatch.score(query: "ab", candidate: "axb"))
        let far = try #require(FuzzyMatch.score(query: "ab", candidate: "axxxxxxxxxxxxxxxxxxxxxxxxxxxxxb"))
        #expect(near.score > far.score)
    }

    /// The consecutive bonus goes only to a path whose characters touch.
    /// "abc" in the first name matches "ab" then a far "c", or "a" then a
    /// far "bc", and neither path is both consecutive and short, so the
    /// second name, with the shorter gap, outranks it.
    @Test func aRun_isCountedOnlyOnThePathThatHasIt() throws {
        let split = try #require(FuzzyMatch.score(
            query: "abc",
            candidate: "ab" + String(repeating: "x", count: 40) + "bc"
        ))
        let shorter = try #require(FuzzyMatch.score(
            query: "abc",
            candidate: "ab" + String(repeating: "x", count: 37) + "c"
        ))
        #expect(shorter.score > split.score)
        #expect(split.score == -3)
    }

    @Test("characters out of order do not match")
    func outOfOrder_doesNotMatch() {
        #expect(FuzzyMatch.score(query: "ba", candidate: "ab") == nil)
        #expect(FuzzyMatch.score(query: "aa", candidate: "a") == nil)
    }
}
