// ReviewRowGlyphTests.swift
// Weir — when a changed line shows + or − beside its fill, and the mark after a line whose ending changed.

import AppKit
import Testing
@testable import Weir

@MainActor
struct ReviewRowGlyphTests {
    private struct GlyphCase: Sendable {
        let isSelected: Bool
        let differentiatesWithoutColor: Bool
        let signs: [String?]
    }

    @Test(arguments: [
        GlyphCase(isSelected: true, differentiatesWithoutColor: false, signs: ["+", "\u{2212}"]),
        GlyphCase(isSelected: true, differentiatesWithoutColor: true, signs: ["+", "\u{2212}"]),
        GlyphCase(isSelected: false, differentiatesWithoutColor: true, signs: ["+", "\u{2212}"]),
        GlyphCase(isSelected: false, differentiatesWithoutColor: false, signs: [nil, nil])
    ])
    private func changedLinesShowSignsWhenSelectedOrDifferentiatingWithoutColor(_ input: GlyphCase) {
        let signs = [ReviewLine.Kind.added, .removed].map {
            ReviewRowPainter.kindGlyph(
                for: $0,
                isSelected: input.isSelected,
                differentiatesWithoutColor: input.differentiatesWithoutColor
            )
        }
        #expect(signs == input.signs)
    }

    @Test func aLineThatIsNotAChange_neverShowsASign() {
        for kind: ReviewLine.Kind in [.context, .hunk, .fileHeader, .marker] {
            for isSelected in [false, true] {
                #expect(ReviewRowPainter.kindGlyph(for: kind, isSelected: isSelected, differentiatesWithoutColor: true) == nil)
            }
        }
    }

    /// The mark follows the text and is not part of it, so what a comment
    /// quotes and what a selection measures stay the line's own text.
    @Test func aChangedLineEnding_isDrawnAfterTheText() throws {
        let attributes = ReviewRowPainter.attributes(
            font: ReviewRowMetrics.font, color: .labelColor, alignment: .left, truncates: false
        )
        let styled = try #require(ReviewRowPainter.styled(
            "one", language: nil, match: "", attributes: attributes, intralineKind: .added, marksLineEnding: true
        ))
        #expect(styled.string == "one" + ReviewRowPainter.carriageReturnGlyph)
        let blank = try #require(ReviewRowPainter.styled(
            "", language: nil, match: "", attributes: attributes, intralineKind: .removed, marksLineEnding: true
        ))
        #expect(blank.string == ReviewRowPainter.carriageReturnGlyph)
        #expect(ReviewRowPainter.styled("one", language: nil, match: "", attributes: attributes, intralineKind: .added) == nil)
    }
}
