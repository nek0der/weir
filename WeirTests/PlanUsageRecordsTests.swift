// PlanUsageRecordsTests.swift
// Weir — the usage directory the status line relay writes into: reading a record, and noticing a new one.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Plan usage records")
struct PlanUsageRecordsTests {
    @Test("reads an agent's record from the usage directory, and nothing before one")
    func record_readsTheFile() throws {
        try withTempDir { dir in
            let records = PlanUsageRecordDirectory(directory: dir)
            #expect(records.record(for: .claude) == nil)
            let record = #"{"windows":[{"kind":"five_hour","usedPercent":81}],"observedAt":"2026-10-29T02:13:20Z"}"#
            let file = dir.appendingPathComponent("claude.json")
            try Data(record.utf8).write(to: file)
            let usage = try #require(records.record(for: .claude))
            #expect(usage.windows.map(\.kind) == ["five_hour"])
            #expect(usage.windows.map(\.usedPercent) == [81])
            #expect(usage.observedAt == Date(timeIntervalSince1970: 1_793_240_000))
            #expect(records.record(for: .codex) == nil)
            try Data("not json".utf8).write(to: file)
            #expect(records.record(for: .claude) == nil)
        }
    }

    /// The relay writes through a temporary file and a rename, which is
    /// what the directory watch has to catch.
    @Test("says so when a record is written by rename")
    func watch_seesARenamedRecord() async throws {
        try await withTempDir { dir in
            let records = PlanUsageRecordDirectory(directory: dir)
            var reportedDate: Date?
            records.watch { [weak records] in reportedDate = records?.record(for: .claude)?.observedAt }
            let record = #"{"windows":[],"observedAt":"2026-10-29T02:13:20Z"}"#
            try Data(record.utf8).write(to: dir.appendingPathComponent("claude.json"), options: .atomic)
            // The event and the debounce after it both wait on the main actor,
            // which a parallel run can stall past a short deadline, so only a
            // change never reported should reach this one.
            await pollUntil(timeout: .seconds(30), interval: .milliseconds(20)) { reportedDate != nil }
            #expect(reportedDate == Date(timeIntervalSince1970: 1_793_240_000))
        }
    }
}
