// AgentProjectionAdapterTests.swift
// Weir — what the adapter has to tell the rules, and what it must not.
//
// The rules read only what this process hands them. A field the adapter does
// not fill is not an error on the other side, it is a fact the rules never
// learn, so the cases here are the ones where staying silent would look like
// a decision.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("AgentProjectionAdapter")
struct AgentProjectionAdapterTests {
    private static let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"

    private struct Harness {
        let adapter: AgentProjectionAdapter
        let session: WorkspaceSession
        let state: URL
        let intents: AgentResumeIntentStore
        let recordURL: URL
    }

    /// One pane holding one run whose process is gone, which is the shape the
    /// sweep retires unless something says otherwise.
    private func harness(in root: URL, paneID: UUID, writesFiles: Bool = true) throws -> Harness {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let record = AgentStateRecordFixture(
            runId: Self.run,
            revision: 4,
            stateEpisodeToken: "4",
            paneId: paneID.uuidString,
            state: "finished",
            updatedAt: "2026-09-14T12:00:00Z",
            pid: "4242"
        )
        let recordURL = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.run))
        try AgentRecordFixtures.write(record, to: state)

        let intents = AgentResumeIntentStore(
            directory: root.appendingPathComponent("resume-intents", isDirectory: true),
            writesFiles: writesFiles
        )
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let adapter = ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            resumeIntents: intents,
            writesFiles: writesFiles,
            processStatus: { _ in .dead }
        )
        return Harness(
            adapter: adapter,
            session: session,
            state: state,
            intents: intents,
            recordURL: recordURL
        )
    }

    @Test("a fresh intent protects a dead run from retirement", arguments: [false, true])
    func resumeIntent_keepsTheRecordTheRestoreNeeds(hasIntent: Bool) throws {
        try withTempDir { root in
            let paneID = UUID()
            let harness = try harness(in: root, paneID: paneID)
            let original = try Data(contentsOf: harness.recordURL)
            if hasIntent {
                try harness.intents.save(AgentResumeIntent(
                    runID: Self.run,
                    paneID: paneID,
                    sessionID: "session-1",
                    ownerRunID: nil,
                    pid: "4242",
                    createdAt: Date()
                ))
                try #require(harness.intents.record(runID: Self.run)?.paneID == paneID)
            }
            var passes = 0
            harness.adapter.onProjectionApplied = { _ in passes += 1 }

            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            #expect(harness.adapter.lastFailure == nil)
            #expect(passes == 1)
            if hasIntent {
                #expect(try Data(contentsOf: harness.recordURL) == original)
                #expect(try Self.archivedRecords(in: harness.state).isEmpty)
            } else {
                #expect(!FileManager.default.fileExists(atPath: harness.recordURL.path))
                #expect(try Self.archivedRecords(in: harness.state) == [original])
            }
        }
    }

    private static func archivedRecords(in state: URL) throws -> [Data] {
        let retired = state.appendingPathComponent("retired", isDirectory: true)
        guard FileManager.default.fileExists(atPath: retired.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil)
            .map { try Data(contentsOf: $0) }
    }

    @Test("an adapter without writes leaves real records and hints as they were")
    func anAdapterThatMayNotWrite_retiresNothing() throws {
        try withTempDir { root in
            let pane = UUID()
            let harness = try harness(in: root, paneID: pane, writesFiles: false)
            let hints = root.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: pane.uuidString, sessionId: "private-session", cwd: "/private/project",
                updatedAt: "2026-09-14T12:00:00Z", runId: Self.run
            ), to: hints)
            let before = try Self.files(in: root)
            let attention = AttentionState()
            let originalTabs = harness.session.tabs

            harness.adapter.prepareForLaunch()
            harness.adapter.bootstrap(into: harness.session, attention: attention)
            harness.adapter.refresh()
            harness.adapter.prepareForTermination()

            #expect(try Self.files(in: root) == before)
            #expect(harness.session.tabs == originalTabs)
            #expect(attention.allRuntimes.isEmpty)
        }
    }

    private static func files(in directory: URL) throws -> [String: Data] {
        let manager = FileManager.default
        var entries: [String: Data] = [:]
        for entry in try manager.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            try #require(manager.fileExists(atPath: url.path, isDirectory: &isDirectory))
            entries[entry] = isDirectory.boolValue ? Data() : try Data(contentsOf: url)
        }
        return entries
    }

    @Test("the first pass after launch lists the stop of a dead run nothing claimed, then retires it, hint and all")
    func launch_leavesADeadRunNothingClaimedToTheFirstPass() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let record = AgentStateRecordFixture(
                runId: Self.run,
                revision: 4,
                stateEpisodeToken: "4",
                paneId: pane.uuidString,
                state: "running",
                updatedAt: "2026-09-14T12:00:00Z",
                pid: "4242"
            )
            try AgentRecordFixtures.write(record, to: state)
            let hint = AgentSessionHintFixture(
                paneId: pane.uuidString,
                sessionId: "S",
                cwd: "/tmp",
                updatedAt: "2026-09-14T12:00:00Z",
                runId: Self.run
            )
            let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
            try AgentRecordFixtures.write(hint, to: sessions)

            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .dead }
            )
            let attention = AttentionState()
            adapter.prepareForLaunch()
            let recordURL = try state.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.run))
            // No kill marker and no intent means Weir did not stop this run,
            // so nothing says it should come back. It died at work, though,
            // and no pass has shown that yet: the launch leaves it for the
            // first pass, which lists the stop a live death would have
            // rather than retiring it before anyone saw it.
            #expect(adapter.lastFailure == nil)
            let originalRecord = try Data(contentsOf: recordURL)
            let originalHint = try Data(contentsOf: hintURL)
            var stopSessions: [AgentSessionInfo] = []
            var stopCalls = 0
            adapter.onRunsExited = {
                stopCalls += 1
                #expect((try? Data(contentsOf: recordURL)) == originalRecord)
                #expect((try? Data(contentsOf: hintURL)) == originalHint)
                if let info = session.activeTab(in: session.primaryWindowID)?.agentSessions[.claude]?[pane] {
                    stopSessions.append(info)
                }
            }

            adapter.bootstrap(into: session, attention: attention)

            // The first pass shows the run stopped once, with its session
            // still at hand for the stop ledger, and retires the record and
            // the hint it owned, for every provider alike. The restored pane
            // gets no resume candidate from that hint: it types a resume
            // from the candidates, and this run is the stop's to resume, not
            // the relaunch's. The pid is what decides, not the pane.
            #expect(adapter.lastFailure == nil)
            try #require(attention.allRuntimes.count == 1)
            let runtime = try #require(attention.allRuntimes.first)
            #expect(runtime.runID == Self.run)
            #expect(runtime.kind == .claude)
            #expect(runtime.paneIDs == [pane])
            #expect(runtime.badge.stopReason == AgentBadge.processExitedReason)
            let info = AgentSessionInfo(sessionId: "S", cwd: "/tmp")
            #expect(stopCalls == 1)
            #expect(stopSessions == [info])
            #expect(!FileManager.default.fileExists(atPath: hintURL.path))
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
            let tab = try #require(session.activeTab(in: session.primaryWindowID))
            #expect(tab.agentSessions[.claude]?[pane] == info)
            #expect(tab.agentResumeCandidates[pane] == nil)

            adapter.refresh()
            #expect(adapter.lastFailure == nil)
            #expect(stopCalls == 1)
        }
    }

    /// "Start New Conversation" ends the stopped session for good, by its
    /// hint. A hook holding the hint's lock at that moment leaves it on
    /// disk: the ended session is kept from the rules until the hint can
    /// go, so it is neither shown as the pane's again nor resumed by the
    /// next launch, and the deletion is tried again until it lands.
    @Test("a hint ended while a hook held it is kept from the rules, and deleted once free")
    func aForgottenHint_whileItsLockIsHeld_isKeptFromTheRules_thenDeleted() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let hint = AgentSessionHintFixture(
                paneId: pane.uuidString,
                sessionId: "S",
                cwd: "/tmp",
                updatedAt: "2026-09-14T12:00:00Z"
            )
            let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
            try AgentRecordFixtures.write(hint, to: sessions)
            let adapter = ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: sessions, processStatus: { _ in .dead }
            )
            adapter.bootstrap(into: session, attention: AttentionState())
            @MainActor func paneSession() -> String? {
                session.activeTab(in: session.primaryWindowID)?.agentSessions[.claude]?[pane]?.sessionId
            }
            #expect(paneSession() == "S")

            do {
                let held = try AgentRecordFixtures.HeldLock(on: hintURL)
                withExtendedLifetime(held) {
                    adapter.forgetSession("S", of: .claude, inPane: pane)
                    #expect(FileManager.default.fileExists(atPath: hintURL.path))
                    #expect(adapter.forgottenHints == [.init(provider: "claude", pane: pane, sessionID: "S")])
                    adapter.refresh()
                    #expect(adapter.lastFailure == nil)
                    #expect(paneSession() == nil)
                    #expect(session.activeTab(in: session.primaryWindowID)?.agentResumeCandidates[pane] == nil)
                }
            }

            // The hook let go: the next pass deletes the hint.
            adapter.refresh()
            #expect(!FileManager.default.fileExists(atPath: hintURL.path))
            #expect(adapter.forgottenHints.isEmpty)
            #expect(paneSession() == nil)
        }
    }

    /// A hint the person ended a session by that is still on disk at quit
    /// (a hook held its lock past the quit's waits, or the file could not
    /// be removed) is kept in the adapter's file: the next launch keeps it
    /// from the rules and deletes it once it can, and the file goes with
    /// the last one. A removal that failed is tried again, not settled.
    @Test("an ended session's hint left at quit is kept from the next launch's rules, and deleted then")
    func aForgottenHint_leftAtQuit_isKeptAcrossARelaunch() throws {
        try withTempDir { root in
            let fixture = try Self.forgottenHintFixture(in: root)
            let quitting = fixture.adapter()
            let relaunched: AgentProjectionAdapter
            do {
                let held = try AgentRecordFixtures.HeldLock(on: fixture.hintURL)
                try withExtendedLifetime(held) { () throws in
                    quitting.forgetSession("S", of: .claude, inPane: fixture.pane)
                    quitting.prepareForTermination()
                    #expect(quitting.forgottenHints == fixture.forgotten)
                    #expect(try Data(contentsOf: fixture.hintURL) == fixture.hintBytes)
                    #expect(AgentForgottenHintFile.read(fixture.queueURL).elements == fixture.forgotten)
                }
                relaunched = fixture.adapter()
                withExtendedLifetime(held) {
                    #expect(relaunched.forgottenHints == fixture.forgotten)
                    relaunched.bootstrap(into: fixture.session, attention: AttentionState())
                    #expect(relaunched.lastFailure == nil)
                    let tab = fixture.session.activeTab(in: fixture.session.primaryWindowID)
                    #expect(tab?.agentSessions[.claude]?[fixture.pane] == nil)
                    #expect(tab?.agentResumeCandidates[fixture.pane] == nil)
                    #expect(relaunched.forgottenHints == fixture.forgotten)
                }
            }

            relaunched.refresh()
            #expect(relaunched.lastFailure == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.hintURL.path))
            #expect(relaunched.forgottenHints.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.queueURL.path))
        }
    }

    @Test(
        "a failed forgotten-hint save is retried by the next pass or at quit",
        .enabled(if: geteuid() != 0),
        arguments: [false, true]
    )
    func aForgottenHint_whoseSaveFailed_isSavedOnceTheFolderTakesIt(retryAtQuit: Bool) throws {
        try withTempDir { root in
            let fixture = try Self.forgottenHintFixture(in: root)
            let adapter = fixture.adapter()
            adapter.bootstrap(into: fixture.session, attention: AttentionState())
            let kept = fixture.queueURL.deletingLastPathComponent()
            let probe = kept.appendingPathComponent("write-probe")
            let manager = FileManager.default
            let held = try AgentRecordFixtures.HeldLock(on: fixture.hintURL)
            defer { withExtendedLifetime(held) {} }
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path) }
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: kept.path)
            #expect(throws: (any Error).self) { try Data("probe".utf8).write(to: probe, options: .atomic) }
            try #require(!manager.fileExists(atPath: probe.path))

            adapter.forgetSession("S", of: .claude, inPane: fixture.pane)

            try #require(adapter.forgottenHints == fixture.forgotten)
            try #require(!manager.fileExists(atPath: fixture.queueURL.path))
            try #require(try Data(contentsOf: fixture.hintURL) == fixture.hintBytes)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path)
            try Data("probe".utf8).write(to: probe, options: .atomic)
            try #require(try Data(contentsOf: probe) == Data("probe".utf8))

            if retryAtQuit {
                adapter.prepareForTermination()
            } else {
                adapter.refresh()
            }

            #expect(adapter.forgottenHints == fixture.forgotten)
            #expect(AgentForgottenHintFile.read(fixture.queueURL).elements == fixture.forgotten)
            #expect(try Data(contentsOf: fixture.hintURL) == fixture.hintBytes)
        }
    }

    private struct ForgottenHintFixture {
        let state: URL
        let hints: URL
        let hintURL: URL
        let queueURL: URL
        let pane: UUID
        let session: WorkspaceSession
        let hintBytes: Data

        var forgotten: [AgentForgottenHint] {
            [AgentForgottenHint(provider: "claude", pane: pane, sessionID: "S")]
        }

        @MainActor
        func adapter() -> AgentProjectionAdapter {
            ProjectionFixture.adapter(
                provider: "claude", state: state, sessions: hints, forgottenHintsURL: queueURL, processStatus: { _ in .dead }
            )
        }
    }

    private static func forgottenHintFixture(in root: URL) throws -> ForgottenHintFixture {
        let state = root.appendingPathComponent("agent-states", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let kept = root.appendingPathComponent("kept", isDirectory: true)
        for directory in [state, sessions, kept] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let hintURL = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(pane.uuidString))
        try AgentRecordFixtures.write(AgentSessionHintFixture(
            paneId: pane.uuidString, sessionId: "S", cwd: "/tmp", updatedAt: "2026-09-14T12:00:00Z"
        ), to: sessions)
        return try ForgottenHintFixture(
            state: state, hints: sessions, hintURL: hintURL, queueURL: kept.appendingPathComponent(AgentForgottenHintFile.fileName),
            pane: pane, session: session, hintBytes: Data(contentsOf: hintURL)
        )
    }

    /// `~/.codex` linked to a dotfiles folder: the rules read the memory
    /// agent's directories against the target as well, which only we can
    /// resolve. A home that does not exist, or is no link, adds nothing.
    @Test("a provider's symlinked default home is resolved for the rules")
    func resolvedHomes_followTheDefaultHomesLink() throws {
        try withTempDir { root in
            let home = root.appendingPathComponent("home", isDirectory: true)
            let target = root.appendingPathComponent("dotfiles/.codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: home.appendingPathComponent(".codex"), withDestinationURL: target
            )
            let physicalHome = try #require(realpath(home.path, nil))
            defer { free(physicalHome) }
            let physicalTarget = try #require(realpath(target.path, nil))
            defer { free(physicalTarget) }

            let resolved = AgentProjectionInput.resolvedHomes(of: ["codex", "claude"], under: home.path)
            #expect(resolved == ["codex": String(cString: physicalTarget)])
            // Under a home written as it is on disk, a real `.claude` is no link.
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
            )
            let physical = AgentProjectionInput.resolvedHomes(of: ["claude"], under: String(cString: physicalHome))
            #expect(physical.isEmpty)
        }
    }

    @Test("the projection's recorded pid reaches the runtime as a process id")
    func projectedPID_becomesTheRuntimeProcessID() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let record = AgentStateRecordFixture(
                runId: Self.run,
                revision: 4,
                stateEpisodeToken: "4",
                paneId: pane.uuidString,
                state: "finished",
                updatedAt: "2026-09-14T12:00:00Z",
                pid: "4242"
            )
            try AgentRecordFixtures.write(record, to: state)
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .alive }
            )
            let attention = AttentionState()

            adapter.bootstrap(into: session, attention: attention)

            // The cache panel types a command only when this pid is what the
            // pane has in front, so a pid lost on the way in would quietly
            // fall back to matching names.
            #expect(adapter.lastFailure == nil)
            let runtime = try #require(attention.runtimesByKind[.claude]?.first)
            #expect(runtime.processID == 4242)
        }
    }

    @Test("a pass names the tab by its conversation")
    func apply_remembersTheConversationName() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let record = AgentStateRecordFixture(
                runId: Self.run,
                revision: 4,
                stateEpisodeToken: "4",
                paneId: pane.uuidString,
                state: "running",
                updatedAt: "2026-09-14T12:00:00Z",
                pid: "4242",
                firstPrompt: "Append a line to notes.txt",
                sessionId: "S"
            )
            try AgentRecordFixtures.write(record, to: state)
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .alive }
            )

            adapter.bootstrap(into: session, attention: AttentionState())

            #expect(adapter.lastFailure == nil)
            #expect(session.tab(tab.id)?.conversationName?.name == "Append a line to notes.txt")
            #expect(session.tab(tab.id)?.conversationName?.conversationID == "S")
        }
    }

    @Test("a tab restored without a name is named by the badges it was saved with")
    func apply_namesARestoredTabFromItsSavedBadges() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            for directory in [state, sessions] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            // The tab as a file from before conversation names holds it:
            // the badge of a run that has since ended, and no name.
            var saved = try #require(session.tab(tab.id))
            saved.agentBadges[.claude] = [pane: AgentBadge(
                state: .finished,
                updatedAt: Date(timeIntervalSince1970: 0),
                firstPrompt: "Run sleep 15 with a timer",
                conversationID: "S"
            )]
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            object.removeValue(forKey: "conversationName")
            let restored = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(restored.conversationName == nil)
            session.update(tab.id) { $0 = restored }
            let adapter = ProjectionFixture.adapter(
                provider: "claude",
                state: state,
                sessions: sessions,
                processStatus: { _ in .dead }
            )

            adapter.bootstrap(into: session, attention: AttentionState())

            // No record is left, so the pass clears the badge; the name
            // read from it stays. An empty map, not none: a pass writes the
            // map only when the badge it saw there differs.
            #expect(adapter.lastFailure == nil)
            let after = try #require(session.tab(tab.id))
            #expect(after.agentBadges[.claude] == [:])
            #expect(after.conversationName?.name == "Run sleep 15 with a timer")
            #expect(after.conversationName?.conversationID == "S")
            #expect(after.conversationName?.provider == .claude)
            adapter.refresh()
            #expect(adapter.lastFailure == nil)
            #expect(session.tab(tab.id)?.conversationName == after.conversationName)
        }
    }

}

