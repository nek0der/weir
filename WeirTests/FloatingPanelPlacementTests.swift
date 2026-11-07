// FloatingPanelPlacementTests.swift
// Weir — where a floating panel goes relative to its anchor, and where its
// arrow points. Shared by the pane rename field, the prompt cache panel and
// the container color picker.

import CoreGraphics
import Testing
@testable import Weir

struct FloatingPanelOriginTests {
    private static func origin(
        anchor: CGRect,
        container: CGSize = CGSize(width: 800, height: 600),
        alignment: FloatingPanelPlacement.Alignment = .leading
    ) -> CGPoint {
        FloatingPanelPlacement.origin(
            anchor: anchor,
            panelSize: CGSize(width: 240, height: 70),
            container: container,
            gap: 4,
            alignment: alignment
        )
    }

    @Test func leftOf_standsBesideTheAnchor_onItsTop_insideAShortWindow_orNotAtAllWithoutRoom() {
        let anchor = CGRect(x: 500, y: 40, width: 300, height: 400)
        let size = CGSize(width: 400, height: 200)
        let origin = { (height: CGFloat, anchor: CGRect) in
            FloatingPanelPlacement.leftOf(
                anchor: anchor,
                panelSize: size,
                container: CGSize(width: 900, height: height)
            )
        }
        #expect(origin(800, anchor) == CGPoint(x: 90, y: 40))
        #expect(origin(230, anchor) == CGPoint(x: 90, y: 24))
        #expect(origin(150, anchor) == CGPoint(x: 90, y: 6))
        #expect(origin(800, anchor.offsetBy(dx: -90, dy: 0)) == nil)
    }

    @Test(arguments: [
        (FloatingPanelPlacement.Alignment.leading, CGRect(x: 100, y: 200, width: 60, height: 24), CGPoint(x: 100, y: 228)),
        (.centered, CGRect(x: 300, y: 200, width: 10, height: 10), CGPoint(x: 185, y: 214))
    ])
    func origin_hangsBelowTheAnchorWithTheRequestedAlignment(
        alignment: FloatingPanelPlacement.Alignment,
        anchor: CGRect,
        expected: CGPoint
    ) {
        #expect(Self.origin(anchor: anchor, alignment: alignment) == expected)
    }

    @Test(arguments: [
        (FloatingPanelPlacement.Alignment.leading, CGRect(x: 700, y: 200, width: 60, height: 24), CGPoint(x: 554, y: 228)),
        (.leading, CGRect(x: 2, y: 200, width: 60, height: 24), CGPoint(x: 6, y: 228)),
        (.centered, CGRect(x: 20, y: 200, width: 10, height: 10), CGPoint(x: 6, y: 214)),
        (.centered, CGRect(x: 780, y: 200, width: 16, height: 16), CGPoint(x: 554, y: 220))
    ])
    func origin_clampsEitherAlignmentToBothWindowMargins(
        alignment: FloatingPanelPlacement.Alignment,
        anchor: CGRect,
        expected: CGPoint
    ) {
        #expect(Self.origin(anchor: anchor, alignment: alignment) == expected)
    }

    @Test func flipsAboveTheAnchorNearTheBottom() {
        let origin = Self.origin(anchor: CGRect(x: 100, y: 540, width: 60, height: 24))
        let above: CGFloat = 540 - 4 - 70
        #expect(origin.y == above)
    }

    @Test func pinsInsideWhenNeitherSideFits() {
        let origin = Self.origin(
            anchor: CGRect(x: 100, y: 40, width: 60, height: 24),
            container: CGSize(width: 800, height: 120)
        )
        let pinned: CGFloat = 120 - 70 - 6
        #expect(origin.y == pinned)
    }

    @Test(arguments: [(CGFloat(-400), CGFloat(6)), (1400, 524)])
    func origin_clampsAnOffscreenAnchorToTheNearestVerticalMargin(anchorY: CGFloat, expectedY: CGFloat) {
        let anchor = CGRect(x: 100, y: anchorY, width: 60, height: 16)
        #expect(Self.origin(anchor: anchor) == CGPoint(x: 100, y: expectedY))
    }
}

struct FloatingPanelArrowTests {
    private let width: CGFloat = 300
    private let height: CGFloat = 140
    private let inset: CGFloat = 30

