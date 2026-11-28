// TerminalGroundTests.swift
// Weir — covers the ground painted under the terminal, the marks corrected on it, and the theme pickers' rows.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("On-ground color")
struct OnGroundColorTests {
    private let white = RGB8(r: 255, g: 255, b: 255)
    private let black = RGB8(r: 0, g: 0, b: 0)

    @Test func severalGroundsAreAllReached() {
        let amber = RGB8(r: 0xF0, g: 0xA0, b: 0x40)
        let grounds = [RGB8(r: 0x80, g: 0x80, b: 0x80), RGB8(r: 0x40, g: 0x40, b: 0x40)]
        let result = OnGroundColor.resolve(amber, on: grounds, ratio: 3)
        #expect(result.isReached)
        #expect(OnGroundColor.lowestContrast(of: result.color, on: grounds) >= 3)
    }

    @Test func aColorThatAlreadyReachesIsKept() {
        let red = RGB8(r: 0xD4, g: 0x43, b: 0x3A)
        let result = OnGroundColor.resolve(red, on: white, ratio: 3)
        #expect(result.isReached)
        #expect(result.color == red)
    }

    @Test func onALightGroundTheColorDarkens() {
        let amber = RGB8(r: 0xF0, g: 0xA0, b: 0x40)
        let ground = RGB8(r: 0xFD, g: 0xF6, b: 0xE3)
        #expect(amber.contrast(with: ground) < 3)
        let result = OnGroundColor.resolve(amber, on: ground, ratio: 3)
        #expect(result.isReached)
        #expect(result.color.contrast(with: ground) >= 3)
        #expect(result.color.relativeLuminance < amber.relativeLuminance)
    }

    @Test func onADarkGroundTheColorLightens() {
        let red = RGB8(r: 0xD4, g: 0x43, b: 0x3A)
        let ground = RGB8(r: 0x3A, g: 0x3A, b: 0x3A)
        #expect(red.contrast(with: ground) < 3)
        let result = OnGroundColor.resolve(red, on: ground, ratio: 3)
        #expect(result.isReached)
        #expect(result.color.contrast(with: ground) >= 3)
        #expect(result.color.relativeLuminance > red.relativeLuminance)
    }

    @Test func aRatioNoColorReachesGivesTheOriginalBack() {
        // This gray reaches about 4.6:1 with black and 4.5:1 with white, so
        // nothing reaches 7:1 against it.
        let gray = RGB8(r: 0x76, g: 0x76, b: 0x76)
        let amber = RGB8(r: 0xF0, g: 0xA0, b: 0x40)
        let result = OnGroundColor.resolve(amber, on: gray, ratio: 7)
        #expect(!result.isReached)
        #expect(result.color == amber)
    }
}

@Suite("Terminal ground")
@MainActor
struct TerminalGroundTests {
    private let bundledLight = RGB8(r: 0xFE, g: 0xFF, b: 0xFF)
    private let bundledDark = RGB8(r: 0x1E, g: 0x1E, b: 0x1E)
    private let tokens = TerminalGround.Tokens(
        waiting: RGB8(r: 0xF0, g: 0xA0, b: 0x40),
        stopped: RGB8(r: 0xEE, g: 0x6A, b: 0x61),
        accent: RGB8(r: 0x0A, g: 0x84, b: 0xFF)
    )

    private func palette(_ background: RGB8) -> TerminalPalette {
        TerminalPalette(
            background: background,
            foreground: RGB8(r: 0x80, g: 0x80, b: 0x80),
            ansi: Array(repeating: background, count: TerminalPalette.ansiCount)
        )
    }

    private func store(light: RGB8, dark: RGB8) -> TerminalThemeStore {
        let store = TerminalThemeStore()
        store.setBundledPalettes(light: palette(bundledLight), dark: palette(bundledDark))
        store.update(light: palette(light), dark: palette(dark))
        return store
    }

    @Test func theBundledPairPaintsNothing() {
        let store = store(light: bundledLight, dark: bundledDark)
        #expect(store.ground(for: .light, tokens: tokens) == .unpainted)
        #expect(store.ground(for: .dark, tokens: tokens) == .unpainted)
        #expect(store.paintedGround(for: .dark) == nil)
    }

    @Test func nothingIsPaintedBeforeTheReadBack() {
        let store = TerminalThemeStore()
        #expect(store.ground(for: .dark, tokens: tokens) == .unpainted)
    }

