// ForgeRateLimiter.swift
// Weir — holds the pull request lookups of a host whose rate limit ran out, until it resets.
//
// The points the lookups spend are the person's: every token of theirs
// draws on the same 5,000 an hour, so a lookup that keeps asking after
// the forge said stop spends nothing of its own but keeps the limit
// tripped for the person's other tools too, and GitHub's secondary
// limits grow longer the more requests arrive during them. So the
// first lookup that is refused for a rate limit stops every lookup of
// that host until the time the forge gave, or, when it gave none, for
// a backoff that starts at a minute and doubles up to an hour. Then
// one lookup goes as a probe, and the rest wait for its answer.
//
// A row keeps what it showed throughout: a held lookup is no answer
// (`PRStatusFetcher.Lookup.isAnswered`).

import Foundation
import OSLog

private let log = Logger.weir("git.pr.limit")

/// What one run of a forge's CLI said about its rate limit.
struct ForgeQuota: Equatable {
    /// Whether the forge refused the run for a rate limit.
    var isRateLimited = false
    /// When the forge said the limit lifts; `nil` when it did not say.
    var resetAt: Date?
    var remaining: Int?
    var limit: Int?
    /// Whether the forge answered at all. A run that timed out, was
    /// canceled, or never reached the forge says nothing about the limit:
    /// it neither ends a pause nor resets the backoff.
    var hasAnswer = true

    /// Whether less than a tenth of the limit is left, `nil` when the run
    /// said nothing of it. The lookups then stop polling running checks
    /// every 45 seconds, which spends the most for the least.
    var isLow: Bool? {
        guard let remaining, let limit, limit > 0 else { return nil }
        return remaining * 10 < limit
    }

    init(isRateLimited: Bool = false, resetAt: Date? = nil, remaining: Int? = nil, limit: Int? = nil, hasAnswer: Bool = true) {
        self.isRateLimited = isRateLimited
        self.resetAt = resetAt
        self.remaining = remaining
        self.limit = limit
        self.hasAnswer = hasAnswer
    }

    /// Reads a run: a GraphQL `RATE_LIMITED` error, HTTP 429, HTTP 403 that
    /// says it is a rate limit, or a CLI that failed saying so. An HTTP 403
    /// alone is also what a repository the token may not read answers, and
    /// pausing the whole host for that would hide every other repository's
    /// requests. GitHub's headers are `X-RateLimit-*`, GitLab's
    /// `RateLimit-*`; GitHub's GraphQL body also has `rateLimit`.
    init(result: ToolResult, http: HTTPOutput, rateLimit: GhRateLimit?, errorTypes: [String], now: Date) {
        let headers = http.headers
        remaining = rateLimit?.remaining ?? (headers["x-ratelimit-remaining"] ?? headers["ratelimit-remaining"]).flatMap { Int($0) }
        limit = rateLimit?.limit ?? (headers["x-ratelimit-limit"] ?? headers["ratelimit-limit"]).flatMap { Int($0) }
        let retryAfter = headers["retry-after"].flatMap { TimeInterval($0) }
        let saysRateLimit = !result.isSuccess && ["rate limit", "too many requests"].contains {
            result.stderr.localizedCaseInsensitiveContains($0)
        }
        let isExhausted = remaining == 0 || errorTypes.contains("RATE_LIMITED")
        isRateLimited = errorTypes.contains("RATE_LIMITED")
            || http.status == 429
            || (http.status == 403 && (isExhausted || retryAfter != nil || saysRateLimit))
            || saysRateLimit
        // `--include` puts a status line before every response the forge
        // sends, so output without one never reached it: a network error.
        hasAnswer = isRateLimited || http.status != nil
        guard isRateLimited else { return }
        // `Retry-After` is the wait a secondary limit asks for; the reset
        // time is the primary limit's, which only says when a spent limit
        // comes back.
        if let retryAfter {
            resetAt = now.addingTimeInterval(retryAfter)
        } else if isExhausted {
            let header = (headers["x-ratelimit-reset"] ?? headers["ratelimit-reset"])
                .flatMap { TimeInterval($0) }
                .map { Date(timeIntervalSince1970: $0) }
            resetAt = header ?? rateLimit?.resetAt.flatMap { try? Date($0, strategy: .iso8601) }
        }
    }
}