@MainActor
extension AgentProjectionAdapterTests {

    // MARK: - Watchers and sweep cadence

    @Test("a worktree event triggers exactly one refetch while neighboring temporary and lock files survive")
    func worktreeEvents_ignoreWhatIsNotAnEvent() throws {
        try withTempDir { root in
            let harness = try harness(in: root, paneID: UUID())
            let events = try AgentRecordFixtures.worktreeEvents(in: harness.state)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            var requested: [String] = []
            harness.adapter.onGitSyncRequested = { requested.append($0) }
            harness.adapter.bootstrap(into: harness.session, attention: AttentionState())

            let eventURL = try Self.writeWorktreeEvent(in: events)
            let lock = try AgentRecordFixtures.lockURL(for: eventURL)
            let temporary = events.appendingPathComponent(".\(eventURL.lastPathComponent).tmp.42")
            let retained = [(lock, Data("lock bytes".utf8)), (temporary, Data("temporary bytes".utf8))]
            for (file, bytes) in retained {
                try bytes.write(to: file)
            }

            harness.adapter.refresh()

            #expect(harness.adapter.lastFailure == nil)
            #expect(requested == ["/example/repo"])
            let left = try Set(FileManager.default.contentsOfDirectory(atPath: events.path))
            #expect(left == Set(retained.map(\.0.lastPathComponent)))
            for (file, bytes) in retained {
                #expect(try Data(contentsOf: file) == bytes)
            }
            harness.adapter.refresh()
            #expect(requested == ["/example/repo"])
        }
    }

