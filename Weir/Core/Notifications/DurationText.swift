// DurationText.swift
// Weir — a duration in the locale's own units: a command's run, a wait, a time left.

import Foundation

/// Durations in the locale's own units and decimal separator. A format
/// string such as `"%.1fs"` pinned the C locale's "." and English units,
/// so comma-decimal locales read "1,5s" as "15s" and Japanese showed
/// "1.5s" amid translated words.
enum DurationText {
    /// How long a command ran: "48.2s" under a minute, then "2m 14s". The
    /// banner's body and the history's row say it the same way. `locale` is
    /// the one the sentence around it is resolved in.
    static func command(_ seconds: Double, locale: Locale) -> String {
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1))
                    .locale(locale)
            )
        }
        // Whole seconds past a minute: "2m 14s", not "2m 14.6s".
        return Duration.seconds(Int(seconds)).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow)
                .locale(locale)
        )
    }

    /// The largest whole unit of `interval`, localized in `locale`: `4m`,
    /// `45s`, `2h`. Rounded down, never to the nearest: "expires in 5m"
    /// must not appear while under five minutes remain, and an item that
    /// has waited 4m 50s has not waited five minutes. The prompt cache's
    /// panel and Needs Attention's wait both say it this way.
    static func compact(_ interval: TimeInterval, locale: Locale) -> String {
        let seconds = max(0, Int(interval))
        let floored = if seconds >= 86400 {
            seconds / 86400 * 86400
        } else if seconds >= 3600 {
            seconds / 3600 * 3600
        } else if seconds >= 60 {
            seconds / 60 * 60
        } else {
            seconds
        }
        return Duration.seconds(floored).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1)
                .locale(locale)
        )
    }
}
