// ForgeRateLimiterTests.swift
// Weir — what counts as a rate limit, how long a host's lookups then wait, and the one probe after.

import Foundation
import Testing
@testable import Weir

@Suite("ForgeRateLimiter")
struct ForgeRateLimiterTests {
    private let clock = ManualPRStatusClock()
    private let host = "github.com"

    private var now: Date {
        clock.now()
    }

    private func limiter() -> ForgeRateLimiter {
        ForgeRateLimiter(
            now: { [clock] in clock.now() },
            monotonicNow: { [clock] in clock.monotonicNow() },
            jitter: { 1 }
        )
    }

    private func quota(
        exitCode: Int32 = 0,
        output: String,
        stderr: String = "",
        rateLimit: GhRateLimit? = nil,
        errorTypes: [String] = []
    ) -> ForgeQuota {
        ForgeQuota(
            result: ToolResult(exitCode: exitCode, stdout: output, stderr: stderr),
            http: HTTPOutput(output),
            rateLimit: rateLimit,
            errorTypes: errorTypes,
            now: now
        )
    }

    // MARK: - What a rate limit is

    @Test("a GraphQL RATE_LIMITED error waits for the reset the headers give")
    func graphQLRateLimited_waitsForTheHeaderReset() {
        let output = "HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 4000\nX-Ratelimit-Reset: 1800000900\n\n{}"
        let body = GhRateLimit(cost: 1, limit: 5000, remaining: 4000, resetAt: "2028-01-01T00:00:00Z")
        let read = quota(exitCode: 1, output: output, rateLimit: body, errorTypes: ["RATE_LIMITED"])
        #expect(read.isRateLimited)
        #expect(read.resetAt == Date(timeIntervalSince1970: 1_800_000_900))
    }

    @Test("HTTP 429 waits as long as Retry-After says, ahead of the reset time")
    func tooManyRequests_waitsForRetryAfter() {
        let output = "HTTP/1.1 429 Too Many Requests\nRetry-After: 30\nRateLimit-Reset: 1800009999\n\n{}"
        let read = quota(exitCode: 1, output: output)
        #expect(read.isRateLimited)
        #expect(read.resetAt == now.addingTimeInterval(30))
        #expect(read.retryAfter == 30)
    }

    @Test("HTTP 403 is a rate limit only when it says so; otherwise it is a repository the token may not read")
    func forbidden_isARateLimitOnlyWhenItSaysSo() {
        #expect(quota(exitCode: 1, output: "HTTP/2.0 403 Forbidden\nX-Ratelimit-Remaining: 0\n\n{}").isRateLimited)
        #expect(quota(exitCode: 1, output: "HTTP/2.0 403 Forbidden\nRetry-After: 60\n\n{}").isRateLimited)
        #expect(!quota(exitCode: 1, output: "HTTP/2.0 403 Forbidden\nX-Ratelimit-Remaining: 4000\n\n{}").isRateLimited)
        #expect(!quota(exitCode: 1, output: "HTTP/2.0 403 Forbidden\n\n{}").isRateLimited)
    }

