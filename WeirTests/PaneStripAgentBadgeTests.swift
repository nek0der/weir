// PaneStripAgentBadgeTests.swift
// Weir — a pane strip tab wears the badge of the agent whose run record places it in the tab.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// The badge and pane state from staged launches and records read by
/// the real Swift/Rust projection adapter.
@MainActor
@Suite("PaneStripAgentBadge")
struct PaneStripAgentBadgeTests {
    @MainActor
    private struct Projection {
        let state: URL
        let session: WorkspaceSession
        let container: ContainerID
        let adapter: AgentProjectionAdapter
        let attention = AttentionState()

        @discardableResult
        func write(_ record: String, stem: String) throws -> URL {
            let file = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(stem))
            try Data(record.utf8).write(to: file)
            return file
        }

        func bootstrap() {
            adapter.bootstrap(into: session, attention: attention)
        }

        func strip() -> PaneStripModel {
            #expect(adapter.lastFailure == nil)
            return PaneStripModel(
                container: container,
                session: session,
                window: session.primaryWindowID,
                queue: AttentionQueue(),
                runtimes: attention.allRuntimes,
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            )
        }
    }

    private func withProjection(
        provider: String,
        session: WorkspaceSession,
        container: ContainerID = .loose,
        isAlive: Bool = true,
        _ test: (Projection) throws -> Void
    ) throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let adapter = ProjectionFixture.adapter(
                provider: provider,
                state: state,
                sessions: sessions,
                processStatus: { _ in isAlive ? .alive : .dead }
            )
            try test(Projection(state: state, session: session, container: container, adapter: adapter))
        }
    }

    /// A record of the Rust projection corpus, which the real hook runtime
    /// wrote from recorded hook payloads (`rust/fixtures/projection`), moved
    /// to `pane`.
    private func corpusRecord(_ scenario: String, directory: String, stem: String, pane: UUID) throws -> String {
        let root = try #require(RepoFixture.weirRoot)
        let url = root.appendingPathComponent("rust/fixtures/projection/\(scenario)/\(directory)/\(stem).state.json")
        let content = try String(contentsOf: url, encoding: .utf8)
        let corpusPane = "11111111-1111-4111-8111-111111111111"
        try #require(content.contains(corpusPane))
        let moved = content.replacingOccurrences(of: corpusPane, with: pane.uuidString)
        let record = try #require(JSONSerialization.jsonObject(with: Data(moved.utf8)) as? [String: Any])
        #expect(record["paneId"] as? String == pane.uuidString)
        #expect(record["runId"] as? String == stem)
        return moved
    }

    /// A record as a restore at launch leaves it for the resume it types
    /// (`session_lifecycle::restore`): state unknown, pid cleared, the
    /// attempt stamped.
    private static func restoredRecord(run: String, pane: UUID, lastHookEvent: String) -> String {
        """
        {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":8,\
        "stateEpisodeToken":"8","state":"unknown","runStartedAt":null,"updatedAt":"2026-10-19T14:29:36Z",\
        "lastHookEvent":"\(lastHookEvent)","hasPrompt":true,"resumeAttemptedAt":"2026-10-20T06:30:01Z",\
        "sessionId":"01a15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-19T14:29:08Z"}
        """
    }

    // MARK: - An agent typed into a shell

    @Test(.disabled(if: !RepoFixture.hasLocalRepo), arguments: [
        (AgentKind.claude, "claude-turn", "agent-states", "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"),
        (.codex, "codex-turn", "codex-agent-states", "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2")
    ])
    func aCorpusRunInAShell_projectsItsProviderBadge(agent: AgentKind, scenario: String, directory: String, stem: String) throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let record = try corpusRecord(scenario, directory: directory, stem: stem, pane: pane)
        try withProjection(provider: agent.rawValue, session: session) { projection in
            try projection.write(record, stem: stem)
            projection.bootstrap()

            let strip = projection.strip()
            #expect(strip.items.map(\.id) == [tab.id])
            let item = try #require(strip.item(for: tab))
            #expect(item.agents.map(\.kind) == [agent])
            #expect(item.agents.first?.state == nil)
            #expect(item.stateGlyph == nil)
            let header = try #require(projection.attention.headerRuntime(inPane: pane))
            #expect(header.kind == agent)
            #expect(header.badge.state == .finished)
        }
    }

    // MARK: - An agent started from "+"

    @Test(arguments: [AgentKind.claude, .codex])
    func anAgentTab_keepsItsStagedBadge_afterAnIdleRecordArrives(agent: AgentKind) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let container = ContainerID.project(project.id)
        TabActions.newTab(session, in: container, running: agent)
        let tab = try #require(session.activeTab(in: session.primaryWindowID))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let run = UUID().uuidString
        // As the hook helper writes it on the agent's SessionStart.
        let record = """
        {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":1,\
        "stateEpisodeToken":"1","state":"idle","runStartedAt":null,"updatedAt":"2026-10-20T06:32:38Z",\
        "lastHookEvent":"session_started","hasPrompt":false,"pid":"4242",\
        "sessionId":"0aa15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-20T06:32:38Z"}
        """
        try withProjection(provider: agent.rawValue, session: session, container: container) { projection in
            projection.bootstrap()
            let starting = try #require(projection.strip().item(for: tab))
            #expect(starting.agents.map(\.kind) == [agent])
            #expect(starting.stateGlyph == nil)
            #expect(projection.attention.headerRuntime(inPane: pane) == nil)

            try projection.write(record, stem: run)
            projection.adapter.refresh()

            let strip = projection.strip()
            #expect(strip.items.map(\.id) == [tab.id])
            let reported = try #require(strip.item(for: tab))
            #expect(reported.agents.map(\.kind) == [agent])
            #expect(reported.stateGlyph == nil)
            let header = try #require(projection.attention.headerRuntime(inPane: pane))
            #expect(header.kind == agent)
            #expect(header.badge.state == .idle)
        }
    }

    // MARK: - An agent a restore typed again

    /// Codex's record as its turn ended, Claude's as its session did.
    @Test(arguments: [
        (AgentKind.codex, "1E9FFA50-B32F-46C4-BCED-C789AFACE803", "turn_finished"),
        (.claude, "DB8B0962-528F-4FE5-8561-6B75586C8DD5", "session_ended")
    ])
    func aRestoredRun_wearsItsAgentsBadge_beforeItsFirstHook(agent: AgentKind, run: String, lastHookEvent: String) throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: lastHookEvent)
        try withProjection(provider: agent.rawValue, session: session) { projection in
            try projection.write(record, stem: run)
            projection.bootstrap()
            let item = try #require(projection.strip().item(for: tab))
            #expect(projection.attention.allRuntimes.contains { $0.paneIDs.contains(pane) && $0.kind == agent })
            #expect(item.agents.map(\.kind) == [agent])
            #expect(item.stateGlyph == nil, "an unknown state shows no glyph on the badge")
        }
    }

    /// What Codex reports as it comes back at its prompt, after `restoredRecord`'s attempt.
    private static func codexIdle(in pane: UUID, at: String = "2026-10-20T06:30:05Z") -> [String: AgentProjectionProgramStatus] {
        [pane.uuidString: AgentProjectionProgramStatus(app: "codex", state: "idle", kind: nil, observedAt: at, stateSince: at)]
    }

    private static let restoredConversation = ConversationKey(
        provider: .codex, conversationID: "01a15490-ade7-7223-a767-7eb22b5c69e1", isFallback: false
    )

    private static func conversations(in projection: Projection) -> ConversationTabs {
        ConversationTabs(tabs: projection.session.tabs, runtimes: projection.attention.allRuntimes)
    }

    @Test func aFreshReportPlacesTheRestoredConversationInItsPane() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "1E9FFA50-B32F-46C4-BCED-C789AFACE803"
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: "turn_finished")
        try withProjection(provider: "codex", session: session) { projection in
            try projection.write(record, stem: run)
            projection.bootstrap()
            #expect(projection.adapter.lastFailure == nil)

            #expect(projection.attention.headerRuntime(inPane: pane) == nil)
            #expect(Self.conversations(in: projection).place(of: Self.restoredConversation) == nil)

            projection.adapter.programStatus = { Self.codexIdle(in: pane, at: "2026-10-20T06:29:59Z") }
            projection.adapter.refresh()
            #expect(projection.adapter.lastFailure == nil)
            #expect(projection.attention.headerRuntime(inPane: pane) == nil)
            #expect(Self.conversations(in: projection).place(of: Self.restoredConversation) == nil)

            projection.adapter.programStatus = { Self.codexIdle(in: pane) }
            projection.adapter.refresh()
            #expect(projection.adapter.lastFailure == nil)
            let header = try #require(projection.attention.headerRuntime(inPane: pane))
            #expect(header.badge.state == .idle)
            #expect(header.conversation == Self.restoredConversation)
            let tabs = Self.conversations(in: projection)
            #expect(tabs.place(of: Self.restoredConversation) == .init(tabID: tab.id, position: 1, paneID: pane))
            #expect(tabs.conversations(of: tab.id)?.titled == Self.restoredConversation)
        }
    }

    /// A SessionEnd after the restore attempt invalidates the conversation
    /// even with the agent's idle report still standing.
    @Test func sessionEndClearsTheRestoredConversationDespiteTheIdleReport() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "1E9FFA50-B32F-46C4-BCED-C789AFACE803"
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: "turn_finished")
        let ended = AgentStateRecordFixture(
            runId: run, revision: 9, stateEpisodeToken: "9", paneId: pane.uuidString,
            state: "unknown", updatedAt: "2026-10-20T06:30:06Z", lastHookEvent: "session_ended",
            pid: "4242", sessionId: "01a15490-ade7-7223-a767-7eb22b5c69e1",
            resumeAttemptedAt: "2026-10-20T06:30:01Z"
        )
        let payload = try JSONEncoder().encode(ended)
        try withProjection(provider: "codex", session: session) { projection in
            let path = try projection.write(record, stem: run)
            projection.adapter.programStatus = { Self.codexIdle(in: pane) }
            projection.bootstrap()

            let before = try #require(projection.attention.headerRuntime(inPane: pane))
            #expect(before.conversation == Self.restoredConversation)
            #expect(Self.conversations(in: projection).place(of: Self.restoredConversation)?.tabID == tab.id)

            try payload.write(to: path)
            projection.adapter.refresh()
            #expect(projection.adapter.lastFailure == nil)
            #expect(projection.attention.headerRuntime(inPane: pane) == nil)
            let tabs = Self.conversations(in: projection)
            #expect(tabs.place(of: Self.restoredConversation) == nil)
            #expect(tabs.conversations(of: tab.id) == .init(titled: nil, all: []))
        }
    }

    @Test func shellReturnClearsTheRestoredBadgeAndKeepsTheRecord() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "1E9FFA50-B32F-46C4-BCED-C789AFACE803"
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: "turn_finished")
        try withProjection(provider: "codex", session: session) { projection in
            let path = try projection.write(record, stem: run)
            projection.bootstrap()
            let before = try #require(projection.strip().item(for: tab))
            #expect(before.agents.map(\.kind) == [.codex])
            #expect(before.stateGlyph == nil)
            #expect(projection.attention.headerRuntime(inPane: pane) == nil)

            projection.adapter.panesBackAtShell = { [pane] }
            projection.adapter.refresh()
            let after = try #require(projection.strip().item(for: tab))
            #expect(after.agents.isEmpty)
            #expect(after.stateGlyph == nil)
            #expect(projection.attention.headerRuntime(inPane: pane) == nil)
            #expect(try Data(contentsOf: path) == Data(record.utf8))
        }
    }

    // MARK: - A tab reopened

    /// A closed tab comes back under new pane ids, and `codex resume` runs no
    /// hook before its first prompt. The run retired when the tab closed
    /// comes back for the new pane: the agent's report makes the pane the
    /// conversation's, and the hint lets a relaunch resume it.
    @Test(arguments: [false, true], [false, true])
    func aReopenedTabsRun_comesBackForItsNewPane(hasRunID: Bool, isRetired: Bool) throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let oldPane = UUID()
        let run = hasRunID ? "1E9FFA50-B32F-46C4-BCED-C789AFACE803" : nil
        let sessionID = "01a15490-ade7-7223-a767-7eb22b5c69e1"
        var closed = tab
        closed.agentSessions[.codex] = [oldPane: AgentSessionInfo(sessionId: sessionID, cwd: "/tmp/repo")]
        closed.agentResumeCandidates[oldPane] = [.codex]

        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let retired = state.appendingPathComponent("retired", isDirectory: true)
            for directory in [state, sessions, retired] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let record = AgentStateRecordFixture(
                schemaVersion: hasRunID ? 3 : 2, runId: run, revision: hasRunID ? 3 : nil,
                stateEpisodeToken: hasRunID ? "3" : nil, paneId: oldPane.uuidString,
                state: "finished", updatedAt: "2026-10-20T06:40:00Z", lastHookEvent: "turn_finished",
                pid: "4242", sessionId: sessionID
            )
            let sourceStem = isRetired ? "\(record.storageID).1793000000.\(UUID().uuidString)" : record.storageID
            let source = try (isRetired ? retired : state)
                .appendingPathComponent(AgentRecordFixtures.recordFileName(sourceStem))
            try JSONEncoder().encode(record).write(to: source)
            let target = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(run ?? pane.uuidString))

            let adapter = ProjectionFixture.adapter(provider: "codex", state: state, sessions: sessions, processStatus: { _ in .dead })
            adapter.reviveRuns(of: closed, paneIDs: [oldPane: pane])
            #expect(FileManager.default.fileExists(atPath: target.path))
            if source != target {
                #expect(!FileManager.default.fileExists(atPath: source.path))
            }
            let records = AgentRecordFixtures.records(in: state)
            #expect(records.count == 1)
            #expect(records.first?.schemaVersion == record.schemaVersion)
            #expect(records.first?.runId == run)
            #expect(records.first?.paneId == pane.uuidString)
            #expect(records.first?.state == "unknown")
            #expect(records.first?.pid == nil)
            #expect(records.first?.resumeAttemptedAt != nil)

            let hint = try #require(AgentRecordFixtures.hint(forPaneID: pane, in: sessions))
            #expect(hint.schemaVersion == 1)
            #expect(hint.paneId == pane.uuidString)
            #expect(hint.sessionId == sessionID)
            #expect(hint.cwd == "/tmp/repo")
            #expect(hint.runId == run)
            #expect(hint.lastHookEvent == "session_started")
            #expect(hint.updatedAt == records.first?.resumeAttemptedAt)

            let at = AgentDateParsing.formatISO8601(Date().addingTimeInterval(5))
            adapter.programStatus = {
                [pane.uuidString: AgentProjectionProgramStatus(app: "codex", state: "idle", kind: nil, observedAt: at, stateSince: at)]
            }
            let attention = AttentionState()
            adapter.bootstrap(into: session, attention: attention)
            #expect(adapter.lastFailure == nil)
            let header = try #require(attention.headerRuntime(inPane: pane))
            #expect(header.badge.state == .idle)
            #expect(header.conversation == ConversationKey(provider: .codex, conversationID: sessionID, isFallback: false))
            #expect(session.tab(tab.id)?.agentSessions[.codex]?[pane]?.sessionId == sessionID)
            #expect(session.tab(tab.id)?.agentResumeCandidates[pane]?.contains(.codex) == true)
        }
    }

    @Test(arguments: [false, true])
    func aReopenedTab_keepsAnOccupiedRecordDestination(hasRunID: Bool) throws {
        let (_, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let oldPane = UUID()
        let run = hasRunID ? UUID().uuidString : nil
        var closed = tab
        closed.agentSessions[.codex] = [oldPane: AgentSessionInfo(sessionId: "old", cwd: "/tmp/repo")]
        closed.agentResumeCandidates[oldPane] = [.codex]

        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let retired = state.appendingPathComponent("retired", isDirectory: true)
            for directory in [state, sessions, retired] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let record = AgentStateRecordFixture(
                runId: run, paneId: oldPane.uuidString, state: "finished", updatedAt: "2026-10-20T06:40:00Z", sessionId: "old"
            )
            let source = try retired.appendingPathComponent(
                AgentRecordFixtures.recordFileName("\(record.storageID).1793000000.\(UUID().uuidString)")
            )
            let original = try JSONEncoder().encode(record)
            try original.write(to: source)

            let occupied = AgentStateRecordFixture(
                runId: run, paneId: pane.uuidString, state: "running", updatedAt: "2026-10-20T06:41:00Z", sessionId: "other"
            )
            let destination = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(occupied.storageID))
            let existing = try JSONEncoder().encode(occupied)
            try existing.write(to: destination)

            let adapter = ProjectionFixture.adapter(provider: "codex", state: state, sessions: sessions)
            adapter.reviveRuns(of: closed, paneIDs: [oldPane: pane])

            #expect((try? Data(contentsOf: destination)) == existing)
            #expect((try? Data(contentsOf: source)) == original)
            #expect(AgentRecordFixtures.records(in: state) == [occupied])
            #expect(AgentRecordFixtures.hint(forPaneID: pane, in: sessions) == nil)
        }
    }

    /// Either the missing resume intent or the missing matching record
    /// independently prevents revival.
    @Test(arguments: [false, true])
    func reopeningRequiresBothAResumeCandidateAndAMatchingRecord(hasCandidate: Bool) throws {
        let (_, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let oldPane = UUID()
        let conversation = "01a15490-ade7-7223-a767-7eb22b5c69e1"
        var closed = tab
        closed.agentSessions[.codex] = [oldPane: AgentSessionInfo(sessionId: conversation, cwd: nil)]
        if hasCandidate {
            closed.agentResumeCandidates[oldPane] = [.codex]
        }
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let nearby = AgentStateRecordFixture(
                runId: UUID().uuidString, paneId: oldPane.uuidString, state: "finished",
                updatedAt: "2026-10-20T06:40:00Z", sessionId: hasCandidate ? "other" : conversation
            )
            let file = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(nearby.storageID))
            let bytes = try JSONEncoder().encode(nearby)
            try bytes.write(to: file)

            let adapter = ProjectionFixture.adapter(provider: "codex", state: state, sessions: sessions)
            adapter.reviveRuns(of: closed, paneIDs: [oldPane: pane])

            #expect(AgentRecordFixtures.records(in: state) == [nearby])
            let names = try FileManager.default.contentsOfDirectory(atPath: state.path)
            #expect(names.filter { $0.hasSuffix(".state.json") } == [file.lastPathComponent])
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty)
        }
    }

    // MARK: - An agent that is gone

    @Test func aDeadRunIsArchived_andItsBadgeClearsOnTheNextPass() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3"
        let record = """
        {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":3,\
        "stateEpisodeToken":"3","state":"unknown","runStartedAt":null,"updatedAt":"2026-10-20T06:40:00Z",\
        "lastHookEvent":"session_ended","hasPrompt":true,"pid":"4242",\
        "sessionId":"0aa15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-20T06:32:38Z"}
        """
        try withProjection(provider: "codex", session: session, isAlive: false) { projection in
            let path = try projection.write(record, stem: run)
            projection.bootstrap()

            let retiring = try #require(projection.strip().item(for: tab))
            #expect(retiring.agents.map(\.kind) == [.codex])
            #expect(!FileManager.default.fileExists(atPath: path.path))
            let retired = projection.state.appendingPathComponent("retired", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil)
            #expect(files.count == 1)
            let archived = try #require(files.first)
            #expect(archived.lastPathComponent.hasPrefix(run + "."))
            #expect(try Data(contentsOf: archived) == Data(record.utf8))

            projection.adapter.refresh()
            let shell = try #require(projection.strip().item(for: tab))
            #expect(shell.agents.isEmpty)
            #expect(shell.stateGlyph == nil)
            #expect(projection.attention.headerRuntime(inPane: pane) == nil)
        }
    }
}
