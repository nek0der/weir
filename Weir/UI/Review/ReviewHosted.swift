// ReviewHosted.swift
// Weir — the SwiftUI views the review table hosts in its AppKit rows, given the window's environment again.

import SwiftUI

/// What a SwiftUI view hosted in one of the review table's AppKit rows
/// takes from the window: the language, the surface's opacity, the
/// accent, and the window's colors from the terminal theme. SwiftUI's
/// environment stops at the table, so the table hands these over as it
/// configures a row (`ReviewHosted`).
struct ReviewHostedEnvironment: Equatable {
    var locale: Locale = .current
    /// How opaque the surface is filled (`supervisionSurfaceOpacity`).
    var surfaceOpacity: Double = 1
    var accent: Color = WeirColor.defaultAccent
    var windowColors = WindowColors.tokens
}

/// A view a review row hosts, in the window's environment again: the one
/// way across the table's boundary, so a file header's checkbox and a
/// hunk's buttons take the person's accent, language, and transparency as
/// the rest of the window does, and a value added here reaches every one.
struct ReviewHosted<Content: View>: View {
    let environment: ReviewHostedEnvironment
    let content: Content

    var body: some View {
        content
            .environment(\.locale, environment.locale)
            .environment(\.supervisionSurfaceOpacity, environment.surfaceOpacity)
            .weirAppearancePropagated(accent: environment.accent, windowColors: environment.windowColors)
    }
}
