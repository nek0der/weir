// PaneAttentionFrame.swift
// Weir — the frame around a pane whose agent waits on the person or stopped.

import SwiftUI

/// A thin inner frame (`paneAttentionFrameWidth`) around the whole pane,
/// header and decision bar included: amber while the pane's agent waits
/// for an answer or an approval, red once it stopped.
/// It blinks once, for 600ms, when it appears, and not under Reduce
/// Motion. An unread turn has none: it is not urgent. The keyboard stays
/// with the terminal. Where the pane
/// meets the edges of the session's surface, the frame steps inside the
/// surface's border and follows its rounded corners, so none of it is
/// covered or cut (`SurfaceFrameFit`).
struct PaneAttentionFrame: View {
    let paneID: UUID
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false
    @State private var blink: Task<Void, Never>?
    /// Which of the pane's edges and corners are the surface's, read from
    /// the pane's place on it.
    @State private var fit = SurfaceFrameFit.none

    var body: some View {
        let attention = PaneAttention.of(attentionQueue.queue.items(inPane: paneID))
        ZStack {
            if let attention {
                PaneFrameStroke(
                    paneID: paneID,
                    fit: fit,
                    color: attention.isWaiting ? SupervisionTokens.waiting.color : SupervisionTokens.stopped.color,
                    lineWidth: WeirLayout.Supervision.paneAttentionFrameWidth
                )
                .opacity(isDimmed ? 0.2 : 1)
            }
        }
        // The pane's whole face, frame or not, so its place is known before
        // the frame first shows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The pane's place and the surface's size in one reading, so a
        // resize never pairs one moment's place with another's size.
        .onGeometryChange(for: SurfaceFrameFit.self) { proxy in
            SurfaceFrameFit.fit(size: proxy.size, surfaceBounds: proxy.bounds(of: .named(SupervisionWindowView.surfaceSpace)))
        } action: { newFit in
            fit = newFit
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if attention != nil {
                blinkOnce()
            }
        }
        // Once when it appears, and again only when its color changes: an
        // approval followed by a question is still the same amber frame.
        .onChange(of: attention) { previous, current in
            if let current, previous?.isWaiting != current.isWaiting {
                blinkOnce()
            }
        }
        .onDisappear { blink?.cancel() }
    }

    private func blinkOnce() {
        blink?.cancel()
        guard !reduceMotion else { return }
        blink = Task { @MainActor in
            withAnimation(WeirMotion.attentionBlinkHalf) { isDimmed = true }
            try? await Task.sleep(for: .seconds(WeirMotion.attentionBlinkHalfDuration))
            // Canceled or not, the frame ends drawn in full.
            withAnimation(WeirMotion.attentionBlinkHalf) { isDimmed = false }
        }
    }
}

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