    @Test func aDarkThemePaintsItsBackgroundWithALightKnob() {
        let ground = RGB8(r: 0x3A, g: 0x3A, b: 0x3A)
        let store = store(light: bundledLight, dark: ground)
        let resolved = store.ground(for: .dark, tokens: tokens)
        #expect(resolved.ground == ground)
        #expect(resolved.knobStyle == .light)
        // The light side still paints nothing.
        #expect(store.ground(for: .light, tokens: tokens) == .unpainted)
    }

    @Test func theAttentionColorsReachThreeToOneOnTheGround() throws {
        // Middle gray: both tokens fall short of 3:1 on it as they are.
        let ground = RGB8(r: 0x80, g: 0x80, b: 0x80)
        #expect(tokens.waiting.contrast(with: ground) < TerminalGround.markContrast)
        #expect(tokens.stopped.contrast(with: ground) < TerminalGround.markContrast)
        let resolved = store(light: bundledLight, dark: ground).ground(for: .dark, tokens: tokens)
        let waiting = try #require(resolved.waiting)
        let stopped = try #require(resolved.stopped)
        #expect(waiting.contrast(with: ground) >= TerminalGround.markContrast)
        #expect(stopped.contrast(with: ground) >= TerminalGround.markContrast)
    }

    @Test func theMarksReachThreeToOneOnTheGroundAsAnUnfocusedPaneShowsIt() throws {
        // A blue ground faded to 60% over the dark surface: corrected
        // against the ground alone, the accent darkens to a navy that all
        // but disappears on that mix (about 1.75:1).
        let ground = RGB8(r: 0x00, g: 0x77, b: 0xDD)
        let backdrop = TerminalGround.Backdrop(
            surface: RGB8(r: 0x1B, g: 0x1C, b: 0x20),
            surfaceOpacity: 1,
            unfocusedPaneOpacity: 0.6
        )
        let composite = ground.composited(over: backdrop.surface, opacity: 0.6)
        #expect(backdrop.grounds(for: ground).contains(composite))
        let groundOnly = try #require(TerminalGround.resolve(ground: ground, tokens: tokens).accent)
        #expect(groundOnly.contrast(with: composite) < TerminalGround.markContrast)

        let resolved = TerminalGround.resolve(ground: ground, tokens: tokens, backdrop: backdrop)
        for mark in [resolved.waiting ?? tokens.waiting, resolved.stopped ?? tokens.stopped, resolved.accent ?? tokens.accent] {
            #expect(mark.contrast(with: ground) >= TerminalGround.markContrast)
            #expect(mark.contrast(with: composite) >= TerminalGround.markContrast)
        }
    }

    @Test func aTranslucentSurfaceIsCheckedInAFocusedPaneToo() {
        let backdrop = TerminalGround.Backdrop(
            surface: RGB8(r: 0xFF, g: 0xFF, b: 0xFF),
            surfaceOpacity: 0.7,
            unfocusedPaneOpacity: 0.5
        )
        let ground = RGB8(r: 0x20, g: 0x20, b: 0x20)
        #expect(backdrop.grounds(for: ground) == [
            ground,
            ground.composited(over: backdrop.surface, opacity: 0.7),
            ground.composited(over: backdrop.surface, opacity: 0.35)
        ])
    }

    @Test func aTokenThatAlreadyStandsOutIsKept() {
        let ground = RGB8(r: 0x10, g: 0x10, b: 0x10)
        let resolved = TerminalGround.resolve(ground: ground, tokens: tokens)
        #expect(resolved.ground == ground)
        #expect(resolved.waiting == nil)
        #expect(resolved.stopped == nil)
    }

    @Test func aLightGroundTakesADarkKnob() {
        #expect(TerminalGround.knobStyle(on: RGB8(r: 0xFD, g: 0xF6, b: 0xE3)) == .dark)
        #expect(TerminalGround.knobStyle(on: nil) == .automatic)
    }

    @Test func theKnobFollowsContrastRatherThanTheLightDarkLine() {
        // `#bbbbbb` counts as a dark theme (luminance under 0.5), yet black
        // stands out against it more than white does.
        let ground = RGB8(r: 0xBB, g: 0xBB, b: 0xBB)
        #expect(TerminalThemeBrightness(background: ground) == .dark)
        #expect(TerminalGround.knobStyle(on: ground) == .dark)
        #expect(TerminalGround.knobStyle(on: RGB8(r: 0x50, g: 0x50, b: 0x50)) == .light)
    }
}

