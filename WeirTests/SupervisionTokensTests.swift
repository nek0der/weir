// SupervisionTokensTests.swift
// Weir — supervision token values and contrast on representative backgrounds in both appearances.

import AppKit
import SwiftUI
import Testing
@testable import Weir

struct SupervisionTokensTests {
    private typealias Tokens = SupervisionTokens

    /// A foreground token on a background token, named for the failure
    /// message.
    struct Pair {
        let name: String
        let foreground: ThemedColor
        let background: ThemedColor

        init(_ name: String, _ foreground: ThemedColor, _ background: ThemedColor) {
            self.name = name
            self.foreground = foreground
            self.background = background
        }

        func ratio(isDark: Bool) -> Double {
            ContrastRatio.between(foreground.value(isDark: isDark), background.value(isDark: isDark))
        }
    }

    /// Text and the backgrounds it sits on: 4.5:1.
    private static let textPairs: [Pair] = [
        Pair("text on window", Tokens.text, Tokens.window),
        Pair("muted on well", Tokens.muted, Tokens.well),
        Pair("unread count on window", Tokens.unreadText, Tokens.window),
        Pair("unread count on hover", Tokens.unreadText, Tokens.hover),
        Pair("unread count on selection", Tokens.unreadText, Tokens.selection),
        Pair("text on sidebar", Tokens.text, Tokens.sidebar),
        Pair("text on selection", Tokens.text, Tokens.selection),
        Pair("muted on window", Tokens.muted, Tokens.window),
        Pair("muted on sidebar, and on a file header", Tokens.muted, Tokens.sidebar),
        Pair("muted on selection", Tokens.muted, Tokens.selection),
        Pair("amber text on window", Tokens.waitingText, Tokens.window),
        Pair("amber text on sidebar", Tokens.waitingText, Tokens.sidebar),
        // The decision bar's Approval tag and the title bar's attention
        // count are soft chips of their family, on their own fill (the
        // bar's ground for a tag), as the pane strip's exit mark is.
        Pair("amber text on amber fill: Approval tag, attention count", Tokens.waitingText, Tokens.waitingFill),
        Pair("amber text on selection", Tokens.waitingText, Tokens.selection),
        Pair("red text on window", Tokens.stoppedText, Tokens.window),
        Pair("red text on sidebar", Tokens.stoppedText, Tokens.sidebar),
        Pair("red text on selection", Tokens.stoppedText, Tokens.selection),
        Pair("red text on red fill: Stopped tag, exit mark", Tokens.stoppedText, Tokens.stoppedFill),
        // A toast is an inverted surface, drawn in the text color.
        Pair("toast link on a toast", Tokens.toastLink, Tokens.text),
        // Codex's black letters on its white reach the text ratio as well;
        // Claude's are held to the marks' (below).
        Pair("Codex badge letters", Tokens.codexBadgeForeground, Tokens.codex),
        Pair("muted on a terminal's lines", Tokens.muted, Tokens.terminal),
        Pair("muted on hover, and on a discarded hunk header", Tokens.muted, Tokens.hover),
        // The review tab's stacked diff: a file's header and a hunk's, and
        // a discarded hunk's, each with muted words and counts on it.
        Pair("muted on a hunk header", Tokens.muted, Tokens.column),
        Pair("text on a hunk header", Tokens.text, Tokens.column),
        Pair("red text on a hunk header", Tokens.stoppedText, Tokens.column),
        // The "Running · n" chip's words, on the chip's own window fill.
        Pair("running on window", Tokens.running, Tokens.window),
        // The decision bar over unread turns: its words, the receipt's
        // additions and removals, and a failed check.
        Pair("text on unread fill", Tokens.text, Tokens.unreadFill),
        Pair("muted on unread fill", Tokens.muted, Tokens.unreadFill),
        Pair("red text on unread fill", Tokens.stoppedText, Tokens.unreadFill),
        // A receipt's counts, wherever the bar shows one: over unread
        // turns and at rest.
        Pair("additions on unread fill", Tokens.added, Tokens.unreadFill),
        Pair("removals on unread fill", Tokens.removed, Tokens.unreadFill),
        Pair("additions on sidebar, and on a file header", Tokens.added, Tokens.sidebar),
        Pair("removals on sidebar, and on a file header", Tokens.removed, Tokens.sidebar),
        Pair("additions on window", Tokens.added, Tokens.window),
        Pair("additions on selection", Tokens.added, Tokens.selection),
        Pair("removals on window", Tokens.removed, Tokens.window),
        // The bar's words over a wait and a stop.
        Pair("text on amber fill", Tokens.text, Tokens.waitingFill),
        Pair("text on red fill", Tokens.text, Tokens.stoppedFill),
        Pair("muted on amber fill", Tokens.muted, Tokens.waitingFill),
        Pair("muted on red fill", Tokens.muted, Tokens.stoppedFill),
        Pair("unread text on unread fill: Unread tag, unread-only count", Tokens.unreadText, Tokens.unreadFill),
        // A toast's words on its inverted box.
        Pair("toast words on a toast", Tokens.window, Tokens.text),
        // The popovers' opaque surface, with transparency off or reduced:
        // the palette, the history, the lists, and the approval card.
        Pair("waiting badge count on its amber fill", Tokens.onWaiting, Tokens.waitingCount),
        Pair("unread rail count on its blue fill", Tokens.onUnreadCount, Tokens.unreadCount),
        Pair("text on popover", Tokens.text, Tokens.popover),
        Pair("muted on popover", Tokens.muted, Tokens.popover),
        Pair("red text on popover", Tokens.stoppedText, Tokens.popover),
        Pair("amber text on popover", Tokens.waitingText, Tokens.popover)
        // The review's quiet words (a fold's hidden lines, the file list's
        // headings and counts) are "muted on window" and, on a selected
        // file, "muted on selection"; its banners' words on the amber and
        // red grounds are the decision bar's "text on amber fill" and "text
        // on red fill". A comment card's (its title, place, and state) and
        // those on the row fills (the find bar, the preview's chips) are
        // below.
    ]

