// WindowColorResolver.swift
// Weir — derives the window's colors on one appearance from a terminal theme, or keeps the tokens when they would not hold.

import Foundation
import WeirDomain

/// Derives the window's neutral colors on one side from the terminal
/// theme's background and foreground, keeping every contrast the tokens
/// keep (`TokenContrastRequirements`).
///
/// The tokens are the model. Each neutral surface keeps the step in CIELAB
/// lightness it has from the `window` token, measured from the theme's
/// background and in the background's hue, so the surfaces stand apart as
/// the tokens do. The inks sit between the background and the foreground
/// where the tokens sit between `window` and `text`. A state's soft fill
/// keeps its own hue and takes its lightness from the background the same
/// way. The state colors and badge edges keep their values unless one has
/// to move toward black or white to keep its contrast.
///
/// All or nothing, as the review's syntax colors are (`SyntaxColors`): the
/// tokens were chosen against each other, and a window half in the theme's
/// colors and half in the tokens was never checked. A side that cannot keep
/// every requirement keeps every token.
enum WindowColorResolver {
    /// Why a side keeps the tokens, for the survey and the tests.
    enum Refusal: Error, Equatable, Sendable {
        /// A surface's lightness would leave 0...100, or an ink's color
        /// would.
        case surfaceOutOfRange(WindowColorRole)
        /// A requirement could not be met even after moving the colors that
        /// may move.
        case contrast(String)
        /// Two colors meant to read apart came too close.
        case indistinct(WindowColorRole, WindowColorRole)
        /// The foreground is darker than the background on the dark side,
        /// or lighter on the light one, so the window's own controls, drawn
        /// in the appearance's label colors, would not read on it.
        case invertedInk
        /// The system's label color, which the controls Weir does not color
        /// itself draw in, falls short on a surface.
        case systemLabel(WindowColorRole)
    }

    /// The surfaces that follow the background, by their step from `window`.
    static let surfaces: [WindowColorRole] = [
        .page, .well, .window, .sidebar, .column, .selection, .railSelection, .hover,
        .segmentHover, .line, .popover, .terminal,
        .stateFillButton, .stateFillButtonHover, .stateFillButtonPressed, .stateFillButtonEdge
    ]

    /// The inks between the background and the foreground. `text` is the
    /// foreground itself.
    static let inks: [WindowColorRole] = [.text, .muted, .faint, .running]

    /// The soft fills that keep their hue.
    static let fills: [WindowColorRole] = [.waitingFill, .stoppedFill, .unreadFill]

    /// The colors that may move toward black or white to keep a contrast:
    /// the inks, and the state colors and edges drawn on the surfaces.
    static let movable: Set<WindowColorRole> = Set(inks).union([
        .waiting, .waitingText, .waitingGlyphEdge, .stopped, .stoppedText,
        .unread, .unreadText, .added, .removed, .onStopped,
        .claudeEdge, .codexEdge, .opencodeEdge, .kiroEdge, .antigravityEdge
    ])

    /// The pairs that must keep reading as different colors, apart as far
    /// as the tokens are or `minimumDifference`, whichever is less: the
    /// quiet words under the plain ones, and the states beside each other.
    static let distinct: [(WindowColorRole, WindowColorRole)] = [
        (.text, .muted), (.muted, .faint),
        (.waiting, .stopped), (.waiting, .unread), (.stopped, .unread),
        (.waitingText, .stoppedText), (.waitingText, .unreadText), (.stoppedText, .unreadText),
        (.added, .removed), (.added, .waitingText)
    ]

    /// The CIELAB difference two colors in `distinct` need, as the review's
    /// syntax colors do (`SyntaxColors.minimumDifference`).
    static let minimumDifference = SyntaxColors.minimumDifference

    /// The surfaces the system's own controls and labels stand on, held to
    /// text contrast for the system's label color.
    static let labelSurfaces: [WindowColorRole] = [.window, .sidebar, .selection, .popover]

    /// The system label color's opacity, as macOS 26 draws `labelColor`.
    static let systemLabelOpacity = 0.85

    /// How far above black, in CIELAB lightness, the deepest surface stays
    /// when a background has to be raised: enough that the well and the
    /// page do not round to the same 8-bit color as black.
    static let floorMargin = 1.0

    /// How many steps of `OnGroundColor.stepFraction` the text may take
    /// away from the window, and the faintest ink toward it, to read apart
    /// from the quiet ink: all the way to black or white for the text.
    static let spreadSteps = 50

