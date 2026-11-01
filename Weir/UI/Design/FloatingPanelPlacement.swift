// FloatingPanelPlacement.swift
// Weir — where a floating panel goes relative to what opened it, and where
// its arrow points.
//
// Weir draws its small panels (the pane rename field, the prompt cache
// panel, the container color picker) at scene root rather than through
// `.popover`, so they share one surface and can overlap whatever lies below
// the row or header that opened them. Each hangs from an anchor rect; these
// rules decide the panel's corner and its arrow from that rect alone, so the
// panels agree and the geometry is tested once. Pure: what differs between
// panels comes in as arguments, and what must not differ is held here, so no
// panel can stand on an edge of its own.

import CoreGraphics
import Foundation

enum FloatingPanelPlacement {
    /// Between a panel and the window's edges.
    private static let margin = WeirLayout.floatingPanelWindowMargin
    /// From a rail button, or from the Needs Attention list, to the panel
    /// beside it.
    private static let railGap = WeirLayout.Supervision.railPanelGap

    /// How the panel lines up with its anchor horizontally.
    enum Alignment: Equatable {
        /// The panel's leading edge follows the anchor's, as a field that
        /// stands in for the header it renames.
        case leading
        /// The panel is centered on the anchor, as one that points at a
        /// small mark with its arrow.
        case centered
    }

    /// Which edge of the panel faces its anchor.
    enum ArrowEdge: Equatable {
        /// The panel hangs below the anchor.
        case top
        /// The panel sits above the anchor, near the window's bottom.
        case bottom
    }

    /// Where the panel's arrow goes: the edge facing the anchor, and the
    /// arrow's center along that edge in the panel's own coordinates (from
    /// the leading edge).
    struct Arrow: Equatable {
        let edge: ArrowEdge
        let offset: CGFloat
    }

    /// How a panel hangs from its anchor: lined up how, how far off, and
    /// whether it carries an arrow pointing back. The sizes come from the
    /// interface; the rules here only apply them.
    struct Style: Equatable {
        let alignment: Alignment
        /// Between the anchor and the panel's near edge.
        let gap: CGFloat
        /// The least distance from the arrow's center to either corner, or
        /// nil for a panel with no arrow.
        let arrowInset: CGFloat?
    }

    /// Where a panel of `style` and `panelSize` goes, and its arrow if the
    /// style has one: `origin`, then `arrow` from wherever that put it.
    static func layout(
        anchor: CGRect,
        panelSize: CGSize,
        container: CGSize,
        style: Style
    ) -> (origin: CGPoint, arrow: Arrow?) {
        let placed = Self.origin(
            anchor: anchor,
            panelSize: panelSize,
            container: container,
            gap: style.gap,
            alignment: style.alignment
        )
        let pointing = style.arrowInset.flatMap { inset in
            Self.arrow(anchor: anchor, panelOrigin: placed, panelSize: panelSize, minimumInset: inset)
        }
        return (placed, pointing)
    }

    /// A panel opened from a rail button in the rail's top group (the
    /// notification history, the approval card): past the rail, its top on
    /// the columns'. Columns too short for it shorten it, which its content
    /// scrolls to fit, so it never covers the title bar or the status bar.
    /// `anchor` is in the container's coordinates.
    static func besideRail(anchor: RailPanelAnchor, panelSize: CGSize, containerWidth: CGFloat) -> CGRect {
        let x = clampX(preferredX: anchor.frame.maxX + railGap, panelWidth: panelSize.width, containerWidth: containerWidth)
        let height = min(panelSize.height, max(0, anchor.columnBottom - anchor.columnTop))
        return CGRect(x: x, y: anchor.columnTop, width: panelSize.width, height: height)
    }

    /// Where a panel from the rail's bottom group goes (the plan usage
    /// panel). It grows upward from `bottom` by as much as `maximumHeight`.
    struct RailBottomPlace: Equatable {
        let leading: CGFloat
        let bottom: CGFloat
        let maximumHeight: CGFloat
    }

