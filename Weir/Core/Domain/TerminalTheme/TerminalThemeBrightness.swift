// TerminalThemeBrightness.swift
// Weir — whether a terminal theme is a light or a dark one, judged from its background.

import Foundation

/// Whether a terminal theme reads as light or dark.
package enum TerminalThemeBrightness: String, Equatable, Hashable, Sendable {
    case light
    case dark

    /// The relative luminance above which a background counts as light.
    /// We take the midpoint of WCAG's 0...1 scale so the classifier has no
    /// tuning of its own; the bundled pair (`#feffff` and `#1e1e1e`) sits far
    /// from it on either side. This is the only place that draws the line.
    package static let lightLuminanceThreshold = 0.5

    /// Classifies a theme by its background color.
    package init(background: RGB8) {
        self = background.relativeLuminance > Self.lightLuminanceThreshold ? .light : .dark
    }
}
