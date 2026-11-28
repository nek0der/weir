// TokenContrastRequirements.swift
// Weir — the contrast every token pair must keep, on the tokens and on the colors a terminal theme gives them.

import Foundation

/// One color drawn on a ground, and the contrast it must keep there.
///
/// The one list of them (`TokenContrastRequirements`) is what
/// `SupervisionTokensTests` holds the tokens to and what
/// `WindowColorResolver` holds a theme's colors to, so a pair added for the
/// tokens is checked under every theme as well.
struct ContrastRequirement: Sendable {
    /// What the foreground is drawn on.
    enum Ground: Sendable {
        /// An opaque token.
        case token(ThemedColor)
        /// Ink laid over a token.
        case overlay(ThemedOverlay, over: ThemedColor)
    }

    let name: String
    let foreground: ThemedColor
    let ground: Ground
    let ratio: Double

    init(_ name: String, _ foreground: ThemedColor, on ground: Ground, ratio: Double) {
        self.name = name
        self.foreground = foreground
        self.ground = ground
        self.ratio = ratio
    }

    /// The ground's color on one side, in `colors`.
    func groundValue(isDark: Bool, in colors: WindowColors) -> SRGB {
        switch ground {
        case let .token(token): token.value(isDark: isDark, in: colors)
        case let .overlay(overlay, surface): overlay.value(over: surface.value(isDark: isDark, in: colors), isDark: isDark)
        }
    }

    /// The contrast the pair reaches on one side, in `colors`.
    func contrast(isDark: Bool, in colors: WindowColors = .tokens) -> Double {
        ContrastRatio.between(foreground.value(isDark: isDark, in: colors), groundValue(isDark: isDark, in: colors))
    }
}

/// Every pair of tokens drawn one on the other in the window, with the
/// contrast it must keep.
enum TokenContrastRequirements {
    private typealias Tokens = SupervisionTokens
    private typealias Requirement = ContrastRequirement

    /// Every pair below, text and marks alike.
    static let all = text + overlayText + icons

