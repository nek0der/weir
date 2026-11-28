// TerminalThemeStore.swift
// Weir — the terminal colors libghostty resolved for each appearance, for views that match them.

import Foundation
import Observation
import WeirDomain

/// The palette the running terminal uses on each side (light and dark), as
/// read back from libghostty after each config load.
///
/// `AppState` owns the one instance and refreshes it at launch and after
/// every successful reload. A side is `nil` until a read-back succeeds, or
/// when libghostty is unavailable; views then keep their own colors.
@MainActor
@Observable
final class TerminalThemeStore {
    /// The light side's palette; `nil` while it has not been read.
    private(set) var light: TerminalPalette?
    /// The dark side's palette; `nil` while it has not been read.
    private(set) var dark: TerminalPalette?
    /// Increases each time `light` or `dark` changes, and only then, so a
    /// view that caches derived colors can key them on one integer.
    private(set) var revision = 0

    /// The bundled default theme's palette on each side, read the same way
    /// as the live palettes so `paintsGround(for:)` and
    /// `followsTheme(for:)` compare like with like. `nil` while it has not
    /// been read.
    private(set) var bundledLight: TerminalPalette?
    private(set) var bundledDark: TerminalPalette?

    /// The chosen themes that were not found when the config was last
    /// built, by side; each such side uses the bundled default. Settings
    /// reads it, since at launch no window can show a toast about it.
    private(set) var fallbacks: [TerminalThemeBrightness: TerminalThemeRef] = [:]

    /// How far the theme colors the window, from Settings.
    private(set) var scope = TerminalThemeScope.terminal

    /// The colors the theme gives the window's tokens, every token as it
    /// is unless `scope` is `.window` (`WindowColorResolver`). Made again
    /// only when what it is made from changes, and set only when it differs,
    /// so a reload with the same colors redraws nothing.
    var windowColors = WindowColors.tokens

    init() {}

    /// Records how far the theme colors the window.
    func setScope(_ scope: TerminalThemeScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        refreshWindowColors()
    }

    /// Records which chosen themes the last config build could not use.
    func setFallbacks(_ fallbacks: [TerminalThemeBrightness: TerminalThemeRef]) {
        guard fallbacks != self.fallbacks else { return }
        self.fallbacks = fallbacks
    }

    /// Replaces both palettes, bumping `revision` only when either differs.
    func update(light: TerminalPalette?, dark: TerminalPalette?) {
        guard light != self.light || dark != self.dark else { return }
        self.light = light
        self.dark = dark
        revision += 1
        refreshWindowColors()
    }

    /// Records the bundled default theme's palette for each side.
    func setBundledPalettes(light: TerminalPalette?, dark: TerminalPalette?) {
        bundledLight = light
        bundledDark = dark
        refreshWindowColors()
    }

    /// The palette of `side`, or `nil` while it has not been read.
    func palette(for side: TerminalThemeBrightness) -> TerminalPalette? {
        switch side {
        case .light: light
        case .dark: dark
        }
    }

    /// Whether the terminal's background on `side` differs from the bundled
    /// default's, so surfaces around the pane have a ground of their own to
    /// match. `false` while either color has not been read.
    func paintsGround(for side: TerminalThemeBrightness) -> Bool {
        guard let background = palette(for: side)?.background,
              let bundled = bundledPalette(for: side)?.background
        else { return false }
        return background != bundled
    }

    /// Whether the terminal's ANSI colors on `side` differ from the bundled
    /// default's, so the review's syntax colors take them
    /// (`ReviewSyntaxColors`). `false` while either palette has not been
    /// read.
    func followsTheme(for side: TerminalThemeBrightness) -> Bool {
        guard let ansi = palette(for: side)?.ansi, let bundled = bundledPalette(for: side)?.ansi else { return false }
        return ansi != bundled
    }

    private func bundledPalette(for side: TerminalThemeBrightness) -> TerminalPalette? {
        switch side {
        case .light: bundledLight
        case .dark: bundledDark
        }
    }
}
