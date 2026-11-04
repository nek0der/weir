// StopReasonText.swift
// Weir — why an agent stopped, as the Needs Attention list, the sidebar rows, and the decision bar say it.

import Foundation
import WeirDomain

/// Why an agent stopped, in words. The list and the sidebar's
/// second line read the same sentence; the decision bar reads the reason
/// alone, beside its own "Stopped" tag.
enum StopReasonText {
    /// "Stopped: {reason}", or "Stopped" for a stop with no reason worded.
    static func make(_ reason: StopReason, locale: Locale, now: Date = Date()) -> String {
        guard let message = message(reason, locale: locale, now: now) else {
            return LocalizedStringResource("Stopped").resolved(in: locale)
        }
        return LocalizedStringResource(
            "Stopped: \(message)",
            comment: "Needs Attention row; why the agent stopped"
        ).resolved(in: locale)
    }

    /// The reason alone: an agent's error, an exit, a usage limit, a new
    /// session's failed stage, a worktree deleted outside Weir, or a resume
    /// at relaunch that did not bring the conversation back. An error with no
    /// words has none (`nil`).
    static func message(_ reason: StopReason, locale: Locale, now: Date = Date()) -> String? {
        switch reason {
        case .processExited:
            LocalizedStringResource(
                "The process exited unexpectedly.",
                comment: "Why an agent stopped: its process ended without being asked to"
            ).resolved(in: locale)
        case let .error(text):
            text.flatMap { $0.isEmpty ? nil : $0 }
        case let .launchFailed(stage, _):
            launchFailure(stage).resolved(in: locale)
        case let .usageLimit(limit):
            usageLimit(limit, locale: locale, now: now)
        case let .signInRequired(upstream):
            signInRequired(upstream).resolved(in: locale)
        case let .modelUnavailable(model):
            modelUnavailable(model).resolved(in: locale)
        case .worktreeMissing:
            LocalizedStringResource(
                "Worktree not found.",
                comment: "Why a worktree's agent stopped: its folder was deleted outside Weir"
            ).resolved(in: locale)
        case .notResumedAtLaunch:
            LocalizedStringResource(
                "Couldn’t resume after Weir relaunched.",
                comment: "Why an agent stopped: the resume Weir typed when it relaunched did not bring the conversation back"
            ).resolved(in: locale)
        }
    }

    /// "5-hour limit reached · resets 3:40 PM": the limit by
    /// name when the provider gave it, and the time while it is ahead.
    static func usageLimit(_ limit: UsageLimit, locale: Locale, now: Date) -> String {
        // The provider's own words, which already say the limit was reached.
        if let label = limit.label {
            guard limit.resetsLater(than: now), let resetAt = limit.resetAt else { return label }
            return LocalizedStringResource(
                "stopReason.labeledLimitResets",
                defaultValue: "\(label) · resets \(resetTime(resetAt, locale: locale, now: now))",
                comment: "Why an agent stopped: a usage limit in the agent's own words, and when it resets (3:40 PM, Tue 3:40 PM)"
            ).resolved(in: locale)
        }
        let name = limitName(limit.window).resolved(in: locale)
        guard limit.resetsLater(than: now), let resetAt = limit.resetAt else {
            return LocalizedStringResource(
                "\(name) reached",
                comment: "Why an agent stopped: its plan's usage limit, named as in 5-hour limit, with no reset time ahead"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "\(name) reached · resets \(resetTime(resetAt, locale: locale, now: now))",
            comment: "Why an agent stopped: its plan's usage limit, named as in 5-hour limit, and when it resets (3:40 PM, Tue 3:40 PM)"
        ).resolved(in: locale)
    }

    private static func signInRequired(_ upstream: String?) -> LocalizedStringResource {
        guard let upstream else {
            return LocalizedStringResource(
                "Sign-in required.",
                comment: "Why an agent stopped: the service behind its model wants a sign-in; the service is not known"
            )
        }
        return LocalizedStringResource(
            "Sign in to \(upstream) to go on.",
            comment: "Why an agent stopped: the service behind its model wants a sign-in; argument: the service's name, as in OpenRouter"
        )
    }

    private static func modelUnavailable(_ model: String?) -> LocalizedStringResource {
        guard let model else {
            return LocalizedStringResource(
                "The model isn’t available.",
                comment: "Why an agent stopped: the model it asked for cannot be reached; the model is not known"
            )
        }
        return LocalizedStringResource(
            "Can’t use the model \(model).",
            comment: "Why an agent stopped: the model it asked for cannot be reached; argument: the model's name"
        )
    }

    /// The limit as the person knows it from the agent's own words; Claude's
    /// names (`five_hour`, `seven_day`, and the weekly limits of one model).
    /// A name this build does not know is the plain usage limit.
    static func limitName(_ window: String?) -> LocalizedStringResource {
        switch window {
        case PlanUsageWindow.fiveHour:
            LocalizedStringResource("5-hour limit", comment: "The plan's limit over five hours, as in 5-hour limit reached")
        case PlanUsageWindow.sevenDay:
            LocalizedStringResource("Weekly limit", comment: "The plan's limit over a week, as in Weekly limit reached")
        case PlanUsageWindow.sevenDayOpus:
            LocalizedStringResource("Opus weekly limit", comment: "The plan's weekly limit of the Opus model; Opus is a product name")
        case PlanUsageWindow.sevenDaySonnet:
            LocalizedStringResource("Sonnet weekly limit", comment: "The plan's weekly limit of the Sonnet model; Sonnet is a product name")
        default:
            LocalizedStringResource("Usage limit", comment: "The plan's usage limit, of a kind not named, as in Usage limit reached")
        }
    }

    /// When a limit resets: the time alone today, with the weekday on a
    /// later day, as the agents themselves name it ("resets 3pm", "resets
    /// Tue 9am").
    static func resetTime(_ date: Date, locale: Locale, now: Date, calendar: Calendar = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        if !calendar.isDate(date, inSameDayAs: now) {
            style = style.weekday(.abbreviated)
        }
        return date.formatted(style)
    }

    /// The stage a new session stopped at, as one short sentence.
    static func launchFailure(_ stage: NewSessionStage) -> LocalizedStringResource {
        switch stage {
        case .creatingWorktree:
            LocalizedStringResource("The worktree wasn’t created.", comment: "Why a new session stopped: git could not add its worktree")
        case let .setup(stepIndex):
            LocalizedStringResource(
                "Setup command \(stepIndex + 1) failed.",
                comment: "Why a new session stopped: one of the project's setup commands failed; the number counts from 1"
            )
        case .startingCLI:
            LocalizedStringResource("The agent didn’t start.", comment: "Why a new session stopped: its CLI did not start")
        }
    }
}
