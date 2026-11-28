// PaneAttentionFrame.swift
// Weir — the frame around a pane whose agent waits on the person or stopped.

import SwiftUI
import WeirDomain

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
    @Environment(TerminalThemeStore.self) private var terminalTheme
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
    @Environment(\.weirAccent) private var accent
    @Environment(\.weirWindowColors) private var windowColors
    @State private var isDimmed = false
    @State private var blink: Task<Void, Never>?

    var body: some View {
        let attention = attention(of: paneID)
        PaneFrameStroke(
            paneID: paneID,
            color: attention.map(color(for:)),
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

    /// The token, or, on a terminal ground Weir paints, the token moved
    /// until it stands out against that ground (`TerminalGround`). The
    /// frame runs over the header too, which keeps its own ground; the
    /// terminal area is most of the frame's length.
    private func color(for attention: PaneAttention) -> Color {
        let ground = terminalTheme.ground(
            colorScheme: colorScheme,
            accent: accent,
            surfaceOpacity: surfaceOpacity,
            unfocusedPaneOpacity: settingsStore.settings.appearance.unfocusedPaneOpacity,
            windowColors: windowColors
        )
        // Resolved here rather than handed down as a style: the frame
        // compares its color to tell whether it moved, and this body runs
        // again on an appearance switch, as it reads the color scheme.
        let isDark = colorScheme == .dark
        let token = attention.isWaiting ? SupervisionTokens.waiting : SupervisionTokens.stopped
        let corrected = attention.isWaiting ? ground.waiting : ground.stopped
        return corrected?.color ?? Color(nsColor: token.value(isDark: isDark, in: windowColors).nsColor)
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
