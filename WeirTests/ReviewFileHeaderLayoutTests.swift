// ReviewFileHeaderLayoutTests.swift
// Weir — usable file paths and separate counts in narrow review headers.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@Suite(.hostsWindows)
@MainActor
struct ReviewFileHeaderLayoutTests {
    /// A fitting row can still give its path only an ellipsis. We require
    /// room for a directory and extension as well as counts within the row.
    @Test func fileHeader_withAllMarksAndManyConversations_keepsAUsablePath() async throws {
        let header = ReviewStackHeader(
            file: ReviewFile(path: "apps/api/migrations/20261020_reminder_schedules.sql", layer: .turns, status: .added),
            stat: ReviewFileStat(added: 1234, removed: 5678),
            marks: ReviewFileMark.allCases,
            tags: (1...5).map { ReviewFileTag(provider: .claude, ordinal: $0, turns: [$0], identity: $0) },
            isViewed: true,
            isFolded: false
        )
        let sample = NSHostingController(rootView: Text(verbatim: "api/…sql")
            .font(.supervisionCode(beside: .label, weight: .semibold)))
        let minimumPathWidth = sample.sizeThatFits(in: CGSize(width: 600, height: 40)).width
        try #require(minimumPathWidth > 0)
        for language in ["en", "ja"] {
            for width in [ReviewRail.diffMinimum, 600] {
                let path = FrameRecorder()
                let counts = FrameRecorder()
                let view = ReviewStackFileHeader(
                    header: header,
                    onPathFrame: { path.frame = $0 },
                    onCountsFrame: { counts.frame = $0 }
                )
                .environment(\.locale, Locale(identifier: language))
                let (window, host) = hostedInWindow(view, width: width, height: WeirLayout.Supervision.reviewFileHeaderHeight)
                defer { window.close() }
                let settled = await settledValue(in: host) { () -> HeaderFrames? in
                    guard let path = path.frame, let counts = counts.frame else { return nil }
                    return HeaderFrames(path: path, counts: counts)
                }
                let frames = try #require(settled, "\(language), \(width)pt: header geometry was not reported")
                let context = "\(language), \(width)pt: path \(frames.path), counts \(frames.counts), minimum path \(minimumPathWidth)"
                print("Review header geometry: \(context)")
                #expect(frames.path.width >= minimumPathWidth, "\(context)")
                #expect(frames.path.minX >= 0 && frames.path.maxX <= width, "\(context)")
                #expect(frames.counts.width > 0, "\(context)")
                #expect(frames.counts.minX >= 0 && frames.counts.maxX <= width, "\(context)")
                #expect(frames.path.maxX <= frames.counts.minX, "\(context)")
                #expect(frames.path.height <= WeirLayout.Supervision.reviewFileHeaderHeight, "\(context)")
                #expect(frames.counts.height <= WeirLayout.Supervision.reviewFileHeaderHeight, "\(context)")
            }
        }
    }

    private struct HeaderFrames: Equatable {
        let path: CGRect
        let counts: CGRect
    }
}
