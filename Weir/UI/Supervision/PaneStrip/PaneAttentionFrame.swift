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

    var body: some View {
        let attention = attention(of: paneID)
        PaneFrameStroke(
            paneID: paneID,
            color: attention.map { $0.isWaiting ? SupervisionTokens.waiting.color : SupervisionTokens.stopped.color },
            lineWidth: WeirLayout.Supervision.paneAttentionFrameWidth,
            isFramed: { self.attention(of: $0) != nil }
        )
        .opacity(isDimmed ? 0.2 : 1)
        // The pane's whole face, frame or not, so it appears with the pane
        // and its first frame blinks.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// What frames a pane, this one or one past a divider: one rule for both,
    /// so a seam joins only the frames that are drawn.
    private func attention(of pane: UUID) -> PaneAttention? {
        PaneAttention.of(attentionQueue.queue.items(inPane: pane))
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
