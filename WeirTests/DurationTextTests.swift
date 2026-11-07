// DurationTextTests.swift
// Weir — a duration in words: a command's run, a wait, a time left.

import Foundation
import Testing
@testable import Weir

struct DurationTextTests {
    private let en = Locale(identifier: "en")

    @Test func aCommandsTime_isSaidInWholeSecondsPastAMinute() {
        #expect(DurationText.command(48.24, locale: en) == "48.2s")
        #expect(DurationText.command(48.26, locale: en) == "48.3s")
        #expect(DurationText.command(59.9, locale: en) == "59.9s")
        #expect(DurationText.command(60, locale: en) == "1m")
        #expect(DurationText.command(134, locale: en) == "2m 14s")
        #expect(DurationText.command(134.6, locale: en) == "2m 14s")
    }

    @Test func aDecodedCommandKeepsItsExitFactWhenTheDurationIsUnsupported() throws {
        let decoder = PersistenceCoders.makeDecoder()
        for (seconds, expectedFacts) in [
            ("1e20", "exit 1"),
            ("9223372036854775808", "exit 1"),
            ("-2", "exit 1"),
            ("134.6", "exit 1 2m 14s"),
            ("null", "exit 1")
        ] {
            let data = Data("""
            {"id":"00000000-0000-4000-8000-000000000001","kind":"commandFinished",
             "timestamp":"2026-10-29T04:20:00Z","title":"Build","body":"Finished","exitCode":1,
             "durationSeconds":\(seconds),"isRead":false}
            """.utf8)
            let entry = try decoder.decode(NotificationEntry.self, from: data)
            let lines = NotificationHistoryRowText.lines(of: entry, sourceTabTitle: nil, locale: en)

            #expect(lines.headline == "Command failed")
            #expect(lines.factsText == expectedFacts, "recorded duration: \(seconds)")
        }
    }

    @Test func commandAndCompact_handleOutOfRangeDurations() {
        for invalid in [Double.nan, .infinity, -.infinity, 1e20, Double(Int.max)] {
            #expect(DurationText.command(invalid, locale: en) == "—")
            #expect(DurationText.compact(invalid, locale: en) == "—")
        }
        #expect(DurationText.command(-1e20, locale: en) == "—")
        #expect(DurationText.compact(-1e20, locale: en) == "0s")

        let lastRepresentable = Double(Int.max).nextDown
        #expect(DurationText.command(lastRepresentable, locale: en) != "—")
        #expect(DurationText.compact(lastRepresentable, locale: en) != "—")
    }

    @Test func aCompactDuration_roundsDownToTheLargestUnit() {
        let style = Duration.UnitsFormatStyle.units(
            allowed: [.days, .hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 1
        ).locale(en)
        #expect(DurationText.compact(299, locale: en) == Duration.seconds(240).formatted(style))
        #expect(DurationText.compact(45, locale: en) == Duration.seconds(45).formatted(style))
        #expect(DurationText.compact(7199, locale: en) == Duration.seconds(3600).formatted(style))
        #expect(DurationText.compact(-5, locale: en) == Duration.seconds(0).formatted(style))
    }

    /// Five minutes only once five have passed: 4m 50s is still "4m",
    /// where the nearest whole minute says "5m".
    @Test func aCompactDuration_saysFiveMinutesOnlyAtFive() {
        let ja = Locale(identifier: "ja")
        #expect(DurationText.compact(4 * 60 + 50, locale: en) == "4m")
        #expect(DurationText.compact(5 * 60, locale: en) == "5m")
        #expect(DurationText.compact(4 * 60 + 50, locale: ja) == "4分")
        #expect(DurationText.compact(5 * 60, locale: ja) == "5分")
    }

    /// The unit follows the locale it is handed, not the one the process
    /// launched with, so the panel's duration matches the sentence around it.
    @Test func aCompactDuration_isFormattedInTheGivenLocale() {
        #expect(DurationText.compact(240, locale: Locale(identifier: "en_US")) == "4m")
        #expect(DurationText.compact(240, locale: Locale(identifier: "ja_JP")) == "4分")
    }
}
