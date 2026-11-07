// PaneStripAgentBadgeTests.swift
// Weir — a pane strip tab wears the badge of the agent whose run record places it in the tab.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// From the record a hook writes to the tab's badge, through the real rules:
/// the path a tab takes from the shell glyph to Cl or Cx, whether the agent
/// was started from "+" or typed into a shell (both reach the tab only
/// through the record), or typed again by a restore at launch.
@MainActor
@Suite("PaneStripAgentBadge")
struct PaneStripAgentBadgeTests {
    /// What one projection pass made of the records, and the strip it shows.
    private struct Pass {
        let strip: PaneStripModel
        let attention: AttentionState
    }

    /// The strip of `container`'s tabs after one projection pass over
    /// `records` (file stem to content), in `provider`'s state directory.
    /// `isAlive` answers for every pid the pass asks about; `passes` more
    /// than one runs the next passes in place, as the sweep would.
    private func pass(
        provider: String,
        records: [String: String],
        session: WorkspaceSession,
        container: ContainerID = .loose,
        isAlive: Bool = true,
        passes: Int = 1,
        programStatus: [String: AgentProjectionProgramStatus] = [:],
        panesBackAtShell: Set<UUID> = []
    ) throws -> Pass {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for (stem, content) in records {
                try Data(content.utf8).write(to: state.appendingPathComponent(AgentRecordFixtures.recordFileName(stem)))
            }
            let adapter = ProjectionFixture.adapter(
                provider: provider,
                state: state,
                sessions: sessions,
                processStatus: { _ in isAlive ? .alive : .dead }
            )
            adapter.programStatus = { programStatus }
            adapter.panesBackAtShell = { panesBackAtShell }
            let attention = AttentionState()
            adapter.bootstrap(into: session, attention: attention)
            for _ in 1..<passes {
                adapter.refresh()
            }
            #expect(adapter.lastFailure == nil)
            let strip = PaneStripModel(
                container: container,
                session: session,
                window: session.primaryWindowID,
                queue: AttentionQueue(),
                runtimes: attention.allRuntimes,
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            )
            return Pass(strip: strip, attention: attention)
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
        #expect(content.contains(corpusPane))
        return content.replacingOccurrences(of: corpusPane, with: pane.uuidString)
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
    func aRun_typedIntoAShell_wearsItsAgentsBadge(agent: AgentKind, scenario: String, directory: String, stem: String) throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let record = try corpusRecord(scenario, directory: directory, stem: stem, pane: pane)
        let item = try pass(provider: agent.rawValue, records: [stem: record], session: session).strip.item(for: tab)
        #expect(item?.agents.first?.kind == agent)
    }

    // MARK: - An agent started from "+"

    @Test(arguments: [AgentKind.claude, .codex])
    func anAgentTab_fromThePlusMenu_wearsItsAgentsBadge_onceItsRecordComes(agent: AgentKind) throws {
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
        let strip = try pass(provider: agent.rawValue, records: [run: record], session: session, container: container).strip
        #expect(strip.item(for: tab)?.agents.first?.kind == agent)
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
        let result = try pass(provider: agent.rawValue, records: [run: record], session: session)
        let item = try #require(result.strip.item(for: tab))
        // The sidebar's row has said Cl or Cx for this run all along.
        #expect(result.attention.allRuntimes.contains { $0.paneIDs.contains(pane) && $0.kind == agent })
        #expect(item.agents.first?.kind == agent)
        #expect(item.stateGlyph == nil, "an unknown state shows no glyph on the badge")
    }

    /// What Codex reports as it comes back at its prompt, after `restoredRecord`'s attempt.
    private static func codexIdle(in pane: UUID) -> [String: AgentProjectionProgramStatus] {
        let at = "2026-10-20T06:30:05Z"
        return [pane.uuidString: AgentProjectionProgramStatus(app: "codex", state: "idle", kind: nil, observedAt: at, stateSince: at)]
    }

