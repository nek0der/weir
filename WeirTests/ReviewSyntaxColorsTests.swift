// ReviewSyntaxColorsTests.swift
// Weir — covers how the review's syntax colors follow the terminal theme.

import AppKit
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Review syntax colors")
@MainActor
struct ReviewSyntaxColorsTests {
    private static let white = RGB8(r: 0xFF, g: 0xFF, b: 0xFF)
    private static let black = RGB8(r: 0, g: 0, b: 0)

    /// A palette whose ANSI entries are all `filler` except the four the
    /// review takes.
    private func palette(
        background: RGB8 = RGB8(r: 0x20, g: 0x20, b: 0x20),
        keyword: RGB8 = RGB8(r: 0xC0, g: 0x60, b: 0xF0),
        string: RGB8 = RGB8(r: 0xF0, g: 0x60, b: 0x50),
        number: RGB8 = RGB8(r: 0xE0, g: 0xC0, b: 0x40),
        comment: RGB8 = RGB8(r: 0x80, g: 0x80, b: 0x80),
        filler: RGB8 = RGB8(r: 0x40, g: 0x40, b: 0x40)
    ) -> TerminalPalette {
        var ansi = Array(repeating: filler, count: TerminalPalette.ansiCount)
        ansi[SyntaxRole.keyword.ansiIndex] = keyword
        ansi[SyntaxRole.string.ansiIndex] = string
        ansi[SyntaxRole.number.ansiIndex] = number
        ansi[SyntaxRole.comment.ansiIndex] = comment
        return TerminalPalette(background: background, foreground: Self.white, ansi: ansi)
    }

    // MARK: The rule

    @Test func colorsThatAlreadyStandOutAreKept() {
        let theme = palette()
        let resolved = SyntaxColors.resolve(theme, on: [Self.black], ink: Self.white)
        #expect(resolved[.keyword] == theme.ansi[5])
        #expect(resolved[.string] == theme.ansi[1])
        #expect(resolved[.number] == theme.ansi[3])
        #expect(resolved[.comment] == theme.ansi[8])
    }

    @Test func aColorTooFaintForTheGroundIsMovedUntilItReaches() throws {
        let theme = palette(number: RGB8(r: 0xF0, g: 0xE0, b: 0x60))
        let grounds = [Self.white, RGB8(r: 0xE0, g: 0xF0, b: 0xE0)]
        let resolved = SyntaxColors.resolve(theme, on: grounds, ink: Self.black)
        let number = try #require(resolved[.number])
        #expect(number != theme.ansi[3])
        #expect(OnGroundColor.lowestContrast(of: number, on: grounds) >= SyntaxColors.ratio)
    }

    @Test func aRoleNoStepCanSaveGivesTheCallerAllFour() {
        // Nothing reaches 3:1 against white, black, and a mid gray at once.
        let grounds = [Self.white, Self.black, RGB8(r: 0x77, g: 0x77, b: 0x77)]
        #expect(SyntaxColors.resolve(palette(), on: grounds, ink: Self.black).isEmpty)
    }

    @Test func colorsThatBlurIntoEachOtherGiveTheCallerAllFour() {
        let same = RGB8(r: 0xC0, g: 0x60, b: 0xF0)
        let theme = palette(keyword: same, string: RGB8(r: 0xC4, g: 0x64, b: 0xF0))
        #expect(SyntaxColors.resolve(theme, on: [Self.black], ink: Self.white).isEmpty)
    }

    @Test func aColorLikeThePlainTextGivesTheCallerAllFour() {
        let theme = palette(comment: RGB8(r: 0xF8, g: 0xF8, b: 0xF8))
        #expect(SyntaxColors.resolve(theme, on: [Self.black], ink: Self.white).isEmpty)
    }

    @Test func aPastelBesideTheInkStillCountsAsItsOwnColor() {
        // A theme's pink keyword next to near-white text: close in every
        // channel, far apart in hue. A per-channel measure rejected the
        // pastel themes for it.
        let pink = RGB8(r: 0xF5, g: 0xC2, b: 0xE7)
        let ink = RGB8(r: 0xDC, g: 0xDC, b: 0xDD)
        #expect(pink.difference(from: ink) >= SyntaxColors.minimumDifference)
        #expect(ink.difference(from: ink) == 0)
        #expect(Self.black.difference(from: Self.white) > 99)
    }