    /// The colors `palette` gives one side, or why that side keeps the
    /// tokens. `isDark` names the side; the background must be of that
    /// side's brightness, since the window's appearance stays the one the
    /// person chose.
    static func resolve(_ palette: TerminalPalette, isDark: Bool) -> Result<[WindowColorRole: SRGB], Refusal> {
        func token(_ role: WindowColorRole) -> SRGB {
            Self.token(for: role).value(isDark: isDark)
        }
        let windowLab = RGB8(token(.window)).lab
        var background = palette.background.lab
        // A background darker than the deepest step below `window` leaves
        // the well and the page no room, so the window stands that far
        // above black instead, in the background's hue; the terminal area
        // keeps the background itself, a step under the window, as the
        // tokens' terminal is. A light background never needs it: its
        // surfaces all step down from the window.
        let deepest = surfaces.map { RGB8(token($0)).lab[0] - windowLab[0] }.min() ?? 0
        let floor = -deepest + Self.floorMargin
        let isRaised = background[0] < floor
        background[0] = max(background[0], floor)
        var values: [WindowColorRole: SRGB] = [:]

        for role in surfaces {
            let lab = RGB8(token(role)).lab
            let lightness = background[0] + (lab[0] - windowLab[0])
            guard let color = RGB8(lightness: lightness, keepingHueOf: background[1], background[2]) else {
                return .failure(.surfaceOutOfRange(role))
            }
            values[role] = SRGB(color)
        }
        if !isRaised {
            values[.window] = SRGB(palette.background)
        }
        values[.terminal] = SRGB(palette.background)

        let textLab = RGB8(token(.text)).lab
        let foreground = palette.foreground.lab
        let span = textLab[0] - windowLab[0]
        for role in inks {
            let lab = RGB8(token(role)).lab
            let share = role == .text || span == 0 ? 1 : (lab[0] - windowLab[0]) / span
            let mixed = zip(background, foreground).map { $0 + ($1 - $0) * share }
            guard let color = RGB8(lightness: mixed[0], keepingHueOf: mixed[1], mixed[2]) else {
                return .failure(.surfaceOutOfRange(role))
            }
            values[role] = SRGB(color)
        }

        for role in fills {
            let lab = RGB8(token(role)).lab
            let lightness = background[0] + (lab[0] - windowLab[0])
            guard let color = RGB8(lightness: lightness, keepingHueOf: lab[1], lab[2]) else {
                return .failure(.surfaceOutOfRange(role))
            }
            values[role] = SRGB(color)
        }

        var colors = side(values, isDark: isDark)
        // Each color that may move is moved against every ground it is held
        // to and at the strictest ratio among them, so it ends one color
        // whatever ground it is drawn on. Twice over: a mark drawn on a
        // color that moved itself, as the stop's "!" is on its red disc,
        // is moved again against where that color ended.
        for _ in 0..<2 {
            for role in movable.sorted(by: { $0.rawValue < $1.rawValue }) {
                let held = TokenContrastRequirements.all.filter { $0.foreground.role == role }
                guard let ratio = held.map(\.ratio).max() else { continue }
                let grounds = held.map { RGB8($0.groundValue(isDark: isDark, in: colors)) }
                let current = RGB8(Self.token(for: role).value(isDark: isDark, in: colors))
                let moved = OnGroundColor.resolve(current, on: grounds, ratio: ratio)
                if moved.isReached, moved.color != current {
                    values[role] = SRGB(moved.color)
                    colors = side(values, isDark: isDark)
                }
            }
        }

        // A foreground close to its background leaves the quiet ink, moved
        // up to its ratio, too close to the text to tell apart. Room is made
        // outward: the text steps away from the window, and the faintest
        // ink back toward it, until the pair reads apart or runs out of
        // room.
        let window = RGB8(SupervisionTokens.window.value(isDark: isDark, in: colors))
        let extreme = window.contrast(with: RGB8(r: 0, g: 0, b: 0)) > window.contrast(with: RGB8(r: 255, g: 255, b: 255))
            ? RGB8(r: 0, g: 0, b: 0) : RGB8(r: 255, g: 255, b: 255)
        func spread(_ moving: WindowColorRole, from fixed: WindowColorRole, toward target: RGB8) {
            let needed = min(minimumDifference, difference(token(moving), token(fixed)))
            let start = RGB8(Self.token(for: moving).value(isDark: isDark, in: colors))
            let other = RGB8(Self.token(for: fixed).value(isDark: isDark, in: colors))
            var step = 0
            var candidate = start
            while candidate.difference(from: other) < needed, step < Self.spreadSteps {
                step += 1
                candidate = target.composited(over: start, opacity: Double(step) * OnGroundColor.stepFraction)
            }
            if candidate != start {
                values[moving] = SRGB(candidate)
                colors = side(values, isDark: isDark)
            }
        }
        spread(.text, from: .muted, toward: extreme)
        spread(.faint, from: .muted, toward: window)

        if let refusal = refusal(of: colors, isDark: isDark) {
            return .failure(refusal)
        }
        // Only what differs from the token, so a side whose theme matches
        // the tokens compares equal to them.
        return .success(values.filter { $0.value != token($0.key) })
    }

