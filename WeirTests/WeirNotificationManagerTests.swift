// WeirNotificationManagerTests.swift
// Weir — the rate limiter's window and the wake hold's observation.

import Foundation
import Testing
import UserNotifications
@testable import Weir

@MainActor
struct WeirNotificationManagerTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)
    private static let wake = Notification.Name("WeirNotificationManagerTests.wake")

    @MainActor
    private final class Banners {
        var posted: [UNNotificationRequest] = []
    }

    private func manager(_ history: NotificationHistoryStore, banners: Banners) -> WeirNotificationManager {
        WeirNotificationManager(
            historyStore: history,
            appLocale: { Locale(identifier: "en") },
            bannerPoster: { banners.posted.append($0) }
        )
    }

    private func sendAgentBanner(_ manager: WeirNotificationManager) {
        manager.send(title: "Claude", body: "finished", paneID: UUID(), kind: .agentFinished)
    }

    @Test func allow_dropsEveryKeyWhoseWindowHasEmptied() {
        var now = ContinuousClock.now
        var limiter = RateLimiter(maxPerSecond: 5, clock: { now })
        _ = limiter.allow(key: UUID())
        _ = limiter.allow(key: UUID())
        #expect(limiter.trackedKeyCount == 2)

        // Neither of the first keys is asked about again; their entries go
        // when any key is asked about after their window.
        now += .seconds(2)
        _ = limiter.allow(key: UUID())
        #expect(limiter.trackedKeyCount == 1)
    }

    @Test func allow_refusesBeyondTheLimitWithinASecond() {
        let start = ContinuousClock.now
        var now = start
        var limiter = RateLimiter(maxPerSecond: 2, clock: { now })
        let key = UUID()
        var answers = [limiter.allow(key: key)]
        now = start + .milliseconds(100)
        answers.append(limiter.allow(key: key))
        now = start + .milliseconds(200)
        answers.append(limiter.allow(key: key))
        answers.append(limiter.allow(key: UUID()))
        // The first event leaves exactly one second after it arrived.
        now = start + .seconds(1)
        answers.append(limiter.allow(key: key))
        now = start + .milliseconds(1050)
        answers.append(limiter.allow(key: key))
        #expect(answers == [true, true, false, true, true, false])
    }

    @Test(arguments: [-3600.0, 3600.0])
    func allow_usesElapsedTimeAcrossWallClockChanges(jump: TimeInterval) {
        let clock = ManualPRStatusClock(start: Self.start)
        var limiter = RateLimiter(maxPerSecond: 1, clock: { clock.monotonicNow() })
        let key = UUID()
        let first = limiter.allow(key: key)
        #expect(first)

        clock.changeWallClock(by: jump)
        #expect(clock.now() == Self.start.addingTimeInterval(jump))
        let duringWindow = limiter.allow(key: key)
        #expect(!duringWindow)
        clock.advance(by: 1)
        let afterWindow = limiter.allow(key: key)
        #expect(afterWindow)
    }

    @Test func theObservedNotification_holdsTheAgentsBanners() throws {
        try withTempDir { root in
            let banners = Banners()
            let history = NotificationHistoryStore(directory: root, writesFiles: false)
            let manager = manager(history, banners: banners)
            let center = NotificationCenter()
            manager.holdAgentBanners(onEvery: Self.wake, in: center, for: .seconds(60)) { nil }

            sendAgentBanner(manager)
            #expect(banners.posted.count == 1)

            center.post(name: Self.wake, object: nil)
            sendAgentBanner(manager)
            #expect(banners.posted.map(\.content.title) == ["Claude"])
            #expect(history.entries.map(\.kind) == [.agentFinished, .agentFinished])

            manager.send(title: "Build", body: "Finished", paneID: UUID(), kind: .desktop)
            #expect(banners.posted.map(\.content.title) == ["Claude", "Build"])
        }
    }

    @Test func theObservation_doesNotKeepTheManagerAlive() throws {
        try withTempDir { root in
            let center = NotificationCenter()
            weak var released: WeirNotificationManager?
            do {
                let manager = manager(NotificationHistoryStore(directory: root), banners: Banners())
                manager.holdAgentBanners(onEvery: Self.wake, in: center, for: .seconds(60)) { nil }
                released = manager
            }
            #expect(released == nil)
            // The observer went with the manager, so a later post reaches
            // nothing.
            center.post(name: Self.wake, object: nil)
        }
    }
}
