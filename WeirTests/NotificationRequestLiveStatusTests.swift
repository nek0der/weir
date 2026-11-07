// NotificationRequestLiveStatusTests.swift
// Weir — a request's history row read from the approval ledger's entry for
// that request: amber while it waits, retired once it is answered or gone.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Notification request live status", .timeLimit(.minutes(1)))
@MainActor
struct NotificationRequestLiveStatusTests {

    // MARK: - Helpers

    /// The row `postRequestBanner` records for `request`: the run's ID and
    /// the request's key, and no event token.
    private func row(
        for request: ApprovalPresentation, isRead: Bool = false, timestamp: Date = Date(), pane: UUID? = nil
    ) -> NotificationEntry {
        NotificationEntry.test(
            kind: .agentNeedsInput,
            timestamp: timestamp,
            paneID: pane,
            title: "Approval",
            body: "Bash",
            isRead: isRead,
            runtimeID: AgentRuntimePresentation.id(kind: .claude, runID: request.runID.uuidString),
            requestKey: request.key,
            event: RequestBannerText.event(for: request)
        )
    }

    /// A store that accepts every decision, as a broker that took it does.
    private func acceptingStore() -> ApprovalPresentationStore {
        ApprovalPresentationStore(decisionSender: { _, _ in })
    }

    /// The mark the history row draws for `entry`.
    private func mark(of entry: NotificationEntry, live: NotificationLiveStatus?) -> NotificationHistoryRowText.Mark {
        NotificationHistoryRowText.mark(
            of: entry,
            happening: NotificationHistoryRowText.happening(of: entry, locale: Locale(identifier: "en")),
            liveStatus: live,
            isSourceClosed: false
        )
    }

    // MARK: - Pure rule

    @Test func ofRequest_waitsExactlyWhileTheAttentionListListsTheRequest() {
        let waiting: [ApprovalRequestState] = [
            .held,
            .sending(.allowOnce, since: .now),
            .sendFailed(.allowOnce, error: "x"),
            .handedToTerminal(since: .now),
            .timedOut,
            .unknownResult
        ]
        for state in waiting {
            #expect(NotificationLiveStatus.ofRequest(state: state, hasReadService: true) == .stillWaiting, "\(state)")
        }
        for state in [ApprovalRequestState.answered(.allowOnce), .withdrawn] {
            #expect(NotificationLiveStatus.ofRequest(state: state, hasReadService: true) == .resolved, "\(state)")
        }
        #expect(NotificationLiveStatus.ofRequest(state: nil, hasReadService: true) == .resolved)
        // Before the first pending list the service may still hold it.
        #expect(NotificationLiveStatus.ofRequest(state: nil, hasReadService: false) == nil)
    }

    // MARK: - From the notification to its ending

    @Test func aSuccessfulDecision_resolvesTheHistoryRow_andTheSyncMarksItRead() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            let waiting = try attention.liveStatus(for: #require(history.entries.first), requests: store.ledger)
            #expect(waiting == .stillWaiting)
            #expect(try mark(of: #require(history.entries.first), live: waiting) == .approval)
            #expect(history.unreadCount == 1)

            store.resolve(request, .allowOnce)
            await store.waitUntilResolved(request)

            let live = try attention.liveStatus(for: #require(history.entries.first), requests: store.ledger)
            #expect(live == .resolved)
            await untilObserved { history.unreadCount == 0 }
            #expect(history.unreadCount == 0, "the ledger's change alone retires the row")
            #expect(try mark(of: #require(history.entries.first), live: live) == .idle)
            history.flushSynchronously()
            _ = sync
        }
    }

    @Test(arguments: [false, true])
    func expired_waitsAtTheAgentsPrompt_untilItsTurnIsOver(stoppedFirst: Bool) throws {
        try withTempDir { (dir: URL) throws in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let (session, pane) = ApprovalEpisodeEndTests.claudePane(.running)
            let request = ApprovalPresentation.test(sessionID: "session")
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.releaseStaleApprovals(in: session)
            if stoppedFirst {
                store.stop()
                #expect(store.ledger.epoch == nil)
                #expect(store.ledger.entry(for: request)?.state == .held)
                try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)
            }

            store.receive([], epoch: request.epoch, terminals: [request.id: .expired])
            store.releaseStaleApprovals(in: session)
            #expect(store.ledger.entry(for: request)?.state == .timedOut)
            sync.reconcile()
            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)