    private func arrow(anchor: CGRect, panelAt origin: CGPoint) -> FloatingPanelPlacement.Arrow? {
        FloatingPanelPlacement.arrow(
            anchor: anchor,
            panelOrigin: origin,
            panelSize: CGSize(width: width, height: height),
            minimumInset: inset
        )
    }

    @Test(arguments: [
        (CGFloat(40), CGFloat(66), FloatingPanelPlacement.ArrowEdge.top),
        (600, 447, .bottom)
    ])
    func arrow_pointsFromThePanelsNearEdgeToTheAnchorsCenter(
        anchorY: CGFloat,
        panelY: CGFloat,
        edge: FloatingPanelPlacement.ArrowEdge
    ) {
        let anchor = CGRect(x: 400, y: anchorY, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: panelY)) == .init(edge: edge, offset: 150))
    }

    @Test(arguments: [(CGFloat(772), CGFloat(492), CGFloat(270)), (0, 8, 30)])
    func arrow_staysClearOfThePanelsRoundedCorners(anchorX: CGFloat, panelX: CGFloat, offset: CGFloat) {
        let anchor = CGRect(x: anchorX, y: 40, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: panelX, y: 66)) == .init(edge: .top, offset: offset))
    }

    @Test func panelOverTheAnchor_hasNoArrow() {
        let anchor = CGRect(x: 400, y: 100, width: 16, height: 16)
        #expect(arrow(anchor: anchor, panelAt: CGPoint(x: 258, y: 50)) == nil)
    }

    @Test func panelNarrowerThanBothInsets_centersTheArrow() {
        let placement = FloatingPanelPlacement.arrow(
            anchor: CGRect(x: 0, y: 0, width: 16, height: 16),
            panelOrigin: CGPoint(x: 0, y: 30),
            panelSize: CGSize(width: 40, height: 50),
            minimumInset: 30
        )
        #expect(placement?.offset == 20)
    }
}

/// The two ways Weir's panels hang, as hosts lay them out: the presets,
/// with their sizes from `WeirLayout`. Where the origin rule itself lands
/// is `FloatingPanelOriginTests`; these check what each preset adds.
@MainActor
struct FloatingPanelLayoutTests {
    private let container = CGSize(width: 800, height: 600)
    private let panel = CGSize(width: WeirLayout.paneRenamePanelWidth, height: 70)

    private func layout(
        _ anchor: CGRect,
        style: FloatingPanelPlacement.Style
    ) -> (origin: CGPoint, arrow: FloatingPanelPlacement.Arrow?) {
        FloatingPanelPlacement.layout(
            anchor: anchor,
            panelSize: panel,
            container: container,
            style: style
        )
    }

    @Test func aPromptCachePanel_nearTheWindowEdge_pointsAtItsClock() throws {
        let clock = CGRect(x: 750, y: 12, width: 16, height: 16)
        let card = CGSize(width: WeirLayout.promptCachePanelWidth, height: 180)
        let placed = FloatingPanelPlacement.layout(
            anchor: clock,
            panelSize: card,
            container: container,
            style: .arrowed
        )
        #expect(placed.origin == CGPoint(x: 494, y: 28 + WeirLayout.floatingPanelArrowAnchorGap))
        let arrow = try #require(placed.arrow)
        #expect(arrow.edge == .top)
        #expect(arrow.offset == 264)
    }

    @Test(arguments: [(CGFloat(200), true), (540, false)])
    func underHeader_keepsTheLeadingEdgeAndDrawsNoArrow(headerY: CGFloat, fitsBelow: Bool) {
        let header = CGRect(x: 100, y: headerY, width: 160, height: 24)
        let placed = layout(header, style: .underHeader)
        let gap = WeirLayout.paneRenamePanelAnchorGap
        let expectedY = fitsBelow ? header.maxY + gap : header.minY - gap - panel.height
        #expect(placed.origin == CGPoint(x: 100, y: expectedY))
        #expect(placed.arrow == nil)
    }