@Suite("Terminal theme choices")
@MainActor
struct TerminalThemeChoicesTests {
    private func entry(_ name: String, _ origin: TerminalThemeOrigin, _ brightness: TerminalThemeBrightness?) -> TerminalThemeCatalog
        .Entry
    {
        TerminalThemeCatalog.Entry(ref: TerminalThemeRef(name: name, origin: origin), path: "/themes/\(name)", brightness: brightness)
    }

    private var entries: [TerminalThemeCatalog.Entry] {
        [
            entry("Apple System Colors", .bundled, .dark),
            entry("Apple System Colors Light", .bundled, .light),
            entry("Night", .user, .dark),
            entry("Night", .ghostty, .dark),
            entry("Paper", .user, .light),
            entry("Unreadable", .user, nil)
        ]
    }

    @Test func eachSideListsItsOwnThemesWithoutTheDefaultOrUnreadableFiles() {
        let light = TerminalThemeChoices.choices(entries: entries, side: .light, selected: nil).map(\.ref.name)
        #expect(light == ["Paper"])
        let dark = TerminalThemeChoices.choices(entries: entries, side: .dark, selected: nil)
        #expect(dark.map(\.id) == ["user/Night", "ghostty/Night"])
        #expect(dark.first?.kind == .theme(isNameShared: true))
    }

    @Test func anUnreadableFileStillShowsWhileItIsTheChoice() {
        let unreadable = TerminalThemeRef(name: "Unreadable", origin: .user)
        let rows = TerminalThemeChoices.choices(entries: entries, side: .dark, selected: unreadable)
        #expect(rows.map(\.id) == ["user/Night", "ghostty/Night", "user/Unreadable"])
    }

    @Test func aChosenThemeMissingFromEveryFolderIsListedAsMissing() {
        let gone = TerminalThemeRef(name: "Gone", origin: .user)
        let rows = TerminalThemeChoices.choices(entries: entries, side: .dark, selected: gone)
        #expect(rows.first == TerminalThemeChoice(ref: gone, kind: .missing))
    }

    @Test func beforeTheFoldersAreReadTheChoiceIsNotCalledMissing() {
        let chosen = TerminalThemeRef(name: "Night", origin: .user)
        let rows = TerminalThemeChoices.choices(entries: nil, side: .dark, selected: chosen)
        #expect(rows == [TerminalThemeChoice(ref: chosen, kind: .theme(isNameShared: false))])
    }

    @Test func aChoiceFromTheOtherSideIsStillListed() {
        let chosen = TerminalThemeRef(name: "Night", origin: .user)
        let rows = TerminalThemeChoices.choices(entries: entries, side: .light, selected: chosen)
        #expect(rows.contains { $0.ref == chosen && $0.kind != .missing })
    }

    @Test func theTagIgnoresFieldsANewerBuildStoredAndMapsTheDefaultToNone() {
        var stored = TerminalThemeRef(name: "Night", origin: .user)
        stored.unknownFields = ["tint": .string("blue")]
        #expect(TerminalThemeChoices.tag(for: stored, side: .dark) == TerminalThemeRef(name: "Night", origin: .user))
        let explicitDefault = GhosttyConfigBridge.defaultThemeRef(for: .dark)
        #expect(TerminalThemeChoices.tag(for: explicitDefault, side: .dark) == nil)
    }
}

@Suite("Terminal theme settings surface")
@MainActor
struct TerminalThemeSettingsSurfaceTests {
    @Test(arguments: ["appearance.terminal-theme-light", "appearance.terminal-theme-dark"])
    func bothPickersCanBeFoundInSearch(id: String) {
        #expect(SettingsSearchCatalog.entries.first { $0.id == id }?.section == .appearance)
    }

    @Test func theDemoShowsTheBundledPair() {
        var settings = WeirSettings.default
        settings.appearance.terminalTheme = TerminalThemeSelection(
            light: TerminalThemeRef(name: "Paper", origin: .user),
            dark: TerminalThemeRef(name: "Night", origin: .ghostty)
        )
        SettingsStore.pinForDemo(&settings)
        #expect(settings.appearance.terminalTheme.isDefault)
    }
}