    /// Words on a ground laid over a surface (`ThemedOverlay`), named for
    /// the failure message.
    struct OverlayPair {
        let name: String
        let foreground: ThemedColor
        let overlay: ThemedOverlay
        let surface: ThemedColor

        init(_ name: String, _ foreground: ThemedColor, on overlay: ThemedOverlay, over surface: ThemedColor) {
            self.name = name
            self.foreground = foreground
            self.overlay = overlay
            self.surface = surface
        }

        func ratio(isDark: Bool) -> Double {
            let ground = overlay.value(over: surface.value(isDark: isDark), isDark: isDark)
            return ContrastRatio.between(foreground.value(isDark: isDark), ground)
        }
    }

    /// A comment card's words in the diff, and the stale note in the
    /// comments' preview, whose card is a lighter coat than this one.
    private static let overlayTextPairs: [OverlayPair] = [
        OverlayPair("muted on a comment card", Tokens.muted, on: Tokens.reviewCard, over: Tokens.window),
        OverlayPair("text on a comment card", Tokens.text, on: Tokens.reviewCard, over: Tokens.window),
        OverlayPair("amber text on a comment card", Tokens.waitingText, on: Tokens.reviewCard, over: Tokens.window),
        OverlayPair("amber text on a comment card on popover", Tokens.waitingText, on: Tokens.reviewCard, over: Tokens.popover),
        OverlayPair("muted on a comment card on popover", Tokens.muted, on: Tokens.reviewCard, over: Tokens.popover)
    ]