    /// Text and the backgrounds it sits on: 4.5:1.
    static let text: [ContrastRequirement] = [
        Requirement("text on window", Tokens.text, on: .token(Tokens.window), ratio: ContrastRatio.text),
        Requirement("muted on well", Tokens.muted, on: .token(Tokens.well), ratio: ContrastRatio.text),
        Requirement("unread count on window", Tokens.unreadText, on: .token(Tokens.window), ratio: ContrastRatio.text),
        Requirement("unread count on hover", Tokens.unreadText, on: .token(Tokens.hover), ratio: ContrastRatio.text),
        Requirement("unread count on selection", Tokens.unreadText, on: .token(Tokens.selection), ratio: ContrastRatio.text),
        Requirement("text on sidebar", Tokens.text, on: .token(Tokens.sidebar), ratio: ContrastRatio.text),
        Requirement("text on selection", Tokens.text, on: .token(Tokens.selection), ratio: ContrastRatio.text),
        Requirement("muted on window", Tokens.muted, on: .token(Tokens.window), ratio: ContrastRatio.text),
        Requirement("muted on sidebar, and on a file header", Tokens.muted, on: .token(Tokens.sidebar), ratio: ContrastRatio.text),
        Requirement("muted on selection", Tokens.muted, on: .token(Tokens.selection), ratio: ContrastRatio.text),
        Requirement("amber text on window", Tokens.waitingText, on: .token(Tokens.window), ratio: ContrastRatio.text),
        Requirement("amber text on sidebar", Tokens.waitingText, on: .token(Tokens.sidebar), ratio: ContrastRatio.text),
        // The decision bar's Approval tag and the title bar's attention
        // count are soft chips of their family, on their own fill (the
        // bar's ground for a tag), as the pane strip's exit mark is.
        Requirement(
            "amber text on amber fill: Approval tag, attention count",
            Tokens.waitingText,
            on: .token(Tokens.waitingFill),
            ratio: ContrastRatio.text
        ),
        Requirement("amber text on selection", Tokens.waitingText, on: .token(Tokens.selection), ratio: ContrastRatio.text),
        Requirement("red text on window", Tokens.stoppedText, on: .token(Tokens.window), ratio: ContrastRatio.text),
        Requirement("red text on sidebar", Tokens.stoppedText, on: .token(Tokens.sidebar), ratio: ContrastRatio.text),
        Requirement("red text on selection", Tokens.stoppedText, on: .token(Tokens.selection), ratio: ContrastRatio.text),
        Requirement(
            "red text on red fill: Stopped tag, exit mark",
            Tokens.stoppedText,
            on: .token(Tokens.stoppedFill),
            ratio: ContrastRatio.text
        ),
        // Codex's black letters on its white reach the text ratio as well;
        // Claude's are held to the marks' (below).
        Requirement("Codex badge letters", Tokens.codexBadgeForeground, on: .token(Tokens.codex), ratio: ContrastRatio.text),
        Requirement("muted on a terminal's lines", Tokens.muted, on: .token(Tokens.terminal), ratio: ContrastRatio.text),
        Requirement("muted on hover, and on a discarded hunk header", Tokens.muted, on: .token(Tokens.hover), ratio: ContrastRatio.text),
        // The review tab's stacked diff: a file's header and a hunk's, and
        // a discarded hunk's, each with muted words and counts on it.
        Requirement("muted on a hunk header", Tokens.muted, on: .token(Tokens.column), ratio: ContrastRatio.text),
        Requirement("text on a hunk header", Tokens.text, on: .token(Tokens.column), ratio: ContrastRatio.text),
        Requirement("red text on a hunk header", Tokens.stoppedText, on: .token(Tokens.column), ratio: ContrastRatio.text),
        // The "Running · n" chip's words, on the chip's own window fill.
        Requirement("running on window", Tokens.running, on: .token(Tokens.window), ratio: ContrastRatio.text),
        // The decision bar over unread turns: its words, the receipt's
        // additions and removals, and a failed check.
        Requirement("text on unread fill", Tokens.text, on: .token(Tokens.unreadFill), ratio: ContrastRatio.text),
        Requirement("muted on unread fill", Tokens.muted, on: .token(Tokens.unreadFill), ratio: ContrastRatio.text),
        Requirement("red text on unread fill", Tokens.stoppedText, on: .token(Tokens.unreadFill), ratio: ContrastRatio.text),
        // A receipt's counts, wherever the bar shows one: over unread
        // turns and at rest.
        Requirement("additions on unread fill", Tokens.added, on: .token(Tokens.unreadFill), ratio: ContrastRatio.text),
        Requirement("removals on unread fill", Tokens.removed, on: .token(Tokens.unreadFill), ratio: ContrastRatio.text),
        Requirement("additions on sidebar, and on a file header", Tokens.added, on: .token(Tokens.sidebar), ratio: ContrastRatio.text),
        Requirement("removals on sidebar, and on a file header", Tokens.removed, on: .token(Tokens.sidebar), ratio: ContrastRatio.text),
        Requirement("additions on window", Tokens.added, on: .token(Tokens.window), ratio: ContrastRatio.text),
        Requirement("additions on selection", Tokens.added, on: .token(Tokens.selection), ratio: ContrastRatio.text),
        Requirement("removals on window", Tokens.removed, on: .token(Tokens.window), ratio: ContrastRatio.text),
        // The bar's words over a wait and a stop.
        Requirement("text on amber fill", Tokens.text, on: .token(Tokens.waitingFill), ratio: ContrastRatio.text),
        Requirement("text on red fill", Tokens.text, on: .token(Tokens.stoppedFill), ratio: ContrastRatio.text),
        Requirement("muted on amber fill", Tokens.muted, on: .token(Tokens.waitingFill), ratio: ContrastRatio.text),
        Requirement("muted on red fill", Tokens.muted, on: .token(Tokens.stoppedFill), ratio: ContrastRatio.text),
        Requirement(
            "unread text on unread fill: Unread tag, unread-only count",
            Tokens.unreadText,
            on: .token(Tokens.unreadFill),
            ratio: ContrastRatio.text
        ),
        // The popovers' opaque surface, with transparency off or reduced:
        // the palette, the history, the lists, and the approval card.
        Requirement("waiting badge count on its amber fill", Tokens.onWaiting, on: .token(Tokens.waitingCount), ratio: ContrastRatio.text),
        Requirement("unread rail count on its blue fill", Tokens.onUnreadCount, on: .token(Tokens.unreadCount), ratio: ContrastRatio.text),
        Requirement("text on popover", Tokens.text, on: .token(Tokens.popover), ratio: ContrastRatio.text),
        Requirement("muted on popover", Tokens.muted, on: .token(Tokens.popover), ratio: ContrastRatio.text),
        Requirement("red text on popover", Tokens.stoppedText, on: .token(Tokens.popover), ratio: ContrastRatio.text),
        Requirement("amber text on popover", Tokens.waitingText, on: .token(Tokens.popover), ratio: ContrastRatio.text),
        // A button standing inside a state's soft fill, at rest, hovered,
        // and pressed (`stateFillButton`).
        Requirement("text on a state fill's button", Tokens.text, on: .token(Tokens.stateFillButton), ratio: ContrastRatio.text),
        Requirement(
            "text on a state fill's hovered button",
            Tokens.text,
            on: .token(Tokens.stateFillButtonHover),
            ratio: ContrastRatio.text
        ),
        Requirement(
            "text on a state fill's pressed button",
            Tokens.text,
            on: .token(Tokens.stateFillButtonPressed),
            ratio: ContrastRatio.text
        )
        // The review's quiet words (a fold's hidden lines, the file list's
        // headings and counts) are "muted on window" and, on a selected
        // file, "muted on selection"; its banners' words on the amber and
        // red grounds are the decision bar's "text on amber fill" and "text
        // on red fill". A comment card's (its title, place, and state) and
        // those on the row fills (the find bar, the preview's chips) are
        // below.
    ]