    /// `codex resume` runs no hook before its first prompt, and its status
    /// report is what says it is back: the pane then speaks for its
    /// conversation, which the tab's colors, its hover, and "Show Tab" read.
    @Test func aRestoredRun_whoseAgentReports_isThePanesConversation() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "1E9FFA50-B32F-46C4-BCED-C789AFACE803"
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: "turn_finished")

        let silent = try pass(provider: "codex", records: [run: record], session: session)
        #expect(silent.attention.headerRuntime(inPane: pane) == nil, "a resume that failed reports nothing")

        let reporting = try pass(provider: "codex", records: [run: record], session: session, programStatus: Self.codexIdle(in: pane))
        let header = try #require(reporting.attention.headerRuntime(inPane: pane))
        #expect(header.badge.state == .idle)
        let conversation = try #require(header.conversation)
        let tabs = ConversationTabs(tabs: session.tabs, runtimes: reporting.attention.allRuntimes)
        #expect(tabs.place(of: conversation)?.paneID == pane)
        #expect(tabs.conversations(of: tab.id)?.titled == conversation)
    }

    /// A `SessionEnd` written after the restore's mark makes the pane a shell
    /// again, even with the agent's report still standing.
    @Test func aRestoredRun_whoseSessionEnded_isNoConversation() throws {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "1E9FFA50-B32F-46C4-BCED-C789AFACE803"
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: "session_ended")
            .replacingOccurrences(
                of: "\"updatedAt\":\"2026-10-19T14:29:36Z\"",
                with: "\"updatedAt\":\"2026-10-20T06:30:04Z\",\"pid\":\"4242\""
            )
        let result = try pass(provider: "codex", records: [run: record], session: session, programStatus: Self.codexIdle(in: pane))
        #expect(result.attention.headerRuntime(inPane: pane) == nil)
    }

    /// Quit or killed before its first prompt, an agent leaves its record
    /// unwritten, with no pid to sweep: the shell's prompt coming back is
    /// what turns the tab into a plain terminal again.
    @Test func aRestoredRun_whosePaneIsBackAtTheShell_leavesTheTab() throws {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let run = "1E9FFA50-B32F-46C4-BCED-C789AFACE803"
        let record = Self.restoredRecord(run: run, pane: pane, lastHookEvent: "turn_finished")
        let result = try pass(provider: "codex", records: [run: record], session: session, panesBackAtShell: [pane])
        let item = try #require(result.strip.item(for: tab))
        #expect(item.agents.isEmpty)
        #expect(result.attention.headerRuntime(inPane: pane) == nil)
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

    /// A pane with no resume to type, or a session with no record, gets nothing.
    @Test func aReopenedTab_revivesOnlyWhatItResumes() throws {
        let (_, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let oldPane = UUID()
        var closed = tab
        closed.agentSessions[.codex] = [oldPane: AgentSessionInfo(sessionId: "s", cwd: nil)]
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let adapter = ProjectionFixture.adapter(provider: "codex", state: state, sessions: sessions)
            adapter.reviveRuns(of: closed, paneIDs: [oldPane: pane])
            closed.agentResumeCandidates[oldPane] = [.codex]
            adapter.reviveRuns(of: closed, paneIDs: [oldPane: pane])
            #expect(AgentRecordFixtures.records(in: state).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: sessions.path).allSatisfy { !$0.hasSuffix(".json") })
        }
    }

    // MARK: - An agent that is gone

    @Test func aRunWhoseProcessDied_isRetired_andTheTabIsAShellAgain() throws {
        /// The agents on the tab after `passes` passes over the record.
        func agents(after passes: Int) throws -> [AgentKind] {
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let run = "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3"
            // As the hook helper writes it on SessionEnd, with the agent's pid.
            let record = """
            {"schemaVersion":3,"paneId":"\(pane.uuidString)","runId":"\(run)","revision":3,\
            "stateEpisodeToken":"3","state":"unknown","runStartedAt":null,"updatedAt":"2026-10-20T06:40:00Z",\
            "lastHookEvent":"session_ended","hasPrompt":true,"pid":"4242",\
            "sessionId":"0aa15490-ade7-7223-a767-7eb22b5c69e1","sessionStartedAt":"2026-10-20T06:32:38Z"}
            """
            let strip = try pass(provider: "codex", records: [run: record], session: session, isAlive: false, passes: passes).strip
            return try #require(strip.item(for: tab)).agents.map(\.kind)
        }
        // The pass that retires the run shows it once; the next has none.
        #expect(try agents(after: 1) == [.codex])
        #expect(try agents(after: 2) == [])
    }
}