    /// Icons and the backgrounds they sit on: 3:1.
    private static let iconPairs: [Pair] = [
        // The "?" is a mark, held to 3:1 on its disc; the disc's edge
        // carries it off every surface it sits on.
        Pair("needs-input mark on its disc", Tokens.onWaiting, Tokens.waitingGlyph),
        // The stopped disc's white "!" is a mark too, as the "?" is.
        Pair("stopped mark on its disc", Tokens.onStopped, Tokens.stopped),
        Pair("needs-input disc's edge on window", Tokens.waitingGlyphEdge, Tokens.window),
        Pair("needs-input disc's edge on sidebar", Tokens.waitingGlyphEdge, Tokens.sidebar),
        Pair("needs-input disc's edge on hover", Tokens.waitingGlyphEdge, Tokens.hover),
        Pair("needs-input disc's edge on the terminal", Tokens.waitingGlyphEdge, Tokens.terminal),
        // The decision bar's tag edges and the attention count's ring, on
        // their own fill, which is also the bar's ground: the edge is what
        // makes them chips. The count's button turns to `hover` while it
        // is hovered or open. The review's banners carry their amber and
        // red in the icon, on the matching fill (`ReviewBanner.Tone`), and
        // the decision bar's top rule over unread turns is the unread ring.
        Pair("amber on amber fill: tag edge, count ring, warning icon", Tokens.waiting, Tokens.waitingFill),
        Pair("red on red fill: tag edge, error icon", Tokens.stopped, Tokens.stoppedFill),
        Pair("unread on unread fill: tag edge, count ring, rule", Tokens.unread, Tokens.unreadFill),
        Pair("unread-only count's ring on hover", Tokens.unread, Tokens.hover),
        Pair("stopped disc on window", Tokens.stopped, Tokens.window),
        Pair("stopped disc on sidebar", Tokens.stopped, Tokens.sidebar),
        // The fixed unread blue where it marks without words (a count's
        // ring, the decision bar's rule, a history row's dot, and the unread
        // state glyph). Every icon ground is covered in `StateGlyphTests`.
        Pair("unread blue mark on window", Tokens.unread, Tokens.window),
        Pair("unread blue mark on sidebar", Tokens.unread, Tokens.sidebar),
        Pair("unread blue mark on selection", Tokens.unread, Tokens.selection),
        // `muted` marks need no rows of their own: `textPairs` holds it to
        // the stricter ratio on each of their grounds. They are the idle ring
        // under Increase Contrast (`StateGlyphGeometry.idleInk`), on window,
        // sidebar, selection, hover, and popover; a tab's unread dot, on the
        // terminal; and the review tab's file list marks, on window.
        Pair("running arc on window", Tokens.running, Tokens.window),
        Pair("running arc on sidebar", Tokens.running, Tokens.sidebar),
        Pair("amber on window, and the attention count's ring there", Tokens.waiting, Tokens.window),
        Pair("amber on sidebar", Tokens.waiting, Tokens.sidebar),
        // A selected row's glyph, a tab's dot on a selected tab, and the
        // pane's frame on the terminal.
        Pair("needs-input disc's edge on selection", Tokens.waitingGlyphEdge, Tokens.selection),
        Pair("amber on selection", Tokens.waiting, Tokens.selection),
        Pair("amber on hover, and the attention count's ring there", Tokens.waiting, Tokens.hover),
        Pair("amber on well", Tokens.waiting, Tokens.well),
        Pair("amber on the terminal", Tokens.waiting, Tokens.terminal),
        // The two letters on Claude's orange are a mark, not words to read
        // (`SupervisionTokens.badgeForeground`).
        Pair("Claude badge letters", Tokens.badgeForeground, Tokens.claude),
        Pair("Kiro badge letters", Tokens.badgeForeground, Tokens.kiro),
        // A badge is told apart by its shape as much as its letters: where
        // a brand fill stands too close to a surface, its edge carries it.
        Pair("Claude badge's edge on window", Tokens.claudeEdge, Tokens.window),
        Pair("Codex badge's edge on window", Tokens.codexEdge, Tokens.window),
        Pair("Antigravity badge's blue on window", Tokens.antigravity, Tokens.window),
        Pair("OpenCode badge's edge on window", Tokens.opencodeEdge, Tokens.window),
        Pair("Kiro badge's edge on window", Tokens.kiroEdge, Tokens.window),
        Pair("Claude badge's edge on sidebar", Tokens.claudeEdge, Tokens.sidebar),
        Pair("Codex badge's edge on sidebar", Tokens.codexEdge, Tokens.sidebar),
        Pair("Antigravity badge's blue on sidebar", Tokens.antigravity, Tokens.sidebar),
        Pair("OpenCode badge's edge on sidebar", Tokens.opencodeEdge, Tokens.sidebar),
        Pair("Kiro badge's edge on sidebar", Tokens.kiroEdge, Tokens.sidebar),
        Pair("Claude badge's edge on selection", Tokens.claudeEdge, Tokens.selection),
        Pair("Codex badge's edge on selection", Tokens.codexEdge, Tokens.selection),
        Pair("Antigravity badge's blue on selection", Tokens.antigravity, Tokens.selection),
        Pair("OpenCode badge's edge on selection", Tokens.opencodeEdge, Tokens.selection),
        Pair("Kiro badge's edge on selection", Tokens.kiroEdge, Tokens.selection),
        Pair("Claude badge's edge on hover", Tokens.claudeEdge, Tokens.hover),
        Pair("Codex badge's edge on hover", Tokens.codexEdge, Tokens.hover),
        Pair("Antigravity badge's blue on hover", Tokens.antigravity, Tokens.hover),
        Pair("OpenCode badge's edge on hover", Tokens.opencodeEdge, Tokens.hover),
        Pair("Kiro badge's edge on hover", Tokens.kiroEdge, Tokens.hover),
        Pair("Claude badge's edge on popover", Tokens.claudeEdge, Tokens.popover),
        Pair("Codex badge's edge on popover", Tokens.codexEdge, Tokens.popover),
        Pair("Antigravity badge's blue on popover", Tokens.antigravity, Tokens.popover),
        Pair("OpenCode badge's edge on popover", Tokens.opencodeEdge, Tokens.popover),
        Pair("Kiro badge's edge on popover", Tokens.kiroEdge, Tokens.popover),
        Pair("unread blue mark on popover", Tokens.unread, Tokens.popover),
        Pair("stopped disc on popover", Tokens.stopped, Tokens.popover),
        Pair("needs-input disc's edge on popover", Tokens.waitingGlyphEdge, Tokens.popover)
    ]

