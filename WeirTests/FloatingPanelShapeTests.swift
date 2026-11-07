// FloatingPanelShapeTests.swift
// Weir — a floating panel's outline, with and without its arrow.

import SwiftUI
import Testing
@testable import Weir

struct FloatingPanelShapeTests {
    private let rect = CGRect(x: 0, y: 0, width: 240, height: 70)

    @Test func withoutAnArrow_isTheContinuousRoundedRectangle() {
        // What `floatingPanelSurface(cornerRadius:)` draws, so a panel with
        // no arrow looks as it did on that surface.
        let shape = FloatingPanelShape(cornerRadius: 16, arrow: nil, arrowHeight: 10)
        #expect(shape.path(in: rect) == RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: rect))
        #expect(shape.path(in: rect).boundingRect == rect)
    }

    @Test func withAnArrow_standsOutOnTheEdgeItFaces() {
        let top = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .top, offset: 70), arrowHeight: 10)
        let topPath = top.path(in: rect)
        let bounds = topPath.boundingRect
        #expect(bounds.minY == rect.minY - 10)
        #expect(bounds.maxY == rect.maxY)
        #expect(topPath.contains(CGPoint(x: 70, y: rect.minY - 5)))
        #expect(!topPath.contains(CGPoint(x: 120, y: rect.minY - 5)))

        let bottom = FloatingPanelShape(cornerRadius: 16, arrow: .init(edge: .bottom, offset: 170), arrowHeight: 10)
        let bottomPath = bottom.path(in: rect)
        let bottomBounds = bottomPath.boundingRect
        #expect(bottomBounds.maxY == rect.maxY + 10)
        #expect(bottomBounds.minY == rect.minY)
        #expect(bottomPath.contains(CGPoint(x: 170, y: rect.maxY + 5)))
        #expect(!bottomPath.contains(CGPoint(x: 120, y: rect.maxY + 5)))
    }
}