    /// A panel opened from a rail button in the rail's bottom group: past
    /// the rail, its bottom on the columns', growing as far up as their top.
    /// `anchor` is in the container's coordinates.
    static func besideRailBottom(anchor: RailPanelAnchor, panelWidth: CGFloat, container: CGSize) -> RailBottomPlace {
        let bottom = min(anchor.columnBottom, container.height - margin)
        let top = max(margin, anchor.columnTop)
        return RailBottomPlace(
            leading: clampX(preferredX: anchor.frame.maxX + railGap, panelWidth: panelWidth, containerWidth: container.width),
            bottom: bottom,
            maximumHeight: max(0, bottom - top)
        )
    }

    /// Where a panel stands left of `anchor`, on its top and inside a short
    /// window; `nil` where the window has no room for it there.
    static func leftOf(anchor: CGRect, panelSize: CGSize, container: CGSize) -> CGPoint? {
        let x = anchor.minX - railGap - panelSize.width
        guard x >= margin else { return nil }
        let lowest = max(margin, container.height - panelSize.height - margin)
        return CGPoint(x: x, y: min(max(anchor.minY, margin), lowest))
    }

    /// A panel level with `anchor`, `gap` after it, or before it when after
    /// would take it past the window's trailing margin: the PR hover card.
    static func flanking(anchor: CGRect, panelSize: CGSize, container: CGSize, gap: CGFloat) -> CGPoint {
        let after = anchor.maxX + gap
        let x = after + panelSize.width <= container.width - margin
            ? after
            : clampX(preferredX: anchor.minX - gap - panelSize.width, panelWidth: panelSize.width, containerWidth: container.width)
        let lowest = max(margin, container.height - panelSize.height - margin)
        return CGPoint(x: x, y: min(max(anchor.midY - panelSize.height / 2, margin), lowest))
    }

    /// The width of a panel that narrows with its window: `preferred` while
    /// the window has room for it and both margins, and never below `minimum`.
    static func fittedWidth(preferred: CGFloat, minimum: CGFloat, containerWidth: CGFloat) -> CGFloat {
        min(preferred, max(minimum, containerWidth - margin * 2))
    }

    /// Where the panel's top-leading corner goes, in the same coordinates as
    /// `anchor` and `container`. Horizontally it follows `alignment`, pulled
    /// inside the window. It hangs `gap` below the anchor, or sits that far
    /// above it when below would run past the window's bottom; when neither
    /// fits, it is pinned inside the bottom. Whatever the branch, the result
    /// is kept inside the window's top and bottom margins, so an anchor that
    /// has scrolled or been laid out off screen cannot take the panel with it.
    static func origin(
        anchor: CGRect,
        panelSize: CGSize,
        container: CGSize,
        gap: CGFloat,
        alignment: Alignment = .leading
    ) -> CGPoint {
        let preferredX = switch alignment {
        case .leading: anchor.minX
        case .centered: anchor.midX - panelSize.width / 2
        }
        let x = clampX(preferredX: preferredX, panelWidth: panelSize.width, containerWidth: container.width)

        let below = anchor.maxY + gap
        let above = anchor.minY - gap - panelSize.height
        let maximumY = container.height - panelSize.height - margin
        let y: CGFloat = if below <= maximumY {
            below
        } else if above >= margin {
            above
        } else {
            max(margin, maximumY)
        }
        return CGPoint(x: x, y: min(max(y, margin), max(margin, maximumY)))
    }

    /// Returns a panel's left edge as near `preferredX` as the window
    /// allows, inside the margin on either side of a container `containerWidth` wide. In a
    /// container too narrow for the panel and both margins it starts at the
    /// left margin, where its rows begin. Every panel placed across the
    /// window clamps through here (`origin`, `beside`, and the command
    /// palette's dropdown), so none of them can hold a different edge.
    static func clampX(preferredX: CGFloat, panelWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let maximumX = containerWidth - panelWidth - margin
        return maximumX >= margin ? min(max(preferredX, margin), maximumX) : margin
    }