    @Test(arguments: [false, true])
    func text_reachesFourAndAHalfToOne(isDark: Bool) {
        for pair in Self.textPairs {
            let ratio = pair.ratio(isDark: isDark)
            #expect(ratio >= 4.5, "\(pair.name) in \(isDark ? "dark" : "light"): \(ratio)")
        }
    }

    @Test(arguments: [false, true])
    func textOnALaidOverGround_reachesFourAndAHalfToOne(isDark: Bool) {
        for pair in Self.overlayTextPairs {
            let ratio = pair.ratio(isDark: isDark)
            #expect(ratio >= 4.5, "\(pair.name) in \(isDark ? "dark" : "light"): \(ratio)")
        }
    }

    /// The review's quiet words on the row fills it lays over a surface:
    /// the find bar on the review tab, and in the comments' preview a
    /// comment's span chip, on the card, on the popover. The fills are
    /// `WeirColor`'s, resolved with their opacity, so a stronger one
    /// fails here.
    @Test(arguments: [false, true])
    @MainActor
    func mutedOnDeclaredReviewRowFillRecipes_reachesFourAndAHalfToOne(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        func laid(_ fill: Color, over ground: SRGB) throws -> SRGB {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(fill).usingColorSpace(.sRGB)
            }
            let coat = try #require(resolved)
            let alpha = coat.alphaComponent
            return SRGB(
                red: coat.redComponent * alpha + ground.red * (1 - alpha),
                green: coat.greenComponent * alpha + ground.green * (1 - alpha),
                blue: coat.blueComponent * alpha + ground.blue * (1 - alpha)
            )
        }
        let muted = Tokens.muted.value(isDark: isDark)
        let mode = isDark ? "dark" : "light"
        let findBar = try laid(WeirColor.rowActiveFill.opacity(0.5), over: Tokens.window.value(isDark: isDark))
        let card = try laid(WeirColor.rowActiveFill.opacity(0.5), over: Tokens.popover.value(isDark: isDark))
        let chip = try laid(WeirColor.rowHoverFill.opacity(0.6), over: card)
        for (name, ground) in [("find bar", findBar), ("preview card", card), ("span chip", chip)] {
            let ratio = ContrastRatio.between(muted, ground)
            #expect(ratio >= 4.5, "muted on the \(name) in \(mode): \(ratio)")
        }
    }

    /// The split diff's placeholder for a missing line: its lines show
    /// (above 1.8:1, clear of the 1.6:1 at which they read only zoomed in)
    /// but stay under an icon's 3:1, so they never read as content; its
    /// ground stands off the diff's surface without becoming a band.
    @Test(arguments: [false, true])
    func theDiffsHatch_isSubtleButVisible(isDark: Bool) {
        let window = Tokens.window.value(isDark: isDark)
        let ground = Tokens.diffPlaceholder.value(over: window, isDark: isDark)
        let line = Tokens.diffHatch.value(over: ground, isDark: isDark)
        let lineOnGround = ContrastRatio.between(line, ground)
        let groundOnWindow = ContrastRatio.between(ground, window)
        let mode = isDark ? "dark" : "light"
        #expect(lineOnGround >= 1.8, "hatch on its ground in \(mode): \(lineOnGround)")
        #expect(lineOnGround < 3.0, "hatch on its ground in \(mode): \(lineOnGround)")
        #expect(groundOnWindow > 1.05, "ground on the diff in \(mode): \(groundOnWindow)")
        #expect(groundOnWindow < 1.5, "ground on the diff in \(mode): \(groundOnWindow)")
    }

    /// An overlay laid over a surface is the ink mixed in at its opacity:
    /// none leaves the surface, all of it is the ink.
    @MainActor
    @Test func anOverlay_mixesItsInkIntoTheSurface() throws {
        let white = SRGB(0xFFFFFF)
        #expect(ThemedOverlay(lightOpacity: 0, darkOpacity: 0).value(over: white, isDark: false) == white)
        #expect(ThemedOverlay(lightOpacity: 1, darkOpacity: 1).value(over: white, isDark: false) == SRGB(0x000000))
        #expect(ThemedOverlay(lightOpacity: 1, darkOpacity: 1).value(over: SRGB(0x000000), isDark: true) == white)
        let overlay = ThemedOverlay(lightOpacity: 0.25, darkOpacity: 0.5)
        let ground = SRGB(red: 0.25, green: 0.5, blue: 0.75)
        #expect(overlay.value(over: ground, isDark: false) == SRGB(red: 0.1875, green: 0.375, blue: 0.5625))
        #expect(overlay.value(over: ground, isDark: true) == SRGB(red: 0.625, green: 0.75, blue: 0.875))

        let light = try Self.resolved(overlay.nsColor, in: .aqua)
        let dark = try Self.resolved(overlay.nsColor, in: .darkAqua)
        #expect(light.redComponent == 0 && light.greenComponent == 0 && light.blueComponent == 0)
        #expect(dark.redComponent == 1 && dark.greenComponent == 1 && dark.blueComponent == 1)
        #expect(light.alphaComponent == 0.25)
        #expect(dark.alphaComponent == 0.5)
    }

    @Test(arguments: [false, true])
    func icons_reachThreeToOne(isDark: Bool) {
        for pair in Self.iconPairs {
            let ratio = pair.ratio(isDark: isDark)
            #expect(ratio >= 3.0, "\(pair.name) in \(isDark ? "dark" : "light"): \(ratio)")
        }
    }

    /// The decision bar's tag is a soft chip of its family: the state's
    /// soft fill, its text tone, and an edge in the state's own color; at
    /// rest and while resuming, no fill and the `line` edge.
    @Test func theDecisionBarsTag_isASoftChipOfItsFamily() {
        let waiting = DecisionBarTagStyle.of(.waiting)
        #expect(waiting == DecisionBarTagStyle(fill: Tokens.waitingFill, label: Tokens.waitingText, edge: Tokens.waiting))
        let stopped = DecisionBarTagStyle.of(.stopped)
        #expect(stopped == DecisionBarTagStyle(fill: Tokens.stoppedFill, label: Tokens.stoppedText, edge: Tokens.stopped))
        let unread = DecisionBarTagStyle.of(.unread)
        #expect(unread == DecisionBarTagStyle(fill: Tokens.unreadFill, label: Tokens.unreadText, edge: Tokens.unread))
        for tone in [DecisionBarModel.Tone.muted, .done] {
            #expect(DecisionBarTagStyle.of(tone) == DecisionBarTagStyle(fill: nil, label: Tokens.muted, edge: Tokens.line))
        }
        // Their contrast is the tables' "Approval tag", "Stopped tag", and
        // "Unread tag" rows.
    }

    /// Either a one-byte red increase or a one-byte green increase drops
    /// the white mark below its contrast floor.
    @Test(arguments: [false, true])
    func theNeedsInputDisc_isAtTheRedAndGreenContrastBoundary(isDark: Bool) {
        let disc = Tokens.waitingGlyph.value(isDark: isDark)
        let white = SRGB(0xFFFFFF)
        #expect(Tokens.onWaiting.value(isDark: isDark) == white)
        #expect(disc == Tokens.waitingGlyph.value(isDark: !isDark))
        #expect(ContrastRatio.between(white, disc) >= 3.0)
        let step = 1.0 / 255
        let redder = SRGB(red: disc.red + step, green: disc.green, blue: disc.blue)
        let greener = SRGB(red: disc.red, green: disc.green + step, blue: disc.blue)
        #expect(ContrastRatio.between(white, redder) < 3.0)
        #expect(ContrastRatio.between(white, greener) < 3.0)
    }

    @Test(arguments: [false, true])
    func anAgentBadge_wearsItsBrandColorAndItsMarksLetters(isDark: Bool) {
        #expect(Tokens.claude.value(isDark: isDark) == SRGB(0xD97757))
        #expect(Tokens.codex.value(isDark: isDark) == SRGB(0xFFFFFF))
        #expect(Tokens.codexBadgeForeground.value(isDark: isDark) == SRGB(0x000000))
        #expect(Tokens.antigravity.value(isDark: isDark) == SRGB(0x2B7BEF))
        #expect(Tokens.opencode.value(isDark: isDark) == SRGB(0x211E1E))
        #expect(Tokens.kiro.value(isDark: isDark) == SRGB(0x9046FF))
        #expect(Tokens.badgeForeground.value(isDark: isDark) == SRGB(0xFFFFFF))
        #expect(AgentBrand.of(.claude) == AgentBrand(
            letters: "Cl", fill: .solid(Tokens.claude), foreground: Tokens.badgeForeground, edge: Tokens.claudeEdge
        ))
        #expect(AgentBrand.of(.codex) == AgentBrand(
            letters: "Cx", fill: .solid(Tokens.codex), foreground: Tokens.codexBadgeForeground, edge: Tokens.codexEdge
        ))
        #expect(AgentBrand.of(.antigravity) == AgentBrand(
            letters: "Ag", fill: .antigravityMesh, foreground: Tokens.badgeForeground, edge: nil
        ))
        #expect(AgentBrand.of(.opencode) == AgentBrand(
            letters: "Op", fill: .solid(Tokens.opencode), foreground: Tokens.badgeForeground, edge: Tokens.opencodeEdge
        ))
        #expect(AgentBrand.of(.kiro) == AgentBrand(
            letters: "Ki", fill: .solid(Tokens.kiro), foreground: Tokens.badgeForeground, edge: Tokens.kiroEdge
        ))
    }

    /// Disc, Claude, and Codex edges match the quantized selection rule.
    /// OpenCode's lighter dark edge also clears the floor.
    @Test(arguments: [false, true])
    func theDiscAndBadgeEdges_preserveSelectedRowContrast(isDark: Bool) {
        let selection = Tokens.selection.value(isDark: isDark)
        let cases = [
            (name: "needs-input disc", fill: Tokens.waitingGlyph, edge: Tokens.waitingGlyphEdge),
            (name: "Claude badge", fill: Tokens.claude, edge: Tokens.claudeEdge),
            (name: "Codex badge", fill: Tokens.codex, edge: Tokens.codexEdge)
        ]
        for sample in cases {
            let fill = sample.fill.value(isDark: isDark)
            let edge = sample.edge.value(isDark: isDark)
            #expect((ContrastRatio.between(fill, selection) < 3.0) == !isDark, "\(sample.name)")
            #expect(ContrastRatio.between(edge, selection) >= 3.0, "\(sample.name)")
            #expect(edge.hexBytes == SelectionEdgeRule.color(fill, on: selection).hexBytes, "\(sample.name)")
            #expect((edge == fill) == isDark, "\(sample.name)")
        }
        let fill = Tokens.opencode.value(isDark: isDark)
        let edge = Tokens.opencodeEdge.value(isDark: isDark)
        #expect((ContrastRatio.between(fill, selection) < 3.0) == isDark, "OpenCode badge")
        #expect(ContrastRatio.between(edge, selection) >= 3.0, "OpenCode badge")
        #expect((edge == fill) == !isDark, "OpenCode badge")
        // Kiro's purple stands under 3:1 off a selected row only in dark,
        // where its edge is the selection rule's.
        let kiroFill = Tokens.kiro.value(isDark: isDark)
        let kiroEdge = Tokens.kiroEdge.value(isDark: isDark)
        #expect((ContrastRatio.between(kiroFill, selection) < 3.0) == isDark, "Kiro badge")
        #expect(ContrastRatio.between(kiroEdge, selection) >= 3.0, "Kiro badge")
        #expect((kiroEdge == kiroFill) == !isDark, "Kiro badge")
        if isDark {
            #expect(kiroEdge.hexBytes == SelectionEdgeRule.color(kiroFill, on: selection).hexBytes, "Kiro badge")
        }
    }

    @Test(arguments: [false, true])
    func theWell_isDarkerThanTheWindow(isDark: Bool) {
        let well = Tokens.well.value(isDark: isDark).luminance
        #expect(well < Tokens.window.value(isDark: isDark).luminance)
    }

    // MARK: Conversation identity

    /// The identity bar is decorative. The Changes card is on the window's
    /// ground at rest and takes the hover token when its panel is opaque.
    @Test(arguments: [false, true])
    func conversationIdentity_staysVisible_onRepresentativeCardAndTerminalGrounds(isDark: Bool) throws {
        var grounds = [
            ("window", Tokens.window.value(isDark: isDark)),
            ("hovered card and tab", Tokens.hover.value(isDark: isDark)),
            ("terminal", Tokens.terminal.value(isDark: isDark))
        ]
        if !isDark {
            grounds.append(("representative light card", SRGB(0xF7F7F8)))
        }
        try #require(Tokens.conversationIdentity.count >= 6)
        for (index, color) in Tokens.conversationIdentity.enumerated() {
            for (name, ground) in grounds {
                let ratio = ContrastRatio.between(color.value(isDark: isDark), ground)
                #expect(ratio >= 2, "color \(index) on \(name): \(ratio)")
            }
        }
    }

    /// The existing six indices remain in order. New colors may be added
    /// at the end and must meet the same distance requirements.
    @Test(arguments: [false, true])
    func conversationIdentity_colorsStayApart(isDark: Bool) {
        let colors = Tokens.conversationIdentity.map { $0.value(isDark: isDark) }
        let expected: [UInt32] = isDark
            ? [0x4FC46B, 0xA77BF0, 0x2FC0C8, 0xEC6FB8, 0xEBCB45, 0xD9DCE2]
            : [0x43C061, 0xA678F3, 0x29BBC3, 0xEF6CB9, 0xCAA611, 0x3A3D44]
        #expect(Array(colors.prefix(expected.count)) == expected.map(SRGB.init))
        let unread = Tokens.unread.value(isDark: isDark)
        for first in colors.indices {
            let distanceFromUnread = OKLab.distance(colors[first], unread) * 100
            #expect(distanceFromUnread >= 10, "color \(first) against unread: \(distanceFromUnread)")
            for second in colors.indices where second > first {
                let distance = OKLab.distance(colors[first], colors[second]) * 100
                #expect(distance >= 12, "colors \(first) and \(second): \(distance)")
            }
        }
    }

    /// Each successive state moves further from rest while keeping the
    /// label readable on its own fill.
    @Test(arguments: [false, true])
    func stateFillButton_keepsTextContrastAndStepsAwayFromRest(isDark: Bool) {
        let rest = Tokens.stateFillButton.value(isDark: isDark)
        let hover = Tokens.stateFillButtonHover.value(isDark: isDark)
        let pressed = Tokens.stateFillButtonPressed.value(isDark: isDark)
        #expect(ContrastRatio.between(rest, hover) > 1)
        #expect(ContrastRatio.between(rest, pressed) > ContrastRatio.between(rest, hover))
        #expect(isDark ? rest.luminance < hover.luminance : rest.luminance > hover.luminance)
        #expect(isDark ? hover.luminance < pressed.luminance : hover.luminance > pressed.luminance)
        for face in [rest, hover, pressed] {
            #expect(ContrastRatio.between(Tokens.text.value(isDark: isDark), face) >= 4.5)
        }
    }

    @MainActor
    private static func resolved(_ color: NSColor, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }

    /// Reused colors still resolve independently for both drawing appearances.
    @MainActor
    @Test func aTokensColor_isStableAcrossReads_andStillResolvesPerAppearance() throws {
        #expect(Tokens.text.color == Tokens.text.color)
        #expect(Tokens.waitingGlyph.color == Tokens.waitingGlyph.color)
        #expect(Tokens.reviewCard.color == Tokens.reviewCard.color)
        #expect(Tokens.text.nsColor === Tokens.text.nsColor)
        #expect(Tokens.reviewCard.nsColor === Tokens.reviewCard.nsColor)

        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(SRGB(Tokens.text.nsColor, in: light)?.hexBytes == Tokens.text.light.hexBytes)
        #expect(SRGB(Tokens.text.nsColor, in: dark)?.hexBytes == Tokens.text.dark.hexBytes)
        let lightCoat = try Self.resolved(Tokens.reviewCard.nsColor, in: .aqua)
        let darkCoat = try Self.resolved(Tokens.reviewCard.nsColor, in: .darkAqua)
        #expect(lightCoat.redComponent == 0)
        #expect(darkCoat.redComponent == 1)
        #expect(abs(Double(lightCoat.alphaComponent) - Tokens.reviewCard.lightOpacity) < 0.000_001)
        #expect(abs(Double(darkCoat.alphaComponent) - Tokens.reviewCard.darkOpacity) < 0.000_001)
    }

}

/// sRGB to OKLab (Björn Ottosson's matrices), only to measure how far apart
/// two colors look.
private enum OKLab {
    static func distance(_ first: SRGB, _ second: SRGB) -> Double {
        let difference = components(first) - components(second)
        return (difference * difference).sum().squareRoot()
    }

    private static func components(_ color: SRGB) -> SIMD3<Double> {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let red = linear(color.red)
        let green = linear(color.green)
        let blue = linear(color.blue)
        let long = cbrt(0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue)
        let medium = cbrt(0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue)
        let short = cbrt(0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue)
        return SIMD3(
            0.210_454_255_3 * long + 0.793_617_785_0 * medium - 0.004_072_046_8 * short,
            1.977_998_495_1 * long - 2.428_592_205_0 * medium + 0.450_593_709_9 * short,
            0.025_904_037_1 * long + 0.782_771_766_2 * medium - 0.808_675_766_0 * short
        )
    }
}