    private static func writeWorktreeEvent(in events: URL) throws -> URL {
        let name = try "1757000000-1-a-create" + AgentRecordFixtures.layout().worktreeEventSuffix
        let url = events.appendingPathComponent(name)
        try Data(#"{"repoRoot":"/example/repo","worktreePath":"/example/feature","branch":"feature"}"#.utf8)
            .write(to: url, options: .atomic)
        return url
    }

    @Test("only providers with records take part in the sweep cadence")
    func sweepInterval_followsTheRecordsThePassRead() throws {
        try withTempDir { root in
            let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
            let claude = root.appendingPathComponent("claude-state")
            let codex = root.appendingPathComponent("codex-state")
            let directories = [
                "claude": AgentDirectories(state: claude, sessions: root.appendingPathComponent("claude-hints"), cwdEvents: nil),
                "codex": AgentDirectories(state: codex, sessions: root.appendingPathComponent("codex-hints"), cwdEvents: nil)
            ]
            let adapter = AgentProjectionAdapter(
                directories: directories,
                descriptors: AgentProviderRegistry.descriptors.filter { directories[$0.key] != nil },
                resumeIntents: AgentResumeIntentStore(directory: root.appendingPathComponent("resume-intents")),
                processStatus: { _ in .alive },
                turnCollector: TurnGarbageCollector(sweep: ProjectionFixture.sweepsNothing)
            )
            let slow = olderRunRecord(paneID: pane, runID: Self.run, pid: "4242")
            let fast = olderRunRecord(paneID: pane, runID: UUID().uuidString, pid: "4343")
            try AgentRecordFixtures.write(slow, to: claude)

            adapter.bootstrap(into: session, attention: AttentionState())
            #expect(adapter.lastFailure == nil)
            #expect(adapter.sweepInterval == 30)

            try AgentRecordFixtures.write(fast, to: codex)
            adapter.refresh()
            #expect(adapter.lastFailure == nil)
            #expect(adapter.sweepInterval == 3)

            try FileManager.default.removeItem(at: codex.appendingPathComponent(AgentRecordFixtures.recordFileName(fast.storageID)))
            adapter.refresh()
            #expect(adapter.lastFailure == nil)
            #expect(adapter.sweepInterval == 30)

            try FileManager.default.removeItem(at: claude.appendingPathComponent(AgentRecordFixtures.recordFileName(slow.storageID)))
            adapter.refresh()
            #expect(adapter.lastFailure == nil)
            #expect(adapter.sweepInterval == nil)
        }
    }

    @Test("watching creates hook directories only when writes are enabled", arguments: [false, true])
    func startWatching_createsTheDirectoriesThatDoNotExistYet(writesFiles: Bool) async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("codex-agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("codex-sessions", isDirectory: true)
            let cwd = root.appendingPathComponent("codex-cwd-events", isDirectory: true)
            let events = try AgentRecordFixtures.worktreeEvents(in: state)
            let turns = try AgentRecordFixtures.turns(in: state)
            let paths = [state, sessions, cwd, events, turns]
            let adapter = ProjectionFixture.adapter(
                state: state, sessions: sessions, cwdEvents: cwd,
                resumeIntents: AgentResumeIntentStore(
                    directory: root.appendingPathComponent("resume-intents", isDirectory: true), writesFiles: writesFiles
                ),
                writesFiles: writesFiles
            )
            let session = WorkspaceSession()
            var requested: [String] = []
            var applied = 0
            adapter.onGitSyncRequested = { requested.append($0) }
            adapter.onProjectionApplied = { _ in applied += 1 }
            adapter.bootstrap(into: session)
            try #require(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

            adapter.startWatching()
            defer { adapter.stopWatching() }

            for directory in paths {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                #expect(exists == writesFiles, "\(directory.path)")
                if writesFiles {
                    #expect(isDirectory.boolValue, "\(directory.path)")
                }
            }
            if writesFiles {
                // Let the catch-up pass finish before writing the event. The
                // fixture has no runtime records to arm the sweep timer.
                await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { applied >= 2 }
                try #require(applied >= 2)
                try #require(adapter.sweepInterval == nil)
                let event = try Self.writeWorktreeEvent(in: events)
                await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { !requested.isEmpty }
                #expect(requested == ["/example/repo"])
                #expect(!FileManager.default.fileExists(atPath: event.path))
                #expect(adapter.lastFailure == nil)
            }
        }
    }

