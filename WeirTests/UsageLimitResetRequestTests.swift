// UsageLimitResetRequestTests.swift
// Weir — "Notify When It Resets" on a usage limit stop: when it is offered, what it and the setting
// schedule and withdraw, and the menu that offers it.

import Foundation
import Observation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct UsageLimitResetRequestTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let reset = now.addingTimeInterval(3600)

    private static func stop(_ limit: UsageLimit?, provider: AgentKind = .claude, runtime: String = "r") -> AttentionItem {
        AttentionItem.testUsageLimitStop(limit, provider: provider, runtime: runtime, arrivedAt: now)
    }

    /// The limits of one stop per provider, each with the reset given.
    private static func limits(_ resets: [AgentKind: Date?]) -> UsageLimits {
        UsageLimits(items: resets.map { provider, reset in
            stop(UsageLimit(resetAt: reset), provider: provider, runtime: provider.rawValue)
        })
    }

    private enum NoticeEvent: Equatable {
        case scheduled(AgentKind, Date)
        case canceled(AgentKind)
    }

    @MainActor
    private final class Recorder {
        var events: [NoticeEvent] = []
        var scheduled: [(AgentKind, Date)] {
            events.compactMap {
                if case let .scheduled(provider, date) = $0 {
                    (provider, date)
                } else {
                    nil
                }
            }
        }

        var canceled: [AgentKind] {
            events.compactMap {
                if case let .canceled(provider) = $0 {
                    provider
                } else {
                    nil
                }
            }
        }

        func schedule(_ provider: AgentKind, _ date: Date) {
            events.append(.scheduled(provider, date))
        }

        func cancel(_ provider: AgentKind) {
            events.append(.canceled(provider))
        }

        func clearCancellations() {
            events.removeAll {
                if case .canceled = $0 {
                    true
                } else {
                    false
                }
            }
        }
    }

    @Observable
    final class Sources {
        var limits: UsageLimits
        var isEnabled: Bool

        init(limits: UsageLimits, isEnabled: Bool) {
            self.limits = limits
            self.isEnabled = isEnabled
        }
    }

    private static func sync(
        _ items: Recorded<[AttentionItem]>,
        isEnabled: Bool = false,
        now: Recorded<Date> = Recorded(now),
        recorder: Recorder
    ) -> UsageLimitResetSync {
        UsageLimitResetSync(
            limits: { UsageLimits(items: items.value) },
            isEnabled: { isEnabled },
            now: { now.value },
            schedule: recorder.schedule,
            cancel: recorder.cancel
        )
    }

    // MARK: - When it is offered

    @Test func notice_isOfferedOnlyWhileTheProviderIsHeldWithATimeAhead() {
        let never: (AgentKind) -> Bool = { _ in false }
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let limits = UsageLimits(items: [limited])
        #expect(UsageLimitResetNotice.of(limited, in: limits, isRequested: never, now: Self.now) == .offered)
        #expect(UsageLimitResetNotice.of(limited, in: limits, isRequested: { _ in true }, now: Self.now) == .requested)
        #expect(UsageLimitResetNotice.of(limited, in: limits, isRequested: never, now: Self.reset) == nil)
        let unknown = Self.stop(UsageLimit())
        #expect(UsageLimitResetNotice.of(unknown, in: UsageLimits(items: [unknown]), isRequested: never, now: Self.now) == nil)
        let exited = Self.stop(nil)
        #expect(UsageLimitResetNotice.of(exited, in: UsageLimits(items: [exited]), isRequested: never, now: Self.now) == nil)
    }

    /// A five-hour stop whose reset passed still offers the notice while a
    /// weekly limit holds the provider: resuming would meet that one.
    @Test func notice_followsTheProvidersRelease_notTheStopsOwnReset() {
        let passed = Self.stop(UsageLimit(resetAt: Self.now.addingTimeInterval(-60), window: "five_hour"), runtime: "a")
        let weekly = Self.stop(UsageLimit(resetAt: Self.reset, window: "seven_day"), runtime: "b")
        let limits = UsageLimits(items: [passed, weekly])
        #expect(UsageLimitResetNotice.of(passed, in: limits, isRequested: { _ in false }, now: Self.now) == .offered)
        #expect(limits.releaseAt(of: .claude, now: Self.now) == Self.reset)
    }

    /// A notification is pending for each provider the person asked one for,
    /// or for every provider with the setting on, and only for a reset ahead.
    @Test func pending_onlyForTheProvidersAskedOf_andOnlyForAFutureReset() {
        let limits = UsageLimits(items: [
            Self.stop(UsageLimit(resetAt: Self.reset), provider: .claude, runtime: "a"),
            Self.stop(UsageLimit(resetAt: Self.reset.addingTimeInterval(60)), provider: .codex, runtime: "b")
        ])
        #expect(limits.pendingResetNotifications(isEnabled: false, requested: [], now: Self.now).isEmpty)
        #expect(limits.pendingResetNotifications(isEnabled: false, requested: [.claude], now: Self.now) == [.claude: Self.reset])
        let codex = Self.reset.addingTimeInterval(60)
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.now) == [.claude: Self.reset, .codex: codex])
        #expect(limits.pendingResetNotifications(isEnabled: false, requested: [.codex], now: Self.now) == [.codex: codex])
        #expect(limits.pendingResetNotifications(isEnabled: true, now: Self.reset) == [.codex: codex])

        let unknown = Self.limits([.claude: Self.reset, .codex: nil])
        #expect(unknown.pendingResetNotifications(isEnabled: true, now: Self.now) == [.claude: Self.reset])
        #expect(unknown.pendingResetNotifications(isEnabled: true, now: Self.reset).isEmpty)
    }

    // MARK: - What it schedules

    @Test func request_schedulesTheResetWithTheSettingOff() {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let sync = Self.sync(Recorded([limited]), recorder: recorder)
        recorder.events = []
        #expect(sync.pending.isEmpty)
        #expect(sync.notice(for: limited, now: Self.now) == .offered)

        #expect(sync.requestIfOffered(limited, now: Self.now))
        #expect(sync.pending == [.claude: Self.reset])
        #expect(sync.requested == [.claude: Self.reset])
        #expect(sync.notice(for: limited, now: Self.now) == .requested)
        #expect(!sync.requestIfOffered(limited, now: Self.now))
        #expect(recorder.events == [.scheduled(.claude, Self.reset)])
    }

    @Test func request_isRefusedForAStopThatOffersNoNotice() {
        let recorder = Recorder()
        let exited = Self.stop(nil, runtime: "exited")
        let live = Self.stop(UsageLimit(resetAt: Self.reset), runtime: "live")
        let expired = Self.stop(UsageLimit(resetAt: Self.now), provider: .codex, runtime: "expired")
        let unknown = Self.stop(UsageLimit(resetAt: nil), provider: .antigravity, runtime: "unknown")
        let sync = Self.sync(Recorded([exited, live, expired, unknown]), recorder: recorder)
        recorder.events = []
        #expect(sync.notice(for: live, now: Self.now) == .offered)

        for item in [exited, expired, unknown] {
            #expect(sync.notice(for: item, now: Self.now) == nil)
            #expect(!sync.requestIfOffered(item, now: Self.now))
        }
        #expect(sync.requested.isEmpty)
        #expect(sync.pending.isEmpty)
        #expect(recorder.events.isEmpty)
    }

    @Test(arguments: [false, true])
    func request_withTheSettingOnIsAlreadyRequested(hasManualRequest: Bool) {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let isEnabled = Recorded(!hasManualRequest)
        let sync = UsageLimitResetSync(
            limits: { UsageLimits(items: [limited]) },
            isEnabled: { isEnabled.value },
            now: { Self.now },
            schedule: recorder.schedule,
            cancel: recorder.cancel
        )
        recorder.clearCancellations()
        if hasManualRequest {
            #expect(sync.requestIfOffered(limited, now: Self.now))
            isEnabled.value = true
            sync.refresh()
        }
        #expect(sync.notice(for: limited, now: Self.now) == .requested)

        #expect(!sync.requestIfOffered(limited, now: Self.now))
        let manual = hasManualRequest ? [AgentKind.claude: Self.reset] : [:]
        #expect(sync.requested == manual)
        #expect(sync.pending == [.claude: Self.reset])
        #expect(recorder.events == [.scheduled(.claude, Self.reset)])

        isEnabled.value = false
        sync.refresh()
        #expect(sync.requested == manual)
        #expect(sync.pending == manual)
        if hasManualRequest {
            #expect(sync.notice(for: limited, now: Self.now) == .requested)
            #expect(recorder.events == [.scheduled(.claude, Self.reset)])
        } else {
            #expect(sync.notice(for: limited, now: Self.now) == .offered)
            #expect(recorder.events == [.scheduled(.claude, Self.reset), .canceled(.claude)])
        }
    }

    @Test func request_leavesTheOtherProviderAlone() {
        let recorder = Recorder()
        let claude = Self.stop(UsageLimit(resetAt: Self.reset), provider: .claude, runtime: "a")
        let later = Self.reset.addingTimeInterval(60)
        let codex = Self.stop(UsageLimit(resetAt: later), provider: .codex, runtime: "b")
        let items = Recorded([claude, codex])
        let sync = Self.sync(items, recorder: recorder)
        recorder.events = []
        #expect(sync.requestIfOffered(claude, now: Self.now))
        #expect(recorder.events == [.scheduled(.claude, Self.reset)])
        #expect(sync.notice(for: codex, now: Self.now) == .offered)
        #expect(sync.requestIfOffered(codex, now: Self.now))
        #expect(sync.pending == [.claude: Self.reset, .codex: later])

        items.value = [codex]
        sync.refresh()
        #expect(sync.requested == [.codex: later])
        #expect(sync.pending == [.codex: later])
        #expect(sync.notice(for: codex, now: Self.now) == .requested)
        #expect(recorder.events == [.scheduled(.claude, Self.reset), .scheduled(.codex, later), .canceled(.claude)])
    }

    /// A stop replaced before its reset keeps the request, at the new time.
    @Test func request_followsTheReleaseWhileTheProviderIsHeld() {
        let recorder = Recorder()
        let first = Self.stop(UsageLimit(resetAt: Self.reset), runtime: "a")
        let items = Recorded([first])
        let sync = Self.sync(items, recorder: recorder)
        sync.requestIfOffered(first, now: Self.now)

        let sooner = Self.now.addingTimeInterval(75)
        items.value = [Self.stop(UsageLimit(resetAt: sooner), runtime: "a")]
        sync.refresh()
        #expect(sync.requested[.claude] == sooner)
        #expect(recorder.scheduled.map(\.1) == [Self.reset, sooner])
    }

    /// Once the release it was for has come, a request is spent: a limit
    /// met later offers its own notice.
    @Test(arguments: [false, true])
    func request_endsAtTheReleaseItWasFor(hasLaterLimit: Bool) {
        let recorder = Recorder()
        let clock = Recorded(Self.now)
        let first = Self.stop(UsageLimit(resetAt: Self.reset), runtime: "a")
        let items = Recorded([first])
        let sync = Self.sync(items, now: clock, recorder: recorder)
        recorder.events = []
        #expect(sync.requestIfOffered(first, now: Self.now))
        #expect(sync.pending == [.claude: Self.reset])

        clock.value = Self.reset.addingTimeInterval(1)
        let second = Self.stop(UsageLimit(resetAt: Self.reset.addingTimeInterval(7200)), runtime: "b")
        if hasLaterLimit {
            items.value = [first, second]
        }
        sync.refresh()

        #expect(sync.requested.isEmpty)
        #expect(sync.pending.isEmpty)
        #expect(recorder.events == [.scheduled(.claude, Self.reset)])
        if hasLaterLimit {
            #expect(sync.notice(for: second, now: clock.value) == .offered)
        } else {
            #expect(sync.notice(for: first, now: clock.value) == nil)
        }
    }

    /// A notice the person asked for, or one the setting schedules, is
    /// withdrawn with the limit it was for.
    @Test(arguments: [false, true])
    func aNotice_isWithdrawnWithTheLimitItWasFor(isSettingOn: Bool) {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let items = Recorded([limited])
        let sync = Self.sync(items, isEnabled: isSettingOn, recorder: recorder)
        if !isSettingOn {
            sync.requestIfOffered(limited, now: Self.now)
        }
        #expect(recorder.scheduled.map(\.1) == [Self.reset])
        recorder.clearCancellations()

        items.value = []
        sync.refresh()
        #expect(sync.requested.isEmpty)
        #expect(sync.pending.isEmpty)
        #expect(recorder.canceled == [.claude])
    }

    @Test func sync_withdrawsWhatAnEarlierLaunchLeftThenSchedulesWhatHolds() {
        let recorder = Recorder()
        let reset = Self.now.addingTimeInterval(60)
        _ = UsageLimitResetSync(
            limits: { Self.limits([.claude: reset]) },
            isEnabled: { true },
            now: { Self.now },
            schedule: recorder.schedule,
            cancel: recorder.cancel
        )
        let cancellations = AgentKind.allCases.map(NoticeEvent.canceled)
        #expect(recorder.events == cancellations + [.scheduled(.claude, reset)])
    }

    @Test func sync_schedulesOncePerResetAndWithdrawsWhatGoes() async throws {
        let recorder = Recorder()
        let first = Self.now.addingTimeInterval(60)
        let second = Self.now.addingTimeInterval(120)
        let sources = Sources(limits: Self.limits([.claude: first]), isEnabled: true)
        let sync = UsageLimitResetSync(
            limits: { sources.limits },
            isEnabled: { sources.isEnabled },
            now: { Self.now },
            schedule: recorder.schedule,
            cancel: recorder.cancel
        )
        recorder.clearCancellations()
        #expect(recorder.events == [.scheduled(.claude, first)])

        sync.refresh()
        #expect(recorder.events == [.scheduled(.claude, first)])

        sources.limits = Self.limits([.claude: second])
        await pollUntil(timeout: .seconds(2), interval: .milliseconds(10)) { sync.pending == [.claude: second] }
        try #require(sync.pending == [.claude: second])
        #expect(recorder.events == [.scheduled(.claude, first), .scheduled(.claude, second)])

        sources.isEnabled = false
        await pollUntil(timeout: .seconds(2), interval: .milliseconds(10)) { sync.pending.isEmpty }
        #expect(sync.pending.isEmpty)
        #expect(recorder.events == [.scheduled(.claude, first), .scheduled(.claude, second), .canceled(.claude)])
    }

    // MARK: - Reading again

    /// The bar and the menu are drawn again when the limits are read, which
    /// the sync does a second past the next reset with no event to ask.
    @Test func check_isDueASecondPastTheNextReset() {
        let recorder = Recorder()
        let clock = Recorded(Self.now)
        let soon = Self.now.addingTimeInterval(60)
        let items = Recorded([
            Self.stop(UsageLimit(resetAt: Self.reset), runtime: "a"),
            Self.stop(UsageLimit(resetAt: soon), provider: .codex, runtime: "b")
        ])
        let sync = Self.sync(items, now: clock, recorder: recorder)
        #expect(sync.resetPassedAt == Self.now)
        #expect(sync.nextCheck == soon.addingTimeInterval(1))

        clock.value = soon.addingTimeInterval(1)
        sync.refresh()
        #expect(sync.nextCheck == Self.reset.addingTimeInterval(1))

        items.value = []
        sync.refresh()
        #expect(sync.nextCheck == nil)
    }

    /// The real wait is armed for a relative duration. The injected clock
    /// advances independently, without notifying the sources.
    @Test(.tags(.slow)) func check_marksTheResetPassed() async throws {
        let clock = Recorded(Self.now)
        let reset = Self.now.addingTimeInterval(0.05)
        let deadline = reset.addingTimeInterval(1)
        let limited = Self.stop(UsageLimit(resetAt: reset))
        let sync = Self.sync(Recorded([limited]), now: clock, recorder: Recorder())
        try #require(sync.nextCheck == deadline)
        #expect(sync.resetPassedAt == Self.now)
        clock.value = deadline

        await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
            sync.resetPassedAt == deadline && sync.nextCheck == nil
        }
        #expect(sync.resetPassedAt == deadline)
        #expect(sync.nextCheck == nil)
    }

    @Test func request_isNotHeldPastItsTime_beforeTheNextRefresh() {
        let recorder = Recorder()
        let limited = Self.stop(UsageLimit(resetAt: Self.reset))
        let sync = Self.sync(Recorded([limited]), recorder: recorder)
        sync.requestIfOffered(limited, now: Self.now)
        #expect(sync.isNoticeRequested(for: .claude, now: Self.reset.addingTimeInterval(-1)))
        #expect(!sync.isNoticeRequested(for: .claude, now: Self.reset))
    }

    // MARK: - The menu

    @Test func menu_followsTheBar() throws {
        let stopID = Self.stop(nil).id
        let unreadID = AttentionItemID.unread(TurnID("T1"))
        let approvalID = AttentionItemID.approval(ApprovalFact.test().key)
        let request = MenuBarModel.Request(command: "ls", isQuestion: false, offer: .timedOut)
        let cases: [MenuCase] = [
            MenuCase(id: stopID, state: .stopped, notice: .offered, actions: [.notifyAtReset]),
            MenuCase(id: stopID, state: .stopped, notice: .requested, actions: [], note: .resetNoticeRequested),
            MenuCase(id: stopID, state: .stopped, actions: [.resume]),
            MenuCase(id: unreadID, state: .unread, notice: .offered, actions: []),
            MenuCase(id: unreadID, state: .unread, notice: .requested, actions: []),
            MenuCase(id: approvalID, state: .approval, notice: .requested, request: request, actions: [], note: .timedOut)
        ]
        for test in cases {
            let row = NeedsAttentionListModel.Row(
                id: test.id, state: test.state, title: "s", place: nil, fact: "f", placeLead: "", action: nil, arrivedAt: Self.now
            )
            let model = MenuBarModel(
                rows: [row], request: { _ in test.request }, canResume: { _ in true }, resetNotice: { _ in test.notice }
            )
            let item = try #require(model.items.first)
            #expect(item.row == row)
            #expect(item.actions == test.actions)
            #expect(item.note == test.note)
        }
    }

    private struct MenuCase {
        let id: AttentionItemID
        let state: NeedsAttentionListModel.RowState
        var notice: UsageLimitResetNotice?
        var request: MenuBarModel.Request?
        let actions: [MenuBarModel.Action]
        var note: MenuBarModel.Note?
    }
}
