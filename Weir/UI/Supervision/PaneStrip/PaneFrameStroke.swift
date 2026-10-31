// PaneFrameStroke.swift
// Weir — the line a frame around a pane draws, and where it meets the frame of the pane beside it.

import SwiftUI

/// The line a frame around a pane draws. Where the pane meets another framed
/// pane above or before it, it reaches over the divider to lie on that pane's
/// frame, so the seam of the two is one line, drawn in the later pane's color.
/// Beside an unframed pane it stays on its own: there it would stand apart from
/// its pane, on the neighbor's face.
struct PaneFrameStroke: View {
    let paneID: UUID
    let fit: SurfaceFrameFit
    let color: Color
    let lineWidth: CGFloat
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionQueueStore.self) private var attentionQueue

    var body: some View {
        UnevenRoundedRectangle(cornerRadii: fit.radii, style: .continuous)
            .strokeBorder(color, lineWidth: lineWidth)
            .padding(seamedFit.insets)
    }

    private var seamedFit: SurfaceFrameFit {
        guard let tab = session.tab(containing: paneID) else { return fit }
        let reach = PaneFrameSeam.reach(of: paneID, in: tab.splitTree, zoomedLeafID: tab.zoomedLeafID, isFramed: isFramed)
        return fit.reachingAcross(top: reach.top, leading: reach.leading, by: PaneSplit.dividerThickness + lineWidth)
    }

    private func isFramed(_ pane: UUID) -> Bool {
        PaneAttention.of(attentionQueue.queue.items(inPane: pane)) != nil
    }
}

/// Which edges of a pane's frame reach over a divider onto the frame beyond.
enum PaneFrameSeam {
    /// A zoomed pane stands alone, with no seam whatever the tree holds. Past
    /// a divider, every pane along it has to be framed, not just one: the tree
    /// does not say which of them this pane touches, and a line moved for one
    /// that it does not would stand apart from this pane on another's face.
    static func reach(
        of paneID: UUID,
        in tree: SplitTree,
        zoomedLeafID: UUID?,
        isFramed: (UUID) -> Bool
    ) -> (top: Bool, leading: Bool) {
        guard zoomedLeafID != paneID else { return (false, false) }
        let before = tree.panesBefore(paneID)
        return (
            !before.above.isEmpty && before.above.allSatisfy(isFramed),
            !before.leading.isEmpty && before.leading.allSatisfy(isFramed)
        )
    }
}
