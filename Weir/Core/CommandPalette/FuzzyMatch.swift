// FuzzyMatch.swift
// Weir — subsequence fuzzy matching, scored with bonuses for word-start,
// consecutive, CamelCase, and exact-case matches and a penalty for gaps.

import Foundation

enum FuzzyMatch {

    struct Result: Equatable {
        let score: Int
        let matchedIndices: [Int]
    }

    // MARK: - Bonuses / penalties

    private static let baseMatch = 16
    private static let wordStartBonus = 32
    private static let camelCaseBonus = 24
    private static let consecutiveBonus = 16
    private static let exactCaseBonus = 8
    private static let gapPenalty = -3

    // MARK: - Separators

    private static let separators: Set<Character> = [" ", "/", "-", "_", ".", "\\"]

    // MARK: - Public API

    /// Returns nil when the query cannot be matched against the candidate.
    /// Empty query matches everything with score 0.
    static func score(query: String, candidate: String) -> Result? {
        if query.isEmpty {
            return Result(score: 0, matchedIndices: [])
        }
        if candidate.isEmpty {
            return nil
        }

        let q = Array(query.lowercased())
        let cLower = Array(candidate.lowercased())
        let cOriginal = Array(candidate)
        let qOriginal = Array(query)
        let qLen = q.count
        let cLen = cLower.count

        if qLen > cLen {
            return nil
        }

        // scores[i][j] = best score aligning all of query[0..<i] within
        // candidate[0..<j]; matches[i][j] = the same, with query[i-1]
        // matched at candidate[j-1]. nil means no such alignment exists.
        // We keep no Smith-Waterman floor: a floor lets a character score
        // with no alignment of the ones before it, and the best cell of the
        // last row then cannot be traced back to every query character, so
        // a real subsequence came back as no match. Without it a long gap
        // only lowers the score, and any cell with a score is a full
        // alignment.
        var scores = [[Int?]](repeating: [Int?](repeating: nil, count: cLen + 1), count: qLen + 1)
        var matches = [[Int?]](repeating: [Int?](repeating: nil, count: cLen + 1), count: qLen + 1)
        // Whether matches[i][j] is best reached by matching query[i-2] at
        // candidate[j-2] too. The consecutive bonus belongs to that path
        // alone: asking only whether some match ends just before credited
        // the run to an alignment that skipped there.
        var extendsARun = [[Bool]](repeating: [Bool](repeating: false, count: cLen + 1), count: qLen + 1)
        for j in 0...cLen {
            scores[0][j] = 0
        }

        for i in 1...qLen {
            for j in i...cLen {
                if q[i - 1] == cLower[j - 1], let previous = scores[i - 1][j - 1] {
                    let bonus = matchBonus(query: qOriginal[i - 1], candidate: cOriginal, at: j - 1)
                    let fresh = previous + bonus
                    if let run = matches[i - 1][j - 1].map({ $0 + bonus + consecutiveBonus }), run > fresh {
                        matches[i][j] = run
                        extendsARun[i][j] = true
                    } else {
                        matches[i][j] = fresh
                    }
                }
                let skipped = scores[i][j - 1].map { $0 + gapPenalty }
                if let skipped, let match = matches[i][j] {
                    scores[i][j] = max(skipped, match)
                } else {
                    scores[i][j] = skipped ?? matches[i][j]
                }
            }
        }

        // The characters after the last match cost nothing, so we take the
        // best cell of the last row rather than its rightmost one.
        var best: (score: Int, j: Int)?
        for j in qLen...cLen {
            if let score = scores[qLen][j], score > best?.score ?? Int.min {
                best = (score, j)
            }
        }
        guard let best else {
            return nil
        }

        let matched = traceback(from: (qLen, best.j), scores: scores, matches: matches, extendsARun: extendsARun)
        return Result(score: best.score, matchedIndices: matched)
    }

    /// The candidate indices the best alignment ending at `cell` matched.
    /// Every cell with a score came from a match or from the cell to its
    /// left, so this always consumes every query character. A match that
    /// extends a run must be preceded by the match just before it, which
    /// its score counted.
    private static func traceback(
        from cell: (i: Int, j: Int),
        scores: [[Int?]],
        matches: [[Int?]],
        extendsARun: [[Bool]]
    ) -> [Int] {
        var matched: [Int] = []
        var (i, j) = cell
        var mustMatch = false
        while i > 0 {
            if mustMatch || (matches[i][j] != nil && matches[i][j] == scores[i][j]) {
                matched.append(j - 1)
                mustMatch = extendsARun[i][j]
                i -= 1
            }
            j -= 1
        }
        return matched.reversed()
    }

    /// What matching `query` at `candidate[index]` is worth, by where it
    /// falls in the candidate. The consecutive bonus depends on the path, so
    /// the caller adds it.
    private static func matchBonus(query: Character, candidate: [Character], at index: Int) -> Int {
        var bonus = baseMatch

        // Word-start: preceded by separator or is the first character.
        if index == 0 || separators.contains(candidate[index - 1]) {
            bonus += wordStartBonus
        }

        // CamelCase: lowercase → uppercase boundary.
        if index > 0, candidate[index - 1].isLowercase, candidate[index].isUppercase {
            bonus += camelCaseBonus
        }

        // Exact case match.
        if query == candidate[index] {
            bonus += exactCaseBonus
        }
        return bonus
    }
}
