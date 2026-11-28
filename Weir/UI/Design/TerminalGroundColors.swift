// TerminalGroundColors.swift
// Weir — turns the tokens into `TerminalGround`'s colors and its values back into SwiftUI and AppKit ones.

import AppKit
import SwiftUI
import WeirDomain

extension TerminalThemeBrightness {
    /// The side of the terminal theme that `scheme` shows.
    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

extension TerminalThemeStore {
    /// The ground and its marks for the appearance a view is drawn in,
    /// with the tokens and `accent` resolved for that appearance. The
    /// marks are checked against the ground as a pane shows it, laid over
    /// the surface at `surfaceOpacity` and, without focus, faded to
    /// `unfocusedPaneOpacity` (`TerminalGround.Backdrop`). The tokens and
    /// the surface are taken in `windowColors`, so a window that follows
    /// the theme corrects the colors it draws.
    func ground(
        colorScheme: ColorScheme,
        accent: Color,
        surfaceOpacity: Double,
        unfocusedPaneOpacity: Double,
        windowColors: WindowColors
    ) -> TerminalGround {
        let side = TerminalThemeBrightness(colorScheme)
        // Nothing to correct while nothing is painted, so the tokens and
        // the accent are not resolved then.
        guard paintedGround(for: side) != nil else { return .unpainted }
        let isDark = colorScheme == .dark
        return ground(
            for: side,
            tokens: TerminalGround.Tokens(
                waiting: RGB8(SupervisionTokens.waiting.value(isDark: isDark, in: windowColors)),
                stopped: RGB8(SupervisionTokens.stopped.value(isDark: isDark, in: windowColors)),
                accent: RGB8(accent, colorScheme: colorScheme)
            ),
            backdrop: TerminalGround.Backdrop(
                surface: RGB8(SupervisionTokens.window.value(isDark: isDark, in: windowColors)),
                surfaceOpacity: surfaceOpacity,
                unfocusedPaneOpacity: unfocusedPaneOpacity
            )
        )
    }
}

extension RGB8 {
    /// `srgb`, rounded to 8 bits a channel.
    init(_ srgb: SRGB) {
        self.init(r: Self.channel(srgb.red), g: Self.channel(srgb.green), b: Self.channel(srgb.blue))
    }

    /// `color` as it is drawn in `colorScheme`. A system color, the accent
    /// among them, differs between light and dark.
    init(_ color: Color, colorScheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let resolved = color.resolve(in: environment)
        self.init(
            r: Self.channel(Double(resolved.red)),
            g: Self.channel(Double(resolved.green)),
            b: Self.channel(Double(resolved.blue))
        )
    }

    /// The color as SwiftUI draws it.
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// A channel from 0...1, clamped: a wide-gamut color can fall outside.
    private static func channel(_ value: Double) -> UInt8 {
        UInt8((min(1, max(0, value)) * 255).rounded())
    }
}

extension TerminalGround.KnobStyle {
    var scrollerKnobStyle: NSScroller.KnobStyle {
        switch self {
        case .automatic: .default
        case .light: .light
        case .dark: .dark
        }
    }
}
