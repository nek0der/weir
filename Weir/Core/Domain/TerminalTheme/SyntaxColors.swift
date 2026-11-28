// SyntaxColors.swift
// Weir — the review's four syntax colors, taken from a terminal theme's ANSI colors and checked against the grounds they are drawn on.

import Foundation

/// The four things the review's lexer colors (`ReviewSyntax.Kind`), held
/// here so the rule stays free of the app target.
package enum SyntaxRole: CaseIterable, Sendable {
    case keyword, string, number, comment

    /// The ANSI color a theme lends the role.
    ///
    /// Chosen to keep the hues of the review's system colors
    /// (`ReviewSyntaxColors.systemColor(for:)`): keywords magenta, strings
    /// red, numbers yellow in place of orange, which ANSI lacks. Comments
    /// take bright black, a gray, as the system colors keep them gray:
    /// green text on an added line's green fill would not read as a
    /// comment.
    package var ansiIndex: Int {
        switch self {
        case .keyword: 5
        case .string: 1
        case .number: 3
        case .comment: 8
        }
    }
}

/// Decides the syntax colors one side of a terminal theme gives the review.
package enum SyntaxColors {
    /// The contrast each color must reach against every ground it is drawn
    /// on. The same floor as the marks on the terminal ground
    /// (`TerminalGround`), and no lower than the system colors the review
    /// drew before, some of which fall short of it.
    package static let ratio = 3.0

    /// How far apart two colors must be (`RGB8.difference(from:)`) to read
    /// as different kinds of code at a glance. Below it the colors tell the
    /// reader nothing the plain text does not.
    package static let minimumDifference = 12.0

    /// The theme's color for each role, corrected to reach `ratio` against
    /// every one of `grounds`, or empty when the theme cannot color the
    /// review well and the caller keeps its own four colors.
    ///
    /// It is empty when a role's color reaches `ratio` at no step toward
    /// black or white, and when two of the four colors, or one of them and
    /// `ink`, the plain text, sit closer than `minimumDifference`. All four or
    /// none: the caller's colors mixed with a theme's were never chosen to
    /// sit together, and four colors that blur into each other read worse
    /// than the caller's own.
    package static func resolve(_ palette: TerminalPalette, on grounds: [RGB8], ink: RGB8) -> [SyntaxRole: RGB8] {
        guard palette.ansi.count >= TerminalPalette.ansiCount else { return [:] }
        var result: [SyntaxRole: RGB8] = [:]
        var drawn = [ink]
        for role in SyntaxRole.allCases {
            let corrected = OnGroundColor.resolve(palette.ansi[role.ansiIndex], on: grounds, ratio: ratio)
            guard corrected.isReached,
                  !drawn.contains(where: { corrected.color.difference(from: $0) < minimumDifference })
            else { return [:] }
            result[role] = corrected.color
            drawn.append(corrected.color)
        }
        return result
    }
}
