// ApprovalDeadlineTests.swift
// Weir — the time left on held requests, read against the service clock.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ApprovalDeadlineTests {
    private static let receivedAt = SuspendingClock.now

    @Test func aReading_keepsOnlyRequestsStillPendingInTheObservedEpoch() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let gone = ApprovalPresentation.test(epoch: epoch)
        store.receive([held], epoch: epoch)
        let reading = ServiceDeadline(deadlineMs: 10000, serviceNowMs: 0, receivedAt: Self.receivedAt)

        store.applyServiceDeadlines([held.id: reading, gone.id: reading], epoch: epoch)
        #expect(store.serviceDeadlines == [held.id: reading])

        // A reading from a restarted service describes requests we no longer
        // show.
        let foreignReading = ServiceDeadline(
            deadlineMs: 20000, serviceNowMs: 1000, receivedAt: Self.receivedAt.advanced(by: .seconds(1))
        )
        store.applyServiceDeadlines([held.id: foreignReading], epoch: UUID())
        #expect(store.serviceDeadlines == [held.id: reading])
    }

    @Test func aRequestLeavingTheList_dropsItsDeadline() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let remaining = ApprovalPresentation.test(epoch: epoch)
        store.receive([held, remaining], epoch: epoch)
        let reading = ServiceDeadline(deadlineMs: 10000, serviceNowMs: 0, receivedAt: Self.receivedAt)
        store.applyServiceDeadlines([held.id: reading, remaining.id: reading], epoch: epoch)
        #expect(store.serviceDeadlines == [held.id: reading, remaining.id: reading])

        store.receive([remaining], epoch: epoch)

        #expect(store.serviceDeadlines == [remaining.id: reading])
    }

    @Test func eachWakeNotification_readsTheClockAgainAndAppliesIt() async throws {
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let received = SuspendingClock.now
        let first = ServiceDeadline(deadlineMs: 20000, serviceNowMs: 5000, receivedAt: received)
        let second = ServiceDeadline(deadlineMs: 20000, serviceNowMs: 7000, receivedAt: received + .seconds(1))
        let reader = ClockReader([first, second].map {
            ApprovalControllerConnection.ServiceClockReading(epoch: epoch, deadlines: [held.id: $0])
        })
        let store = ApprovalPresentationStore(serviceClockReader: { try await reader.read() })
        let center = NotificationCenter()
        let wake = Notification.Name("test.wake")
        store.receive([held], epoch: epoch)
        store.refreshServiceClock(onEvery: wake, in: center)

        for reading in [first, second] {
            center.post(name: wake, object: nil)
            await pollUntil { store.serviceDeadlines == [held.id: reading] }
            try #require(store.serviceDeadlines == [held.id: reading])
        }
        #expect(await reader.reads == 2)
    }

    @Test func aReadingThatLandsAfterStop_isDropped() async throws {
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let reading = ServiceDeadline(deadlineMs: 20000, serviceNowMs: 5000, receivedAt: SuspendingClock.now)
        let reply = ApprovalControllerConnection.ServiceClockReading(epoch: epoch, deadlines: [held.id: reading])
        let gate = Gate<ApprovalControllerConnection.ServiceClockReading>()
        defer { gate.open(with: reply) }
        let store = ApprovalPresentationStore(serviceClockReader: { await gate.wait() })
        store.receive([held], epoch: epoch)

        let refresh = try #require(store.refreshServiceClock())
        await pollUntil { gate.requests == 1 }
        try #require(gate.requests == 1)
        store.stop()
        // Back in the same epoch, so only the generation check can drop the
        // reading that was in flight across the stop.
        store.receive([held], epoch: epoch)
        gate.open(with: reply)
        await refresh.value

        #expect(gate.requests == 1)
        #expect(store.serviceDeadlines.isEmpty)
    }

    @Test func beforeAnyProjection_refreshStartsNoClockRead() async {
        let reader = ClockReader([ApprovalControllerConnection.ServiceClockReading(epoch: UUID(), deadlines: [:])])
        let store = ApprovalPresentationStore(serviceClockReader: { try await reader.read() })

        #expect(store.refreshServiceClock() == nil, "no read was started")

        #expect(await reader.reads == 0)
    }

    @Test func anOlderReading_doesNotReplaceANewerOne() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let held = ApprovalPresentation.test(epoch: epoch)
        let other = ApprovalPresentation.test(epoch: epoch)
        store.receive([held, other], epoch: epoch)
        let older = ServiceDeadline(deadlineMs: 20000, serviceNowMs: 5000, receivedAt: Self.receivedAt)
        let newer = ServiceDeadline(deadlineMs: 20000, serviceNowMs: 9000, receivedAt: Self.receivedAt.advanced(by: .seconds(4)))

        store.applyServiceDeadlines([held.id: newer, other.id: newer], epoch: epoch)
        // A reading taken before the last one arrives late, and covers only
        // one of the requests.
        store.applyServiceDeadlines([held.id: older], epoch: epoch)

        #expect(store.serviceDeadlines == [held.id: newer, other.id: newer])
    }

    // MARK: - The deadline check

    @Test func aPassedDeadline_timesTheRequestOutAndKeepsThePresentedCard() throws {
        let store = ApprovalPresentationStore()
        let card = TestApprovalCard(store)
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        let passed = ServiceDeadline(deadlineMs: 5000, serviceNowMs: 5000, receivedAt: SuspendingClock.now)

        store.receive([request], epoch: epoch)
        card.present(request)
        try #require(card.isCardOpen)
        try #require(card.presentedApproval?.key == request.key)
        #expect(store.ledger.entry(for: request)?.state == .held)

        store.applyServiceDeadlines([request.id: passed], epoch: epoch)

        #expect(store.ledger.entry(for: request)?.state == .timedOut)
        #expect(card.isCardOpen)
        #expect(card.presentedApproval?.key == request.key)
    }

    @Test func aDeadlineThatPassesLater_timesTheRequestOutThen() async {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        let received = SuspendingClock.now
        let soon = ServiceDeadline(deadlineMs: 6000, serviceNowMs: 5000, receivedAt: received)

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [request], deadlines: [request.id: soon]),
            epoch: epoch,
            now: received
        )
        #expect(store.ledger.entry(for: request)?.state == .held)

        // The deadline's timer fires on the main actor, which a parallel run can
        // stall past a short deadline, so only a timer that never fires should
        // reach this one.
        await pollUntil(timeout: .seconds(30), interval: .milliseconds(10)) { store.ledger.entry(for: request)?.state == .timedOut }
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
    }

    @Test func aRequestWithoutAServiceClock_doesNotTimeOutLocally() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        // Its deadline reading alone would have passed long ago.
        let request = ApprovalPresentation.test(epoch: epoch, deadlineMilliseconds: 0)

        store.apply(ApprovalControllerConnection.Projection.test(pending: [request]), epoch: epoch, now: Self.receivedAt)
        // A minute on, as the deadline check would see it.
        #expect(store.checkDeadlines(now: Self.receivedAt + .seconds(60)) == nil, "nothing to wait for")

        #expect(store.ledger.entry(for: request)?.state == .held)
    }

    @Test func aServiceDeadline_isCheckedAtTheMomentGiven() {
        let store = ApprovalPresentationStore()
        let epoch = UUID()
        let request = ApprovalPresentation.test(epoch: epoch)
        let received = SuspendingClock.now
        let inASecond = ServiceDeadline(deadlineMs: 6000, serviceNowMs: 5000, receivedAt: received)

        store.apply(
            ApprovalControllerConnection.Projection.test(pending: [request], deadlines: [request.id: inASecond]),
            epoch: epoch,
            now: Self.receivedAt
        )
        #expect(store.checkDeadlines(now: received + .milliseconds(500)) == .milliseconds(500))
        #expect(store.ledger.entry(for: request)?.state == .held)

        #expect(store.checkDeadlines(now: received + .seconds(1)) == nil)
        #expect(store.ledger.entry(for: request)?.state == .timedOut)
    }
}

/// Distinct replies for successive injected clock reads.
private actor ClockReader {
    private let readings: [ApprovalControllerConnection.ServiceClockReading]
    private(set) var reads = 0

    init(_ readings: [ApprovalControllerConnection.ServiceClockReading]) {
        self.readings = readings
    }

    func read() throws -> ApprovalControllerConnection.ServiceClockReading {
        let index = reads
        reads += 1
        guard readings.indices.contains(index) else { throw AgentIntegrationError.invalidResponse }
        return readings[index]
    }
}
