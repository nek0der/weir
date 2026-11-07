// AttentionStateTests.swift
// Weir — `AttentionState`: when a run counts as viewed, which runs are at
// work, the pane a run is shown in, passes that change nothing, a new
// episode, and the count of running agents.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct AttentionStateTests {
    /// Build a Claude badge in a given state stamped at `epoch` seconds.
    private func badge(_ state: AgentState, at epoch: TimeInterval) -> AgentBadge {
        AgentBadge(
            state: state,
            detail: nil,
            // A run at work is in a turn here, as one that took a prompt is.
            runStartedAt: state.isMidTurn ? Date(timeIntervalSince1970: epoch) : nil,
            updatedAt: Date(timeIntervalSince1970: epoch),
            lastPrompt: nil
        )
    }

    /// Add a fresh tab carrying one pane with the given Claude badge;
    /// returns the pane id. Attention reads only the runtime projection,
    /// so the helper publishes a matching Claude runtime as well as
    /// writing the session badge.
    private func paneWithBadge(
        _ session: WorkspaceSession,
        _ attention: AttentionState,
        _ state: AgentState,
        at epoch: TimeInterval,
        in container: ContainerID = .loose
    ) -> UUID {
        let tab = session.openTab(container: container)
        let paneID = tab.splitTree.allLeafIDs()[0]
        setBadge(session, attention, paneID: paneID, state, at: epoch)
        return paneID
    }

    /// The runtime id `paneWithBadge` publishes for a pane. The run id is
    /// derived from the pane id so a test can address the runtime without
    /// threading an extra identifier through every helper.
    private func runtimeID(for paneID: UUID) -> String {
        AgentRuntimePresentation.id(kind: .claude, runID: paneID.uuidString)
    }

    /// Write a pane's Claude badge and republish its runtime. The episode
    /// token folds in the stamp, so restating a pane at a later epoch is a
    /// new attention episode and clears any earlier viewed mark.
    private func setBadge(
        _ session: WorkspaceSession,
        _ attention: AttentionState,
        paneID: UUID,
        _ state: AgentState,
        at epoch: TimeInterval
    ) {
        let written = badge(state, at: epoch)
        if let tab = session.tab(containing: paneID) {
            session.update(tab.id) { $0.agentBadges[.claude, default: [:]][paneID] = written }
        }
        let runtime = AgentRuntimePresentation.test(
            runID: paneID.uuidString,
            revision: Int(epoch),
            badge: written,
            paneIDs: [paneID],
            stateEpisodeToken: "\(paneID.uuidString):\(epoch)"
        )
        let others = (attention.runtimesByKind[.claude] ?? []).filter { $0.runID != paneID.uuidString }
        attention.replaceRuntimes(others + [runtime], kind: .claude)
    }

    private func runtime(
        _ state: AgentState,
        paneID: UUID,
        runID: String = "run",
        revision: Int,
        episode: String
    ) -> AgentRuntimePresentation {
        AgentRuntimePresentation.test(
            kind: .codex,
            runID: runID,
            revision: revision,
            badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: TimeInterval(revision))),
            paneIDs: [paneID],
            stateEpisodeToken: episode
        )
    }

    /// The Claude runtime `paneWithBadge` published for a pane.
    private func publishedRuntime(_ attention: AttentionState, for paneID: UUID) -> AgentRuntimePresentation? {
        attention.allRuntimes.first { $0.id == runtimeID(for: paneID) }
    }

    @Test func focusMoved_marksOnlyTheArrivedPanesFinishedRunViewed() throws {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let arrived = paneWithBadge(session, attention, .finished, at: 100)
        let other = paneWithBadge(session, attention, .finished, at: 200)
        let finished = try #require(publishedRuntime(attention, for: arrived))
        let untouched = try #require(publishedRuntime(attention, for: other))
        let waiting = runtime(.needsInput, paneID: arrived, revision: 300, episode: "waiting")
        attention.replaceRuntimes([waiting], kind: .codex)
        let before = attention.allRuntimes

        #expect(attention.viewedRuntimeTokens.isEmpty)
        #expect(attention.queueItems(in: session).map(\.subject.runtimeID) == [finished.id, untouched.id, waiting.id])

        attention.focusMoved(to: arrived, in: session)

        #expect(attention.allRuntimes == before)
        #expect(attention.viewedRuntimeTokens == [finished.id: finished.attentionEventToken])
        #expect(attention.isViewed(finished))
        #expect(attention.queueItems(in: session).map(\.subject.runtimeID) == [untouched.id, waiting.id])
    }

    @Test func claudeAndCodexFinishedInOnePane_areBothListed() throws {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .finished, at: 200)
        let tab = try #require(session.tab(containing: pane))
        let claude = try #require(publishedRuntime(attention, for: pane))
        let codex = runtime(.finished, paneID: pane, runID: claude.runID, revision: 100, episode: "codex-100")
        attention.replaceRuntimes([codex], kind: .codex)

        let items = attention.queueItems(in: session)
        #expect(items.map(\.id) == [
            .unread(TurnID("codex:\(claude.runID)#codex-100")),
            .unread(TurnID("claude:\(claude.runID)#\(claude.attentionEventToken)"))
        ])
        #expect(items.map(\.subject) == [
            .runtime(id: codex.id, provider: .codex, paneID: pane, tabID: tab.id, projectID: nil),
            .runtime(id: claude.id, provider: .claude, paneID: pane, tabID: tab.id, projectID: nil)
        ])
    }

    @Test func aRunWhoseTurnsAreRecorded_isViewedAsItsTurnsSay_notByLooking() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        let recorded = runtimeID(for: pane)
        var isRead = false
        attention.turnReadDecision = { $0.id == recorded ? isRead : nil }

        attention.focusMoved(to: pane, in: session)
        let runtime = attention.allRuntimes.first { $0.id == recorded }

        #expect(runtime.map(attention.isViewed) == false, "a changed turn is not read by looking")
        isRead = true
        #expect(runtime.map(attention.isViewed) == true)
    }

    @Test func focusMoved_reportsEachNonNilPaneToHistorySync() {
        let session = WorkspaceSession()
        let attention = AttentionState()
        let first = paneWithBadge(session, attention, .running, at: 100)
        let second = paneWithBadge(session, attention, .running, at: 200)
        var focusedPanes: [UUID] = []
        attention.onPaneFocused = { focusedPanes.append($0) }

        attention.focusMoved(to: first, in: session)
        #expect(focusedPanes == [first])
        attention.focusMoved(to: nil, in: session)
        #expect(focusedPanes == [first])
        attention.focusMoved(to: second, in: session)
        #expect(focusedPanes == [first, second])
    }

    // MARK: - A run at work, and the pane it is shown in

    /// Every run in the workspace's panes counts, not only the one each
    /// pane's header names: a newer run resting in a pane hides an older one
    /// still at work there, which the request would not hold.
    @Test func anAgentMidTurn_isAnyRunInThePanes_notOnlyTheHeaders() {
        let pane = UUID()
        func runtime(_ id: String, _ state: AgentState, at seconds: TimeInterval) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                runID: id,
                badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: seconds)),
                paneIDs: [pane],
                stateEpisodeToken: "1"
            )
        }
        let attention = AttentionState()
        let working = runtime("working", .running, at: 100)
        let resting = runtime("resting", .idle, at: 200)
        attention.replaceRuntimes([working, resting], kind: .claude)

        #expect(attention.headerRuntime(inPane: pane) == resting)
        #expect(attention.isAgentMidTurn(inPanes: [pane]))
        #expect(!attention.isAgentMidTurn(inPanes: [UUID()]))

        attention.replaceRuntimes([resting], kind: .claude)
        #expect(!attention.isAgentMidTurn(inPanes: [pane]))
    }

    @Test func agentMidTurn_includesRunningCompactingAndNeedsInput() {
        let pane = UUID()
        func runtime(_ state: AgentState) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                kind: .codex,
                runID: "r",
                badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: 0)),
                paneIDs: [pane],
                stateEpisodeToken: "1"
            )
        }
        let atWork = AgentState.allCases.filter { AttentionState.isAgentMidTurn([runtime($0)], inPanes: [pane]) }
        #expect(Set(atWork) == [.running, .compacting, .needsInput])
    }

    @Test func aRuntimeUsesAFocusedPaneInAnyWindowThenTheFirstAttachedPane() throws {
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        let session = fixture.session
        let stale = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let pair = [(fixture.tabA, fixture.paneA), (fixture.tabB, fixture.paneB)].sorted { $0.1.uuidString < $1.1.uuidString }
        let (_, first) = pair[0]
        let (lastTab, last) = pair[1]
        let unrelated = session.openTab(container: .loose)
        func runtime(_ panes: Set<UUID>) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                kind: .codex,
                badge: AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 100)),
                paneIDs: panes
            )
        }
        let attached = runtime([stale, first, last])

        session.setActiveTab(lastTab.id)
        #expect(AttentionState.shownPane(of: attached, in: session) == last)

        session.setActiveTab(unrelated.id)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(lastTab.id, in: other)
        #expect(session.selection(other)?.activeTabID == lastTab.id)
        #expect(AttentionState.shownPane(of: attached, in: session) == last)

        session.setActiveTab(nil, in: other)
        #expect(session.shownTabIDs.isDisjoint(with: [pair[0].0.id, lastTab.id]))
        #expect(AttentionState.shownPane(of: attached, in: session) == first)
        #expect(AttentionState.shownPane(of: runtime([stale]), in: session) == nil)
    }

    // MARK: - Observation hygiene

    @Test func identicalRuntimeAndViewedMarkReplacements_doNotNotifyObservers() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let attention = AttentionState()
        setBadge(session, attention, paneID: paneID, .finished, at: 100)
        let sameRuntimes = attention.runtimesByKind[.claude] ?? []
        attention.markVisibleRuntimesViewed(paneID: paneID)
        let sameMarks = attention.viewedRuntimeTokens

        let runtimesChanged = Recorded(false)
        let marksChanged = Recorded(false)
        withObservationTracking {
            _ = attention.runtimesByKind
        } onChange: {
            runtimesChanged.value = true
        }
        withObservationTracking {
            _ = attention.viewedRuntimeTokens
        } onChange: {
            marksChanged.value = true
        }

        attention.replaceRuntimes(sameRuntimes, kind: .claude)
        attention.replaceMarks(viewed: sameMarks)
        #expect(!runtimesChanged.value)
        #expect(!marksChanged.value)

        setBadge(session, attention, paneID: paneID, .running, at: 200)
        #expect(runtimesChanged.value)
        #expect(!marksChanged.value)

        attention.replaceMarks(viewed: [:])
        #expect(marksChanged.value)
    }

    @Test func replaceRuntimes_firstPass_createsTheKeyEvenWhenEmpty() {
        let attention = AttentionState()
        #expect(attention.runtimesByKind[.codex] == nil)

        attention.replaceRuntimes([], kind: .codex)

        #expect(attention.runtimesByKind[.codex] == [])
    }

    // MARK: - A new episode

    @Test func aNewEpisode_startsUnviewed_evenForTheSameRun() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let attention = AttentionState()
        let first = runtime(.finished, paneID: paneID, revision: 100, episode: "first")
        let revised = runtime(.finished, paneID: paneID, revision: 101, episode: "first")
        let next = runtime(.finished, paneID: paneID, revision: 200, episode: "next")
        attention.replaceRuntimes([first], kind: .codex)
        #expect(attention.queueItems(in: session).map(\.id) == [.unread(TurnID("codex:run#first"))])

        attention.markVisibleRuntimesViewed(paneID: paneID)
        #expect(attention.viewedRuntimeTokens == [first.id: "first"])
        #expect(attention.isViewed(first))

        attention.replaceRuntimes([revised], kind: .codex)
        #expect(attention.isViewed(revised))
        #expect(attention.queueItems(in: session).isEmpty)

        attention.replaceRuntimes([next], kind: .codex)
        #expect(!attention.isViewed(next))
        #expect(attention.queueItems(in: session).map(\.id) == [.unread(TurnID("codex:run#next"))])
    }

    // MARK: - Running agents in a project

    @Test func runningAgentCount_countsRunningAndCompactingRunsInTheProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let other = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("other"))
        let attention = AttentionState()
        func count() -> Int {
            attention.runningAgentCount(inProject: project.id, session: session)
        }

        _ = paneWithBadge(session, attention, .running, at: 100, in: .project(project.id))
        #expect(count() == 1)
        _ = paneWithBadge(session, attention, .compacting, at: 110, in: .worktree(projectID: project.id, worktreeID: worktree.id))
        #expect(count() == 2)
        _ = paneWithBadge(session, attention, .needsInput, at: 120, in: .project(project.id))
        #expect(count() == 2)
        _ = paneWithBadge(session, attention, .running, at: 130)
        #expect(count() == 2)
        _ = paneWithBadge(session, attention, .running, at: 135, in: .project(other.id))
        #expect(count() == 2)
        #expect(attention.runningAgentCount(inProject: other.id, session: session) == 1)

        // An attached run working between turns counts. An unattached run has
        // no project pane and cannot contribute.
        let outside = session.openTab(container: .project(project.id)).splitTree.allLeafIDs()[0]
        let working = AgentBadge(state: .running, updatedAt: Date(timeIntervalSince1970: 140))
        let existing = attention.runtimesByKind[.claude] ?? []
        let continuation = AgentRuntimePresentation.test(runID: "continuation", badge: working, paneIDs: [outside])
        let detached = AgentRuntimePresentation.test(runID: "detached", badge: working, attachmentResolution: .detached)
        attention.replaceRuntimes(existing + [continuation], kind: .claude)
        #expect(count() == 3)
        attention.replaceRuntimes(existing + [continuation, detached], kind: .claude)
        #expect(count() == 3)
        #expect(attention.runningAgentCount(inProject: UUID(), session: session) == 0)
    }

    /// One run shown in two tabs (a tmux session attached twice) is one
    /// item on the list and one running agent in the project.
    @Test func oneRunInTwoTabs_countsOnce() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let paneA = session.openTab(container: .project(project.id)).splitTree.allLeafIDs()[0]
        let paneB = session.openTab(container: .project(project.id)).splitTree.allLeafIDs()[0]
        let attention = AttentionState()
        let finished = AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 100))
        attention.replaceRuntimes([AgentRuntimePresentation.test(
            kind: .codex,
            runID: "shared-run",
            badge: finished,
            paneIDs: [paneA, paneB],
            stateEpisodeToken: "finished"
        )], kind: .codex)
        let items = attention.queueItems(in: session)
        #expect(items.map(\.id) == [.unread(TurnID("codex:shared-run#finished"))])
        #expect(items.map(\.subject.runtimeID) == ["codex:shared-run"])

        let running = AgentBadge(
            state: .running,
            runStartedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        attention.replaceRuntimes([AgentRuntimePresentation.test(
            kind: .codex,
            runID: "shared-run",
            revision: 2,
            badge: running,
            paneIDs: [paneA, paneB]
        )], kind: .codex)
        #expect(attention.queueItems(in: session).isEmpty)
        #expect(attention.runningAgentCount(inProject: project.id, session: session) == 1)
    }

    @Test(arguments: [
        (Optional("episode-2"), Optional(3), "episode-2"),
        (nil, 3, "3"),
        (nil, nil, "42.5")
    ])
    func attentionEventToken_prefersEpisodeThenRevisionThenStamp(episode: String?, revision: Int?, expected: String) {
        let runtime = AgentRuntimePresentation.test(
            kind: .codex,
            revision: revision,
            badge: AgentBadge(state: .needsInput, updatedAt: Date(timeIntervalSince1970: 42.5)),
            stateEpisodeToken: episode
        )

        #expect(runtime.attentionEventToken == expected)
    }

    @Test func outerFocus_marksOnlyTheFinishedRunInTheActiveTmuxPane() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let badge = AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 100))
        func runtime(_ id: String, tmuxPane: String, isActive: Bool) -> AgentRuntimePresentation {
            let location = TmuxPaneLocation(
                socketPath: "/tmp/s",
                serverPID: "42",
                serverStartedAt: "100",
                sessionID: "$2",
                windowID: "@3",
                paneID: tmuxPane,
                isActive: isActive
            )
            return AgentRuntimePresentation.test(
                kind: .codex,
                runID: id,
                badge: badge,
                paneIDs: [paneID],
                tmuxLocations: [paneID: location],
                stateEpisodeToken: "\(id)-finished"
            )
        }
        let front = runtime("front", tmuxPane: "%4", isActive: true)
        let background = runtime("background", tmuxPane: "%5", isActive: false)
        let attention = AttentionState()
        attention.replaceRuntimes([front, background], kind: .codex)

        attention.focusMoved(to: paneID, in: session)

        #expect(attention.viewedRuntimeTokens == [front.id: "front-finished"])
        #expect(attention.isViewed(front))
        #expect(!attention.isViewed(background))
    }
}
