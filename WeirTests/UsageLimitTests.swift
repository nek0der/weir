// UsageLimitTests.swift
// Weir — usage limits: read from the projection, made into stops and row chips, and notified at their reset.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct UsageLimitTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)
    private static let reset = start.addingTimeInterval(3600)

    private static func runtime(_ id: String, provider: AgentKind = .claude, limit: UsageLimit?) -> RuntimeFact {
        var fact = RuntimeFact.test(id, .error, provider: provider, tabID: UUID(), updatedAt: start, detail: "rate_limit")
        fact.usageLimit = limit
        return fact
    }

    @Test func badge_readsTheLimitFromTheProjection() throws {
        let reset = Date(timeIntervalSince1970: 1_791_873_600)
        let cases: [(json: String, expected: UsageLimit?)] = [
            (
                #"{"resetsAt":"2026-10-13T06:40:00Z","window":"five_hour"}"#,
                UsageLimit(resetAt: reset, window: "five_hour", scope: .account)
            ),
            (
                #"{"resetsAt":7,"window":"five_hour","scope":"upstream","label":"Over"}"#,
                UsageLimit(window: "five_hour", scope: .upstream, label: "Over")
            ),
            (
                #"{"resetsAt":"invalid","window":"seven_day_opus","label":"Over"}"#,
                UsageLimit(window: "seven_day_opus", scope: .model, label: "Over")
            ),
            (
                #"{"resetsAt":"2026-10-13T06:40:00Z","scope":"from-a-newer-build","label":"Over"}"#,
                UsageLimit(resetAt: reset, scope: .upstream, label: "Over")
            ),
            (#"{"window":"seven_day_sonnet"}"#, UsageLimit(window: "seven_day_sonnet", scope: .model)),
            (#"{"window":"seven_day_opus","scope":"account"}"#, UsageLimit(window: "seven_day_opus", scope: .account)),
            ("7", UsageLimit()),
            ("{}", UsageLimit()),
            ("null", nil)
        ]
        for sample in cases {
            let badge = try runtime(provider: "opencode", badge: ",\"usageLimit\":\(sample.json)").badge.asAgentBadge
            #expect(badge.state == .error, "\(sample.json)")
            #expect(badge.usageLimit == sample.expected, "\(sample.json)")
        }
        #expect(try runtime(provider: "opencode").badge.asAgentBadge.usageLimit == nil)
    }

    @Test func reducer_anErrorAtTheLimitIsAUsageLimitStop() {
        let limited = Self.runtime("r1", limit: UsageLimit(resetAt: Self.reset, window: "five_hour"))
        let other = Self.runtime("r2", limit: nil)
        let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [limited, other]))
        #expect(queue.items.count == 2)
        #expect(queue.items.first { $0.subject.runtimeID == "r1" }?.kind ==
            .stop(.usageLimit(UsageLimit(resetAt: Self.reset, window: "five_hour"))))
        #expect(queue.items.first { $0.subject.runtimeID == "r2" }?.kind == .stop(.error("rate_limit")))
        #expect(queue.counts().stops == 2)
    }

    @Test func ledger_keepsTheUsageLimitAsTheStopsReason() {
        var ledger = StopLedger()
        let limited = Self.runtime("r1", limit: UsageLimit(resetAt: Self.reset, window: nil))
        _ = ledger.update(runtimes: [limited], paneExists: { _ in true })
        #expect(ledger.records.values.map(\.reason) == [.usageLimit(UsageLimit(resetAt: Self.reset, window: nil))])
    }

    static func stop(_ provider: AgentKind, _ limit: UsageLimit, _ token: String) -> AttentionItem {
        AttentionItem.testUsageLimitStop(limit, provider: provider, runtime: token, arrivedAt: start)
    }

    @Test func limits_holdEachProviderUntilItsLatestReset() {
        let later = Self.reset.addingTimeInterval(600)
        let limits = UsageLimits(items: [
            Self.stop(.claude, UsageLimit(resetAt: Self.reset), "a"),
            Self.stop(.claude, UsageLimit(resetAt: later), "b"),
            Self.stop(.claude, UsageLimit(resetAt: nil), "c"),
            Self.stop(.codex, UsageLimit(resetAt: nil), "d")
        ])
        #expect(UsageLimit.holding(limits.limits[.claude] ?? [], at: Self.start)?.resetAt == later)
        #expect(limits.limits[.codex] == [UsageLimit(resetAt: nil)])
        #expect(UsageLimits(items: []).limits.isEmpty)
    }

    /// The person left the stopped agent (upgraded the plan, or signed in
    /// to another account) and went on in a new conversation: a turn of
    /// the provider served to its end after the stop lifts the limit, for
    /// every row and the reset notice, and keeps it lifted through that
    /// run's next turn. The stop itself stays. A prompt taken, a session
    /// started, a turn from before the stop, another provider's turn, or a
    /// model's own weekly limit lifts nothing.
    @Test(arguments: [nil, Self.reset] as [Date?])
    func limits_aTurnServedAfterTheStop_liftsTheAccountWideLimit(resetAt: Date?) throws {
        let limit = UsageLimit(resetAt: resetAt, window: "five_hour")
        let limited = Self.runtime("r1", limit: limit)
        let otherLimit = UsageLimit(resetAt: Self.reset)
        let other = Self.runtime("codex", provider: .codex, limit: otherLimit)
        let stopped = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(runtimes: [limited, other])).0
        let original = try #require(stopped.items.first { $0.subject.runtimeID == "r1" })
        #expect(original.kind == .stop(.usageLimit(limit)))
        #expect(UsageLimits(queue: stopped).accountWide(of: .claude) == [limit])
        var notices: [AgentKind: Date] = [.codex: Self.reset]
        if let resetAt {
            notices[.claude] = resetAt
        }
        #expect(UsageLimits(queue: stopped).pendingResetNotifications(isEnabled: true, now: Self.start) == notices)

        func after(_ runtime: RuntimeFact) -> AttentionQueue {
            AttentionQueueReducer.reduce(stopped, input: .init(runtimes: [limited, other, runtime])).0
        }
        let later = Self.start.addingTimeInterval(60)
        for runtime in [
            RuntimeFact.test("r2", .running, updatedAt: later),
            RuntimeFact.test("r2", .idle, updatedAt: later),
            RuntimeFact.test("r2", .finished, updatedAt: Self.start),
            RuntimeFact.test("r2", .finished, provider: .codex, updatedAt: later)
        ] {
            #expect(UsageLimits(queue: after(runtime)).accountWide(of: .claude) == [limit])
        }

        let lifted = after(RuntimeFact.test("r2", .finished, updatedAt: later))
        #expect(UsageLimits(queue: lifted).limits == [.codex: [otherLimit]])
        #expect(lifted.items.first { $0.id == original.id } == original)
        #expect(lifted.counts().stops == 2)
        #expect(UsageLimits(queue: lifted).pendingResetNotifications(isEnabled: true, now: later) == [.codex: Self.reset])
        let next = AttentionQueueReducer.reduce(
            lifted,
            input: .init(runtimes: [limited, other, RuntimeFact.test("r2", .running, updatedAt: later.addingTimeInterval(5))])
        ).0
        #expect(UsageLimits(queue: next).limits == [.codex: [otherLimit]])
        #expect(next.items.first { $0.id == original.id } == original)

        let opus = AttentionItem.testUsageLimitStop(UsageLimit(resetAt: Self.reset, window: "seven_day_opus"), arrivedAt: Self.start)
        #expect(!UsageLimits.isLifted(opus, by: RuntimeFact.test("r2", .finished, updatedAt: later)))
    }

    /// A time still ahead first, then a time not known, and a time past
    /// never: a reset that has passed does not hide a newer limit.
    @Test func holding_prefersATimeAheadThenAnUnknownOneOverOnePast() {
        let past = UsageLimit(resetAt: Self.start.addingTimeInterval(-60))
        let unknown = UsageLimit(resetAt: nil)
        let ahead = UsageLimit(resetAt: Self.reset)
        #expect(UsageLimit.holding([past, unknown, ahead], at: Self.start) == ahead)
        #expect(UsageLimit.holding([past, unknown], at: Self.start) == unknown)
        #expect(UsageLimit.holding([past], at: Self.start) == nil)
        #expect(UsageLimit.holding([], at: Self.start) == nil)
    }

    /// A weekly limit of one model holds the agents on that model only, so
    /// it marks no other row; it is still notified.
    @Test func limits_aModelsOwnLimitIsNotAccountWide() {
        let opus = UsageLimit(resetAt: Self.reset, window: "seven_day_opus")
        let limits = UsageLimits(items: [Self.stop(.claude, opus, "a")])
        #expect(limits.accountWide(of: .claude).isEmpty)
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.start) == [.claude: Self.reset])
        #expect(UsageLimit(resetAt: nil, window: "five_hour").isAccountWide)
        #expect(UsageLimit(resetAt: nil, window: nil).isAccountWide)
    }

    /// The other agents are free when the account-wide limit resets, even
    /// with a model's weekly limit ahead.
    @Test func notifications_followTheAccountWideLimitFirst() {
        let monday = Self.reset.addingTimeInterval(4 * 24 * 3600)
        let limits = UsageLimits(items: [
            Self.stop(.claude, UsageLimit(resetAt: monday, window: "seven_day_opus"), "a"),
            Self.stop(.claude, UsageLimit(resetAt: Self.reset, window: "five_hour"), "b")
        ])
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.start) == [.claude: Self.reset])
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.reset) == [.claude: monday])
    }

    @Test func stopReason_namesTheLimitAndItsReset() {
        let en = Locale(identifier: "en_US")
        let ja = Locale(identifier: "ja")
        #expect(StopReasonText.usageLimit(UsageLimit(), locale: en, now: Self.start) == "Usage limit reached")
        #expect(StopReasonText.usageLimit(UsageLimit(resetAt: Self.start), locale: en, now: Self.start) == "Usage limit reached")
        let fiveHour = UsageLimit(resetAt: Self.reset, window: "five_hour")
        #expect(StopReasonText.usageLimit(fiveHour, locale: en, now: Self.start) ==
            "5-hour limit reached · resets \(StopReasonText.resetTime(Self.reset, locale: en, now: Self.start))")
        #expect(StopReasonText.usageLimit(UsageLimit(window: "seven_day"), locale: en, now: Self.start) == "Weekly limit reached")
        #expect(StopReasonText.usageLimit(UsageLimit(), locale: ja, now: Self.start) == "利用上限に達しました")
        #expect(StopReasonText.usageLimit(fiveHour, locale: ja, now: Self.start) ==
            "5 時間枠の上限に達しました · \(StopReasonText.resetTime(Self.reset, locale: ja, now: Self.start)) に解除")
        #expect(StopReasonText.make(.usageLimit(UsageLimit()), locale: en, now: Self.start) == "Stopped: Usage limit reached")
    }

    @Test func resetTime_isTheTimeTodayAndTheWeekdayAfter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let en = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9)))
        let today = now.addingTimeInterval(3 * 3600 + 40 * 60)
        let tomorrow = now.addingTimeInterval(24 * 3600)
        #expect(StopReasonText.resetTime(today, locale: en, now: now, calendar: calendar) == "12:40\u{202F}PM")
        #expect(StopReasonText.resetTime(tomorrow, locale: en, now: now, calendar: calendar) == "Wed 9:00\u{202F}AM")
        let ja = Locale(identifier: "ja")
        #expect(StopReasonText.resetTime(today, locale: ja, now: now, calendar: calendar) == "12:40")
        #expect(StopReasonText.resetTime(tomorrow, locale: ja, now: now, calendar: calendar) == "水 9:00")
    }

    @Test func chip_goesOnceAKnownResetHasPassed() {
        let en = Locale(identifier: "en_US")
        let limit = UsageLimit(resetAt: Self.reset)
        #expect(SessionRowFactText.usageLimitChip([limit], locale: en, now: Self.start) ==
            "Limit · \(StopReasonText.resetTime(Self.reset, locale: en, now: Self.start))")
        #expect(SessionRowFactText.usageLimitSpoken([limit], locale: en, now: Self.start) ==
            "Usage limit reached · resets \(StopReasonText.resetTime(Self.reset, locale: en, now: Self.start))")
        #expect(SessionRowFactText.usageLimitChip([limit], locale: en, now: Self.reset) == nil)
        #expect(SessionRowFactText.usageLimitSpoken([limit], locale: en, now: Self.reset) == nil)
        #expect(SessionRowFactText.usageLimitChip([limit, UsageLimit()], locale: en, now: Self.reset) == "Limit")
        #expect(SessionRowFactText.usageLimitSpoken([limit, UsageLimit()], locale: en, now: Self.reset) == "Usage limit reached")
        #expect(SessionRowFactText.usageLimitChip([], locale: en, now: Self.start) == nil)
        #expect(SessionRowFactText.usageLimitSpoken([], locale: en, now: Self.start) == nil)
    }

    @Test func badge_keepsTheLimitThroughPersistence() throws {
        let badge = AgentBadge(state: .error, updatedAt: Self.start, usageLimit: UsageLimit(resetAt: Self.reset, window: "five_hour"))
        let decoded = try JSONDecoder().decode(AgentBadge.self, from: JSONEncoder().encode(badge))
        #expect(decoded.usageLimit == badge.usageLimit)
    }

    @Test func sidebar_everyRowWithALimitedAgentShowsTheChip() {
        func row(_ name: String, _ providers: [AgentKind]) -> SessionSidebarModel.RowInput {
            var fact = SessionRowFact.Input()
            fact.agents = providers.map { .init(provider: $0, state: .idle, detail: nil) }
            return SessionSidebarModel.RowInput(
                container: .worktree(projectID: UUID(), worktreeID: UUID()),
                name: name,
                nameTruncation: .name,
                fact: fact,
                lastActivity: nil,
                isMissing: false,
                agents: [fact]
            )
        }
        let stop = AttentionItem(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.usageLimit(UsageLimit())),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
            arrivalSequence: 0,
            arrivedAt: Self.start
        )
        let model = SessionSidebarModel(
            rows: [row("a", [.claude]), row("b", [.claude]), row("mixed", [.codex, .claude]), row("other", [.codex])],
            activeContainer: .loose,
            usageLimits: UsageLimits(items: [stop]),
            locale: Locale(identifier: "en_US")
        )
        let en = Locale(identifier: "en_US")
        #expect(model.rows.map(\.name) == ["a", "b", "mixed", "other"])
        #expect(model.rows.map(\.usageLimits) == [[UsageLimit()], [UsageLimit()], [UsageLimit()], []])
        #expect(model.rows.map { SessionRowFactText.usageLimitChip($0.usageLimits, locale: en, now: Self.start) } ==
            ["Limit", "Limit", "Limit", nil])
        #expect(model.rows.map { SessionRowFactText.usageLimitSpoken($0.usageLimits, locale: en, now: Self.start) } ==
            ["Usage limit reached", "Usage limit reached", "Usage limit reached", nil])
        #expect(model.rows.map {
            SessionRowFactText.spokenLabel(for: $0, projectName: nil, now: Self.start, locale: en).contains("Usage limit reached")
        } == [true, true, true, false])
    }

    /// The stopped row names its reset only while it is ahead, against the
    /// row's own clock rather than when the sidebar was built.
    @Test func sidebar_theStoppedRowDropsItsResetOnceItPasses() {
        let limit = UsageLimit(resetAt: Self.reset, window: "five_hour")
        var fact = SessionRowFact.Input()
        fact.items = [AttentionItem(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.usageLimit(limit)),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
            arrivalSequence: 0,
            arrivedAt: Self.start
        )]
        fact.agents = [.init(provider: .claude, state: .error, detail: nil)]
        let en = Locale(identifier: "en_US")
        let model = SessionSidebarModel(
            rows: [.init(container: .loose, name: "a", nameTruncation: .name, fact: fact, lastActivity: nil, isMissing: false)],
            activeContainer: .loose,
            usageLimits: UsageLimits(items: fact.items),
            locale: en
        )
        #expect(SessionRowFactText.current(model.rows[0], now: Self.start, locale: en).contains("resets"))
        #expect(SessionRowFactText.current(model.rows[0], now: Self.reset, locale: en) == "Stopped: 5-hour limit reached")
    }

    // MARK: - Whom a limit holds

    @Test func aLimitOnOneServiceMarksNoOtherAgent_andOffersNoWaitInPlaceOfGoingOn() throws {
        let upstream = UsageLimit(resetAt: Self.reset, scope: .upstream, label: "Free usage limit reached")
        let item = AttentionItem.testUsageLimitStop(upstream, provider: .opencode, arrivedAt: Self.start)
        let limits = UsageLimits(items: [item])
        #expect(limits.limits == [.opencode: [upstream]])
        for provider in AgentKind.allCases {
            #expect(limits.accountWide(of: provider).isEmpty)
        }
        for requested in [false, true] {
            let notice = UsageLimitResetNotice.of(item, in: limits, isRequested: { _ in requested }, now: Self.start)
            #expect(notice == nil)
            let row = NeedsAttentionListModel.Row(
                id: item.id, state: .stopped, title: "OpenCode", place: nil,
                fact: "Free usage limit reached", placeLead: "", action: nil, arrivedAt: Self.start
            )
            let menu = MenuBarModel(rows: [row], request: { _ in nil }, canResume: { $0 == item.id }, resetNotice: { _ in notice })
            let entry = try #require(menu.items.first)
            #expect(menu.items.count == 1)
            #expect(entry.actions == [.resume])
            #expect(entry.note == nil)
        }
    }

    @Test func aClaudeModelsWeeklyLimit_keepsItsNotice() {
        let opus = UsageLimit(resetAt: Self.reset, window: "seven_day_opus")
        #expect(opus.scope == .model)
        let item = AttentionItem.testUsageLimitStop(opus, provider: .claude, arrivedAt: Self.start)
        let limits = UsageLimits(items: [item])
        #expect(UsageLimitResetNotice.of(item, in: limits, isRequested: { _ in
            false
        }, now: Self.reset.addingTimeInterval(-60)) == .offered)
    }

    @Test func aLimitKeptFromBeforeScopes_readsAsItDidThen() throws {
        let cases: [(String, UsageLimit)] = [
            (#"{"window":"five_hour"}"#, UsageLimit(window: "five_hour", scope: .account)),
            (#"{"window":"seven_day_opus"}"#, UsageLimit(window: "seven_day_opus", scope: .model)),
            (#"{"window":"seven_day_sonnet"}"#, UsageLimit(window: "seven_day_sonnet", scope: .model)),
            (#"{"window":"seven_day_opus","scope":"account"}"#, UsageLimit(window: "seven_day_opus", scope: .account)),
            (
                #"{"scope":"from-a-newer-build","window":"five_hour","label":"Over"}"#,
                UsageLimit(window: "five_hour", scope: .upstream, label: "Over")
            )
        ]
        for (json, expected) in cases {
            #expect(try JSONDecoder().decode(UsageLimit.self, from: Data(json.utf8)) == expected, "\(json)")
        }
        let kept = UsageLimit(window: "five_hour", scope: .upstream, label: "Over")
        let bytes = try JSONEncoder().encode(kept)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
        #expect(object == ["window": "five_hour", "scope": "upstream", "label": "Over"])
        #expect(try JSONDecoder().decode(UsageLimit.self, from: bytes) == kept)
    }

    @Test func aLimitInTheAgentsOwnWords_isShownAsItIsSaid() {
        let english = Locale(identifier: "en")
        let label = "Free usage limit reached"
        let unknown = UsageLimit(scope: .upstream, label: label)
        let timed = UsageLimit(resetAt: Self.reset, scope: .upstream, label: label)
        for locale in [english, Locale(identifier: "ja")] {
            #expect(StopReasonText.usageLimit(unknown, locale: locale, now: Self.start) == label)
            #expect(StopReasonText.usageLimit(timed, locale: locale, now: Self.reset) == label)
            #expect(StopReasonText.usageLimit(timed, locale: locale, now: Self.reset.addingTimeInterval(1)) == label)
        }
        #expect(StopReasonText.usageLimit(timed, locale: english, now: Self.start) ==
            "\(label) · resets \(StopReasonText.resetTime(Self.reset, locale: english, now: Self.start))")
        let japanese = Locale(identifier: "ja")
        #expect(StopReasonText.usageLimit(timed, locale: japanese, now: Self.start) ==
            "\(label) · \(StopReasonText.resetTime(Self.reset, locale: japanese, now: Self.start)) に解除")
    }

    // MARK: - Who a run is, and what stopped it

    private func runtime(provider: String, badge: String = "") throws -> AgentProjectedRuntime {
        let json = #"""
        {"id":"r","provider":"\#(provider)","panes":[],"attachment":"attached","eventToken":"e","episodeToken":"1",
         "badge":{"state":"error","isTmuxHosted":false,"updatedAt":"2026-10-13T06:40:00Z"\#(badge)}}
        """#
        return try JSONDecoder().decode(AgentProjectedRuntime.self, from: Data(json.utf8))
    }

    @Test func aRunOfAProviderThisBuildDoesNotKnow_isNotShownAsAnotherAgent() throws {
        #expect(try AgentRuntimePresentation(projected: runtime(provider: "from-a-newer-build"), tmuxLocationsByEndpoint: [:]) == nil)
        #expect(try AgentRuntimePresentation(projected: runtime(provider: "opencode"), tmuxLocationsByEndpoint: [:])?.kind == .opencode)
    }

    @MainActor
    @Test func aFailureOfItsOwnKind_namesTheServiceOrModelItNeeds() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        struct FailureCase {
            let kind: String
            let reason: StopReason
            let text: String
        }
        let cases = [
            FailureCase(kind: "signIn", reason: .signInRequired(upstream: "OpenRouter"), text: "Sign in to OpenRouter to go on."),
            FailureCase(kind: "modelUnavailable", reason: .modelUnavailable(model: "GPT-5.5"), text: "Can’t use the model GPT-5.5."),
            FailureCase(kind: "from-a-newer-build", reason: .error(nil), text: "Stopped")
        ]
        for sample in cases {
            var projected = try runtime(
                provider: "opencode",
                badge: #","failureKind":"\#(sample.kind)","model":"GPT-5.5","modelUpstream":"OpenRouter""#
            )
            projected.panes = [pane]
            let runtime = try #require(AgentRuntimePresentation(projected: projected, tmuxLocationsByEndpoint: [:]))
            let input = AttentionQueueStore.makeInput(
                runtimes: [runtime], isRead: { _ in false }, approvals: [], session: session, isApprovalServiceRunning: false
            )
            let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: input)
            let item = try #require(queue.items.first)
            #expect(queue.items.count == 1)
            #expect(item.subject == .runtime(id: "r", provider: .opencode, paneID: pane, tabID: tab.id, projectID: nil))
            #expect(item.kind == .stop(sample.reason), "\(sample.kind)")
            guard case let .stop(reason) = item.kind else {
                Issue.record("Expected a stop for the projected failure.")
                continue
            }
            let expected = sample.kind == "from-a-newer-build" ? sample.text : "Stopped: \(sample.text)"
            #expect(StopReasonText.make(reason, locale: Locale(identifier: "en")) == expected)
        }
    }

}