/// Which host's lookups wait, until when, and whose quota runs low. One for
/// the app, shared by every repository's lookups, since a host's limit is
/// the person's across all of them.
actor ForgeRateLimiter {
    /// Whether a lookup of a host may go.
    enum Admission: Equatable {
        case open
        /// The first lookup after a pause, which decides whether it ends.
        case probe
        /// Paused, or a probe is out.
        case held
    }

    private struct Pause {
        var until: Date
        var probeStartedAt: Date?
    }

    private var pauses: [String: Pause] = [:]
    /// How many backoffs in a row each host has had, for the next one's
    /// length.
    private var backoffSteps: [String: Int] = [:]
    private var lowHosts: Set<String> = []

    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double

    static let firstBackoff: TimeInterval = 60
    static let longestBackoff: TimeInterval = 3600
    /// A probe that has not answered in this long is taken as lost (its
    /// task canceled), and the next lookup probes instead: a pause must not
    /// outlive the reason for it.
    static let lostProbe: TimeInterval = 120

    /// `jitter` scales each backoff, by a factor in 0.75...1 by default, so
    /// the lookups of several repositories, or of several apps on one
    /// account, do not all come back in the same second.
    init(
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.75...1) }
    ) {
        self.now = now
        self.jitter = jitter
    }

    func admit(host: String) -> Admission {
        guard var pause = pauses[host] else { return .open }
        let now = now()
        if now < pause.until {
            return .held
        }
        if let started = pause.probeStartedAt, now.timeIntervalSince(started) < Self.lostProbe {
            return .held
        }
        pause.probeStartedAt = now
        pauses[host] = pause
        return .probe
    }

    /// What a lookup admitted as `admission` found. Only a probe ends a
    /// pause: a lookup that started before the pause and answers after it
    /// says nothing about the limit now.
    func record(_ quota: ForgeQuota, host: String, admission: Admission) {
        let now = now()
        if quota.isRateLimited {
            let until: Date
            if let reset = quota.resetAt, reset > now {
                until = reset
            } else {
                let step = backoffSteps[host, default: 0]
                until = now.addingTimeInterval(Self.backoff(step: step) * jitter())
                backoffSteps[host] = step + 1
            }
            pauses[host] = Pause(until: until)
            log.info("rate limited on \(host, privacy: .private); lookups wait \(Int(until.timeIntervalSince(now)), privacy: .public)s")
            return
        }
        guard quota.hasAnswer else {
            // A probe the forge did not answer leaves the pause on, and the
            // next probe goes after the last backoff again, not doubled: the
            // forge said nothing more about the limit.
            if admission == .probe, pauses[host] != nil {
                let step = max(backoffSteps[host, default: 0] - 1, 0)
                pauses[host] = Pause(until: now.addingTimeInterval(Self.backoff(step: step) * jitter()))
            }
            return
        }
        if pauses[host] != nil {
            guard admission == .probe else { return }
            log.info("rate limit on \(host, privacy: .private) lifted")
        }
        pauses[host] = nil
        backoffSteps[host] = nil
        if let isLow = quota.isLow {
            if isLow {
                lowHosts.insert(host)
            } else {
                lowHosts.remove(host)
            }
        }
    }

    func isLow(host: String) -> Bool {
        lowHosts.contains(host)
    }

    /// The backoff before jitter: a minute, doubling, at most an hour.
    static func backoff(step: Int) -> TimeInterval {
        min(longestBackoff, firstBackoff * pow(2, Double(min(step, 16))))
    }
}