    /// The arrow for a panel placed at `panelOrigin`, in the same
    /// coordinates as `anchor`. The panel is placed and clamped to the
    /// window first (`origin`); the arrow then points at the anchor's center
    /// from wherever the panel ended up, kept `minimumInset` from either
    /// corner so it never sits on the rounding. Nil when the panel overlaps
    /// the anchor vertically, which only happens when the window is too
    /// short for it either side: an arrow there would point from inside the
    /// anchor.
    static func arrow(
        anchor: CGRect,
        panelOrigin: CGPoint,
        panelSize: CGSize,
        minimumInset: CGFloat
    ) -> Arrow? {
        let edge: ArrowEdge
        if panelOrigin.y >= anchor.maxY {
            edge = .top
        } else if panelOrigin.y + panelSize.height <= anchor.minY {
            edge = .bottom
        } else {
            return nil
        }
        let wanted = anchor.midX - panelOrigin.x
        let maximum = panelSize.width - minimumInset
        let x = maximum >= minimumInset ? min(max(wanted, minimumInset), maximum) : panelSize.width / 2
        return Arrow(edge: edge, offset: x)
    }

    /// The least a panel's scrolling body is given, a few lines of text,
    /// so a short window still shows some of what is asked.
    static let minimumScrollingHeight: CGFloat = 80

    /// The tallest a panel may be: the columns' height. A panel with more to
    /// say scrolls its body (`scrollingBodyHeight`), so its heading and its
    /// actions stay on screen. The floor is above the columns' height only in
    /// columns shorter than the window's own minimum height allows.
    static func maximumHeight(columnTop: CGFloat, columnBottom: CGFloat) -> CGFloat {
        max(minimumScrollingHeight, columnBottom - columnTop)
    }

    /// What a panel capped at `cap` leaves its scrolling body, when the rest
    /// of it (heading, status, actions, insets) measures `chrome`.
    static func scrollingBodyHeight(cap: CGFloat, chrome: CGFloat) -> CGFloat {
        max(minimumScrollingHeight, cap - max(0, chrome))
    }

    /// Does the same for a list with a height of its own to stop at
    /// (`preferred`), such as a dropdown's: it returns that height while the
    /// panel has room for it, and less when it does not.
    static func scrollingBodyHeight(preferred: CGFloat, cap: CGFloat, chrome: CGFloat) -> CGFloat {
        min(preferred, scrollingBodyHeight(cap: cap, chrome: chrome))
    }

    /// Returns the tallest a panel hung `gap` below `anchor` may be and
    /// still end inside the window's bottom margin (`containerMaxY`, in the
    /// anchor's coordinates). A title bar dropdown needs this, as it has no
    /// room above its control to flip to. The result is never below
    /// `minimumScrollingHeight`.
    static func roomBelow(anchor: CGRect, containerMaxY: CGFloat, gap: CGFloat) -> CGFloat {
        max(minimumScrollingHeight, containerMaxY - anchor.maxY - gap - margin)
    }

    /// The surface a panel stands on (`beside`): its leading edge, and the
    /// top and bottom of the window's columns, in the anchor's coordinates.
    struct Surface: Equatable {
        let minX: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// A panel on `surface`, level with its anchor: the approval card opened
    /// from a sidebar row. Its leading edge is the surface's and it stays
    /// between the columns' top and bottom, centered on the anchor where
    /// there is room. Placed by `placementHeight` rather than the panel's own
    /// height, so a panel that shrinks keeps its top edge where it was. A
    /// window too narrow for it pulls it left, inside the window's margin,
    /// and columns too short for it center it on them.
    static func beside(
        anchor: CGRect,
        panelSize: CGSize,
        placementHeight: CGFloat,
        surface: Surface,
        containerWidth: CGFloat
    ) -> CGPoint {
        let x = clampX(preferredX: surface.minX, panelWidth: panelSize.width, containerWidth: containerWidth)
        let y: CGFloat = if surface.bottom - surface.top >= placementHeight {
            min(max(anchor.midY - placementHeight / 2, surface.top), surface.bottom - placementHeight)
        } else {
            (surface.top + surface.bottom - panelSize.height) / 2
        }
        return CGPoint(x: x, y: y)
    }
}
