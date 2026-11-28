// TerminalPalette.swift
// Weir — the colors a terminal theme resolves to: ground, ink, and the 16 ANSI colors.

import Foundation

/// The colors libghostty resolved for one side (light or dark) of the
/// terminal theme.
package struct TerminalPalette: Equatable, Sendable {
    /// The number of ANSI entries a palette carries: the 8 normal colors and
    /// their 8 bright variants.
    package static let ansiCount = 16

    package var background: RGB8
    package var foreground: RGB8
    /// The ANSI colors 0 through 15, in palette order. Holds exactly
    /// `ansiCount` entries when built by the read-back.
    package var ansi: [RGB8]

    package init(background: RGB8, foreground: RGB8, ansi: [RGB8]) {
        self.background = background
        self.foreground = foreground
        self.ansi = ansi
    }
}
