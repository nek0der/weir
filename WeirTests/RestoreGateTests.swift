// RestoreGateTests.swift
// Weir — when a turn's start may be restored, and what keeps it back.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct RestoreGateTests {
    private static func turn(
        _ id: String = "T1", phase: String = "finished", isRecorded: Bool = true,
        conversation: String = "s1", runID: String = "R"
    ) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = conversation
        extras.runID = runID
        if isRecorded {
            extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        }
        return try TurnSummaryFixture.turn(id, phase: phase, extras: extras)
    }

    private static func input(
        _ turn: TurnSummary,
        agents: [RestoreGate.Agent] = [],
        isWaiting: Bool = false,
        isRestoring: Bool = false
    ) -> RestoreGate.Input {
        RestoreGate.Input(turn: turn, agents: agents, isWaiting: isWaiting, isRestoring: isRestoring)
    }

    private static func agent(_ provider: AgentKind, _ state: AgentState, isTurnsOwn: Bool = false) -> RestoreGate.Agent {
        RestoreGate.Agent(provider: provider, state: state, isTurnsOwn: isTurnsOwn)
    }

    @Test(arguments: [
        BlockerCase("no agents"),
        BlockerCase("resting agents", agents: [
            agent(.claude, .idle, isTurnsOwn: true), agent(.codex, .finished), agent(.codex, .error)
        ]),
        BlockerCase("missing start", isRecorded: false, expected: .notRecorded),
        BlockerCase("started turn", phase: "started", expected: .turnRunning),
        BlockerCase("own worker", agents: [agent(.claude, .running, isTurnsOwn: true)], expected: .agentRunning(other: nil)),
        BlockerCase("one other worker", agents: [agent(.codex, .compacting)], expected: .agentRunning(other: .codex)),
        BlockerCase(
            "two workers of one provider",
            agents: [agent(.codex, .compacting), agent(.codex, .running)],
            expected: .agentRunning(other: .codex)
        ),
        BlockerCase(
            "two providers",
            agents: [agent(.claude, .running), agent(.codex, .running)],
            expected: .agentRunning(other: nil)
        ),
        BlockerCase(
            "own worker beside another of the same provider",
            agents: [agent(.claude, .running, isTurnsOwn: true), agent(.claude, .running)],
            expected: .agentRunning(other: nil)
        ),
        BlockerCase("waiting pane", isWaiting: true, expected: .agentWaiting),
        BlockerCase("waiting agent", agents: [agent(.codex, .needsInput)], expected: .agentWaiting),
        BlockerCase("missing start beats restore", isRecorded: false, isRestoring: true, expected: .notRecorded),
        BlockerCase("restore beats started", phase: "started", isRestoring: true, expected: .restoring),
        BlockerCase("started beats waiting", phase: "started", isWaiting: true, expected: .turnRunning),
        BlockerCase("waiting beats working", agents: [agent(.codex, .running)], isWaiting: true, expected: .agentWaiting)
    ])
    func blocker_followsPriorityAndAttributesTheProvider(test: BlockerCase) throws {
        let turn = try Self.turn(phase: test.phase, isRecorded: test.isRecorded)
        let input = Self.input(turn, agents: test.agents, isWaiting: test.isWaiting, isRestoring: test.isRestoring)
        #expect(RestoreGate.blocker(input) == test.expected, "\(test.name)")
    }

    struct BlockerCase {
        let name: String
        let phase: String
        let isRecorded: Bool
        let agents: [RestoreGate.Agent]
        let isWaiting: Bool
        let isRestoring: Bool
        let expected: RestoreGate.Blocker?

        init(
            _ name: String, phase: String = "finished", isRecorded: Bool = true, agents: [RestoreGate.Agent] = [],
            isWaiting: Bool = false, isRestoring: Bool = false, expected: RestoreGate.Blocker? = nil
        ) {
            self.name = name
            self.phase = phase
            self.isRecorded = isRecorded
            self.agents = agents
            self.isWaiting = isWaiting
            self.isRestoring = isRestoring
            self.expected = expected
        }
    }

    // MARK: - Who is the worktree's

    private static func runtime(
        _ provider: AgentKind = .claude,
        _ state: AgentState = .running,
        conversation: String = "other",
        panes: Set<UUID> = [],
        root: String?
    ) -> RestoreGate.Runtime {
        RestoreGate.Runtime(
            provider: provider,
            state: state,
            conversation: ConversationKey(provider: provider, conversationID: conversation, isFallback: false),
            paneIDs: panes,
            roots: root.map { [$0] } ?? []
        )
    }

    private static func built(
        _ runtimes: [RestoreGate.Runtime],
        turn: TurnSummary? = nil,
        tabPanes: Set<UUID> = [],
        waitingPanes: Set<UUID> = []
    ) throws -> RestoreGate.Input {
        try RestoreGate.input(
            for: turn ?? Self.turn(),
            facts: RestoreGate.Facts(runtimes: runtimes, worktreeTabPanes: tabPanes, waitingPanes: waitingPanes)
        ) { $0 == "/repo" || $0 == "/link/repo" }
    }

    @Test(arguments: [
        MembershipCase(claudeRoots: ["/link/repo"], codexRoots: ["/elsewhere"], codexOwnsTab: true, expected: .claude),
        MembershipCase(claudeRoots: ["/elsewhere", "/repo"], codexRoots: ["/elsewhere"], codexOwnsTab: false, expected: .claude),
        MembershipCase(claudeRoots: ["/repo", "/elsewhere"], codexRoots: ["/elsewhere"], codexOwnsTab: false, expected: .claude),
        MembershipCase(claudeRoots: [], codexRoots: [], codexOwnsTab: true, expected: .codex)
    ])
    func aRuntimeBelongsToTheWorktree_byItsRootsOrRootlessTab(test: MembershipCase) throws {
        let tab = UUID()
        let runtimes = [
            RestoreGate.Runtime(
                provider: .claude, state: .running, conversation: nil, paneIDs: [UUID()], roots: test.claudeRoots
            ),
            RestoreGate.Runtime(
                provider: .codex, state: .running, conversation: nil,
                paneIDs: [test.codexOwnsTab ? tab : UUID()], roots: test.codexRoots
            )
        ]
        let input = try Self.built(runtimes, tabPanes: [tab])
        #expect(input.agents == [Self.agent(test.expected, .running)])
    }

    struct MembershipCase: Sendable {
        let claudeRoots: [String]
        let codexRoots: [String]
        let codexOwnsTab: Bool
        let expected: AgentKind
    }

    @Test func theTurnsOwnConversation_isOwn_whicheverRunResumedIt() throws {
        let original = try Self.turn("original", runID: "original-run")
        let resumed = try Self.turn("resumed", runID: "resumed-run")
        try #require(original.runID != resumed.runID)
        let conversation = original.conversation.conversationID
        let own = Self.runtime(conversation: conversation, root: "/repo")
        let otherProvider = Self.runtime(.codex, conversation: conversation, root: "/repo")

        let input = try Self.built([own, otherProvider], turn: resumed)
        #expect(input.agents == [Self.agent(.claude, .running, isTurnsOwn: true), Self.agent(.codex, .running)])
        #expect(try RestoreGate.blocker(Self.built([own], turn: resumed)) == .agentRunning(other: nil))
        #expect(try RestoreGate.blocker(Self.built([otherProvider], turn: resumed)) == .agentRunning(other: .codex))
    }

    @Test(arguments: [WaitingPane.agent, .tab, .claimedElsewhere, .unrelated])
    func aWaitCounts_inThePanesOfTheWorktreesAgentsAndTabsOnly(waiting: WaitingPane) throws {
        let tab = UUID()
        let elsewhereTab = UUID()
        let agentPane = UUID()
        let runtimes = [
            Self.runtime(.claude, .idle, panes: [agentPane], root: "/repo"),
            Self.runtime(.codex, .idle, panes: [elsewhereTab], root: "/elsewhere")
        ]
        let pane = switch waiting {
        case .agent: agentPane
        case .tab: tab
        case .claimedElsewhere: elsewhereTab
        case .unrelated: UUID()
        }
        let input = try Self.built(runtimes, tabPanes: [tab, elsewhereTab], waitingPanes: [pane])
        #expect(input.isWaiting == (waiting == .agent || waiting == .tab))
    }

    enum WaitingPane: CaseIterable {
        case agent, tab, claimedElsewhere, unrelated
    }

    // MARK: - Many turns at once

    /// The changes panel asks for every row. Each path is resolved once for
    /// all of them, not once per row.
    @MainActor
    @Test func aLookup_resolvesEachPathOnce_forEveryTurnItIsAsked() throws {
        var resolutions: [String: Int] = [:]
        let tabPane = UUID()
        let otherPaths = (0..<50).map { "/other/\($0)" }
        var tabs = otherPaths.map { path in
            RestoreGateLookup.Tab(directory: URL(fileURLWithPath: path), panes: [UUID()])
        }
        tabs.append(RestoreGateLookup.Tab(directory: URL(fileURLWithPath: "/link/repo"), panes: [tabPane]))
        let lookup = RestoreGateLookup(
            tabs: tabs,
            runtimes: [
                Self.runtime(.codex, panes: [tabPane], root: nil),
                Self.runtime(conversation: "first", root: "/link/repo"),
                Self.runtime(.codex, root: "/offsite")
            ],
            waitingPanes: [],
            isBusy: { _ in false },
            resolve: { url in
                resolutions[url.path, default: 0] += 1
                return url.path == "/link/repo" ? URL(fileURLWithPath: "/repo") : url
            }
        )
        let turns = try (0..<200).map { index in
            try Self.turn("T\(index)", conversation: index.isMultiple(of: 2) ? "first" : "second")
        }
        for (index, turn) in turns.enumerated() {
            let input = lookup.input(for: turn)
            #expect(input.turn == turn)
            #expect(input.agents == [
                Self.agent(.codex, .running), Self.agent(.claude, .running, isTurnsOwn: index.isMultiple(of: 2))
            ])
        }
        let expectedPaths = Set(otherPaths + ["/repo", "/link/repo", "/offsite"])
        #expect(Set(resolutions.keys) == expectedPaths)
        #expect(resolutions.values.allSatisfy { $0 == 1 })
    }
}