    @Test func arrowed_centersOnTheAnchorAndPointsBackAtIt() throws {
        let dot = CGRect(x: 300, y: 200, width: 10, height: 10)
        let placed = layout(dot, style: .arrowed)
        #expect(placed.origin.x == 185)
        #expect(placed.origin.y == dot.maxY + WeirLayout.floatingPanelArrowAnchorGap)
        let arrow = try #require(placed.arrow)
        #expect(arrow.edge == .top)
        #expect(placed.origin.x + arrow.offset == dot.midX)
    }

    @Test func arrowed_nearTheBottom_pointsDown() throws {
        let dot = CGRect(x: 300, y: 560, width: 10, height: 10)
        let arrow = try #require(layout(dot, style: .arrowed).arrow)
        #expect(arrow.edge == .bottom)
    }
}

/// The approval card on the session's surface, level with the row that opened it.
struct FloatingPanelBesideTests {
    private static let surface = FloatingPanelPlacement.Surface(minX: 330, top: 50, bottom: 680)
    private static let panel = CGSize(width: 400, height: 200)

    private static func beside(
        _ anchor: CGRect,
        panel: CGSize = Self.panel,
        placementHeight: CGFloat? = nil,
        surface: FloatingPanelPlacement.Surface = Self.surface,
        containerWidth: CGFloat = 1000
    ) -> CGPoint {
        FloatingPanelPlacement.beside(
            anchor: anchor,
            panelSize: panel,
            placementHeight: placementHeight ?? panel.height,
            surface: surface,
            containerWidth: containerWidth
        )
    }

    @Test(arguments: [(CGFloat(300), CGFloat(220)), (60, 50), (650, 480), (900, 480)])
    func beside_centersOnTheRowWithinTheSurface(rowY: CGFloat, expectedY: CGFloat) {
        let row = CGRect(x: 10, y: rowY, width: 280, height: 40)
        #expect(Self.beside(row) == CGPoint(x: 330, y: expectedY))
    }

    @Test func aNarrowWindow_pullsThePanelInsideTheMargin() {
        let row = CGRect(x: 10, y: 300, width: 280, height: 40)
        #expect(Self.beside(row, containerWidth: 600).x == 194)
    }

    @Test func aShrunkPanel_keepsItsTopWhereTheTallestPutIt() {
        let row = CGRect(x: 10, y: 300, width: 280, height: 40)
        let tall = Self.beside(row, panel: CGSize(width: 400, height: 300))
        let shrunk = Self.beside(row, panel: CGSize(width: 400, height: 200), placementHeight: 300)
        #expect(tall.y == 170)
        #expect(shrunk.y == 170)
    }

    @Test func columnsTooShort_centerThePanelOnThem() {
        let short = FloatingPanelPlacement.Surface(minX: 330, top: 50, bottom: 150)
        let row = CGRect(x: 10, y: 60, width: 280, height: 40)
        #expect(Self.beside(row, surface: short).y == 0)
    }
}

/// The approval card opened from a pane's decision bar: on the bar, its
/// trailing edge level with the bar's, where the bar's Answer… is.
struct FloatingPanelOnBarTests {
    private static let panel = CGSize(width: 400, height: 200)

    private static func onBar(_ bar: CGRect, panel: CGSize = Self.panel, top: CGFloat = 50) -> CGPoint {
        FloatingPanelPlacement.onBar(bar, panelSize: panel, gap: 6, top: top)
    }

    @Test(arguments: [
        (CGFloat(300), CGFloat(800), CGFloat(700)),
        (300, 898, 798),
        (500, 200, 300),
        (60, 200, 6)
    ])
    func onBar_alignsToItsTrailingEdgeWithinTheLeadingMargin(barX: CGFloat, barWidth: CGFloat, expectedX: CGFloat) {
        let bar = CGRect(x: barX, y: 700, width: barWidth, height: 32)
        #expect(Self.onBar(bar) == CGPoint(x: expectedX, y: 494))
    }

    @Test func aTallerPanel_growsUpward_andStopsAtTheColumnsTop() {
        let bar = CGRect(x: 300, y: 700, width: 800, height: 32)
        let short = Self.onBar(bar)
        let tall = Self.onBar(bar, panel: CGSize(width: 400, height: 300))
        #expect(short.y + Self.panel.height == tall.y + 300, "its bottom stays on the bar")
        #expect(Self.onBar(bar, panel: CGSize(width: 400, height: 900)).y == 50)
    }

