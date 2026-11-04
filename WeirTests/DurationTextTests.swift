// DurationTextTests.swift
// Weir — a duration in words: a command's run, a wait, a time left.

import Foundation
import Testing
@testable import Weir

struct DurationTextTests {
    private let en = Locale(identifier: "en")

    @Test func aCommandsTime_isSaidInWholeSecondsPastAMinute() {
        #expect(DurationText.command(134.6, locale: en) == DurationText.command(134, locale: en))
        #expect(DurationText.command(134, locale: en).contains("2"))
        #expect(DurationText.command(48.25, locale: en).contains("48.2") || DurationText.command(48.25, locale: en).contains("48.3"))
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
