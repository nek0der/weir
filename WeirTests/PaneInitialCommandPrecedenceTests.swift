// PaneInitialCommandPrecedenceTests.swift
// Weir — which of the sources a restored pane's first command can come from wins: a staged command, tmux, or a resume.

// A pane could take more than one. A pane that both reattaches to tmux and
// resumes an agent would run two processes against one session id, which
// the tmux branch's precedence prevents.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Pane initial command precedence")
@MainActor
struct PaneInitialCommandPrecedenceTests {
    private let pane = UUID()

    private func tab() -> Tab {
        Tab(title: "t", splitTree: SplitTree(leafID: pane), container: .loose)
    }

    private func binding() -> TmuxBinding {
        TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work")
    }

    @Test("a staged command outranks tmux and an eligible resume")
    func stagedBeatsTmuxAndResume_thenClearingItExposesTmux() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { tab in
            tab.initialCommands[pane] = "echo staged"
            tab.tmuxBindings[pane] = binding()
            tab.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: nil)
            tab.agentResumeCandidates[pane] = [.claude]
        }
        #expect(PaneHostRepresentable.launch(session: session, paneID: pane).command == "echo staged")
        session.clearStagedLaunch(paneID: pane)
        #expect(PaneHostRepresentable.launch(session: session, paneID: pane).command == "tmux -S '/tmp/s' attach -t '=work'")
        session.update(tab.id) { $0.tmuxBindings[pane] = nil }
        #expect(PaneHostRepresentable.launch(session: session, paneID: pane).command == "claude --resume c1")
    }

    /// A staged agent left in the saved tab would start a fresh
    /// conversation at every launch instead of resuming this one.
    @Test("after its staged command, a pane resumes its conversation")
    func staged_thenResume() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { tab in
            tab.initialCommands[pane] = AgentKind.claude.launchCommand
            tab.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: nil)
            tab.agentResumeCandidates[pane] = [.claude]
        }
        #expect(PaneHostRepresentable.launch(session: session, paneID: pane).command == "claude")
        session.clearStagedLaunch(paneID: pane)
        #expect(PaneHostRepresentable.launch(session: session, paneID: pane).command == "claude --resume c1")
    }

    @Test("an empty staged command, or a pane in no tab, stages nothing")
    func stagedLaunch_ignoresEmptyAndUnknownPanes() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.initialCommands[pane] = "" }
        #expect(session.stagedLaunch(paneID: pane) == nil)
        #expect(session.stagedLaunch(paneID: UUID()) == nil)
    }

    /// What the stop ledger watches at launch is the resume the pane is
    /// typed: the session, its folder, and the command; nothing for a pane
    /// reattaching to tmux, whose agent already runs in there.
    @Test("the restored resume names the session the pane is typed to resume")
    func restoredResume_namesItsSession_andYieldsToTmux() throws {
        var tab = tab()
        tab.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: "/tmp/repo")
        tab.agentResumeCandidates[pane] = [.claude]
        let resume = try #require(PaneHostRepresentable.resolveRestoredResume(tab: tab, paneID: pane))
        #expect(resume == AgentResume(
            provider: .claude, sessionID: "c1", cwd: "/tmp/repo", command: "cd '/tmp/repo' && claude --resume c1"
        ))
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane) == resume.command)
        tab.tmuxBindings[pane] = binding()
        #expect(PaneHostRepresentable.resolveRestoredResume(tab: tab, paneID: pane) == nil)
        #expect(PaneHostRepresentable.resolveRestoredResume(tab: nil, paneID: pane) == nil)
    }

    /// The stop ledger hears of a restored pane's resume from its terminal,
    /// once the command is typed, and dates the resume from then. A
    /// view made but never given a terminal (switched away before one was
    /// made, or one that failed to start) typed nothing, so nothing waits
    /// to fail into a stop.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func aRestoredResume_isWatchedWhenTheTypingCallbackReportsIt() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.writesUserFiles = false
        session.update(tab.id) { tab in
            tab.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: "/tmp/repo")
            tab.agentResumeCandidates[pane] = [.claude]
        }
        let stops = StopLedgerStore(resumeTimeout: .seconds(30))
        let view = PaneHostRepresentable.resolveOrCreateSurfaceView(
            paneID: pane,
            ghosttyApp: ghosttyApp,
            registry: RecordingSurfaceRegistry(),
            session: session,
            hostsAgentsInTmux: false,
            stopLedger: stops
        )
        #expect(view.initialCommand == "cd '/tmp/repo' && claude --resume c1")
        #expect(stops.ledger.launchResumes.isEmpty)
        #expect(!stops.hasResumeClock)

        let onTyped = try #require(view.onInitialCommandTyped)
        view.typeInitialCommand("cd '/tmp/repo' && claude --resume c1")
        #expect(stops.ledger.launchResumes.isEmpty)
        #expect(!stops.hasResumeClock)

        // Simulate the terminal's completion callback with a known timestamp.
        let typedAt = Date(timeIntervalSince1970: 5000)
        onTyped(typedAt)
        #expect(stops.ledger.launchResumes.count == 1)
        let resume = try #require(stops.ledger.launchResumes[pane])
        #expect(resume.paneID == pane)
        #expect(resume.provider == .claude)
        #expect(resume.sessionID == "c1")
        #expect(resume.cwd == "/tmp/repo")
        #expect(resume.since == typedAt)
        #expect(stops.hasResumeClock)
    }

    /// The agent is running inside the session we are reattaching to,
    /// so resuming as well would start a second one against the same id;
    /// a provisional binding, not confirmed yet, blocks it the same.
    @Test("a tmux binding outranks an agent resume", arguments: [false, true])
    func tmux_beatsAgentResume(isProvisional: Bool) throws {
        var tab = tab()
        var binding = binding()
        if isProvisional {
            binding.serverPID = "42"
            binding.serverStartedAt = "100"
            binding.isProvisional = true
        }
        tab.tmuxBindings[pane] = binding
        tab.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: nil)
        tab.agentSessions[.codex, default: [:]][pane] = AgentSessionInfo(sessionId: "x1", cwd: nil)
        tab.agentResumeCandidates[pane] = [.claude, .codex]

        let command = try #require(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane))

        #expect(command.hasPrefix("tmux -S "))
        #expect(!command.contains("claude --resume"))
        #expect(!command.contains("codex resume"))
    }

    @Test("an agent resume still fires when the pane was not in tmux")
    func noBinding_fallsThroughToAgentResume() {
        var tab = tab()
        tab.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: nil)
        tab.agentResumeCandidates[pane] = [.claude]
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: pane) == "claude --resume c1")
    }

    @Test("a pane with nothing recorded just gets its shell")
    func nothingRecorded_isNil() {
        #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab(), paneID: pane) == nil)
    }
}
