// WindowColorResolverTests.swift
// Weir — covers how the window's colors follow a terminal theme and keep every contrast the tokens keep.

import AppKit
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Window color resolver")
@MainActor
struct WindowColorResolverTests {
    private static func palette(background: UInt32, foreground: UInt32) -> TerminalPalette {
        func rgb(_ hex: UInt32) -> RGB8 {
            RGB8(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF))
        }
        return TerminalPalette(
            background: rgb(background),
            foreground: rgb(foreground),
            ansi: Array(repeating: rgb(0x808080), count: TerminalPalette.ansiCount)
        )
    }

    /// A dark blue theme and a warm light one, both far enough from the
    /// tokens to move every surface, and both able to keep every contrast.
    private static let darkTheme = palette(background: 0x1E2433, foreground: 0xD8DEE9)
    private static let lightTheme = palette(background: 0xFAF4E6, foreground: 0x3B3A36)

    private func resolved(_ palette: TerminalPalette, isDark: Bool) throws -> WindowColors {
        let values = try WindowColorResolver.resolve(palette, isDark: isDark).get()
        return isDark ? WindowColors(light: [:], dark: values) : WindowColors(light: values, dark: [:])
    }

    // MARK: The rule

    @Test(arguments: [false, true])
    func aThemeTheTokensCanFollowKeepsEveryRequirement(isDark: Bool) throws {
        let colors = try resolved(isDark ? Self.darkTheme : Self.lightTheme, isDark: isDark)
        #expect(!colors.isTokens)
        for requirement in TokenContrastRequirements.all {
            let ratio = requirement.contrast(isDark: isDark, in: colors)
            #expect(ratio >= requirement.ratio, "\(requirement.name): \(ratio)")
        }
    }

    @Test(arguments: [false, true])
    func theWindowIsTheBackgroundAndTheTextIsTheForeground(isDark: Bool) throws {
        let theme = isDark ? Self.darkTheme : Self.lightTheme
        let colors = try resolved(theme, isDark: isDark)
        #expect(SupervisionTokens.window.value(isDark: isDark, in: colors) == SRGB(theme.background))
        #expect(SupervisionTokens.text.value(isDark: isDark, in: colors) == SRGB(theme.foreground))
    }

    /// Each surface keeps the step it has from the window, so the well
    /// stays under the window and the selection apart from the hover.
    @Test(arguments: [false, true])
    func theSurfacesKeepTheirOrder(isDark: Bool) throws {
        let colors = try resolved(isDark ? Self.darkTheme : Self.lightTheme, isDark: isDark)
        func lightness(_ token: ThemedColor, in colors: WindowColors) -> Double {
            RGB8(token.value(isDark: isDark, in: colors)).lab[0]
        }
        // The terminal area is the background itself, not a step from it.
        let surfaces = WindowColorResolver.surfaces.filter { $0 != .terminal }.map(WindowColorResolver.token(for:))
        for first in surfaces {
            for second in surfaces {
                let tokenOrder = lightness(first, in: .tokens) - lightness(second, in: .tokens)
                let drawnOrder = lightness(first, in: colors) - lightness(second, in: colors)
                // Within a rounding step of 8 bits a channel.
                #expect(abs(tokenOrder - drawnOrder) < 1, "\(String(describing: first.role)) and \(String(describing: second.role))")
            }
        }
    }

    /// Black leaves the well and the page no room under the window, so the
    /// window stands above black, and the terminal area keeps the black.
    @Test func aBlackBackgroundRaisesTheWindowAndKeepsTheTerminalBlack() throws {
        let theme = Self.palette(background: 0x000000, foreground: 0xFFFFFF)
        let colors = try resolved(theme, isDark: true)
        let well = SupervisionTokens.well.value(isDark: true, in: colors)
        let window = SupervisionTokens.window.value(isDark: true, in: colors)
        #expect(RGB8(well) != RGB8(r: 0, g: 0, b: 0))
        #expect(RGB8(well).lab[0] < RGB8(window).lab[0])
        #expect(SupervisionTokens.terminal.value(isDark: true, in: colors) == SRGB(theme.background))
    }

    @Test func aWhiteBackgroundKeepsEverySurfaceInRange() throws {
        // Every light surface is darker than the window, so white has room.
        _ = try resolved(Self.palette(background: 0xFFFFFF, foreground: 0x222222), isDark: false)
    }

    @Test func aForegroundTooCloseToTheBackgroundKeepsTheTokens() {
        let result = WindowColorResolver.resolve(Self.palette(background: 0x777777, foreground: 0x808080), isDark: true)
        guard case .failure = result else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func theDefaultPairsColorsAreTheTokensThemselves() {
        // The tokens' own window and text give back only the roles whose
        // derived value differs; none of the surfaces does.
        let light = WindowColorResolver.resolve(Self.palette(background: 0xFFFFFF, foreground: 0x1C1E22), isDark: false)
        if case let .success(values) = light {
            #expect(values[.window] == nil)
            #expect(values[.text] == nil)
        }
    }

    /// A mid gray counted as dark, with a lighter foreground the resolver
    /// would have to flip dark: the appearance's own labels, white, would
    /// not read on it.
    @Test func aBackgroundTheSystemLabelCannotReadOnKeepsTheTokens() {
        let result = WindowColorResolver.resolve(Self.palette(background: 0xAAAAAA, foreground: 0xF0F0F0), isDark: true)
        guard case .failure = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
    }

    /// Whatever passes, the text keeps 4.5:1 on a state fill's button in
    /// every state, the pressed one included.
    @Test func aThemeThatPassesKeepsTheTextOnEveryStateFillButton() {
        for background: UInt32 in [0x444444, 0x2B2B2B, 0x1E2433, 0x303446] {
            let theme = Self.palette(background: background, foreground: 0xF0F0F0)
            guard case let .success(values) = WindowColorResolver.resolve(theme, isDark: true) else { continue }
            let colors = WindowColors(light: [:], dark: values)
            let text = SupervisionTokens.text.value(isDark: true, in: colors)
            for face in [
                SupervisionTokens.stateFillButton,
                SupervisionTokens.stateFillButtonHover,
                SupervisionTokens.stateFillButtonPressed
            ] {
                let ratio = ContrastRatio.between(text, face.value(isDark: true, in: colors))
                #expect(ratio >= ContrastRatio.text, "\(String(format: "%06X", background)): \(ratio)")
            }
        }
    }

    /// An AppKit color made before the theme changed draws the new theme:
    /// a pooled review row keeps the colors it was given.
    @Test func anAppKitColorDrawsTheColorsInUseWhenItDraws() throws {
        defer { AppKitWindowColors.set(.tokens) }
        AppKitWindowColors.set(.tokens)
        let color = AppKitWindowColors.color(SupervisionTokens.muted)
        let appearance = try #require(NSAppearance(named: .darkAqua))
        func drawn() throws -> SRGB {
            try #require(SRGB(color, in: appearance))
        }
        #expect(try drawn() == SupervisionTokens.muted.dark)
        let themed = SRGB(0x8899AA)
        AppKitWindowColors.set(WindowColors(light: [:], dark: [.muted: themed]))
        let after = try drawn()
        #expect(abs(after.red - themed.red) < 0.002 && abs(after.blue - themed.blue) < 0.002)
    }

    @Test func everyRoleHasTheTokenThatCarriesIt() {
        for role in WindowColorRole.allCases {
            #expect(WindowColorResolver.token(for: role).role == role, "\(role)")
        }
    }

    // MARK: The store

    private func store(scope: TerminalThemeScope, live: TerminalPalette) -> TerminalThemeStore {
        let store = TerminalThemeStore()
        let bundled = Self.palette(background: 0x202020, foreground: 0xEEEEEE)
        store.setBundledPalettes(light: Self.palette(background: 0xFEFFFF, foreground: 0x000000), dark: bundled)
        store.update(light: Self.lightTheme, dark: live)
        store.setScope(scope)
        return store
    }

    @Test func theTerminalScopeLeavesEveryToken() {
        #expect(store(scope: .terminal, live: Self.darkTheme).windowColors == .tokens)
        #expect(TerminalThemeStore().windowColors == .tokens)
    }

    @Test func theWindowScopeTakesBothSides() {
        let colors = store(scope: .window, live: Self.darkTheme).windowColors
        #expect(!colors.light.isEmpty)
        #expect(!colors.dark.isEmpty)
    }

    @Test func aSideOnTheBundledGroundKeepsItsTokens() {
        let store = TerminalThemeStore()
        let bundled = Self.palette(background: 0x202020, foreground: 0xEEEEEE)
        store.setBundledPalettes(light: Self.lightTheme, dark: bundled)
        store.update(light: Self.lightTheme, dark: bundled)
        store.setScope(.window)
        #expect(store.windowColors == .tokens)
    }

    @Test func aBackgroundOfTheOtherBrightnessKeepsItsSidesTokens() {
        // A light theme chosen for the dark side: the appearance stays
        // dark, so that side keeps the tokens.
        let colors = store(scope: .window, live: Self.lightTheme).windowColors
        #expect(colors.dark.isEmpty)
        #expect(!colors.light.isEmpty)
    }

    @Test func anEqualReloadKeepsTheSameValue() {
        let store = store(scope: .window, live: Self.darkTheme)
        let before = store.windowColors
        store.update(light: Self.lightTheme, dark: Self.darkTheme)
        store.setScope(.window)
        #expect(store.windowColors == before)
    }

    // MARK: Drawing

    @Test func aTokensStyleDrawsTheThemesColorOnItsSideAndTheTokenElsewhere() {
        let themed = SRGB(0x336699)
        let colors = WindowColors(light: [.window: themed], dark: [:])
        func drawn(_ scheme: ColorScheme, _ colors: WindowColors) -> Color.Resolved {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            environment.weirWindowColors = colors
            return SupervisionTokens.window.color.resolve(in: environment)
        }
        let light = drawn(.light, colors)
        #expect(abs(Double(light.red) - themed.red) < 0.001)
        #expect(abs(Double(light.blue) - themed.blue) < 0.001)
        let dark = drawn(.dark, colors)
        #expect(abs(Double(dark.red) - SupervisionTokens.window.dark.red) < 0.001)
        // A token with no role ignores the theme.
        var environment = EnvironmentValues()
        environment.weirWindowColors = WindowColors(light: [.window: themed], dark: [.window: themed])
        environment.colorScheme = .light
        let toast = SupervisionTokens.toastLink.color.resolve(in: environment)
        #expect(abs(Double(toast.red) - SupervisionTokens.toastLink.light.red) < 0.001)
    }

    /// The style draws exactly what the token's dynamic color draws, so a
    /// view drawn in the style looks as one drawn in the color.
    @Test(arguments: [false, true])
    func aTokensStyleMatchesItsDynamicColor(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        var environment = EnvironmentValues()
        environment.colorScheme = isDark ? .dark : .light
        for role in WindowColorRole.allCases {
            let token = WindowColorResolver.token(for: role)
            let style = token.color.resolve(in: environment)
            var drawn: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                drawn = token.nsColor.usingColorSpace(.sRGB)
            }
            let color = try #require(drawn)
            #expect(abs(Double(style.red) - color.redComponent) < 0.002, "\(role)")
            #expect(abs(Double(style.green) - color.greenComponent) < 0.002, "\(role)")
            #expect(abs(Double(style.blue) - color.blueComponent) < 0.002, "\(role)")
        }
    }
}
