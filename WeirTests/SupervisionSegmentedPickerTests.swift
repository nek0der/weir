// SupervisionSegmentedPickerTests.swift
// Weir — the segmented choice's pill: it moves only on a change of the choice, sideways at one width, eased without overshoot; and its
// arrow keys.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct SupervisionSegmentedPickerTests {
    typealias Picker = SupervisionSegmentedPicker<Int>
    private static let now = Date(timeIntervalSinceReferenceDate: 1000)

    @Test(arguments: [false, true])
    func pillSlide_changesOnlyForANewSelection(reduceMotion: Bool) {
        let resting = SegmentPillSlide.resting(at: 1)
        let inFlight = SegmentPillSlide(from: 0, to: 1, start: Self.now.addingTimeInterval(-0.12), duration: 0.24)
        for slide in [resting, inFlight] {
            for selection in [1, nil] {
                #expect(SegmentPillSlide.after(
                    selecting: selection, previously: 1, current: slide, now: Self.now, reduceMotion: reduceMotion
                ) == slide)
            }
        }
        let slide = SegmentPillSlide.after(selecting: 0, previously: 1, current: resting, now: Self.now, reduceMotion: reduceMotion)
        let duration = (reduceMotion ? 0.18 : 0.24) * WeirMotion.pace
        #expect(slide == SegmentPillSlide(from: 1, to: 0, start: Self.now, duration: duration))
        #expect(slide.duration > 0)
        if reduceMotion {
            #expect(slide.duration < 0.24 * WeirMotion.pace)
        }
    }

    @Test func aSlide_easesFromItsSegmentToTheNext_withoutPassingEither() {
        let slide = SegmentPillSlide(from: 1, to: 0, start: Self.now, duration: 0.24)
        #expect(slide.position(at: Self.now) == 1)
        #expect(slide.position(at: Self.now.addingTimeInterval(-1)) == 1)
        #expect(abs(slide.position(at: Self.now.addingTimeInterval(0.12)) - 0.5) < 1e-6)
        #expect(abs(slide.position(at: Self.now.addingTimeInterval(0.24))) < 1e-6)
        #expect(slide.position(at: Self.now.addingTimeInterval(5)) == 0)
        // Every 60fps frame: always between the two segments, always
        // moving the same way, never back.
        var previous = 1.0
        for frame in 0...20 {
            let position = slide.position(at: Self.now.addingTimeInterval(Double(frame) / 60))
            #expect((0...1).contains(position))
            #expect(position <= previous)
            previous = position
        }
    }

    @Test func aSecondClickMidSlide_turnsThePillFromWhereItIs() {
        let first = SegmentPillSlide(from: 0, to: 1, start: Self.now, duration: 0.24)
        let midway = Self.now.addingTimeInterval(0.12)
        let second = SegmentPillSlide.after(selecting: 0, previously: 1, current: first, now: midway, reduceMotion: false)
        #expect(abs(first.position(at: midway) - 0.5) < 1e-6)
        #expect(abs(second.from - 0.5) < 1e-6)
        #expect(second.to == 0)
        #expect(second.start == midway)
        #expect(abs(second.position(at: midway) - 0.5) < 1e-6)
        #expect(abs(second.position(at: midway.addingTimeInterval(second.duration))) < 1e-6)
    }

    @Test func thePill_isOneSegmentWide_whateverItsPosition() {
        // The width comes from the track alone, never from the slide.
        #expect(SegmentPillSlide.segmentWidth(trackWidth: 440, count: 2) == 220)
        #expect(SegmentPillSlide.segmentWidth(trackWidth: 300, count: 3) == 100)
        #expect(SegmentPillSlide.segmentWidth(trackWidth: 300, count: 0) == 300)
    }

    @Test func theEasing_startsAndEndsStill_andStaysWithinItsRange() {
        #expect(SegmentPillSlide.easeInOut(0) == 0)
        #expect(SegmentPillSlide.easeInOut(1) == 1)
        #expect(SegmentPillSlide.easeInOut(0.5) == 0.5)
        #expect(SegmentPillSlide.easeInOut(0.05) < 0.05)
        #expect(SegmentPillSlide.easeInOut(0.95) > 0.95)
    }

    private struct ArrowCase: Sendable {
        let from: Int?
        let offset: Int
        let count: Int
        var isEnabled = true
        var unavailable: Set<Int> = []
        let next: Int?
        let isHandled: Bool
    }

    @Test(arguments: [
        ArrowCase(from: 0, offset: 1, count: 3, next: 1, isHandled: true),
        ArrowCase(from: 2, offset: -1, count: 3, next: 1, isHandled: true),
        ArrowCase(from: 0, offset: -1, count: 2, next: nil, isHandled: true),
        ArrowCase(from: 1, offset: 1, count: 2, next: nil, isHandled: true),
        ArrowCase(from: 1, offset: 1, count: 3, isEnabled: false, next: nil, isHandled: false),
        ArrowCase(from: nil, offset: 1, count: 3, next: nil, isHandled: false),
        ArrowCase(from: 1, offset: 1, count: 4, unavailable: [2], next: 3, isHandled: true),
        ArrowCase(from: 3, offset: -1, count: 4, unavailable: [2], next: 1, isHandled: true),
        ArrowCase(from: 1, offset: 1, count: 3, unavailable: [2], next: nil, isHandled: true),
        ArrowCase(from: 0, offset: 1, count: 4, unavailable: [1, 2], next: 3, isHandled: true)
    ])
    private func arrowStep_skipsUnavailableSegments_andReportsHandling(_ input: ArrowCase) {
        let step = Picker.keyStep(from: input.from, by: input.offset, count: input.count, isEnabled: input.isEnabled) {
            !input.unavailable.contains($0)
        }
        #expect(step.next == input.next)
        #expect(step.isHandled == input.isHandled)
    }

    @Test func segments_shareIdealAndConstrainedWidthsEqually() throws {
        let short = Text(verbatim: "Timeline").lineLimit(1)
        let long = Text(verbatim: "By Conversation").lineLimit(1)
        let shortWidth = NSHostingView(rootView: short.fixedSize()).fittingSize.width
        let longWidth = NSHostingView(rootView: long.fixedSize()).fittingSize.width
        #expect(shortWidth < longWidth)
        let row = EqualSegmentsLayout {
            short.frame(maxWidth: .infinity).padding(.vertical, 8).background(.red)
            long.frame(maxWidth: .infinity).padding(.vertical, 8).background(.blue)
        }
        let ideal = row.fixedSize()
        let measured = NSHostingView(rootView: ideal).fittingSize.width
        #expect(abs(measured - 2 * longWidth) < 0.5, "\(measured) against \(longWidth)")

        try Self.expectEqualSegmentSpans(in: ideal, segmentWidth: longWidth)
        try Self.expectEqualSegmentSpans(in: row.frame(width: 60), segmentWidth: 30)
    }

    private static func expectEqualSegmentSpans(in row: some View, segmentWidth: CGFloat) throws {
        let renderer = ImageRenderer(content: row)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Two rows inside the vertical padding establish each background's
        // full horizontal span without sampling glyphs.
        for y in [2, bitmap.pixelsHigh - 3] {
            let colors = (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB) }
            try #require(colors.count == bitmap.pixelsWide)
            let red = colors.indices.filter { colors[$0].redComponent > 0.7 && colors[$0].blueComponent < 0.3 }
            let blue = colors.indices.filter { colors[$0].blueComponent > 0.7 && colors[$0].redComponent < 0.3 }
            #expect(abs(CGFloat(red.count) - segmentWidth) <= 1)
            #expect(abs(CGFloat(blue.count) - segmentWidth) <= 1)
            #expect(red.first == 0)
            #expect(blue.last == colors.count - 1)
            let redEnd = try #require(red.last)
            let blueStart = try #require(blue.first)
            #expect((1...2).contains(blueStart - redEnd))
        }
    }
}