    @Test("a CLI that failed saying so is a rate limit with no reset; a request titled so is not")
    func cliWords_countOnlyOnFailure() {
        let refused = quota(exitCode: 1, output: "", stderr: "gh: API rate limit exceeded for user ID 1.")
        #expect(refused.isRateLimited)
        #expect(refused.resetAt == nil)
        #expect(!quota(output: "", stderr: "gh: API rate limit exceeded for user ID 1.").isRateLimited)
        let titled = quota(output: #"HTTP/2.0 200 OK\#n\#n{"title":"react to rate limits"}"#)
        #expect(!titled.isRateLimited)
    }

    @Test("less than a tenth of the limit left is low, from the body or GitLab's headers")
    func remaining_belowATenth_isLow() {
        let body = GhRateLimit(cost: 1, limit: 5000, remaining: 499, resetAt: nil)
        #expect(quota(output: "{}", rateLimit: body).isLow == true)
        #expect(quota(output: "HTTP/1.1 200 OK\nRateLimit-Limit: 2000\nRateLimit-Remaining: 1500\n\n{}").isLow == false)
        #expect(quota(output: "{}").isLow == nil)
        #expect(quota(output: "{}", rateLimit: GhRateLimit(cost: 1, limit: 5000, remaining: 500, resetAt: nil)).isLow == false)
        for limit in [0, -1] {
            #expect(quota(output: "{}", rateLimit: GhRateLimit(cost: 1, limit: limit, remaining: 0, resetAt: nil)).isLow == nil)
        }
        let conflicting = quota(
            output: "HTTP/2.0 200 OK\nX-Ratelimit-Limit: 5000\nX-Ratelimit-Remaining: 4000\n\n{}",
            rateLimit: body
        )
        #expect(conflicting.remaining == 499)
        #expect(conflicting.limit == 5000)
        #expect(conflicting.isLow == true)
    }

    // MARK: - Waiting

    @Test("a host waits until the reset, then sends one probe, and opens when it answers")
    func pause_holdsUntilTheReset_thenProbesOnce() async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(isRateLimited: true, resetAt: now.addingTimeInterval(120)), host: host, admission: .open)
        #expect(await limiter.admit(host: host) == .held)
        #expect(await limiter.admit(host: "gitlab.com") == .open)
        clock.advance(by: 119)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
        #expect(await limiter.admit(host: host) == .held)
        await limiter.record(ForgeQuota(), host: host, admission: .probe)
        #expect(await limiter.admit(host: host) == .open)
    }

    @Test("an answer from a lookup that started before the pause does not end it")
    func pause_isEndedOnlyByTheProbe() async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        await limiter.record(ForgeQuota(), host: host, admission: .open)
        #expect(await limiter.admit(host: host) == .held)
    }

    @Test("with no reset given the wait starts at a minute and doubles up to an hour")
    func backoff_doublesUpToAnHour() async {
        let limiter = limiter()
        for delay: TimeInterval in [60, 120, 240, 480, 960, 1920, 3600, 3600] {
            await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .probe)
            #expect(await limiter.admit(host: host) == .held)
            clock.advance(by: delay - 1)
            #expect(await limiter.admit(host: host) == .held)
            clock.advance(by: 1)
            #expect(await limiter.admit(host: host) == .probe)
            #expect(await limiter.admit(host: host) == .held)
        }
        // A probe that answers resets the backoff.
        await limiter.record(ForgeQuota(), host: host, admission: .probe)
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.advance(by: 60)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("jitter shortens a backoff, never lengthens it past the step")
    func backoff_jitterScalesTheStep() async {
        let limiter = ForgeRateLimiter(
            now: { [clock] in clock.now() },
            monotonicNow: { [clock] in clock.monotonicNow() },
            jitter: { 0.75 }
        )
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.advance(by: 44)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("a probe the forge did not answer keeps the pause and the backoff")
    func unansweredProbe_keepsThePause() async {
        let limiter = limiter()
        // Two backoffs in a row: the second waits two minutes.
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.advance(by: 60)
        #expect(await limiter.admit(host: host) == .probe)
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .probe)
        clock.advance(by: 120)
        #expect(await limiter.admit(host: host) == .probe)
        // The probe timed out: the host still waits, as long as last time.
        await limiter.record(ForgeQuota(hasAnswer: false), host: host, admission: .probe)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 119)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
        // The backoff was kept: the next refusal waits four minutes.
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .probe)
        clock.advance(by: 239)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("output with no status line never reached the forge, and a run that did not finish says nothing")
    func noStatusLine_isNoAnswer() {
        #expect(!quota(exitCode: 1, output: "", stderr: "error connecting to api.github.com").hasAnswer)
        #expect(quota(output: "HTTP/2.0 200 OK\n\n{}").hasAnswer)
        let query = PRStatusQuery(forge: .gitHub, branches: ["a"], numbers: [])
        #expect(!query.response(nil, for: [], baseOwner: nil, now: now).quota.hasAnswer)
    }

    @Test("a probe that never answers is taken as lost, and another goes")
    func lostProbe_letsAnotherGo() async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.advance(by: 60)
        #expect(await limiter.admit(host: host) == .probe)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 119)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
        #expect(await limiter.admit(host: host) == .held)
    }

    @Test("clock changes preserve elapsed backoff", arguments: [-3600.0, 3600.0])
    func backoff_clockChange_usesElapsedTime(wallChange: TimeInterval) async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.changeWallClock(by: wallChange)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 59)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("Retry-After remains an elapsed wait after clock changes", arguments: [-3600.0, 3600.0])
    func retryAfter_clockChange_usesElapsedTime(wallChange: TimeInterval) async {
        let limiter = limiter()
        let response = quota(
            exitCode: 1,
            output: "HTTP/1.1 429 Too Many Requests\nRetry-After: 30\nRateLimit-Reset: 1800009999\n\n{}"
        )
        await limiter.record(response, host: host, admission: .open)
        clock.changeWallClock(by: wallChange)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 29)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("clock changes preserve an unanswered probe's backoff", arguments: [-3600.0, 3600.0])
    func unansweredProbe_clockChange_usesElapsedBackoff(wallChange: TimeInterval) async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.advance(by: 60)
        #expect(await limiter.admit(host: host) == .probe)
        await limiter.record(ForgeQuota(hasAnswer: false), host: host, admission: .probe)
        clock.changeWallClock(by: wallChange)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 59)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("clock changes preserve a probe's elapsed lifetime", arguments: [-3600.0, 3600.0])
    func lostProbe_clockChange_usesElapsedTime(wallChange: TimeInterval) async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(isRateLimited: true), host: host, admission: .open)
        clock.advance(by: 60)
        #expect(await limiter.admit(host: host) == .probe)
        clock.changeWallClock(by: wallChange)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 119)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("an invalid relative wait uses the fallback backoff", arguments: ["0", "-1", "nan", "inf"])
    func retryAfter_invalidWait_usesBackoff(value: String) async {
        let limiter = limiter()
        let response = quota(exitCode: 1, output: "HTTP/1.1 429 Too Many Requests\nRetry-After: \(value)\n\n{}")
        await limiter.record(response, host: host, admission: .open)
        clock.advance(by: 59)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("a fractional Retry-After preserves its subsecond boundary")
    func retryAfter_fractionalWait_keepsItsBoundary() async {
        let limiter = limiter()
        let response = quota(exitCode: 1, output: "HTTP/1.1 429 Too Many Requests\nRetry-After: 0.5\n\n{}")
        await limiter.record(response, host: host, admission: .open)
        clock.changeWallClock(by: 3600)
        clock.advance(by: 0.49)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 0.01)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("a large finite Retry-After does not overflow its deadline or log")
    func retryAfter_largeFiniteWait_staysHeld() async {
        let limiter = limiter()
        let response = quota(exitCode: 1, output: "HTTP/1.1 429 Too Many Requests\nRetry-After: 1e20\n\n{}")
        await limiter.record(response, host: host, admission: .open)
        clock.changeWallClock(by: 3600)
        clock.advance(by: 3600)
        #expect(await limiter.admit(host: host) == .held)
    }

    @Test("an absolute reset becomes an elapsed wait when received", arguments: [-3600.0, 3600.0])
    func reset_clockChange_usesRemainingElapsedTime(wallChange: TimeInterval) async {
        let limiter = limiter()
        let reset = now.addingTimeInterval(120)
        await limiter.record(ForgeQuota(isRateLimited: true, resetAt: reset), host: host, admission: .open)
        clock.changeWallClock(by: wallChange)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 119)
        #expect(await limiter.admit(host: host) == .held)
        clock.advance(by: 1)
        #expect(await limiter.admit(host: host) == .probe)
    }

    @Test("a host whose quota runs low is told apart until it recovers")
    func lowQuota_isTracked() async {
        let limiter = limiter()
        await limiter.record(ForgeQuota(remaining: 100, limit: 5000), host: host, admission: .open)
        #expect(await limiter.isLow(host: host))
        #expect(await !limiter.isLow(host: "gitlab.com"))
        await limiter.record(ForgeQuota(), host: host, admission: .open)
        #expect(await limiter.isLow(host: host))
        await limiter.record(ForgeQuota(remaining: 500, limit: 5000), host: host, admission: .open)
        #expect(await !limiter.isLow(host: host))
    }
}
