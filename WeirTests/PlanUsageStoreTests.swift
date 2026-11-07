// PlanUsageStoreTests.swift
// Weir — the store behind the usage panel: Claude Code's record as it changes, and Codex's reads.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A Codex usage the tests hand out.
private let codexUsage = PlanUsage(
    windows: [PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 90, resetsAt: nil)],
    observedAt: Date(timeIntervalSince1970: 0)
)

@MainActor
@Suite("Plan usage store")
struct PlanUsageStoreTests {
    @Test("reads Claude Code's record at the start and again when it changes")
    func start_readsAndFollowsTheRecord() async {
        let records = FakeRecords()
        let otherUsage = PlanUsage(windows: [], observedAt: Date(timeIntervalSince1970: 1))
        records.claude = codexUsage
        records.antigravity = otherUsage
        let store = PlanUsageStore(records: records, codexReader: FakeCodex([]))
        store.start()
        #expect(store.claude == codexUsage)
        #expect(store.antigravity == otherUsage)
        #expect(records.reads == [.claude, .antigravity])
        #expect(records.watchCount == 1)

        records.claude = nil
        records.antigravity = codexUsage
        records.change()
        #expect(store.claude == nil)
        #expect(store.antigravity == codexUsage)
        #expect(store.level(at: Date(timeIntervalSince1970: 2)) == .nearLimit)
        await pollUntil { store.codex == .read(.failed) }
        #expect(store.codex == .read(.failed))
    }

    @Test("asks Codex once at the start, before any panel opens")
    func start_asksCodexOnce() async {
        let reader = FakeCodex([.usage(codexUsage)])
        let store = PlanUsageStore(records: FakeRecords(), codexReader: reader)
        store.start()
        await pollUntil { store.codex == .read(.usage(codexUsage)) }
        #expect(store.lastCodexUsage == codexUsage)
        #expect(store.codex == .read(.usage(codexUsage)))
        #expect(await reader.calls == 1)
    }

    @Test("keeps Codex's last usage through a read that failed")
    func refreshCodex_keepsTheLastUsageThroughAFailure() async {
        let store = PlanUsageStore(records: FakeRecords(), codexReader: FakeCodex([.usage(codexUsage), .failed]))
        await store.refreshCodex()
        #expect(store.codex == .read(.usage(codexUsage)))
        await store.refreshCodex()
        #expect(store.codex == .read(.failed))
        #expect(store.lastCodexUsage == codexUsage)
        #expect(store.level(at: Date()) == .nearLimit)
    }

    @Test("drops Codex's last usage when there is no plan or installation", arguments: [CodexUsageOutcome.noPlan, .notInstalled])
    func refreshCodex_noPlan_dropsTheLastUsage(outcome: CodexUsageOutcome) async throws {
        let store = PlanUsageStore(records: FakeRecords(), codexReader: FakeCodex([.usage(codexUsage), outcome]))
        await store.refreshCodex()
        try #require(store.lastCodexUsage == codexUsage)
        await store.refreshCodex()
        #expect(store.codex == .read(outcome))
        #expect(store.lastCodexUsage == nil)
        #expect(store.level(at: Date()) == .normal)
    }

    /// The panel closing cancels a read under way; it says nothing about
    /// Codex, so what was shown before stays.
    @Test("keeps what it showed when a read is cut short")
    func refreshCodex_canceled_keepsWhatItShowed() async throws {
        let gate = Gate<CodexUsageOutcome>()
        let codex = FakeCodex([.usage(codexUsage)], thenWaits: gate)
        let store = PlanUsageStore(records: FakeRecords(), codexReader: codex)
        await store.refreshCodex()
        try #require(store.lastCodexUsage == codexUsage)
        let read = Task { await store.refreshCodex() }
        defer {
            read.cancel()
            gate.open(with: .noPlan)
        }
        try await gate.waitUntilRequested()
        try #require(store.codex == .reading)
        read.cancel()
        gate.open(with: .noPlan)
        await read.value
        #expect(store.codex == .read(.usage(codexUsage)))
        #expect(store.lastCodexUsage == codexUsage)
        #expect(store.level(at: Date(timeIntervalSince1970: 2)) == .nearLimit)
        #expect(await codex.calls == 2)
    }

    @Test("reads nothing when it may not show the person's usage")
    func demoMode_readsNothing() async {
        let records = FakeRecords()
        records.claude = codexUsage
        records.antigravity = codexUsage
        let reader = FakeCodex([.usage(codexUsage)])
        let store = PlanUsageStore(records: records, codexReader: reader, readsUsage: false)
        store.start()
        await store.refreshCodex()
        #expect(store.claude == nil)
        #expect(store.antigravity == nil)
        #expect(records.reads.isEmpty)
        #expect(records.watchCount == 0)
        #expect(await reader.calls == 0)
        #expect(store.codex == .unread)
        #expect(store.level(at: Date()) == .normal)
    }
}

/// Records handed out by hand, with the change signal sent by the test.
@MainActor
private final class FakeRecords: PlanUsageRecordSource {
    var claude: PlanUsage?
    var antigravity: PlanUsage?
    private(set) var reads: [AgentKind] = []
    private(set) var watchCount = 0
    private var onChange: (@MainActor () -> Void)?

    func record(for agent: AgentKind) -> PlanUsage? {
        reads.append(agent)
        return agent == .claude ? claude : antigravity
    }

    func watch(_ onChange: @escaping @MainActor () -> Void) {
        watchCount += 1
        self.onChange = onChange
    }

    func change() {
        onChange?()
    }
}

/// Codex's outcomes in the order a test hands them out. Past them it
/// answers `failed`, or waits at the gate until the test releases a result.
private actor FakeCodex: CodexUsageReading {
    private var outcomes: [CodexUsageOutcome]
    private let thenWaits: Gate<CodexUsageOutcome>?
    private(set) var calls = 0

    init(_ outcomes: [CodexUsageOutcome], thenWaits: Gate<CodexUsageOutcome>? = nil) {
        self.outcomes = outcomes
        self.thenWaits = thenWaits
    }

    func read() async -> CodexUsageOutcome {
        calls += 1
        guard outcomes.isEmpty else { return outcomes.removeFirst() }
        if let thenWaits {
            return await thenWaits.wait()
        }
        return .failed
    }
}
