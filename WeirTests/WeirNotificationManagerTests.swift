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
        var limiter = RateLimiter(maxPerSecond: 5)
        _ = limiter.allow(key: UUID(), now: Self.start)
        _ = limiter.allow(key: UUID(), now: Self.start)
        #expect(limiter.trackedKeyCount == 2)

        // Neither of the first keys is asked about again; their entries go
        // when any key is asked about after their window.
        _ = limiter.allow(key: UUID(), now: Self.start.addingTimeInterval(2))
        #expect(limiter.trackedKeyCount == 1)
    }

    @Test func allow_refusesBeyondTheLimitWithinASecond() {
        var limiter = RateLimiter(maxPerSecond: 2)
        let key = UUID()
        let answers = [
            limiter.allow(key: key, now: Self.start),
            limiter.allow(key: key, now: Self.start.addingTimeInterval(0.1)),
            limiter.allow(key: key, now: Self.start.addingTimeInterval(0.2)),
            // Another key has a window of its own.
            limiter.allow(key: UUID(), now: Self.start.addingTimeInterval(0.2)),
            // The first event leaves exactly one second after it arrived.
            limiter.allow(key: key, now: Self.start.addingTimeInterval(1)),
            limiter.allow(key: key, now: Self.start.addingTimeInterval(1.05))
        ]
        #expect(answers == [true, true, false, true, true, false])
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
