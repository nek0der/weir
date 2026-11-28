// ReviewSyntaxColors.swift
// Weir — the review's syntax colors on each appearance, from the terminal theme where it has its own.

import AppKit
import SwiftUI
import WeirDomain

/// The color each syntax role takes on each appearance. A side with no
/// colors keeps the review's system colors (`systemColor(for:)`), and the
/// bundled default pair gives neither side any, so it draws in the system
/// colors.
///
/// Both sides are held at once, as `ThemedColor` holds its two values:
/// some views draw in an appearance other than the app's, and AppKit picks
/// the side as it draws, so switching the appearance needs no reload.
struct ReviewSyntaxColors: Equatable {
    /// Every role on the system color.
    static let system = ReviewSyntaxColors(light: [:], dark: [:])

    var light: [SyntaxRole: RGB8]
    var dark: [SyntaxRole: RGB8]

    /// The color the review draws without a theme's: a system color, which
    /// follows the appearance on its own.
    static func systemColor(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword: .systemPink
        case .string: .systemRed
        case .number: .systemOrange
        case .comment: .secondaryLabelColor
        }
    }

    /// One dynamic color for `role`, or the system color itself when
    /// neither side has a theme color for it.
    func nsColor(for role: SyntaxRole) -> NSColor {
        let light = light[role]
        let dark = dark[role]
        let system = Self.systemColor(for: role)
        guard light != nil || dark != nil else { return system }
        return NSColor(name: nil) { appearance in
            if let color = appearance.isDark ? dark : light {
                return color.nsColor
            }
            // Resolved in the appearance asked for: what a provider returns
            // is drawn as it is, and the system color is dynamic itself.
            var resolved = system
            appearance.performAsCurrentDrawingAppearance {
                resolved = system.usingColorSpace(.sRGB) ?? system
            }
            return resolved
        }
    }
}

@MainActor
extension TerminalThemeStore {
    /// The review's syntax colors for the theme in use, checked against the
    /// grounds the review draws code on, the selected line's fill in the
    /// painter's accent among them (`ReviewRowPainter.accent`).
    func reviewSyntaxColors() -> ReviewSyntaxColors {
        ReviewSyntaxColors(light: reviewSyntax(on: .light), dark: reviewSyntax(on: .dark))
    }

    private func reviewSyntax(on side: TerminalThemeBrightness) -> [SyntaxRole: RGB8] {
        guard followsTheme(for: side), let palette = palette(for: side) else { return [:] }
        let surface = Self.reviewSurface(on: side, windowColors: windowColors)
        return SyntaxColors.resolve(
            palette,
            on: Self.reviewGrounds(on: side, windowColors: windowColors),
            // The plain code's ink, as the painter draws it (`plainInk`).
            ink: windowColors.value(.text, isDark: side == .dark).map(RGB8.init)
                ?? RGB8(seeing: Color(nsColor: .labelColor), over: surface, colorScheme: side.colorScheme)
        )
    }

    /// The grounds a line's code is drawn on, as seen on `side`: the
    /// surface, and the review's own fills for a whole line over it, from
    /// the painter that draws them.
    ///
    /// The fill under changed characters is left out: it covers a few
    /// characters of a changed line, and holding every color to it as well
    /// washed the hues of many themes out toward white or black. The
    /// surface is taken as opaque; under transparency the wallpaper shows
    /// through as well, which we cannot read.
    static func reviewGrounds(on side: TerminalThemeBrightness, windowColors: WindowColors = .tokens) -> [RGB8] {
        let surface = reviewSurface(on: side, windowColors: windowColors)
        let fills = [
            ReviewRowPainter.background(for: .added, isSelected: false),
            ReviewRowPainter.background(for: .removed, isSelected: false)
        ]
        return [surface]
            + fills.map { RGB8(seeing: Color(nsColor: $0), over: surface, colorScheme: side.colorScheme) }
            + [reviewSelectionFill(on: side, windowColors: windowColors)]
    }

    /// The selected line's fill over the surface on `side`, in the
    /// painter's accent as it is drawn now.
    static func reviewSelectionFill(on side: TerminalThemeBrightness, windowColors: WindowColors = .tokens) -> RGB8 {
        RGB8(
            seeing: Color(nsColor: ReviewRowPainter.background(for: .context, isSelected: true)),
            over: reviewSurface(on: side, windowColors: windowColors),
            colorScheme: side.colorScheme
        )
    }

    /// The review's surface, `window`, in the window's colors.
    private static func reviewSurface(on side: TerminalThemeBrightness, windowColors: WindowColors) -> RGB8 {
        RGB8(SupervisionTokens.window.value(isDark: side == .dark, in: windowColors))
    }
}

extension TerminalThemeBrightness {
    /// The appearance that shows this side of the terminal theme.
    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

extension RGB8 {
    /// `color` as it is seen in `colorScheme` laid over `ground`, its own
    /// opacity included: the review's fills and the secondary label are
    /// partly transparent.
    init(seeing color: Color, over ground: RGB8, colorScheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let opacity = Double(color.resolve(in: environment).opacity)
        self = RGB8(color, colorScheme: colorScheme).composited(over: ground, opacity: opacity)
    }

    /// The color as AppKit draws it.
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
