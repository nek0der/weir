// RestoreStripRowTests.swift
// Weir — the restore strip's row takes a narrower fit in a narrow pane rather than cut its buttons off.

import AppKit
import SwiftUI
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Restore strip row")
@MainActor
struct RestoreStripRowTests {
    private typealias Layout = WeirLayout.Supervision

    /// One of two panes side by side in the review's narrowest column, as
    /// a split lays them out (about 197pt): narrower than one of two panes
    /// split left and right in a 730pt window, where the strip's one fixed
    /// layout cut "Restore Code" and "Cancel" off. The decision bar keeps
    /// its buttons down to the same width (`DecisionBarRowFitTests`).
    private nonisolated static let halfOfTheNarrowestReview: CGFloat = 196

    /// Measure each forced fit independently of which one the row chooses.
    @Test(arguments: ["en", "ja"])
    func forcedFits_narrowInOrder_andTheMinimalFitFitsTheReviewPane(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let insets = Layout.footBarLeadingInset + Layout.footBarTrailingInset
            for (strip, confirmation) in Self.strips(locale: Locale(identifier: language)) {
                @MainActor func width(_ fit: RestoreStripRow.Fit) -> CGFloat {
                    let row = Self.row(strip, confirmation, fits: [fit]).fixedSize(horizontal: true, vertical: false)
                    return Self.size(of: row, proposing: nil, language: language, settings: settings).width + insets
                }
                let full = width(.full)
                let minimal = width(.minimal)
                let words = width(.wordsOnly)
                #expect(words < minimal && minimal < full, "\(language) \(strip.phase): \([full, minimal, words])")
                #expect(minimal <= Self.halfOfTheNarrowestReview, "\(language) \(strip.phase): \(minimal)")
            }
        }
    }

    /// From a pane as narrow as a split allows to the session's column in
    /// a 1280×800 window, the row asks for no more than the room inside
    /// the bar's insets, rather than push its buttons past the pane's edge.
    @Test(arguments: ["en", "ja"], [
        CGFloat(TerminalSettings.minPaneSizeRange.lowerBound), halfOfTheNarrowestReview, 280, 400, 580
    ])
    func row_isNoWiderThanThePane(language: String, width: CGFloat) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let room = width - Layout.footBarLeadingInset - Layout.footBarTrailingInset
            for (strip, confirmation) in Self.strips(locale: Locale(identifier: language)) {
                let size = Self.size(of: Self.row(strip, confirmation), proposing: room, language: language, settings: settings)
                #expect(size.width <= room, "\(language) at \(width): \(strip.phase)")
            }
        }
    }

    @Test(arguments: [("en", "Restore", "Restore Code"), ("ja", "復元", "コードを復元")])
    func restoreButton_hasDistinctCompactAndFullLabels(language: String, compact: String, full: String) {
        let locale = Locale(identifier: language)
        #expect(RestoreText.restoreCodeShort(locale: locale) == compact)
        #expect(RestoreText.restoreCode(locale: locale) == full)
    }

    @Test(arguments: ["en", "ja"])
    func minimalFit_rendersTheConfirmAndCloseButtonFaces(language: String) throws {
        try withTempDir { directory in
            let settings = SettingsStore(directory: directory)
            let locale = Locale(identifier: language)
            let strips = Self.strips(locale: locale)
            for ((strip, confirmation), expected) in zip(strips, [2, nil, 1]) {
                guard let expected else { continue }
                let minimal = Self.row(strip, confirmation, fits: [.minimal])
                let words = Self.row(strip, confirmation, fits: [.wordsOnly])
                let minimalCount = try Self.buttonFaceSpans(in: minimal, locale: locale, settings: settings)
                let wordsCount = try Self.buttonFaceSpans(in: words, locale: locale, settings: settings)
                #expect(minimalCount == expected, "\(strip.phase)")
                #expect(wordsCount == 0)
            }
        }
    }

    private static func buttonFaceSpans(in row: some View, locale: Locale, settings: SettingsStore) throws -> Int {
        let room = halfOfTheNarrowestReview - Layout.footBarLeadingInset - Layout.footBarTrailingInset
        let renderer = ImageRenderer(content: row
            .frame(width: room, height: Layout.footBarHeight)
            .environment(settings)
            .environment(\.locale, locale)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        // A scan line through the button faces near their rounded corners,
        // outside the centered one-line text. Ignore isolated pixels.
        let y = Int((Layout.footBarHeight - Layout.secondaryButtonHeight) / 2) + 2
        let pixels = (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: y)?.alphaComponent }
        try #require(pixels.count == Int(room))
        var count = 0
        var run = 0
        for alpha in pixels + [0] {
            if alpha >= 0.15 {
                run += 1
            } else {
                if run >= 10 {
                    count += 1
                }
                run = 0
            }
        }
        return count
    }

    /// The strip asking, running, and ended short of the whole restore,
    /// with a question as long as a run of turns makes it.
    private static func strips(locale: Locale) -> [(RestoreStrip, RestoreConfirmation)] {
        let confirmation = RestoreConfirmation(
            text: RestoreText.confirmation(first: 5, last: 17, added: 12345, removed: 678, locale: locale),
            note: RestoreText.confirmationNote(isShared: true, locale: locale),
            blockedReason: nil,
            added: 12345,
            removed: 678
        )
        let turn = TurnID("T5")
        return [
            (RestoreStrip(turnID: turn), confirmation),
            (RestoreStrip(turnID: turn, phase: .running), confirmation),
            (RestoreStrip(turnID: turn, phase: .ended("The restore wrote nothing: the worktree changed while it ran.")), confirmation)
        ]
    }

    private static func row(
        _ strip: RestoreStrip,
        _ confirmation: RestoreConfirmation,
        fits: [RestoreStripRow.Fit] = RestoreStripRow.Fit.allCases
    ) -> some View {
        RestoreStripRow(strip: strip, confirmation: confirmation, isFocused: false, fits: fits, onRestore: {}, onClose: {})
    }

    private static func size(of view: some View, proposing width: CGFloat?, language: String, settings: SettingsStore) -> CGSize {
        NSHostingController(rootView: view
            .environment(settings)
            .environment(\.locale, Locale(identifier: language)))
            .sizeThatFits(in: CGSize(width: width ?? 4000, height: Layout.footBarHeight))
    }
}