    /// The token that carries `role`. Every role has one
    /// (`WindowColorResolverTests`); `window` stands in for none.
    static func token(for role: WindowColorRole) -> ThemedColor {
        tokensByRole[role] ?? SupervisionTokens.window
    }

    /// Why `colors` cannot stand for the tokens on one side: a requirement
    /// they miss, or a pair that came too close; `nil` when they can.
    private static func refusal(of colors: WindowColors, isDark: Bool) -> Refusal? {
        func token(_ role: WindowColorRole) -> SRGB {
            Self.token(for: role).value(isDark: isDark)
        }
        func drawn(_ role: WindowColorRole) -> SRGB {
            Self.token(for: role).value(isDark: isDark, in: colors)
        }
        let text = drawn(.text).luminance
        let window = drawn(.window).luminance
        if isDark ? text <= window : text >= window {
            return .invertedInk
        }
        // The system's label: white in dark and black in light at its
        // opacity, laid over each surface the window's controls stand on.
        let label = isDark ? SRGB(0xFFFFFF) : SRGB(0x000000)
        for role in labelSurfaces {
            let ground = drawn(role)
            let seen = SRGB(
                red: label.red * systemLabelOpacity + ground.red * (1 - systemLabelOpacity),
                green: label.green * systemLabelOpacity + ground.green * (1 - systemLabelOpacity),
                blue: label.blue * systemLabelOpacity + ground.blue * (1 - systemLabelOpacity)
            )
            if ContrastRatio.between(seen, ground) < ContrastRatio.text {
                return .systemLabel(role)
            }
        }
        for requirement in TokenContrastRequirements.all
            where requirement.contrast(isDark: isDark, in: colors) < requirement.ratio
        {
            return .contrast(requirement.name)
        }
        for (first, second) in distinct {
            let needed = min(minimumDifference, difference(token(first), token(second)))
            let drawn = difference(
                Self.token(for: first).value(isDark: isDark, in: colors),
                Self.token(for: second).value(isDark: isDark, in: colors)
            )
            if drawn < needed {
                return .indistinct(first, second)
            }
        }
        return nil
    }

    /// Every token that carries a role, by its role.
    private static let tokensByRole: [WindowColorRole: ThemedColor] = {
        typealias Tokens = SupervisionTokens
        let tokens = [
            Tokens.page, Tokens.well, Tokens.window, Tokens.sidebar, Tokens.column, Tokens.selection,
            Tokens.railSelection, Tokens.hover, Tokens.segmentHover, Tokens.line, Tokens.popover, Tokens.terminal,
            Tokens.stateFillButton, Tokens.stateFillButtonHover, Tokens.stateFillButtonPressed, Tokens.stateFillButtonEdge,
            Tokens.text, Tokens.muted, Tokens.faint, Tokens.running,
            Tokens.waitingFill, Tokens.stoppedFill, Tokens.unreadFill,
            Tokens.waiting, Tokens.waitingText, Tokens.waitingGlyphEdge, Tokens.stopped, Tokens.stoppedText,
            Tokens.unread, Tokens.unreadText, Tokens.added, Tokens.removed, Tokens.onStopped,
            Tokens.claudeEdge, Tokens.codexEdge, Tokens.opencodeEdge, Tokens.kiroEdge, Tokens.antigravityEdge
        ]
        return Dictionary(uniqueKeysWithValues: tokens.compactMap { token in token.role.map { ($0, token) } })
    }()

    private static func side(_ values: [WindowColorRole: SRGB], isDark: Bool) -> WindowColors {
        isDark ? WindowColors(light: [:], dark: values) : WindowColors(light: values, dark: [:])
    }

    private static func difference(_ first: SRGB, _ second: SRGB) -> Double {
        RGB8(first).difference(from: RGB8(second))
    }
}

extension SRGB {
    /// `color`'s channels, as 0...1.
    init(_ color: RGB8) {
        self.init(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }
}
