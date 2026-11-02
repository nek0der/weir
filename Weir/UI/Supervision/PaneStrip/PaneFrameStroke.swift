// PaneFrameStroke.swift
// Weir — the line a frame around a pane draws, and where it meets the frame of the pane beside it.

import SwiftUI

/// The line a frame around a pane draws, on the pane's place on the surface
/// (`PanePlacementStore`). Where its top or leading edge faces a pane the
/// same kind of frame surrounds, that whole edge reaches over the seam to
/// lie on the frames beyond, so they meet as one line, drawn in the later
/// pane's color. The edge moves as a whole even when it also faces panes
/// without that frame: there it lies on their outermost pixels, which is
/// less wrong than a line that steps sideways where one neighbor ends and
/// the next begins.
///
/// It stays in place while hidden, and goes out as it last stood: the frames
/// beside it stop counting as framed the moment they start going out too,
/// and a line that went back to its own edge as it faded would stand beside
/// theirs for that moment.
struct PaneFrameStroke: View {
    let paneID: UUID
    /// The frame's color, `nil` while it does not show.
    let color: Color?
    let lineWidth: CGFloat
    /// Whether this kind of frame surrounds a pane, asked of the panes across
    /// a seam. The frame that decides whether it shows on this pane passes
    /// the same rule, so a seam is judged by what the neighbor actually draws:
    /// a frame of another kind lies in another layer, and a line reaching onto
    /// it would stand on top of its color or under it.
    let isFramed: (UUID) -> Bool
    @Environment(WorkspaceSession.self) private var session
    @Environment(PanePlacementStore.self) private var placements
    /// The pixel grid the seam is laid on, which sets how far the frame
    /// reaches over it.
    @Environment(\.displayScale) private var displayScale
    /// What the frame last drew while it showed, drawn as it goes out.
    @State private var lastShown: Drawn?

    private struct Drawn: Equatable {
        var color: Color
        var fit: SurfaceFrameFit
        var reach: PaneFrameReach
    }

    var body: some View {
        let seamWidth = SplitSeamGeometry.seamWidth(displayScale: displayScale)
        // The placements are read only while the frame shows, so a hidden
        // frame is not drawn again as the panes move.
        let shown = color.flatMap { color in
            placements.placements[paneID].map {
                Drawn(color: color, fit: $0.fit, reach: reach(of: $0.frame, seamWidth: seamWidth))
            }
        }
        ZStack {
            if let drawn = shown ?? lastShown {
                let shape = { (part: PaneFrameShape.Part) in
                    PaneFrameShape(part: part, fit: drawn.fit, lineWidth: lineWidth, seamWidth: seamWidth, reach: drawn.reach)
                }
                shape(.ring)
                    .fill(drawn.color, style: FillStyle(eoFill: true))
                    .mask { shape(.ringMask).fill(style: FillStyle(eoFill: true)) }
                shape(.lifts)
                    .fill(drawn.color)
            }
        }
        .opacity(shown == nil ? 0 : 1)
        .onChange(of: shown, initial: true) { _, shown in
            if let shown {
                lastShown = shown
            }
        }
    }

    /// A zoomed pane stands alone, with no seam whatever the tab holds.
    private func reach(of frame: CGRect, seamWidth: CGFloat) -> PaneFrameReach {
        guard let tab = session.tab(containing: paneID), tab.zoomedLeafID == nil else { return PaneFrameReach() }
        let neighbors = placements.placements
            .filter { $0.key != paneID && tab.splitTree.contains(leafID: $0.key) }
            .mapValues(\.frame)
        return PaneFrameSeam.reach(of: frame, beside: neighbors, seamWidth: seamWidth, isFramed: isFramed)
    }
}

/// Which of a pane frame's edges reach over a seam onto the frames beyond.
/// Only the top and leading edges reach: the frame of the pane below or
/// after draws the seam, so a seam is drawn once.
struct PaneFrameReach: Equatable {
    var top = false
    var leading = false
}

enum PaneFrameSeam {
    /// Read from where the panes stand rather than from the split tree,
    /// which says which panes lie along a divider but not whether this
    /// pane faces them: one that only touches a corner faces none of its
    /// edge. A pane across the seam is one whose far edge is a seam's width
    /// away and which runs alongside this pane's edge.
    static func reach(
        of frame: CGRect,
        beside neighbors: [UUID: CGRect],
        seamWidth: CGFloat,
        isFramed: (UUID) -> Bool
    ) -> PaneFrameReach {
        // A frame measured in points can land a fraction off the grid; half
        // a seam still tells the pane across it from one a pixel further.
        let tolerance = seamWidth / 2
        var reach = PaneFrameReach()
        for (paneID, other) in neighbors where isFramed(paneID) {
            if abs(other.maxY + seamWidth - frame.minY) <= tolerance,
               overlaps(other.minX...other.maxX, frame.minX...frame.maxX, beyond: tolerance)
            {
                reach.top = true
            }
            if abs(other.maxX + seamWidth - frame.minX) <= tolerance,
               overlaps(other.minY...other.maxY, frame.minY...frame.maxY, beyond: tolerance)
            {
                reach.leading = true
            }
        }
        return reach
    }

    private static func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>, beyond tolerance: CGFloat) -> Bool {
        min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound) > tolerance
    }
}

