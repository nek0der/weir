// PaneConversationFrame.swift
// Weir — the frame around a pane while a turn card of its conversation is under the pointer.

import SwiftUI

/// Says which pane a hovered card belongs to, in the conversation's color
/// (`ConversationHoverRule`); a tab not selected says so with a tint
/// instead, its panes being out of sight. Where the
/// pane meets the edges of the session's surface, it follows the surface's
/// rounded corners, as the attention frame does (`SurfaceFrameFit`). Its own
/// view, so only it is drawn again as the pointer moves between cards.
struct PaneConversationFrame: View {
    let paneID: UUID
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionState.self) private var attention
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.conversationIdentities) private var conversationIdentities
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Layout = WeirLayout.Supervision

    /// The color to frame a pane in, `nil` for none: this pane, or one past a
    /// divider, by one rule, so a seam joins only the frames that are drawn.
    /// The pane's conversation is read only under a card's hover, so the
    /// pointer elsewhere costs nothing.
    private func identity(of pane: UUID) -> Int? {
        guard let hover = window.conversationHover.hovered, hover.source == .card else { return nil }
        let conversation = attention.paneHeaderLabel(paneID: pane, in: session, locale: locale).conversation
        guard ConversationHoverRule.framesPane(of: conversation, hover: hover),
              let conversation,
              let tab = session.tab(containing: pane)
        else { return nil }
        return conversationIdentities?.identities(in: tab.container)[conversation]
    }

    var body: some View {
        let identity = identity(of: paneID)
        PaneFrameStroke(
            paneID: paneID,
            color: identity.map(ConversationIdentityBar.color),
            lineWidth: Layout.conversationHoverOutlineWidth,
            isFramed: { self.identity(of: $0) != nil }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : WeirMotion.conversationHover, value: identity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