    @Test func thePanelIsNoTallerThanWhatIsAboveTheBar() {
        let bar = CGRect(x: 300, y: 700, width: 800, height: 32)
        #expect(FloatingPanelPlacement.roomAbove(bar: bar, top: 50, gap: 6) == 644)
        #expect(
            FloatingPanelPlacement.roomAbove(bar: bar.offsetBy(dx: 0, dy: -640), top: 50, gap: 6)
                == FloatingPanelPlacement.minimumScrollingHeight
        )
    }
}

/// How tall a panel beside its anchor may be: a long reason or question
/// scrolls inside the card rather than pushing its actions off the window.
struct FloatingPanelHeightTests {
    @Test func aPanelIsAtMostTheColumnsHeight() {
        #expect(FloatingPanelPlacement.maximumHeight(columnTop: 50, columnBottom: 650) == 600)
        // Columns too short for any panel still give one some room.
        #expect(FloatingPanelPlacement.maximumHeight(columnTop: 0, columnBottom: 40) == FloatingPanelPlacement.minimumScrollingHeight)
    }

    @Test func theScrollingBodyGetsWhatTheHeadingAndActionsLeave() {
        #expect(FloatingPanelPlacement.scrollingBodyHeight(cap: 584, chrome: 120) == 464)
        // Before anything is measured, the whole cap; never below a few lines.
        #expect(FloatingPanelPlacement.scrollingBodyHeight(cap: 584, chrome: 0) == 584)
        #expect(FloatingPanelPlacement.scrollingBodyHeight(cap: 200, chrome: 190) == FloatingPanelPlacement.minimumScrollingHeight)
    }

    /// A dropdown's list stops at its own height while the panel has room,
    /// and gives up the rest when it does not. It never goes below the
    /// minimum scrolling height, which wins over the cap in a panel too
    /// short for it.
    @Test func aDropdownsList_keepsItsHeightUntilThePanelRunsOutOfRoom() {
        #expect(FloatingPanelPlacement.scrollingBodyHeight(preferred: 320, cap: 800, chrome: 200) == 320)
        #expect(FloatingPanelPlacement.scrollingBodyHeight(preferred: 320, cap: 400, chrome: 200) == 200)
        #expect(FloatingPanelPlacement.scrollingBodyHeight(preferred: 320, cap: 220, chrome: 200)
            == FloatingPanelPlacement.minimumScrollingHeight)
    }

    /// A title bar dropdown may reach down to the window's bottom margin,
    /// and the panel it is capped to then stands inside the window. In a
    /// window too short for any list, the minimum scrolling height wins and
    /// the panel can run past that margin.
    @Test func aDropdownBelowItsControl_endsAboveTheWindowsBottomMargin() {
        let anchor = CGRect(x: 100, y: 10, width: 120, height: 28)
        let room = FloatingPanelPlacement.roomBelow(anchor: anchor, containerMaxY: 500, gap: 4)
        #expect(room == 452)
        let origin = FloatingPanelPlacement.origin(
            anchor: anchor,
            panelSize: CGSize(width: 300, height: room),
            container: CGSize(width: 800, height: 500),
            gap: 4
        )
        #expect(origin.y == anchor.maxY + 4)
        let windowBottomLessMargin: CGFloat = 500 - 6
        #expect(origin.y + room == windowBottomLessMargin)
        // A window too short for any list still gets a few lines.
        #expect(FloatingPanelPlacement.roomBelow(anchor: anchor, containerMaxY: 60, gap: 4)
            == FloatingPanelPlacement.minimumScrollingHeight)
    }

    @Test func aCappedPanelStandsWithinTheColumns() {
        let surface = FloatingPanelPlacement.Surface(minX: 300, top: 50, bottom: 570)
        let height = FloatingPanelPlacement.maximumHeight(columnTop: surface.top, columnBottom: surface.bottom)
        let origin = FloatingPanelPlacement.beside(
            anchor: CGRect(x: 0, y: 560, width: 240, height: 30),
            panelSize: CGSize(width: 400, height: height),
            placementHeight: height,
            surface: surface,
            containerWidth: 800
        )
        #expect(origin.y == surface.top)
        #expect(origin.y + height == surface.bottom)
    }
}