    // MARK: - Records a hook holds

    /// A run's record in the version 2 shape an older hook wrote.
    private func olderRunRecord(paneID: UUID, runID: String, pid: String) -> AgentStateRecordFixture {
        AgentStateRecordFixture(
            schemaVersion: 2,
            runId: runID,
            revision: 1,
            paneId: paneID.uuidString,
            state: "running",
            detail: nil,
            runStartedAt: nil,
            updatedAt: "2026-09-09T00:00:00Z",
            lastHookEvent: nil,
            pid: pid,
            lastPrompt: nil
        )
    }

    /// A hook may be rewriting a dead run's resume hint when the sweep
    /// comes to retire the run. The sweep leaves both the hint and the
    /// record while the hook holds the hint's lock, so the next pass can
    /// still retire them together, and retires both once the lock is free.
    @Test("a dead run whose hint a hook holds keeps its record until the lock is free")
    func aDeadRunsHintHeldByAHook_isRetiredWithItsRecordOnceFree() throws {
        try withTempDir { directory in
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let paneID = UUID(), runID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(olderRunRecord(paneID: paneID, runID: runID, pid: "2147483646"), to: states)
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z",
                runId: runID
            ), to: hints)
            let hintURL = try hints.appendingPathComponent(AgentRecordFixtures.hintFileName(paneID.uuidString))
            let recordURL = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(runID))
            let recordBytes = try Data(contentsOf: recordURL)
            let hintBytes = try Data(contentsOf: hintURL)
            let projection = ProjectionFixture.adapter(state: states, sessions: hints, processStatus: { _ in .dead })
            var passes = 0
            projection.onProjectionApplied = { _ in passes += 1 }
            do {
                let held = try AgentRecordFixtures.HeldLock(on: hintURL)
                try withExtendedLifetime(held) { () throws in
                    projection.bootstrap(into: session)
                    #expect(projection.lastFailure == nil)
                    #expect(passes == 1)
                    #expect(try Data(contentsOf: recordURL) == recordBytes)
                    #expect(try Data(contentsOf: hintURL) == hintBytes)
                    #expect(try Self.archivedRecords(in: states).isEmpty)
                }
            }
            projection.refresh()
            #expect(projection.lastFailure == nil)
            #expect(passes == 2)
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
            #expect(!FileManager.default.fileExists(atPath: hintURL.path))
            #expect(try Self.archivedRecords(in: states) == [recordBytes])
        }
    }

    /// Quitting records the intent to resume a live run even while a hook
    /// holds its record's lock, leaving the record itself for the hook; the
    /// next launch resumes the run from that intent.
    @Test("a quit while a hook holds a live run's record still keeps its resume")
    func aQuitWhileAHookHoldsTheRecord_stillKeepsTheResume() throws {
        try withTempDir { directory in
            let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
            let runID = UUID().uuidString
            let sessionID = UUID().uuidString
            let states = directory.appendingPathComponent("states")
            let hints = directory.appendingPathComponent("sessions")
            try AgentRecordFixtures.write(olderRunRecord(paneID: paneID, runID: runID, pid: "12345"), to: states)
            try AgentRecordFixtures.write(AgentSessionHintFixture(
                paneId: paneID.uuidString, sessionId: sessionID, cwd: directory.path,
                updatedAt: "2026-09-09T00:00:00Z", runId: runID
            ), to: hints)
            let recordURL = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(runID))
            let hintURL = try hints.appendingPathComponent(AgentRecordFixtures.hintFileName(paneID.uuidString))
            let recordBytes = try Data(contentsOf: recordURL)
            let hintBytes = try Data(contentsOf: hintURL)
            let intentDirectory = states.appendingPathComponent("resume-intents", isDirectory: true)
            let intents = AgentResumeIntentStore(directory: intentDirectory)
            let quitting = ProjectionFixture.adapter(
                state: states, sessions: hints, resumeIntents: intents, processStatus: { _ in .alive }
            )
            quitting.bootstrap(into: session)
            #expect(quitting.lastFailure == nil)
            do {
                let held = try AgentRecordFixtures.HeldLock(on: recordURL)
                try withExtendedLifetime(held) { () throws in
                    quitting.prepareForTermination()
                    let intent = try #require(intents.record(runID: runID))
                    #expect(intent.runID == runID)
                    #expect(intent.paneID == paneID)
                    #expect(intent.sessionID == sessionID)
                    #expect(intent.pid == "12345")
                    #expect(try Data(contentsOf: recordURL) == recordBytes)
                    #expect(try Data(contentsOf: hintURL) == hintBytes)
                }
            }

            let reopenedIntents = AgentResumeIntentStore(directory: intentDirectory)
            let relaunched = ProjectionFixture.adapter(
                state: states, sessions: hints, resumeIntents: reopenedIntents, processStatus: { _ in .dead }
            )
            try #require(reopenedIntents.record(runID: runID)?.sessionID == sessionID)
            relaunched.prepareForLaunch()
            #expect(relaunched.lastFailure == nil)
            let marked = try #require(AgentRecordFixtures.records(in: states).first)
            #expect(marked.storageID == runID)
            #expect(marked.resumeAttemptedAt != nil)
            #expect(try Data(contentsOf: hintURL) == hintBytes)
            #expect(reopenedIntents.record(runID: runID) == nil)

            relaunched.bootstrap(into: session)
            #expect(relaunched.lastFailure == nil)
            let tab = try #require(session.activeTab(in: session.primaryWindowID))
            #expect(tab.agentSessions[.codex]?[paneID]?.sessionId == sessionID)
            #expect(tab.agentResumeCandidates[paneID] == [.codex])
        }
    }

    /// Retiring a dead run of a pane leaves the resume hint a newer run of
    /// it wrote.
    @Test func cleanupOldRun_preservesNewRunsResumeHint() throws {
        try withTempDir { directory in
            let states = directory.appendingPathComponent("states")
            let sessions = directory.appendingPathComponent("sessions")
            let paneID = UUID()
            var old = olderRunRecord(paneID: paneID, runID: UUID().uuidString, pid: "2147483646")
            old.state = "idle"
            var current = old
            current.runId = UUID().uuidString
            current.pid = String(getpid())
            try AgentRecordFixtures.write(old, to: states)
            try AgentRecordFixtures.write(current, to: states)
            let hint = AgentSessionHintFixture(
                paneId: paneID.uuidString,
                sessionId: UUID().uuidString,
                cwd: directory.path,
                updatedAt: current.updatedAt,
                runId: current.runId
            )
            try AgentRecordFixtures.write(hint, to: sessions)
            let projection = ProjectionFixture.adapter(state: states, sessions: sessions)
            projection.prepareForLaunch()
            #expect(AgentRecordFixtures.hint(forPaneID: paneID, in: sessions) == hint)
            #expect(AgentRecordFixtures.records(in: states).map(\.storageID) == [current.storageID])
        }
    }
}
