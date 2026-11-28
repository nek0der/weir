// WindowColors.swift
// Weir — the window's colors a terminal theme can take over, and how a view draws a token in them.

import AppKit
import SwiftUI
import Synchronization
import WeirDomain

/// A token the terminal theme can give a value of its own
/// (`WindowColorResolver`). The raw values name the role in anything stored
/// or reported, apart from the Swift names, so a renamed token keeps them.
enum WindowColorRole: String, CaseIterable, Sendable {
    // Neutral surfaces, derived from the theme's background.
    case page, well, window, sidebar, column, selection, railSelection, hover
    case segmentHover, line, popover, terminal
    case stateFillButton, stateFillButtonHover, stateFillButtonPressed, stateFillButtonEdge
    // Neutral inks, derived from the theme's foreground.
    case text, muted, faint, running
    // A state's soft fill, its hue kept and its lightness taken from the
    // background.
    case waitingFill, stoppedFill, unreadFill
    // State colors and edges, kept unless they must move to stand out.
    case waiting, waitingText, waitingGlyphEdge, stopped, stoppedText
    case unread, unreadText, added, removed
    case onStopped
    case claudeEdge, codexEdge, opencodeEdge, kiroEdge, antigravityEdge
}

/// The colors a terminal theme gives the window's tokens, on each
/// appearance. A role absent on a side keeps its token there, so `tokens`,
/// with nothing on either side, draws every token as it is.
///
/// Both sides are held at once, as `ThemedColor` holds its two values:
/// the side is picked as a view is drawn, so an appearance switch needs no
/// new value, and an equal value set again changes nothing a view reads.
struct WindowColors: Equatable, Sendable {
    /// Every token as it is.
    static let tokens = WindowColors(light: [:], dark: [:])

    var light: [WindowColorRole: SRGB]
    var dark: [WindowColorRole: SRGB]

    /// The theme's color for `role` on the side `isDark` names, or `nil`
    /// where the token stands.
    func value(_ role: WindowColorRole, isDark: Bool) -> SRGB? {
        isDark ? dark[role] : light[role]
    }

    /// Whether neither side has a color of its own.
    var isTokens: Bool {
        light.isEmpty && dark.isEmpty
    }
}

extension EnvironmentValues {
    /// The window's colors from the terminal theme. Every token as it is
    /// by default, so a view drawn where no root set it, such as a menu's
    /// image or a test's host, draws the tokens it was checked with.
    @Entry var weirWindowColors = WindowColors.tokens
}

extension ThemedColor {
    /// This token's value on one side, the theme's where it has one.
    func value(isDark: Bool, in colors: WindowColors) -> SRGB {
        role.flatMap { colors.value($0, isDark: isDark) } ?? value(isDark: isDark)
    }
}

/// A token as SwiftUI draws it: the theme's color for its role where the
/// environment's `WindowColors` has one, else the token, on the side the
/// view's color scheme names. Resolved as the view draws, so a new theme
/// repaints the views that draw it without running their bodies again.
struct ThemedStyle: ShapeStyle, Equatable, Sendable {
    let light: SRGB
    let dark: SRGB
    let role: WindowColorRole?

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let isDark = environment.colorScheme == .dark
        let value = role.flatMap { environment.weirWindowColors.value($0, isDark: isDark) } ?? (isDark ? dark : light)
        return Color.Resolved(colorSpace: .sRGB, red: Float(value.red), green: Float(value.green), blue: Float(value.blue))
    }
}

extension TerminalThemeStore {
    /// Makes `windowColors` again from the palettes and the scope, and sets
    /// it only when it differs.
    func refreshWindowColors() {
        let colors = scope == .window
            ? WindowColors(light: derivedWindowColors(for: .light), dark: derivedWindowColors(for: .dark))
            : .tokens
        if colors != windowColors {
            windowColors = colors
        }
    }

    /// The colors one side's theme gives the window, or none where the
    /// tokens stand: the bundled default's background (`paintsGround`), a
    /// side not yet read, a background whose brightness is not the side's,
    /// and a theme whose colors could not keep every contrast.
    private func derivedWindowColors(for side: TerminalThemeBrightness) -> [WindowColorRole: SRGB] {
        guard paintsGround(for: side), let palette = palette(for: side),
              TerminalThemeBrightness(background: palette.background) == side
        else { return [:] }
        return (try? WindowColorResolver.resolve(palette, isDark: side == .dark).get()) ?? [:]
    }
}

/// An edge drawn only where a terminal theme moved its role's color, and
/// clear otherwise: a mark that needs no edge under the tokens takes one
/// under a theme whose surfaces it stands too close to.
struct ThemedEdgeStyle: ShapeStyle, Equatable, Sendable {
    let role: WindowColorRole

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        guard let value = environment.weirWindowColors.value(role, isDark: environment.colorScheme == .dark) else {
            return Color.Resolved(colorSpace: .sRGB, red: 0, green: 0, blue: 0, opacity: 0)
        }
        return Color.Resolved(colorSpace: .sRGB, red: Float(value.red), green: Float(value.green), blue: Float(value.blue))
    }
}

/// The window's colors as AppKit views draw them: one dynamic color per
/// token, made once, that reads the colors in use as it resolves. A view
/// that keeps the color it was given, as a pooled review row keeps its
/// labels', draws the new colors on its next draw without being handed a
/// new one. The colors are held behind a lock rather than on the main actor:
/// AppKit may resolve a dynamic color on any thread.
enum AppKitWindowColors {
    private static let current = Mutex(WindowColors.tokens)
    private static let made = Mutex([WindowColorRole: NSColor]())

    /// The colors the window draws in now.
    static var colors: WindowColors {
        current.withLock { $0 }
    }

    /// Records the colors the window draws in. Returns whether they
    /// changed, so the caller redraws only then.
    @discardableResult
    static func set(_ colors: WindowColors) -> Bool {
        current.withLock { value in
            guard value != colors else { return false }
            value = colors
            return true
        }
    }

    /// `token` in the colors in use, or its own dynamic color when it has no
    /// role.
    static func color(_ token: ThemedColor) -> NSColor {
        guard let role = token.role else { return token.nsColor }
        return made.withLock { made in
            if let color = made[role] {
                return color
            }
            let color = dynamicColor(token)
            made[role] = color
            return color
        }
    }

    /// `fallback` where the colors in use give `role` nothing, the theme's
    /// color for it otherwise: the review's number strip lays its coat over
    /// the system's window color, which no token carries.
    static func color(_ role: WindowColorRole, otherwise fallback: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            if let value = colors.value(role, isDark: appearance.isDark) {
                return value.nsColor
            }
            // Resolved in the appearance asked for: what a provider returns
            // is drawn as it is, and the system color is dynamic itself.
            var resolved = fallback
            appearance.performAsCurrentDrawingAppearance {
                resolved = fallback.usingColorSpace(.sRGB) ?? fallback
            }
            return resolved
        }
    }

    private static func dynamicColor(_ token: ThemedColor) -> NSColor {
        NSColor(name: nil) { appearance in
            token.value(isDark: appearance.isDark, in: colors).nsColor
        }
    }
}