/// A panel from the rail's top group: the notification history, the approval card.
struct FloatingPanelBesideRailTests {
    private static let panel = CGSize(width: 400, height: 520)

    private static func frame(buttonX: CGFloat = 4, columnBottom: CGFloat = 760, containerWidth: CGFloat = 1200) -> CGRect {
        FloatingPanelPlacement.besideRail(
            anchor: RailPanelAnchor(
                frame: CGRect(x: buttonX, y: 132, width: 32, height: 32),
                columnTop: 44,
                columnBottom: columnBottom
            ),
            panelSize: panel,
            containerWidth: containerWidth
        )
    }

    @Test(arguments: [(CGFloat(760), CGFloat(520)), (374, 330)])
    func besideRail_startsAtTheColumnsTopAndFitsItsHeight(columnBottom: CGFloat, panelHeight: CGFloat) {
        #expect(Self.frame(columnBottom: columnBottom) == CGRect(x: 46, y: 44, width: 400, height: panelHeight))
    }

    @Test func aRailNearTheTrailingEdge_pullsThePanelIn_andANarrowWindowPinsItToTheMargin() {
        #expect(Self.frame(buttonX: 1000) == CGRect(x: 794, y: 44, width: 400, height: 520))
        #expect(Self.frame(buttonX: 1000, containerWidth: 300) == CGRect(x: 6, y: 44, width: 400, height: 520))
    }
}

/// A panel level with its anchor, on the side that has room: the PR hover card.
struct FloatingPanelFlankingTests {
    private static let window = CGSize(width: 1000, height: 700)
    private static let panel = CGSize(width: 300, height: 150)

    private static func flanking(_ anchor: CGRect, container: CGSize = window) -> CGPoint {
        FloatingPanelPlacement.flanking(anchor: anchor, panelSize: panel, container: container, gap: 12)
    }

    @Test(arguments: [
        (CGRect(x: 10, y: 300, width: 280, height: 40), CGFloat(1000), CGFloat(302)),
        (CGRect(x: 800, y: 300, width: 100, height: 40), 1000, 488),
        (CGRect(x: 100, y: 300, width: 300, height: 40), 500, 6)
    ])
    func flanking_prefersTrailingThenLeadingThenTheMargin(anchor: CGRect, windowWidth: CGFloat, expectedX: CGFloat) {
        let container = CGSize(width: windowWidth, height: Self.window.height)
        #expect(Self.flanking(anchor, container: container) == CGPoint(x: expectedX, y: 245))
    }

    @Test func flanking_clampsThePanelAtBothVerticalMargins() {
        #expect(Self.flanking(CGRect(x: 10, y: 0, width: 280, height: 20)).y == 6)
        #expect(Self.flanking(CGRect(x: 10, y: 680, width: 280, height: 20)).y == 544)
    }
}

struct FloatingPanelFittedWidthTests {
    @Test func keepsItsWidthWhileTheWindowHasRoom_thenNarrows_downToItsMinimum() {
        #expect(FloatingPanelPlacement.fittedWidth(preferred: 400, minimum: 296, containerWidth: 1000) == 400)
        #expect(FloatingPanelPlacement.fittedWidth(preferred: 400, minimum: 296, containerWidth: 350) == 338)
        #expect(FloatingPanelPlacement.fittedWidth(preferred: 400, minimum: 296, containerWidth: 200) == 296)
    }
}

/// These cover the one horizontal clamp the floating panels and the command
/// palette's dropdown share.
struct FloatingPanelClampXTests {
    @Test(arguments: [
        (CGFloat(100), CGFloat(240), CGFloat(800), CGFloat(100)),
        (-20, 240, 800, 6),
        (700, 240, 800, 554),
        (100, 560, 500, 6)
    ])
    func clampX_respectsTheMarginsAndAnchorsOversizedPanelsAtTheLeadingEdge(
        preferredX: CGFloat,
        panelWidth: CGFloat,
        containerWidth: CGFloat,
        expected: CGFloat
    ) {
        #expect(FloatingPanelPlacement.clampX(
            preferredX: preferredX,
            panelWidth: panelWidth,
            containerWidth: containerWidth
        ) == expected)
    }
}
