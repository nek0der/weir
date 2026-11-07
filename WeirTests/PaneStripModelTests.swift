// PaneStripModelTests.swift
// Weir — the pane strip's tabs: their order, marks, and selection, and what "+" opens.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct PaneStripModelTests {
    private static func items(
        _ kinds: [AttentionItemKind],
        paneID: UUID? = nil,
        provider: AgentKind = .claude
    ) -> [AttentionItem] {
        var queue = AttentionQueue()
        for (offset, kind) in kinds.enumerated() {
            let runtimeID = "\(provider.rawValue):r\(offset)"
            let episode = EpisodeKey(origin: .runtime(runtimeID), episodeToken: "1")
            let id: AttentionItemID = switch kind {
            case let .approval(fact): .approval(fact.key)
            case let .question(fact): .question(fact.key)
            case .prompt: .prompt(episode)
            case .stop: .stop(episode)
            case let .unread(turn): .unread(turn.turnID)
            }
            queue.insert(
                id: id,
                kind: kind,
                subject: .runtime(id: runtimeID, provider: provider, paneID: paneID ?? UUID(), tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }
        return queue.items
    }

    private static func input(
        id: UUID = UUID(),
        title: String = "zsh",
        agent: AgentKind? = nil,
        paneGlyphs: [SessionRowFact.Glyph] = [],
        paneItems: [AttentionItem] = [],
        hasUnread: Bool = false,
        exitCodes: [UInt32] = []
    ) -> PaneStripModel.ItemInput {
        .init(
            id: id,
            title: title,
            agents: agent.map { [PaneStripModel.AgentInput(kind: $0)] } ?? [],
            paneGlyphs: paneGlyphs,
            paneItems: paneItems,
            hasUnread: hasUnread,
            isInTmux: false,
            exitCodes: exitCodes
        )
    }

    private static let unread = AttentionItemKind.unread(
        UnreadTurn(turnID: TurnID("t"), changes: .unknown)
    )

    @Test(arguments: [
        ("…/sample-reviews/demo-repos/alpha", SupervisionTruncation.pathTitle),
        ("~/notes", .pathTitle),
        ("me@mac: ~/weir", .pathTitle),
        ("zsh", .name),
        ("Claude Code", .name),
        ("/review-pr 123 fix", .name),
        ("/init", .name)
    ])
    func aTabsTitle_usesPathOrNameTruncation(title: String, truncation: SupervisionTruncation) throws {
        let model = PaneStripModel(items: [Self.input(title: title)], activeTabID: nil, reviewTab: .none)
        let item = try #require(model.items.first)
        #expect(item.title == title)
        #expect(item.titleTruncation == truncation)
    }

    @Test func aPanesFrame_isForAWaitOrAStop_neverForAnUnreadTurn() {
        let pane = UUID()
        #expect(PaneAttention.of(Self.items([Self.unread, .approval(ApprovalFact.test())], paneID: pane)) == .needsApproval)
        #expect(PaneAttention.of(Self.items([.stop(.processExited), .question(ApprovalFact.test(isQuestion: true))], paneID: pane))
            == .needsAnswer)
        #expect(PaneAttention.of(Self.items([Self.unread, .stop(.processExited)], paneID: pane)) == .stopped)
        #expect(PaneAttention.of(Self.items([.prompt(.unclassified(detail: nil)), .stop(.processExited)], paneID: pane))
            == .needsResponse)
        #expect(PaneAttention.of(Self.items([.prompt(.signIn), .stop(.processExited)], paneID: pane))
            == .needsSignIn)
        #expect(PaneAttention.of(Self.items([
            .approval(ApprovalFact.test()), .question(ApprovalFact.test(isQuestion: true))
        ], paneID: pane)) == .needsAnswer)
        #expect(PaneAttention.of(Self.items([Self.unread], paneID: pane)) == nil)
        #expect(PaneAttention.needsAnswer.isWaiting)
        #expect(PaneAttention.needsApproval.isWaiting)
        #expect(PaneAttention.needsResponse.isWaiting)
        #expect(PaneAttention.needsSignIn.isWaiting)
        #expect(!PaneAttention.stopped.isWaiting)
    }

    @Test func theSelectedTab_isTheActiveOne_untilAReviewStandsInItsPlace() {
        let first = UUID()
        let second = UUID()
        let inputs = [Self.input(id: first), Self.input(id: second)]

        let model = PaneStripModel(items: inputs, activeTabID: second, reviewTab: .none)
        #expect(model.items.map(\.id) == [first, second])
        #expect(model.items.map(\.isActive) == [false, true])
        #expect(!model.showsReviewTab)

        let reviewing = PaneStripModel(items: inputs, activeTabID: second, reviewTab: .inFront)
        #expect(reviewing.items.allSatisfy { !$0.isActive })
        #expect(reviewing.showsReviewTab)

        // Behind a terminal tab, the review keeps its tab and the terminal
        // tab is the selected one.
        let behind = PaneStripModel(items: inputs, activeTabID: second, reviewTab: .behind)
        #expect(behind.items.map(\.isActive) == [false, true])
        #expect(behind.showsReviewTab)
    }

    @Test func aTab_marksTheFirstFailedExit_andItsUnreadOutput() {
        let model = PaneStripModel(
            items: [
                Self.input(exitCodes: [0, 2, 1]),
                Self.input(exitCodes: [0]),
                Self.input(hasUnread: true)
            ],
            activeTabID: nil,
            reviewTab: .none
        )
        #expect(model.items.map(\.failedExitCode) == [2, nil, nil])
        #expect(model.items.map(\.hasUnread) == [false, false, true])
    }

    @Test func aTabsTooltip_namesItsTitle_whoRunsInIt_andTmux() {
        let shell = PaneStripModel(items: [Self.input()], activeTabID: nil, reviewTab: .none).items[0]
        #expect(shell.tooltip(locale: Locale(identifier: "ja")) == "zsh\nシェル")

        let agent = PaneStripModel(
            items: [PaneStripModel.ItemInput(
                id: UUID(),
                title: "Fix the tests",
                agents: [
                    .init(kind: .claude, paneGlyphs: [.running]),
                    .init(kind: .codex),
                    .init(kind: .antigravity),
                    .init(kind: .opencode, paneItems: Self.items([.stop(.processExited)], provider: .opencode))
                ],
                hasUnread: false,
                isInTmux: true,
                exitCodes: []
            )],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(agent.shownAgents.map(\.kind) == [.claude, .codex])
        #expect(agent.hiddenAgentCount == 2)
        #expect(agent.tooltip(locale: Locale(identifier: "en")) == [
            "Fix the tests", "Claude · Running", "Codex", "Antigravity", "OpenCode · Stopped",
            "Running in tmux — the session survives quitting Weir"
        ].joined(separator: "\n"))
        #expect(agent.tooltip(locale: Locale(identifier: "ja")).split(separator: "\n").last
            == "tmux で実行中のため、Weir を終了してもセッションは残ります")
    }

    // MARK: - The state glyph

    /// Each state a pane's header can mark shows on its tab as the same
    /// glyph, drawn through the sidebar's one mapping.
    @Test(arguments: [
        (SessionRowFact.Glyph.running, StateGlyph.Kind.running),
        (.needsApproval, .needsApproval),
        (.needsAnswer, .needsAnswer),
        (.needsResponse, .needsResponse),
        (.needsSignIn, .needsSignIn),
        (.stopped, .stopped)
    ])
    func aTab_showsItsPanesState_asTheSidebarsGlyph(glyph: SessionRowFact.Glyph, kind: StateGlyph.Kind) {
        let kinds: [SessionRowFact.Glyph: AttentionItemKind] = [
            .needsApproval: .approval(ApprovalFact.test()),
            .needsAnswer: .question(ApprovalFact.test(isQuestion: true)),
            .needsResponse: .prompt(.unclassified(detail: nil)),
            .needsSignIn: .prompt(.signIn),
            .stopped: .stop(.processExited)
        ]
        let items = kinds[glyph].map { Self.items([$0], paneID: UUID()) } ?? []
        let item = PaneStripModel(
            items: [Self.input(agent: .claude, paneGlyphs: [glyph], paneItems: items)],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(item.stateGlyph == glyph)
        #expect(item.agents == [.init(kind: .claude, state: glyph, identities: [])])
        #expect(item.stateGlyph.map(StateGlyph.Kind.init) == kind)
    }

    /// A split tab shows its panes' first state in the one state order, as the
    /// sidebar's row does: a wait, then a stop, then a run.
    @Test func aSplitTabsGlyph_usesSidebarStatePriority() {
        func glyph(_ glyphs: [SessionRowFact.Glyph], _ kinds: [AttentionItemKind]) -> SessionRowFact.Glyph? {
            PaneStripModel.tabGlyph(glyphs, items: Self.items(kinds))
        }
        let approval = AttentionItemKind.approval(ApprovalFact.test())
        let question = AttentionItemKind.question(ApprovalFact.test(isQuestion: true))
        let response = AttentionItemKind.prompt(.unclassified(detail: nil))
        let stop = AttentionItemKind.stop(.processExited)
        #expect(glyph([.running, .needsApproval], [approval]) == .needsApproval)
        #expect(glyph([.stopped, .running, .needsAnswer], [stop, question]) == .needsAnswer)
        #expect(glyph([.needsResponse, .stopped], [stop, response]) == .needsResponse)
        #expect(glyph([.needsApproval, .needsAnswer], [approval, question]) == .needsAnswer)
        #expect(glyph([.running, .stopped], [stop]) == .stopped)
        #expect(glyph([.running, .running], []) == .running)
        #expect(glyph([.unread, .running], [Self.unread]) == .running)
    }

    /// An approval and a wait for a response rank the same (`PanePriority`),
    /// so the tab shows the one that arrived first, as the row does.
    @Test func aSplitTab_withAnApprovalAndAResponse_showsTheFirstToArrive() {
        let approval = AttentionItemKind.approval(ApprovalFact.test())
        let response = AttentionItemKind.prompt(.unclassified(detail: nil))
        let glyphs: [SessionRowFact.Glyph] = [.needsApproval, .needsResponse]
        let responseFirst = Self.items([response, approval])
        let approvalFirst = Self.items([approval, response])
        #expect(PaneStripModel.tabGlyph(glyphs, items: responseFirst) == .needsResponse)
        #expect(PaneStripModel.tabGlyph(glyphs, items: responseFirst.reversed()) == .needsResponse)
        #expect(PaneStripModel.tabGlyph(glyphs, items: approvalFirst) == .needsApproval)
        #expect(PaneStripModel.tabGlyph(glyphs, items: approvalFirst.reversed()) == .needsApproval)
    }

    /// A shell's tab, a tab at rest, and a turn's unread show no glyph.
    @Test(arguments: [
        [SessionRowFact.Glyph](),
        [.idle],
        [.shell],
        [.unknown],
        [.unread],
        [.idle, .unread]
    ])
    func aTabAtRest_showsNoGlyph(paneGlyphs: [SessionRowFact.Glyph]) {
        #expect(PaneStripModel.tabGlyph(paneGlyphs, items: []) == nil)
    }

    /// The tooltip and VoiceOver name the agent with its state.
    @Test func aTabsTooltip_namesTheAgentWithItsState() {
        let running = PaneStripModel(
            items: [Self.input(title: "Fix", agent: .claude, paneGlyphs: [.running])],
            activeTabID: nil,
            reviewTab: .none
        ).items[0]
        #expect(running.agentLines(locale: Locale(identifier: "ja")) == ["Claude · 実行中"])
        #expect(running.agentLines(locale: Locale(identifier: "en")) == ["Claude · Running"])
        #expect(running.tooltip(locale: Locale(identifier: "ja")) == "Fix\nClaude · 実行中")
        #expect(running.spokenLabel(locale: Locale(identifier: "en")) == "Fix, Claude, Running")
        #expect(running.spokenLabel(locale: Locale(identifier: "ja")) == "Fix、Claude、実行中")

        let idle = PaneStripModel(items: [Self.input(agent: .codex)], activeTabID: nil, reviewTab: .none).items[0]
        #expect(idle.agentLines(locale: Locale(identifier: "ja")) == ["Codex"])
        #expect(idle.agentLines(locale: Locale(identifier: "en")) == ["Codex"])
    }

    /// A failed exit's mark is in the display language, in the same words
    /// the notification history uses for the status.
    @Test func aFailedExitsMark_isLocalized() {
        let model = PaneStripModel(
            items: [Self.input(exitCodes: [0, 1]), Self.input(exitCodes: [0])],
            activeTabID: nil,
            reviewTab: .none
        )
        #expect(model.items[0].exitMark(locale: Locale(identifier: "en")) == "exit 1")
        #expect(model.items[0].exitMark(locale: Locale(identifier: "ja")) == "終了コード 1")
        #expect(model.items[1].exitMark(locale: Locale(identifier: "ja")) == nil)
    }

    /// Read from the session, a tab takes its panes' header marks: a
    /// running Codex in one pane and a stopped run in the other show the
    /// stop.
    @Test func theStrip_readsEachTabsGlyph_fromItsPanesHeaderMarks() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        let split = try #require(session.tab(tab.id))
        let leaves = split.splitTree.allLeafIDs()
        try #require(leaves.count == 2)
        let neighbor = session.openTab(container: .loose)
        let neighborPane = try #require(neighbor.splitTree.allLeafIDs().first)
        let stamp = Date(timeIntervalSince1970: 100)
        let badge = AgentBadge(state: .running, runStartedAt: stamp, updatedAt: stamp)
        let codex = AgentRuntimePresentation.test(kind: .codex, runID: "x", badge: badge, paneIDs: [leaves[0]])
        let claude = AgentRuntimePresentation.test(runID: "c", badge: badge, paneIDs: [leaves[1]])
        let otherClaude = AgentRuntimePresentation.test(runID: "neighbor", badge: badge, paneIDs: [neighborPane])
        session.update(tab.id) { $0.agentBadges = [.codex: [leaves[0]: badge], .claude: [leaves[1]: badge]] }
        session.update(neighbor.id) { $0.agentBadges = [.claude: [neighborPane: badge]] }

        func model(_ queue: AttentionQueue) -> PaneStripModel {
            PaneStripModel(
                container: split.container,
                session: session,
                window: session.primaryWindowID,
                queue: queue,
                runtimes: [codex, claude, otherClaude],
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            )
        }
        let before = model(AttentionQueue())
        #expect(before.item(for: tab)?.paneCount == 2)
        #expect(before.item(for: tab)?.stateGlyph == .running)
        #expect(before.item(for: neighbor)?.stateGlyph == .running)

        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(claude.id), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: claude.id, provider: .claude, paneID: leaves[1], tabID: tab.id, projectID: nil),
            arrivedAt: stamp
        )
        let after = model(queue)
        #expect(after.item(for: tab)?.stateGlyph == .stopped)
        #expect(after.item(for: tab)?.agents == [
            .init(kind: .claude, state: .stopped, identities: []),
            .init(kind: .codex, state: .running, identities: [])
        ])
        #expect(after.item(for: neighbor)?.stateGlyph == .running)
        #expect(after.item(for: neighbor)?.agents == [.init(kind: .claude, state: .running, identities: [])])
    }

    @Test func anUnreadTurnDoesNotHideARunningAgentOrMarkAFinishedTab() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let stamp = Date(timeIntervalSince1970: 100)
        let running = AgentBadge(state: .running, runStartedAt: stamp, updatedAt: stamp)
        let finished = AgentBadge(state: .finished, updatedAt: stamp)
        let turnID = TurnID("t")
        var queue = AttentionQueue()
        queue.insert(
            id: .unread(turnID),
            kind: .unread(UnreadTurn(turnID: turnID, changes: .unknown)),
            subject: .runtime(id: "claude:c", provider: .claude, paneID: pane, tabID: tab.id, projectID: nil),
            arrivedAt: stamp
        )
        func item(_ badge: AgentBadge) -> PaneStripModel.Item? {
            session.update(tab.id) { $0.agentBadges = [.claude: [pane: badge]] }
            return PaneStripModel(
                container: tab.container,
                session: session,
                window: session.primaryWindowID,
                queue: queue,
                runtimes: [AgentRuntimePresentation.test(runID: "c", badge: badge, paneIDs: [pane])],
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            ).item(for: tab)
        }
        let working = item(running)
        #expect(working?.stateGlyph == .running)
        #expect(working?.hasUnread == false)
        let settled = item(finished)
        #expect(settled?.stateGlyph == nil)
        #expect(settled?.agents == [.init(kind: .claude, state: nil, identities: [])])
        #expect(settled?.hasUnread == false)
    }

    @Test func theStrip_followsTheSessionsTabs_inTheirOrder() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let container = ContainerID.project(project.id)
        let first = session.openTab(container: container)
        let second = session.openTab(container: container)
        let scratch = session.openTab(container: .loose)
        session.update(first.id) { $0.titleOverride = "build" }
        session.setActiveTab(first.id)

        let model = PaneStripModel(
            container: container,
            session: session,
            queue: AttentionQueue(),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
        #expect(model.items.map(\.id) == [first.id, second.id])
        #expect(model.item(for: scratch) == nil)
        #expect(model.item(for: first)?.title == "build")
        #expect(model.items.map(\.isActive) == [true, false])
    }

    @Test(arguments: [
        (Optional(AgentKind.claude), Optional("claude")),
        (.codex, "codex"),
        (.antigravity, "agy"),
        (.opencode, "opencode"),
        (nil, nil)
    ])
    func newTabAction_stagesOnlyTheNewTabInTheRequestingWindow(agent: AgentKind?, command: String?) throws {
        let fixture = ProjectWindowsFixture()
        let window = try fixture.window(showing: fixture.b)
        let container = ContainerID.project(fixture.b.id)
        let before = fixture.session.tabs.map(\.id)

        let pane = try #require(TabActions.newTab(
            fixture.session, in: container, running: agent, window: window.id, intent: .person, selects: true
        ))
        let tab = try #require(fixture.session.drawnTab(in: window.id))

        #expect(fixture.session.tabs.count == before.count + 1)
        #expect(fixture.session.tabs.map(\.id).filter { $0 != tab.id } == before)
        #expect(tab.container == container)
        #expect(tab.splitTree.allLeafIDs() == [pane])
        #expect(tab.initialCommands == (command.map { [pane: $0] } ?? [:]))
        #expect(tab.agentsInFront == (agent.map { [pane: PaneAgentInFront(kind: $0, isStaged: true)] } ?? [:]))
        #expect(fixture.session.drawnTab(in: fixture.primary.id)?.id == fixture.aTab.id)
        #expect(fixture.session.tab(fixture.bTab.id)?.initialCommands.isEmpty == true)
    }

    @Test func theActiveTab_isTheOneOfTheWindowDrawingTheStrip() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let container = ContainerID.project(project.id)
        let first = session.openTab(container: container)
        session.openTab(container: container)
        // The primary moves on to another project, so another window can
        // show this one.
        let elsewhere = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("elsewhere"))
        let elsewhereTab = session.openTab(container: .project(elsewhere.id))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(first.id, in: other)

        let model = PaneStripModel(
            container: container,
            session: session,
            window: other,
            queue: AttentionQueue(),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )

        #expect(model.items.filter(\.isActive).map(\.id) == [first.id])
        #expect(session.primarySelection.activeTabID == elsewhereTab.id)
    }

    // MARK: Conversation identity

    /// A run of conversation `id` in `pane`, its session started at
    /// `seconds`, and the tab badge that says so.
    private static func run(
        _ id: String,
        in pane: UUID,
        startedAt seconds: TimeInterval = 0,
        firstPrompt: String? = nil
    ) -> (badge: AgentBadge, runtime: AgentRuntimePresentation) {
        let stamp = Date(timeIntervalSince1970: seconds)
        var badge = AgentBadge(
            state: .running,
            updatedAt: stamp,
            conversationID: id,
            sessionStartedAt: stamp
        )
        badge.firstPrompt = firstPrompt
        let runtime = AgentRuntimePresentation.test(
            runID: id,
            badge: badge,
            paneIDs: [pane],
            conversation: TurnSummaryFixture.conversation(id)
        )
        return (badge, runtime)
    }

    /// The strip of the fixture's project, with the colors the changes
    /// panel hands out for its worktree.
    private static func strip(_ fixture: ActionStoresFixture) -> PaneStripModel {
        let container = ContainerID.project(fixture.project.id)
        return PaneStripModel(
            container: container,
            session: fixture.session,
            window: fixture.session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: fixture.attention.allRuntimes,
            identities: fixture.conversationIdentities.identities(in: container),
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        )
    }

    @Test func items_tabRunningConversation_carriesItsIdentity() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        fixture.session.openTab(container: container)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 2)
        let first = try Self.run("a", in: #require(tabs[0].splitTree.allLeafIDs().first))
        let second = try Self.run("b", in: #require(tabs[1].splitTree.allLeafIDs().first))
        fixture.session.update(tabs[0].id) { $0.agentBadges[.claude] = [first.runtime.paneIDs.first ?? UUID(): first.badge] }
        fixture.session.update(tabs[1].id) { $0.agentBadges[.claude] = [second.runtime.paneIDs.first ?? UUID(): second.badge] }
        fixture.attention.replaceRuntimes([first.runtime, second.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        let strip = Self.strip(fixture)

        #expect(strip.item(for: tabs[0])?.runningIdentities == [TurnSummaryFixture.conversation("a"): 0])
        #expect(strip.item(for: tabs[0])?.agents.first?.identities == [0])
        #expect(strip.item(for: tabs[1])?.runningIdentities == [TurnSummaryFixture.conversation("b"): 1])
        #expect(strip.item(for: tabs[1])?.agents.first?.identities == [1])
    }

    /// One conversation in the worktree needs no color to tell it apart.
    @Test func items_singleConversationWorktree_hasNoIdentity() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let only = Self.run("a", in: pane)
        fixture.session.update(tab.id) { $0.agentBadges[.claude] = [pane: only.badge] }
        fixture.attention.replaceRuntimes([only.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        #expect(fixture.conversationIdentities.identities(in: container).isEmpty)
        #expect(only.runtime.conversation == TurnSummaryFixture.conversation("a"))
        let item = try #require(Self.strip(fixture).item(for: tab))

        #expect(item.stateGlyph == .running)
        #expect(item.runningIdentities.isEmpty)
        #expect(item.agents == [.init(kind: .claude, state: .running, identities: [])])
    }

    /// A split tab running two conversations of one kind has one badge, with
    /// the colors of both, in pane order.
    @Test func items_splitTabWithTwoConversations_showsTheColorsOfBoth() async throws {
        let fixture = ActionStoresFixture()
        PaneActions.split(fixture.session, direction: .horizontal)
        let container = ContainerID.project(fixture.project.id)
        let tab = try #require(fixture.session.tabs(in: container).first)
        let panes = tab.splitTree.allLeafIDs()
        try #require(panes.count == 2)
        let newer = Self.run("newer", in: panes[0], startedAt: 60)
        let older = Self.run("older", in: panes[1], startedAt: 0)
        fixture.session.update(tab.id) { $0.agentBadges[.claude] = [panes[0]: newer.badge, panes[1]: older.badge] }
        fixture.attention.replaceRuntimes([older.runtime, newer.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)
        let identities = fixture.conversationIdentities.identities(in: container)

        let item = try #require(Self.strip(fixture).item(for: tab))
        let newerKey = TurnSummaryFixture.conversation("newer")
        let olderKey = TurnSummaryFixture.conversation("older")
        let newerColor = try #require(identities[newerKey])
        let olderColor = try #require(identities[olderKey])
        #expect(newerColor != olderColor)

        #expect(item.agents == [.init(kind: .claude, state: .running, identities: [newerColor, olderColor])])
        #expect(item.runningIdentities == [newerKey: newerColor, olderKey: olderColor])
    }

    /// A tab with only a shell, beside two running conversations, has no
    /// conversation and no color.
    @Test func items_shellTab_hasNoConversation() async throws {
        let fixture = ActionStoresFixture()
        let container = ContainerID.project(fixture.project.id)
        fixture.session.openTab(container: container)
        fixture.session.openTab(container: container)
        let tabs = fixture.session.tabs(in: container)
        try #require(tabs.count == 3)
        let firstPane = try #require(tabs[0].splitTree.allLeafIDs().first)
        let secondPane = try #require(tabs[1].splitTree.allLeafIDs().first)
        let first = Self.run("a", in: firstPane)
        let second = Self.run("b", in: secondPane, startedAt: 60)
        fixture.session.update(tabs[0].id) { $0.agentBadges[.claude] = [firstPane: first.badge] }
        fixture.session.update(tabs[1].id) { $0.agentBadges[.claude] = [secondPane: second.badge] }
        fixture.attention.replaceRuntimes([first.runtime, second.runtime], kind: .claude)
        await ChangesPanelActions.resolveRoot(window: fixture.window, stores: fixture.changes)

        let strip = Self.strip(fixture)
        let identities = fixture.conversationIdentities.identities(in: container)
        let a = TurnSummaryFixture.conversation("a")
        let b = TurnSummaryFixture.conversation("b")
        let aColor = try #require(identities[a])
        let bColor = try #require(identities[b])
        #expect(aColor != bColor)
        #expect(strip.item(for: tabs[0])?.agents == [.init(kind: .claude, state: .running, identities: [aColor])])
        #expect(strip.item(for: tabs[1])?.agents == [.init(kind: .claude, state: .running, identities: [bColor])])
        let shell = try #require(strip.item(for: tabs[2]))
        #expect(shell.agents.isEmpty)
        #expect(shell.runningIdentities.isEmpty)
    }

    /// A scratch tab has no cards to match, but its title still follows its
    /// conversation: a split of agents goes by its folder only until then.
    @Test func items_scratchSplitOfAgents_takesItsTitleOnceItsConversationHasAName() {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        let second = UUID()
        var older = Self.run("older", in: first, startedAt: 0)
        var newer = Self.run("newer", in: second, startedAt: 60)
        session.update(tab.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: first, direction: .horizontal, newID: second).tree
            tab.title = "Terminal's title"
            tab.pwd = "/work/alpha"
            tab.agentBadges[.claude] = [first: older.badge, second: newer.badge]
        }
        func title() -> String? {
            PaneStripModel(
                container: tab.container,
                session: session,
                window: session.primaryWindowID,
                queue: AttentionQueue(),
                runtimes: [older.runtime, newer.runtime],
                mountedTmuxPaneIDs: [],
                reviewTab: .none
            ).item(for: tab)?.title
        }
        #expect(session.tab(tab.id)?.latestAgentSessionPaneID == second)
        #expect(title() == "alpha")

        older = Self.run("older", in: first, startedAt: 0, firstPrompt: "Earlier task")
        session.update(tab.id) { $0.agentBadges[.claude]?[first] = older.badge }
        #expect(title() == "alpha")

        newer = Self.run("newer", in: second, startedAt: 60, firstPrompt: "Fix the tests")
        session.update(tab.id) { $0.agentBadges[.claude]?[second] = newer.badge }
        #expect(title() == "Terminal's title")
    }

    /// A scratch tab has no worktree to match its conversation's cards in.
    @Test func items_scratchTab_hasNoConversation() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let scratch = Self.run("a", in: pane)
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: scratch.badge] }
        let item = PaneStripModel(
            container: tab.container,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: [scratch.runtime],
            identities: [TurnSummaryFixture.conversation("a"): 0],
            mountedTmuxPaneIDs: [],
            reviewTab: .none
        ).item(for: tab)
        #expect(item?.runningIdentities.isEmpty == true)
        #expect(item?.agents.first?.identities == [])
    }
}