/// The band a pane's frame fills, as plain pieces: the ring inside the
/// pane's edges, stepped inside the surface's border where the pane meets it
/// (`SurfaceFrameFit`); the stretches of that ring that give way; and the
/// lines laid outside the pane. It is drawn from these pieces rather than
/// joined into one outline, because `Path`'s boolean operations do not give
/// the same answer on every macOS: on macOS 26 the joined outline filled
/// what should have stayed clear.
///
/// A lifted edge's line moves a seam and a line's width out, onto the frames
/// beyond. The top-leading corner square stays while one of its two lines
/// stays on its own edge, and goes when both are lifted, or it would stand
/// alone where neither line runs. An edge with a pane across it has square
/// corners, so a lifted line never meets a rounded one. At each end of a
/// lifted line a short piece crosses the seam to the line that carries on,
/// so a frame running across a seam is not cut by it. Along the seam the
/// hairline still shows between the two panes' lines: the frames stand over
/// it (`SplitSeamLine`) only where a line crosses it.
struct PaneFrameBand: Equatable {
    var outer: CGRect
    var inner: CGRect
    var outerRadii: RectangleCornerRadii
    var innerRadii: RectangleCornerRadii
    /// Stretches of the ring's own line that give way to a lifted one.
    var gaps: [CGRect] = []
    /// The lifted lines and the pieces that cross the seam, outside the ring.
    var lifts: [CGRect] = []

    init(in rect: CGRect, fit: SurfaceFrameFit, lineWidth: CGFloat, seamWidth: CGFloat, reach: PaneFrameReach) {
        outer = CGRect(
            x: rect.minX + fit.insets.leading,
            y: rect.minY + fit.insets.top,
            width: rect.width - fit.insets.leading - fit.insets.trailing,
            height: rect.height - fit.insets.top - fit.insets.bottom
        )
        // Too small to have an inside: the whole pane is the band.
        inner = outer.width > 2 * lineWidth && outer.height > 2 * lineWidth
            ? outer.insetBy(dx: lineWidth, dy: lineWidth)
            : .zero
        outerRadii = fit.radii
        innerRadii = fit.inset(by: lineWidth).radii
        guard inner != .zero else { return }
        let lift = seamWidth + lineWidth
        if reach.top {
            let gapStart = reach.leading ? outer.minX : inner.minX
            gaps.append(CGRect(x: gapStart, y: outer.minY, width: inner.maxX - gapStart, height: lineWidth))
            lifts.append(CGRect(x: outer.minX, y: rect.minY - lift, width: outer.width, height: lineWidth))
            // Down over the seam to the leading and trailing lines. With the
            // leading line lifted too, the corner meets the frames beyond.
            let crossing = CGSize(width: lineWidth, height: lift)
            if !reach.leading {
                lifts.append(CGRect(origin: CGPoint(x: outer.minX, y: rect.minY - seamWidth), size: crossing))
            }
            lifts.append(CGRect(origin: CGPoint(x: outer.maxX - lineWidth, y: rect.minY - seamWidth), size: crossing))
        }
        if reach.leading {
            let gapStart = reach.top ? outer.minY : inner.minY
            gaps.append(CGRect(x: outer.minX, y: gapStart, width: lineWidth, height: inner.maxY - gapStart))
            lifts.append(CGRect(x: rect.minX - lift, y: outer.minY, width: lineWidth, height: outer.height))
            let crossing = CGSize(width: lift, height: lineWidth)
            if !reach.top {
                lifts.append(CGRect(origin: CGPoint(x: rect.minX - seamWidth, y: outer.minY), size: crossing))
            }
            lifts.append(CGRect(origin: CGPoint(x: rect.minX - seamWidth, y: outer.maxY - lineWidth), size: crossing))
        }
    }

    var outerPath: Path {
        UnevenRoundedRectangle(cornerRadii: outerRadii, style: .continuous).path(in: outer)
    }

    var innerPath: Path {
        UnevenRoundedRectangle(cornerRadii: innerRadii, style: .continuous).path(in: inner)
    }

    /// Whether the band covers `point`, read as it is drawn.
    func contains(_ point: CGPoint) -> Bool {
        let isInRing = outerPath.contains(point) && !innerPath.contains(point) && !gaps.contains { $0.contains(point) }
        return isInRing || lifts.contains { $0.contains(point) }
    }
}

/// One piece of a `PaneFrameBand`, as a shape to fill.
struct PaneFrameShape: Shape {
    enum Part {
        /// The outer and inner outlines, filled even-odd.
        case ring
        /// Everywhere but the gaps, filled even-odd, to mask the ring with.
        case ringMask
        /// The lifted lines and seam crossings.
        case lifts
    }

    let part: Part
    let fit: SurfaceFrameFit
    let lineWidth: CGFloat
    let seamWidth: CGFloat
    let reach: PaneFrameReach

    func path(in rect: CGRect) -> Path {
        let band = PaneFrameBand(in: rect, fit: fit, lineWidth: lineWidth, seamWidth: seamWidth, reach: reach)
        var path = Path()
        switch part {
        case .ring:
            path.addPath(band.outerPath)
            path.addPath(band.innerPath)
        case .ringMask:
            path.addRect(rect)
            for gap in band.gaps {
                path.addRect(gap)
            }
        case .lifts:
            for lift in band.lifts {
                path.addRect(lift)
            }
        }
        return path
    }
}
