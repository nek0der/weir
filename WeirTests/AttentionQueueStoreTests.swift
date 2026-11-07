// AttentionQueueStoreTests.swift
// Weir — the attention list's input built from runtimes, the ledger, and what the person sees.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct AttentionQueueStoreTests {
    private static func runtime(
        _ state: AgentState,
        panes: Set<UUID>,
        tmux: [UUID: TmuxPaneLocation] = [:],
        id: String = "run"
    ) -> AgentRuntimePresentation {
        AgentRuntimePresentation.test(
            runID: id,
            badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: 100)),
            paneIDs: panes,
            tmuxLocations: tmux,
            stateEpisodeToken: "episode"
        )
    }

    private static func tmux(isActive: Bool) -> TmuxPaneLocation {
        TmuxPaneLocation(
            socketPath: "/tmp/s", serverPID: "1", serverStartedAt: "0",
            sessionID: "$1", windowID: "@1", paneID: "%1", isActive: isActive
        )
    }

    @Test func aRuntime_isShownInAPaneInATab() throws {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        let outside = UUID()
        let runtime = Self.runtime(.error, panes: [paneID, outside])

        let input = AttentionQueueStore.makeInput(
            runtimes: [runtime],
            isRead: { _ in false },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )

        #expect(input.runtimes.count == 1)
        let fact = try #require(input.runtimes.first)
        #expect(fact.runtimeID == runtime.id)
        #expect(fact.provider == runtime.kind)
        // The pane in no tab is left out.
        #expect(fact.paneIDs == [paneID])
        #expect(fact.tabID == tab.id)
        #expect(fact.episodeToken == "episode")
        #expect(fact.state == .error)
    }

    @Test func aRuntimeInNoTab_isLeftOut() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let input = AttentionQueueStore.makeInput(
            runtimes: [Self.runtime(.error, panes: [UUID()])],
            isRead: { _ in false },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        #expect(input.runtimes.isEmpty)
    }

    @Test(arguments: [false, true])
    func theReadMark_comesFromTheProjection(isRead: Bool) {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let runtime = Self.runtime(.finished, panes: [paneID])
        var checked: [String] = []
        let input = AttentionQueueStore.makeInput(
            runtimes: [runtime],
            isRead: {
                checked.append($0.id)
                return isRead
            },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        #expect(checked == [runtime.id])
        #expect(input.runtimes.count == 1)
        #expect(input.runtimes.first?.isEpisodeRead == isRead)
    }

    @Test func onlyPanesComingIntoSight_areRead() {
        let stayed = UUID()
        let arrived = UUID()
        let left = UUID()
        let coming = AttentionQueueStore.panesComingIntoSight(previous: [stayed, left], current: [stayed, arrived])
        #expect(coming == [arrived])
    }

    @Test func aRuntimeInSeveralPanes_isShownInTheFocusedOne() {
        // A tmux session attached in two tabs; the active tab's pane has focus.
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        let panes: Set<UUID> = [fixture.paneA, fixture.paneB]

        let input = AttentionQueueStore.makeInput(
            runtimes: [Self.runtime(.error, panes: panes)],
            isRead: { _ in false },
            approvals: [],
            session: fixture.session,
            isApprovalServiceRunning: false
        )

        #expect(input.runtimes.first?.paneIDs.first == fixture.paneA)
        #expect(input.runtimes.first?.tabID == fixture.tabA.id)
        #expect(input.runtimes.first?.paneIDs == [fixture.paneA, fixture.paneB])

        fixture.session.setActiveTab(fixture.tabB.id, in: fixture.session.primaryWindowID, intent: .person)
        let moved = AttentionQueueStore.makeInput(
            runtimes: [Self.runtime(.error, panes: panes)],
            isRead: { _ in false },
            approvals: [],
            session: fixture.session,
            isApprovalServiceRunning: false
        )
        #expect(moved.runtimes.first?.paneIDs == [fixture.paneB, fixture.paneA])
        #expect(moved.runtimes.first?.tabID == fixture.tabB.id)
    }

    /// While the service runs, the input leaves unannounced only a wait the
    /// service will receive a request for, as the providers' descriptors
    /// say: Claude's question comes as a request, Codex's waits at its own
    /// prompt.
    @Test func whileTheServiceRuns_aCodexQuestionIsAnnounced_andAClaudeOneIsLeftToItsRequest() throws {
        let fixture = WorkspaceSessionFixture.withTwoLooseTabs()
        func asking(_ kind: AgentKind, in pane: UUID) -> AgentRuntimePresentation {
            var badge = AgentBadge(state: .needsInput, updatedAt: Date(timeIntervalSince1970: 100))
            badge.waitKind = PromptWaitKind.question.rawValue
            return AgentRuntimePresentation.test(
                kind: kind,
                runID: kind.rawValue,
                badge: badge,
                paneIDs: [pane],
                stateEpisodeToken: "episode"
            )
        }
        let input = AttentionQueueStore.makeInput(
            runtimes: [asking(.codex, in: fixture.paneA), asking(.claude, in: fixture.paneB)],
            isRead: { _ in false },
            approvals: [],
            session: fixture.session,
            isApprovalServiceRunning: true
        )

        let (queue, effects) = AttentionQueueReducer.reduce(AttentionQueue(), input: input)

        func wait(of kind: AgentKind) throws -> AttentionItemID {
            let fact = try #require(input.runtimes.first { $0.provider == kind })
            return .prompt(EpisodeKey(origin: .runtime(fact.runtimeID), episodeToken: "episode"))
        }
        let codex = try wait(of: .codex)
        let claude = try wait(of: .claude)
        #expect(Set(queue.items.map(\.id)) == [codex, claude], "both waits are listed")
        #expect(effects == [.announce(codex)])
    }

    @Test func newItems_areAnnouncedOnlyOnceRuntimesAreMatched() {
        let store = AttentionQueueStore()
        var performed: [[AttentionEffect]] = []
        store.performEffects = { performed.append($0) }
        let stop = RuntimeFact.test("a", .error)
        let later = RuntimeFact.test("b", .error)

        store.apply(.init(runtimes: [stop]), announces: false)
        #expect(store.queue.items.map(\.id) == [.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))])
        #expect(performed.isEmpty, "what was waiting at launch is not read out")

        store.apply(.init(runtimes: [stop, later]), announces: true)
        #expect(performed == [[.announce(.stop(EpisodeKey(origin: .runtime("b"), episodeToken: "1")))]])

        performed.removeAll()
        store.apply(.init(runtimes: [stop, later]), announces: true)
        #expect(performed.isEmpty, "unchanged items must not be announced again")
    }

    /// With and without an earlier turn the person has not viewed, which
    /// the bar counts first: the bar reads "2 / 2" with one and has no
    /// count without.
    @Test(arguments: [false, true])
    func aRejectedHandOff_givesTheBarToTheNextRequest_notTheStaleOne(hasEarlierUnviewedTurn: Bool) {
        let store = ApprovalPresentationStore(decisionSender: { _, _ in })
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        session.applyAcrossTabs { tab in
            tab.agentSessions[.claude] = [paneID: AgentSessionInfo(sessionId: "session", cwd: nil)]
        }
        let epoch = UUID()
        func request() -> ApprovalPresentation {
            ApprovalPresentation.test(epoch: epoch, sessionID: "session", toolName: "Write")
        }
        func apply(pending: [ApprovalPresentation], terminals: [String: BrokerTerminal] = [:], seenAt: Date) {
            store.apply(
                ApprovalControllerConnection.Projection(
                    sequence: 1, requests: pending, terminals: terminals, missingIDs: [],
                    unevictableCount: pending.count, deadlines: [:]
                ),
                epoch: epoch,
                now: SuspendingClock.now,
                seenAt: seenAt
            )
        }
        /// The run, running since the prompt `promptAt` started its turn.
        func promptedRun(at promptAt: TimeInterval, revision: Int) -> AgentRuntimePresentation {
            AgentRuntimePresentation.test(
                revision: revision,
                badge: AgentBadge(state: .running, runStartedAt: Date(timeIntervalSince1970: promptAt), updatedAt: Date()),
                paneIDs: [paneID],
                stateEpisodeToken: "episode",
                sessionID: "session"
            )
        }
        // The first turn changed a file, ended before either request, and
        // was not viewed.
        let unviewed = UnreadTurnEntry(
            turn: UnreadTurn(turnID: TurnID("t1"), numbers: 1...1, changes: .changed(files: 1, added: 1, removed: 0)),
            arrivedAt: Date(timeIntervalSince1970: 990)
        )
        /// What the pane's bar is on, after the pass the app makes.
        func bar(_ run: AgentRuntimePresentation) -> DecisionBarContent {
            store.runtimes = { [run] }
            store.releaseStaleApprovals(in: session)
            let input = AttentionQueueStore.makeInput(
                runtimes: [run],
                isRead: { _ in false },
                unreadTurns: hasEarlierUnviewedTurn ? [run.id: [unviewed]] : [:],
                approvals: store.placedApprovals(in: session),
                session: session,
                isApprovalServiceRunning: true
            )
            let items = AttentionQueueReducer.reduce(AttentionQueue(), input: input).0.items(inPane: paneID)
            return DecisionBarContent.make(.init(items: items))
        }
        // An approval outranks the unviewed turn, and is counted after it.
        let turnID = AttentionItemID.unread(unviewed.turn.turnID)
        let position = hasEarlierUnviewedTurn ? DecisionBarContent.Position(index: 2, count: 2, previous: turnID, next: turnID) : nil

        // The first request is handed to the TUI, where the person says "No".
        let rejected = request()
        apply(pending: [rejected], seenAt: Date(timeIntervalSince1970: 1000))
        apply(pending: [], terminals: [rejected.id: .resolved(.delegate)], seenAt: Date(timeIntervalSince1970: 1000))
        let before = bar(promptedRun(at: 995, revision: 1))
        #expect(before.itemID == .approval(rejected.key))
        #expect(before.position == position)

        // No hook follows the "No"; the next prompt does, and the request
        // it leads to arrives after it.
        let next = request()
        apply(pending: [next], seenAt: Date(timeIntervalSince1970: 1002))

        let after = bar(promptedRun(at: 1001, revision: 2))
        #expect(after.itemID == .approval(next.key))
        #expect(after.position == position, "the rejected request is gone, not counted beside the next one")
        #expect(store.ledger.entry(for: rejected) == nil)
    }
}