    /// A comment card's words in the diff, and the stale note in the
    /// comments' preview, whose card is a lighter coat than this one.
    static let overlayText: [ContrastRequirement] = [
        Requirement(
            "muted on a comment card",
            Tokens.muted,
            on: .overlay(Tokens.reviewCard, over: Tokens.window),
            ratio: ContrastRatio.text
        ),
        Requirement("text on a comment card", Tokens.text, on: .overlay(Tokens.reviewCard, over: Tokens.window), ratio: ContrastRatio.text),
        Requirement(
            "amber text on a comment card",
            Tokens.waitingText,
            on: .overlay(Tokens.reviewCard, over: Tokens.window),
            ratio: ContrastRatio.text
        ),
        Requirement(
            "amber text on a comment card on popover",
            Tokens.waitingText,
            on: .overlay(Tokens.reviewCard, over: Tokens.popover),
            ratio: ContrastRatio.text
        ),
        Requirement(
            "muted on a comment card on popover",
            Tokens.muted,
            on: .overlay(Tokens.reviewCard, over: Tokens.popover),
            ratio: ContrastRatio.text
        )
    ]

    /// Icons and the backgrounds they sit on: 3:1.
    static let icons: [ContrastRequirement] = [
        // The "?" is a mark, held to 3:1 on its disc; the disc's edge
        // carries it off every surface it sits on.
        Requirement("needs-input mark on its disc", Tokens.onWaiting, on: .token(Tokens.waitingGlyph), ratio: ContrastRatio.icon),
        // The stopped disc's white "!" is a mark too, as the "?" is.
        Requirement("stopped mark on its disc", Tokens.onStopped, on: .token(Tokens.stopped), ratio: ContrastRatio.icon),
        Requirement("needs-input disc's edge on window", Tokens.waitingGlyphEdge, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("needs-input disc's edge on sidebar", Tokens.waitingGlyphEdge, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("needs-input disc's edge on hover", Tokens.waitingGlyphEdge, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement(
            "needs-input disc's edge on the terminal",
            Tokens.waitingGlyphEdge,
            on: .token(Tokens.terminal),
            ratio: ContrastRatio.icon
        ),
        // The decision bar's tag edges and the attention count's ring, on
        // their own fill, which is also the bar's ground: the edge is what
        // makes them chips. The count's button turns to `hover` while it
        // is hovered or open. The review's banners carry their amber and
        // red in the icon, on the matching fill (`ReviewBanner.Tone`), and
        // the decision bar's top rule over unread turns is the unread ring.
        Requirement(
            "amber on amber fill: tag edge, count ring, warning icon",
            Tokens.waiting,
            on: .token(Tokens.waitingFill),
            ratio: ContrastRatio.icon
        ),
        Requirement("red on red fill: tag edge, error icon", Tokens.stopped, on: .token(Tokens.stoppedFill), ratio: ContrastRatio.icon),
        Requirement(
            "unread on unread fill: tag edge, count ring, rule",
            Tokens.unread,
            on: .token(Tokens.unreadFill),
            ratio: ContrastRatio.icon
        ),
        Requirement("unread-only count's ring on hover", Tokens.unread, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement("stopped disc on window", Tokens.stopped, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("stopped disc on sidebar", Tokens.stopped, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        // The fixed unread blue where it marks without words (a count's
        // ring, the decision bar's rule, a history row's dot, and the unread
        // state glyph). Every icon ground is covered in `StateGlyphTests`.
        Requirement("unread blue mark on window", Tokens.unread, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("unread blue mark on sidebar", Tokens.unread, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("unread blue mark on selection", Tokens.unread, on: .token(Tokens.selection), ratio: ContrastRatio.icon),
        // `muted` marks need no rows of their own: `text` holds it to
        // the stricter ratio on each of their grounds. They are the idle ring
        // under Increase Contrast (`StateGlyphGeometry.idleInk`), on window,
        // sidebar, selection, hover, and popover; a tab's unread dot, on the
        // terminal; and the review tab's file list marks, on window.
        Requirement("running arc on window", Tokens.running, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("running arc on sidebar", Tokens.running, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement(
            "amber on window, and the attention count's ring there",
            Tokens.waiting,
            on: .token(Tokens.window),
            ratio: ContrastRatio.icon
        ),
        Requirement("amber on sidebar", Tokens.waiting, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        // A selected row's glyph, a tab's dot on a selected tab, and the
        // pane's frame on the terminal.
        Requirement(
            "needs-input disc's edge on selection",
            Tokens.waitingGlyphEdge,
            on: .token(Tokens.selection),
            ratio: ContrastRatio.icon
        ),
        Requirement("amber on selection", Tokens.waiting, on: .token(Tokens.selection), ratio: ContrastRatio.icon),
        Requirement(
            "amber on hover, and the attention count's ring there",
            Tokens.waiting,
            on: .token(Tokens.hover),
            ratio: ContrastRatio.icon
        ),
        Requirement("amber on well", Tokens.waiting, on: .token(Tokens.well), ratio: ContrastRatio.icon),
        Requirement("amber on the terminal", Tokens.waiting, on: .token(Tokens.terminal), ratio: ContrastRatio.icon),
        // The two letters on Claude's orange are a mark, not words to read
        // (`SupervisionTokens.badgeForeground`).
        Requirement("Claude badge letters", Tokens.badgeForeground, on: .token(Tokens.claude), ratio: ContrastRatio.icon),
        Requirement("Kiro badge letters", Tokens.badgeForeground, on: .token(Tokens.kiro), ratio: ContrastRatio.icon),
        // A badge is told apart by its shape as much as its letters: where
        // a brand fill stands too close to a surface, its edge carries it.
        Requirement("Claude badge's edge on window", Tokens.claudeEdge, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("Codex badge's edge on window", Tokens.codexEdge, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("Antigravity badge's blue on window", Tokens.antigravityEdge, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("OpenCode badge's edge on window", Tokens.opencodeEdge, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("Kiro badge's edge on window", Tokens.kiroEdge, on: .token(Tokens.window), ratio: ContrastRatio.icon),
        Requirement("Claude badge's edge on sidebar", Tokens.claudeEdge, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("Codex badge's edge on sidebar", Tokens.codexEdge, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("Antigravity badge's blue on sidebar", Tokens.antigravityEdge, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("OpenCode badge's edge on sidebar", Tokens.opencodeEdge, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("Kiro badge's edge on sidebar", Tokens.kiroEdge, on: .token(Tokens.sidebar), ratio: ContrastRatio.icon),
        Requirement("Claude badge's edge on selection", Tokens.claudeEdge, on: .token(Tokens.selection), ratio: ContrastRatio.icon),
        Requirement("Codex badge's edge on selection", Tokens.codexEdge, on: .token(Tokens.selection), ratio: ContrastRatio.icon),
        Requirement(
            "Antigravity badge's blue on selection",
            Tokens.antigravityEdge,
            on: .token(Tokens.selection),
            ratio: ContrastRatio.icon
        ),
        Requirement("OpenCode badge's edge on selection", Tokens.opencodeEdge, on: .token(Tokens.selection), ratio: ContrastRatio.icon),
        Requirement("Kiro badge's edge on selection", Tokens.kiroEdge, on: .token(Tokens.selection), ratio: ContrastRatio.icon),
        Requirement("Claude badge's edge on hover", Tokens.claudeEdge, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement("Codex badge's edge on hover", Tokens.codexEdge, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement("Antigravity badge's blue on hover", Tokens.antigravityEdge, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement("OpenCode badge's edge on hover", Tokens.opencodeEdge, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement("Kiro badge's edge on hover", Tokens.kiroEdge, on: .token(Tokens.hover), ratio: ContrastRatio.icon),
        Requirement("Claude badge's edge on popover", Tokens.claudeEdge, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("Codex badge's edge on popover", Tokens.codexEdge, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("Antigravity badge's blue on popover", Tokens.antigravityEdge, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("OpenCode badge's edge on popover", Tokens.opencodeEdge, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("Kiro badge's edge on popover", Tokens.kiroEdge, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("unread blue mark on popover", Tokens.unread, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("stopped disc on popover", Tokens.stopped, on: .token(Tokens.popover), ratio: ContrastRatio.icon),
        Requirement("needs-input disc's edge on popover", Tokens.waitingGlyphEdge, on: .token(Tokens.popover), ratio: ContrastRatio.icon)
    ]

    /// A toast's pairs. A toast is drawn in the tokens whatever the theme
    /// (`ToastView`), since it inverts the appearance and the other side's
    /// colors may come from another theme, so these hold the tokens only.
    static let toast: [ContrastRequirement] = [
        // A toast is an inverted surface, drawn in the text color.
        Requirement("toast link on a toast", Tokens.toastLink, on: .token(Tokens.text), ratio: ContrastRatio.text),
        // A toast's words on its inverted box.
        Requirement("toast words on a toast", Tokens.window, on: .token(Tokens.text), ratio: ContrastRatio.text)
    ]
}
