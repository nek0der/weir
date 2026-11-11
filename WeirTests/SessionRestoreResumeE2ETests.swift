// SessionRestoreResumeE2ETests.swift
// Weir — end-to-end coverage for the session-restore → resume
// command pipeline. The individual links (SessionSnapshot encode /
// decode, WorkspaceSession.restore, the projection pass,
// AgentResumeCommandBuilder.initialCommand) each have their own
// suite; this file pins down the chain that actually drives a user
// resume: a Weir that quit yesterday with a live Claude / Codex
// session must re-launch the same conversation today via the
// `initialCommand` the surface mount reads.
//
// The chain has one more link than the snapshot: which provider may resume
// in a pane is the projection's answer, taken from the resume hints on disk
// on the first pass after launch. So each case writes the hints, round-trips
// the snapshot, restores, runs that pass, and only then asks the builder.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct SessionRestoreResumeE2ETests {

    // MARK: - Helpers

    private struct Hint {
        let kind: AgentKind
        let sessionId: String
        let cwd: String?
    }

    /// Quits with `hints` in the snapshot and on disk, then relaunches: the
    /// snapshot round-trips, the session restores, and the first projection
    /// pass runs the way `AppState` runs it before any surface mounts.
    private func relaunch(in root: URL, hints: [Hint]) throws -> (tab: Tab, paneID: UUID) {
        let session = WorkspaceSession()
        let tab = session.openTabInActiveScope()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let directories = AgentProviderRegistry.directories(under: root)
        for hint in hints {
            session.update(tab.id) {
                $0.agentSessions[hint.kind, default: [:]][paneID] = AgentSessionInfo(
                    sessionId: hint.sessionId,
                    cwd: hint.cwd
                )
            }
            let sessions = try #require(directories[hint.kind.rawValue]).sessions
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            var record: [String: Any] = [
                "schemaVersion": 1,
                "paneId": paneID.uuidString,
                "sessionId": hint.sessionId,
                "updatedAt": "2026-09-14T12:00:00Z"
            ]
            if let cwd = hint.cwd {
                record["cwd"] = cwd
            }
            try JSONSerialization.data(withJSONObject: record)
                .write(to: sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(paneID.uuidString)))
        }

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        let adapter = AgentProjectionAdapter(
            directories: directories,
            descriptors: AgentProviderRegistry.descriptors,
            resumeIntents: AgentResumeIntentStore(
                directory: root.appendingPathComponent("resume-intents", isDirectory: true)
            ),
            processStatus: { _ in .unknown }
        )
        adapter.bootstrap(into: restored)
        #expect(adapter.lastFailure == nil)
        return try (#require(restored.activeTab(in: restored.primaryWindowID)), paneID)
    }

    /// The command the surface mount reads for `kind`'s agent in the pane.
    private static func resumeCommand(_ kind: AgentKind, for tab: Tab, paneID: UUID) -> String? {
        AgentResumeCommandBuilder.initialCommand(kind, for: tab, paneID: paneID)
    }

    // MARK: - End to end

    @Test("encode → decode → restore preserves each agent's resume command", arguments: [
        (AgentKind.claude, "f47ac10b-58cc-4372-a567-0e02b2c3d479", "claude --resume f47ac10b-58cc-4372-a567-0e02b2c3d479"),
        (.codex, "01963d6b-c0e9-7c4e-9bce-e4d6f2c1c000", "codex resume 01963d6b-c0e9-7c4e-9bce-e4d6f2c1c000"),
        (.antigravity, "2842b64f-6f5a-4d28-948c-b2156ab731f8", "agy --conversation 2842b64f-6f5a-4d28-948c-b2156ab731f8"),
        (.opencode, "ses_e6811df99ffec906Lvdn0geRZZ", "opencode --session ses_e6811df99ffec906Lvdn0geRZZ"),
        // The resume asks for the v3 engine, the one Kiro's hooks load in.
        (.kiro, "sess_6972654a-ef00-47b4-9cfd-d5047d8f9ef0", "kiro-cli --v3 --resume-id sess_6972654a-ef00-47b4-9cfd-d5047d8f9ef0")
    ])
    func aResume_survivesSnapshotRoundTrip(kind: AgentKind, sessionId: String, resume: String) throws {
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: kind, sessionId: sessionId, cwd: "/Users/dev/weir")
            ])

            let expected = "cd '/Users/dev/weir' && \(resume)"
            #expect(tab.agentSessions[kind]?[paneID] == AgentSessionInfo(sessionId: sessionId, cwd: "/Users/dev/weir"))
            #expect(tab.agentResumeCandidates[paneID] == [kind])
            #expect(Self.resumeCommand(kind, for: tab, paneID: paneID) == expected)
            #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: paneID) == expected)
        }
    }

    @Test("a malformed Claude session id types nothing after restore")
    func claudeResume_invalidSessionId_typesNothing() throws {
        // The validator rejects anything outside the UUID-shape character set,
        // so a hand-edited hint can't smuggle shell metacharacters into the
        // spawn command. Nothing takes its place either: a fresh `claude`
        // would be a new conversation in the old one's pane, which a resume
        // never starts.
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: .claude, sessionId: "bad id; rm -rf /", cwd: nil)
            ])

            let command = AgentResumeCommandBuilder.initialCommand(.claude, for: tab, paneID: paneID)
            #expect(command == nil)
        }
    }

    @Test("both restore hints survive, and only Claude can resume the pane")
    func codexResume_defersToClaude_afterRestore() throws {
        // Both providers left a hint for the same pane. The projection names
        // Claude as the one to resume, so the surface mount picks Claude and
        // Codex stays dormant rather than the two racing for the pty.
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [
                Hint(kind: .codex, sessionId: "codex-1", cwd: "/repo/codex"),
                Hint(kind: .claude, sessionId: "claude-1", cwd: "/repo/claude")
            ])

            #expect(tab.agentSessions[.claude]?[paneID] == AgentSessionInfo(sessionId: "claude-1", cwd: "/repo/claude"))
            #expect(tab.agentSessions[.codex]?[paneID] == AgentSessionInfo(sessionId: "codex-1", cwd: "/repo/codex"))
            #expect(tab.agentResumeCandidates[paneID] == [.claude])
            #expect(Self.resumeCommand(.codex, for: tab, paneID: paneID) == nil)
            let expected = AgentResume(
                provider: .claude, sessionID: "claude-1", cwd: "/repo/claude", command: "cd '/repo/claude' && claude --resume claude-1"
            )
            #expect(PaneHostRepresentable.resolveRestoredResume(tab: tab, paneID: paneID) == expected)
            #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: paneID) == expected.command)
        }
    }

    // MARK: - No-session paths

    @Test("a tab with no agent session yields no resume command after restore")
    func noSession_yieldsNilInitialCommand() throws {
        try withTempDir { root in
            let (tab, paneID) = try relaunch(in: root, hints: [])

            #expect(tab.agentResumeCandidates.isEmpty)
            for kind in AgentKind.allCases {
                #expect(tab.agentSessions[kind]?[paneID] == nil)
                #expect(Self.resumeCommand(kind, for: tab, paneID: paneID) == nil)
            }
            #expect(PaneHostRepresentable.resolveRestoredResume(tab: tab, paneID: paneID) == nil)
            #expect(PaneHostRepresentable.resolveInitialCommand(tab: tab, paneID: paneID) == nil)
        }
    }

    @Test("a hint in the snapshot alone does not resume before the first pass")
    func snapshotHint_withoutAPass_yieldsNothing() throws {
        // The snapshot remembers the hint, but permission to resume is the
        // projection's to give: until it has looked at the disk, a restored
        // tab starts no agent.
        let session = WorkspaceSession()
        let tab = session.openTabInActiveScope()
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) {
            $0.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "claude-1", cwd: nil)
        }
        let data = try JSONEncoder().encode(session.makeSnapshot())
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        let restoredTab = try #require(restored.activeTab(in: restored.primaryWindowID))
        #expect(restoredTab.agentSessions[.claude]?[paneID]?.sessionId == "claude-1")
        #expect(AgentResumeCommandBuilder.initialCommand(.claude, for: restoredTab, paneID: paneID) == nil)
    }
}
