// PaneFrameSeamTests.swift
// Weir — a pane's frame reaches over a seam onto the frames beyond, and crosses the seam where its line runs on.

import SwiftUI
import Testing
@testable import Weir

/// Panes on a Retina grid, a half-point seam apart.
struct PaneFrameSeamTests {
    private let seam: CGFloat = 0.5
    private let lineWidth: CGFloat = 1.5
    private let upperLeft = UUID()
    private let upperRight = UUID()
    private let lower = UUID()

    /// Two panes side by side over one that spans both.
    private var frames: [UUID: CGRect] {
        [
            upperLeft: CGRect(x: 0, y: 0, width: 100, height: 50),
            upperRight: CGRect(x: 100.5, y: 0, width: 99.5, height: 50),
            lower: CGRect(x: 0, y: 50.5, width: 200, height: 50)
        ]
    }

    private func reach(
        of pane: UUID,
        framed: Set<UUID>,
        frames: [UUID: CGRect]? = nil,
        seamWidth: CGFloat? = nil
    ) -> PaneFrameReach {
        let frames = frames ?? self.frames
        return PaneFrameSeam.reach(
            of: frames[pane] ?? .zero,
            beside: frames.filter { $0.key != pane },
            seamWidth: seamWidth ?? seam,
            isFramed: framed.contains
        )
    }

    private func band(_ reach: PaneFrameReach, width: CGFloat = 200, height: CGFloat = 50) -> PaneFrameBand {
        PaneFrameBand(in: CGRect(x: 0, y: 0, width: width, height: height), fit: .none, lineWidth: lineWidth, seamWidth: seam, reach: reach)
    }

    // MARK: - Which edges reach

    @Test func anEdgeFacingOneFramedPaneOfTwo_reachesAsAWhole() {
        #expect(reach(of: lower, framed: [upperLeft]).top)
        #expect(reach(of: lower, framed: [upperRight]).top)
    }

    @Test func anEdgeFacingNoFramedPane_staysOnItsOwnEdge() {
        #expect(reach(of: lower, framed: []) == PaneFrameReach())
    }

    @Test func theLeadingEdge_reachesOntoThePaneBeforeIt_andTheTopEdgeOntoNone() {
        let reach = reach(of: upperRight, framed: [upperLeft, lower])
        #expect(reach.leading)
        #expect(!reach.top, "the pane below draws that seam, not this one")
    }

    @Test func aPaneThatOnlyTouchesACorner_facesNoneOfTheEdge() {
        let frames: [UUID: CGRect] = [
            upperLeft: CGRect(x: 0, y: 0, width: 100, height: 50),
            lower: CGRect(x: 100.5, y: 50.5, width: 100, height: 50)
        ]
        #expect(reach(of: lower, framed: [upperLeft], frames: frames) == PaneFrameReach())
    }

    @Test func aPaneAPixelFurtherThanTheSeam_isNotAcrossIt() {
        let frames: [UUID: CGRect] = [
            upperLeft: CGRect(x: 0, y: 0, width: 100, height: 50),
            lower: CGRect(x: 0, y: 51, width: 100, height: 50)
        ]
        #expect(reach(of: lower, framed: [upperLeft], frames: frames) == PaneFrameReach())
    }

    @Test func onA1xDisplay_theSeamIsAWholePoint() {
        let frames: [UUID: CGRect] = [
            upperLeft: CGRect(x: 0, y: 0, width: 100, height: 50),
            upperRight: CGRect(x: 101, y: 0, width: 99, height: 50)
        ]
        #expect(reach(of: upperRight, framed: [upperLeft], frames: frames, seamWidth: 1).leading)
    }

    // MARK: - The band

    @Test func aLiftedEdge_liesOnTheFrameBeyond_andLeavesItsOwnEdge() {
        let frame = band(PaneFrameReach(top: true))
        let lifted = -seam - lineWidth / 2
        #expect(frame.contains(CGPoint(x: 100, y: lifted)))
        #expect(!frame.contains(CGPoint(x: 100, y: lineWidth / 2)))
        // The leading line, still on its own edge, keeps its corner.
        #expect(frame.contains(CGPoint(x: lineWidth / 2, y: lineWidth / 2)))
    }

    @Test func theLinesAcrossTheSeam_bridgeIt_andTheHairlineStillShowsAlongIt() {
        // The right-hand pane of two side by side, both framed.
        let frame = band(PaneFrameReach(leading: true), width: 100)
        #expect(frame.contains(CGPoint(x: -seam / 2, y: lineWidth / 2)))
        #expect(frame.contains(CGPoint(x: -seam / 2, y: 50 - lineWidth / 2)))
        #expect(!frame.contains(CGPoint(x: -seam / 2, y: 25)))
        #expect(!frame.contains(CGPoint(x: 50, y: 25)), "the pane's face stays clear")
    }

    @Test func aCornerWhoseLinesAreBothLifted_leavesNoSquareBehind() {
        let frame = band(PaneFrameReach(top: true, leading: true))
        #expect(!frame.contains(CGPoint(x: lineWidth / 2, y: lineWidth / 2)))
        #expect(frame.contains(CGPoint(x: -seam - lineWidth / 2, y: 10)))
        #expect(frame.contains(CGPoint(x: 10, y: -seam - lineWidth / 2)))
        // The trailing line, never lifted, keeps its corner.
        #expect(frame.contains(CGPoint(x: 200 - lineWidth / 2, y: lineWidth / 2)))
    }
}