            ApprovalEpisodeEndTests.move(session, pane, to: .finished)
            store.releaseStaleApprovals(in: session)
            #expect(store.ledger.entry(for: request) == nil)
            sync.reconcile()
            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: false)
            history.flushSynchronously()
        }
    }

    private func expectHistory(
        _ history: NotificationHistoryStore, attention: AttentionState, ledger: ApprovalLedger,
        waiting: Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let entry = try #require(history.entries.first, sourceLocation: sourceLocation)
        let live = attention.liveStatus(for: entry, requests: ledger)
        #expect(live == (waiting ? .stillWaiting : .resolved), sourceLocation: sourceLocation)
        #expect(entry.isRead == !waiting, sourceLocation: sourceLocation)
        #expect(history.unreadCount == (waiting ? 1 : 0), sourceLocation: sourceLocation)
        #expect(mark(of: entry, live: live) == (waiting ? .approval : .idle), sourceLocation: sourceLocation)
    }

    @Test func withdrawn_isResolved() throws {
        try withTempDir { (dir: URL) throws in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])

            #expect(store.ledger.entry(for: request)?.state == .withdrawn)
            let resolved = try #require(history.entries.first)
            #expect(attention.liveStatus(for: resolved, requests: store.ledger) == .resolved)
            sync.reconcile()
            #expect(history.unreadCount == 0)
            history.flushSynchronously()
        }
    }

    @Test func markedReadWhilePending_staysAmber() throws {
        try withTempDir { (dir: URL) throws in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))

            history.markAllRead()

            let entry = try #require(history.entries.first)
            #expect(entry.isRead)
            let live = attention.liveStatus(for: entry, requests: store.ledger)
            #expect(live == .stillWaiting)
            #expect(mark(of: entry, live: live) == .approval)
            history.flushSynchronously()
        }
    }

    @Test func twoRequestsOfOneRun_onlyTheAnsweredRowChanges() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let epoch = UUID()
            let runID = UUID()
            let first = ApprovalPresentation.test(epoch: epoch, runID: runID)
            let second = ApprovalPresentation.test(epoch: epoch, runID: runID)
            store.receive([first, second])
            history.record(row(for: first))
            history.record(row(for: second))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.resolve(second, .allowOnce)
            await store.waitUntilResolved(second)
            sync.reconcile()

            let firstRow = try #require(history.entries.first { $0.requestKey == first.key })
            let secondRow = try #require(history.entries.first { $0.requestKey == second.key })
            #expect(attention.liveStatus(for: firstRow, requests: store.ledger) == .stillWaiting)
            #expect(!firstRow.isRead)
            #expect(attention.liveStatus(for: secondRow, requests: store.ledger) == .resolved)
            #expect(secondRow.isRead)
            history.flushSynchronously()
        }
    }

    /// After a launch the history names a request of the last run's
    /// service, which the ledger never held. Nothing may retire it until the
    /// first pending list arrives, and that list alone (an epoch, with no
    /// entry added) has to wake the sync. Stopping the service leaves the
    /// ledger without a pending list again, so the row's status is unknown.
    @Test func aRowTheLedgerNeverHeld_waitsForTheFirstPendingList_thenRetires() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let earlier = ApprovalPresentation.test()
            history.record(row(for: earlier))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            let unread = try #require(history.entries.first)
            #expect(attention.liveStatus(for: unread, requests: store.ledger) == nil)
            #expect(history.unreadCount == 1)

            // The service restarted meanwhile: a new epoch, listing nothing.
            store.receive([], epoch: UUID())
            await untilObserved { history.unreadCount == 0 }
            #expect(history.unreadCount == 0, "the epoch alone wakes the sync")
            let resolved = try #require(history.entries.first)
            #expect(attention.liveStatus(for: resolved, requests: store.ledger) == .resolved)

            store.stop()
            let disconnected = try #require(history.entries.first)
            #expect(attention.liveStatus(for: disconnected, requests: store.ledger) == nil)
            history.flushSynchronously()
            _ = sync
        }
    }

    // MARK: - A readiness drop while the TUI holds the request

    enum Reconnect: CaseIterable {
        case sameEpochAfterStop
        case newEpochWithoutStop
        case newEpochAfterStop
    }

    @Test(arguments: Reconnect.allCases)
    func aDelegatedRequest_staysWaitingAcrossReconnect_untilItsTurnEnds(reconnect: Reconnect) throws {
        try withTempDir { (dir: URL) throws in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let fixture = ApprovalEpisodeEndTests.storeWithEndedRequest(state: .running, terminal: .resolved(.delegate))
            let store = fixture.store
            let request = fixture.request
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            try #require(fixture.isKeptAfterAPass())
            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)

            if reconnect != .newEpochWithoutStop {
                store.stop()
                #expect(store.ledger.epoch == nil)
                try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)
            }
            let epoch = reconnect == .sameEpochAfterStop ? request.epoch : UUID()
            store.receive([], epoch: epoch)
            #expect(store.ledger.epoch == epoch)
            try #require(fixture.isKeptAfterAPass())
            #expect(store.ledger.entry(for: request)?.state == .handedToTerminal(since: ApprovalEpisodeEndTests.now))
            sync.reconcile()
            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)

            fixture.agent(.finished, runStartedAt: nil)
            #expect(!fixture.isKeptAfterAPass())
            sync.reconcile()
            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: false)
            history.flushSynchronously()
        }
    }

    @Test func aHeldRequest_ofAServiceThatRestarted_waitsAtTheAgentsPrompt() throws {
        try withTempDir { (dir: URL) throws in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)

            store.receive([], epoch: UUID())
            sync.reconcile()

            let waiting = try #require(history.entries.first)
            #expect(attention.liveStatus(for: waiting, requests: store.ledger) == .stillWaiting)
            #expect(history.unreadCount == 1)
            #expect(store.approvalForCard(request.id) == nil, "the new broker would refuse its buttons")
            history.flushSynchronously()
        }
    }

    @Test func twoRequestsOfOneRun_acrossAReadinessDrop_eachKeepsItsOwnReading() async throws {
        try await withTempDir { dir in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let epoch = UUID()
            let runID = UUID()
            let delegated = ApprovalPresentation.test(epoch: epoch, runID: runID)
            let held = ApprovalPresentation.test(epoch: epoch, runID: runID)
            store.receive([delegated, held])
            history.record(row(for: delegated))
            history.record(row(for: held))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.receive([held], epoch: epoch, terminals: [delegated.id: .resolved(.delegate)])

            store.stop()
            store.receive([held], epoch: epoch)
            store.resolve(held, .allowOnce)
            await store.waitUntilResolved(held)
            sync.reconcile()

            let delegatedRow = try #require(history.entries.first { $0.requestKey == delegated.key })
            let heldRow = try #require(history.entries.first { $0.requestKey == held.key })
            #expect(attention.liveStatus(for: delegatedRow, requests: store.ledger) == .stillWaiting)
            #expect(!delegatedRow.isRead)
            #expect(attention.liveStatus(for: heldRow, requests: store.ledger) == .resolved)
            #expect(heldRow.isRead)
            history.flushSynchronously()
        }
    }

    @Test func aDroppedSubscription_stillKeepsADelegatedRowWaiting() throws {
        try withTempDir { (dir: URL) throws in
            let history = NotificationHistoryStore(directory: dir)
            let attention = AttentionState()
            let store = acceptingStore()
            let request = ApprovalPresentation.test()
            store.receive([request])
            history.record(row(for: request))
            let sync = NotificationReadSync(historyStore: history, attention: attention, requests: store.ledger)
            store.receive([], epoch: request.epoch, terminals: [request.id: .resolved(.delegate)])

            store.connectionDidDrop()
            #expect(store.ledger.epoch == request.epoch)
            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)
            store.receive([], epoch: request.epoch)
            sync.reconcile()

            try expectHistory(history, attention: attention, ledger: store.ledger, waiting: true)
            history.flushSynchronously()
        }
    }

    @Test func historyList_keepsAReadRequestVisibleWhileTheLedgerWaits() throws {
        let attention = AttentionState()
        let store = acceptingStore()
        let request = ApprovalPresentation.test()
        let other = (0..<3).map { _ in ApprovalPresentation.test(epoch: request.epoch) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pane = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let entry = row(for: request, isRead: true, timestamp: now.addingTimeInterval(-10), pane: pane)
        let newer = other.enumerated().map { index, request in
            row(for: request, isRead: true, timestamp: now.addingTimeInterval(Double(index) - 5), pane: pane)
        }
        store.receive([request] + other)
        let terminals = Dictionary(uniqueKeysWithValues: other.map { ($0.id, BrokerTerminal.canceled) })
        store.receive([request], epoch: request.epoch, terminals: terminals)
        let lookup = attention.liveStatusLookup(requests: store.ledger)
        func list(expanded: Set<NotificationHistoryList.SourceID> = []) -> NotificationHistoryList {
            NotificationHistoryList(
                entries: [entry] + newer, now: now, calendar: calendar,
                expanded: expanded, liveStatus: lookup, canOpen: { _ in true }, place: { _ in nil },
                projectsInOtherWindows: []
            )
        }

        let waiting = list()
        try #require(waiting.sources.count == 1)
        let waitingSource = try #require(waiting.sources.first)
        let visible = try #require(waitingSource.shown.first { $0.entry.id == entry.id })
        #expect(visible.liveStatus == .stillWaiting)
        #expect(mark(of: visible.entry, live: visible.liveStatus) == .approval)
        #expect(waitingSource.foldableCount == 1)

        store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])

        let settled = try #require(list().sources.first)
        #expect(settled.shown.map(\.entry.id) == newer.reversed().map(\.id))
        #expect(settled.foldableCount == 1)
        let expanded = try #require(list(expanded: [settled.id]).sources.first)
        let resolved = try #require(expanded.shown.first { $0.entry.id == entry.id })
        #expect(resolved.liveStatus == .resolved)
        #expect(mark(of: resolved.entry, live: resolved.liveStatus) == .idle)
    }
}
