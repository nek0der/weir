// OnGroundColor.swift
// Weir — moves a mark's color toward black or white until it stands out against the grounds under it.

import Foundation

/// The color a mark takes on a ground whose color the person chose, so a
/// frame or ring drawn on a terminal theme's background stays visible.
package enum OnGroundColor {
    /// The share of the way to black or white each step moves. Small, so the
    /// result stays as close to the token's hue as the ratio allows.
    package static let stepFraction = 0.02

    /// Returns `color` unchanged when it reaches `ratio` against `ground`.
    /// See `resolve(_:on:ratio:)` with several grounds.
    package static func resolve(_ color: RGB8, on ground: RGB8, ratio: Double) -> (color: RGB8, isReached: Bool) {
        resolve(color, on: [ground], ratio: ratio)
    }

    /// Returns `color` unchanged when it reaches `ratio` against every one
    /// of `grounds`. Otherwise it tries steps toward black and toward white
    /// and returns the candidate that reaches `ratio` against all of them in
    /// the fewest steps; on a tie, the one whose lowest contrast is higher.
    /// When neither direction reaches `ratio`, even at black or white, it
    /// returns `color` with `isReached` false, and the caller keeps its own
    /// token.
    ///
    /// Several grounds stand for the colors one mark is seen against: a
    /// ground laid over another at less than full opacity mixes with it per
    /// channel, and such a mix can be darker or lighter than both, so the
    /// mix is checked itself rather than bounded by its two ends.
    package static func resolve(_ color: RGB8, on grounds: [RGB8], ratio: Double) -> (color: RGB8, isReached: Bool) {
        guard !grounds.isEmpty else { return (color, true) }
        if lowestContrast(of: color, on: grounds) >= ratio {
            return (color, true)
        }
        let darker = firstReaching(ratio, from: color, toward: RGB8(r: 0, g: 0, b: 0), on: grounds)
        let lighter = firstReaching(ratio, from: color, toward: RGB8(r: 255, g: 255, b: 255), on: grounds)
        switch (darker, lighter) {
        case let (dark?, light?):
            if dark.step != light.step {
                return (dark.step < light.step ? dark.color : light.color, true)
            }
            let isDarkHigher = lowestContrast(of: dark.color, on: grounds) >= lowestContrast(of: light.color, on: grounds)
            return (isDarkHigher ? dark.color : light.color, true)
        case let (dark?, nil):
            return (dark.color, true)
        case let (nil, light?):
            return (light.color, true)
        case (nil, nil):
            return (color, false)
        }
    }

    /// The contrast `color` reaches against the ground it stands out from
    /// least.
    package static func lowestContrast(of color: RGB8, on grounds: [RGB8]) -> Double {
        grounds.map { color.contrast(with: $0) }.min() ?? 21
    }

    private static func firstReaching(
        _ ratio: Double,
        from color: RGB8,
        toward target: RGB8,
        on grounds: [RGB8]
    ) -> (color: RGB8, step: Int)? {
        let steps = Int((1 / stepFraction).rounded())
        for step in 1...steps {
            let candidate = mix(color, toward: target, by: Double(step) * stepFraction)
            if lowestContrast(of: candidate, on: grounds) >= ratio {
                return (candidate, step)
            }
        }
        return nil
    }

    private static func mix(_ color: RGB8, toward target: RGB8, by amount: Double) -> RGB8 {
        target.composited(over: color, opacity: amount)
    }
}