    @Test func aShortPaletteGivesNothing() {
        let short = TerminalPalette(background: Self.black, foreground: Self.white, ansi: [])
        #expect(SyntaxColors.resolve(short, on: [Self.black], ink: Self.white).isEmpty)
    }

    // MARK: The store and the painter's colors

    private func store(bundled: TerminalPalette, live: TerminalPalette) -> TerminalThemeStore {
        let store = TerminalThemeStore()
        store.setBundledPalettes(light: bundled, dark: bundled)
        store.update(light: live, dark: live)
        return store
    }

    @Test func theBundledPairKeepsTheSystemColors() {
        let bundled = palette()
        let colors = store(bundled: bundled, live: bundled).reviewSyntaxColors()
        #expect(colors == .system)
        for role in SyntaxRole.allCases {
            #expect(colors.nsColor(for: role) === ReviewSyntaxColors.systemColor(for: role))
        }
    }

    @Test func nothingFollowsBeforeTheReadBack() {
        #expect(TerminalThemeStore().reviewSyntaxColors() == .system)
    }

    @Test func aThemeLendsColorsThatReachTheFloorOnEveryReviewGround() throws {
        let live = palette(keyword: RGB8(r: 0xD0, g: 0x70, b: 0xFF))
        let colors = store(bundled: palette(keyword: RGB8(r: 0x10, g: 0x10, b: 0x10)), live: live).reviewSyntaxColors()
        // Every role on every ground a line's code is drawn on, on both
        // sides: the surface, the added and removed fills, the selection.
        for side in [TerminalThemeBrightness.light, .dark] {
            let grounds = TerminalThemeStore.reviewGrounds(on: side)
            #expect(grounds.count == 4)
            let drawn = side == .light ? colors.light : colors.dark
            #expect(drawn.count == SyntaxRole.allCases.count)
            for (role, color) in drawn {
                #expect(OnGroundColor.lowestContrast(of: color, on: grounds) >= SyntaxColors.ratio, "\(role) on \(side)")
            }
        }
        // The same color is darkened on the white surface and kept clear of
        // the dark one.
        let light = try #require(colors.light[.keyword])
        let dark = try #require(colors.dark[.keyword])
        #expect(light.relativeLuminance < dark.relativeLuminance)
    }

    @Test func thePainterFollowsAThemeChangeAndTellsStoresApart() {
        defer { ReviewRowPainter.setSyntaxColors(from: TerminalThemeStore()) }
        let bundled = palette(keyword: RGB8(r: 0x10, g: 0x10, b: 0x10))
        let themed = store(bundled: bundled, live: palette(keyword: RGB8(r: 0xD0, g: 0x70, b: 0xFF)))
        ReviewRowPainter.setSyntaxColors(from: themed)
        #expect(ReviewRowPainter.syntaxColors != .system)

        // Another store at the same revision, on the default pair.
        let plain = store(bundled: bundled, live: bundled)
        #expect(plain.revision == themed.revision)
        ReviewRowPainter.setSyntaxColors(from: plain)
        #expect(ReviewRowPainter.syntaxColors == .system)

        // The first store moving to the default pair.
        ReviewRowPainter.setSyntaxColors(from: themed)
        themed.update(light: bundled, dark: bundled)
        ReviewRowPainter.setSyntaxColors(from: themed)
        #expect(ReviewRowPainter.syntaxColors == .system)
    }

    @Test func theDynamicColorPicksTheSideAsItDraws() throws {
        let light = RGB8(r: 0x80, g: 0x20, b: 0xA0)
        let dark = RGB8(r: 0xD0, g: 0x70, b: 0xFF)
        let colors = ReviewSyntaxColors(light: [.keyword: light], dark: [.keyword: dark])
        let color = colors.nsColor(for: .keyword)
        func drawn(_ name: NSAppearance.Name) throws -> RGB8 {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            let srgb = try #require(resolved)
            return RGB8(
                r: UInt8((srgb.redComponent * 255).rounded()),
                g: UInt8((srgb.greenComponent * 255).rounded()),
                b: UInt8((srgb.blueComponent * 255).rounded())
            )
        }
        #expect(try drawn(.aqua) == light)
        #expect(try drawn(.darkAqua) == dark)
    }
}
