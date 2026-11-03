// ReviewRowGlyphTests.swift
// Weir — when a changed line shows + or − beside its fill, and the mark after a line whose ending changed.

import AppKit
import Testing
@testable import Weir

@MainActor
struct ReviewRowGlyphTests {
    @Test func aSelectedChangedLine_showsItsSign_sinceTheFillIsTheAccent() {
        #expect(ReviewRowPainter.kindGlyph(for: .added, isSelected: true, differentiatesWithoutColor: false) == "+")
        #expect(ReviewRowPainter.kindGlyph(for: .removed, isSelected: true, differentiatesWithoutColor: false) == "\u{2212}")
    }

    @Test func differentiateWithoutColor_showsTheSign_onEveryChangedLine() {
        #expect(ReviewRowPainter.kindGlyph(for: .added, isSelected: false, differentiatesWithoutColor: true) == "+")
        #expect(ReviewRowPainter.kindGlyph(for: .removed, isSelected: false, differentiatesWithoutColor: true) == "\u{2212}")
    }

    @Test func anUnselectedLine_leavesItToTheFill() {
        #expect(ReviewRowPainter.kindGlyph(for: .added, isSelected: false, differentiatesWithoutColor: false) == nil)
        #expect(ReviewRowPainter.kindGlyph(for: .removed, isSelected: false, differentiatesWithoutColor: false) == nil)
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
