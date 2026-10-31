// IconBadgeMark.swift
// Weir — the mark an icon control carries on its corner, drawn from its `IconBadge`.

import SwiftUI

/// An icon's mark, a count in the blue kept for unread and unviewed or in amber,
/// with a ring cut out of the icon under it, so the window's ground shows
/// through, translucent or not, and the mark stands off the icon. The
/// icon draws it in a compositing group, which is all the ring cuts. The
/// dot is the history row's unread dot, centered where a count's center
/// would be, so the mark stays in one place on the icon whichever it is.
struct IconBadgeMark: View {
    let badge: IconBadge

    var body: some View {
        let ring = WeirLayout.Supervision.iconBadgeRingWidth
        switch badge {
        case let .count(count, tone):
            let inner = WeirLayout.Supervision.iconBadgeSize - 2 * ring
            Text(IconBadge.text(for: count))
                .font(.supervision(.badge, weight: .bold))
                .monospacedDigit()
                .foregroundStyle((tone == .blocking ? SupervisionTokens.onWaiting : SupervisionTokens.onUnreadCount).color)
                .padding(.horizontal, WeirLayout.Supervision.spaceXS)
                .frame(minWidth: inner, minHeight: inner)
                .background(Capsule().fill((tone == .blocking ? SupervisionTokens.waitingCount : SupervisionTokens.unreadCount).color))
                .padding(ring)
                .background(Capsule().fill(.black).blendMode(.destinationOut))
                .fixedSize()
                .offset(y: 1)
        case .dot:
            dot(color: SupervisionTokens.unread.color, size: WeirLayout.Supervision.notificationUnreadDotSize)
        case .waiting:
            dot(color: SupervisionTokens.waiting.color, size: WeirLayout.Supervision.notificationUnreadDotSize)
        case .stopped:
            dot(color: SupervisionTokens.stopped.color, size: WeirLayout.Supervision.usageLimitDotSize)
        }
    }

    private func dot(color: Color, size: CGFloat) -> some View {
        let ring = WeirLayout.Supervision.iconBadgeRingWidth
        // How far the ringed dot's corner sits inside a ringed count's.
        let inset = (WeirLayout.Supervision.iconBadgeSize - size) / 2 - ring
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .padding(ring)
            .background(Circle().fill(.black).blendMode(.destinationOut))
            .offset(x: -inset, y: 1 + inset)
    }
}
