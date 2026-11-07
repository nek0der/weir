// BackgroundWorkTests.swift
// Weir — work an agent left running after its turn: read from the projection, marked on the rows, and said on the decision bar.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct BackgroundWorkTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()
    private static let resting = SessionRowFact.Agent(provider: .claude, state: .finished, detail: nil)

    private static func badge(_ backgroundWork: String?) throws -> AgentBadge {
        try AgentBadge.decoded(field: "backgroundWork", value: backgroundWork)
    }

    /// `work` as the run of `items`' first item left it, or as the pane's
    /// run when the bar has no item to match.
    private static func ofRun(
        _ work: BackgroundWork,
        of items: [AttentionItem] = []
    ) -> DecisionBarContent.RuntimeBackgroundWork {
        .init(runtimeID: items.first?.subject.runtimeID ?? "claude:run", work: work)
    }

    private static func model(_ input: DecisionBarContent.Input, locale: Locale = english) -> DecisionBarModel {
        DecisionBarModel(content: DecisionBarContent.make(input), locale: locale)
    }

    // MARK: - Projection

    @Test(arguments: [
        (nil, BackgroundWork?.none),
        ("null", nil),
        (#"{"shells":2,"subagents":1}"#, BackgroundWork(shells: 2, subagents: 1)),
        (#"{"others":3}"#, BackgroundWork(others: 3)),
        (#""two""#, nil),
        ("[1,2]", nil),
        ("7", nil),
        ("{}", nil),
        (#"{"shells":0}"#, nil),
        (#"{"shells":"2"}"#, nil),
        (#"{"shells":-1}"#, nil),
        (#"{"shells":"2","subagents":1}"#, BackgroundWork(subagents: 1))
    ])
    func badge_readsValidCounts_andKeepsTheRestOfTheBadge(json: String?, work: BackgroundWork?) throws {
        let badge = try Self.badge(json)
        #expect(badge.backgroundWork == work, "\(json ?? "missing")")
        #expect(badge.state == .finished)
    }

    @Test func persistedWork_readsAMissingCountAsZero() throws {
        let restored = try Self.badge(#"{"shells":1}"#)
        #expect(restored.backgroundWork == BackgroundWork(shells: 1))

        let original = Self.badge(.finished, backgroundWork: BackgroundWork(subagents: 2))
        let written = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AgentBadge.self, from: written) == original)
    }

    // MARK: - Decision bar

    @Test func lastTurn_saysWhatStillRuns_afterItsReceipt() {
        let turn = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let input = DecisionBarContent.Input(agent: Self.resting, lastTurn: turn, backgroundWork: Self.ofRun(BackgroundWork(shells: 1)))

        let bar = Self.model(input)
        #expect(bar.text == "T3 · No file changes · 1 shell still running in the background")
        #expect(bar.spokenText == "Turn 3, No file changes, 1 shell still running in the background")
        #expect(bar.runs.last == ReceiptRun(text: "1 shell still running in the background", role: .plain))
        #expect(bar.runs.map(\.text).joined() == bar.text)
        #expect(bar.tone == .muted, "the run is finished, and nothing waits on the person")

        let japanese = Self.model(input, locale: Self.japanese)
        #expect(japanese.text == "T3 · ファイルの変更なし · バックグラウンドでシェル 1 件が実行中")
    }

    @Test func unread_saysWhatStillRuns_afterItsReceipt() throws {
        let turn = UnreadTurn(turnID: TurnID("T6"), numbers: 6...6, changes: .changed(files: 2, added: 94, removed: 2))
        let items = Self.unreadItems(turn, runtime: "claude:run", provider: .claude)
        let item = try #require(items.first)
        let work = BackgroundWork(shells: 2, subagents: 1)
        let input = DecisionBarContent.Input(items: items, agent: Self.resting, backgroundWork: Self.ofRun(work, of: items))

        let bar = Self.model(input)
        #expect(bar.tag == "T6")
        #expect(bar.text == "2 files +94 −2 · 2 shells and 1 subagent still running in the background")
        #expect(bar.spokenText == "2 files +94 −2, 2 shells and 1 subagent still running in the background")
        #expect(bar.runs.map(\.text).joined() == bar.text)
        #expect(bar.primaryAction == .markReviewed(item.id, throughTurn: 6))
        #expect(bar.runs.last == ReceiptRun(text: "2 shells and 1 subagent still running in the background", role: .plain))

        let japanese = Self.model(input, locale: Self.japanese)
        #expect(japanese.text.hasSuffix(" · バックグラウンドでシェル 2 件、サブエージェント 1 件が実行中"))
    }

    /// A pane can hold two runs: the work one left is not said beside the
    /// other's unread turn.
    @Test(arguments: [AgentKind.claude, .codex])
    func unread_ofAnotherRun_doesNotSayIt(provider: AgentKind) {
        let turn = UnreadTurn(turnID: TurnID("T2"), numbers: 2...2, changes: .changed(files: 1, added: 3, removed: 0))
        let items = Self.unreadItems(turn, runtime: "\(provider.rawValue):reading", provider: provider)
        let input = DecisionBarContent.Input(
            items: items,
            agent: Self.resting,
            backgroundWork: .init(runtimeID: "claude:other", work: BackgroundWork(shells: 1))
        )
        let bar = Self.model(input)
        #expect(bar.tag == "T2", "the unread turn is what the bar shows")
        #expect(bar.content.backgroundWork == nil)
        #expect(bar.content.body == .unread(turn))
        #expect(bar.text == "1 file +3 −0")
    }

    @Test func everyKind_isNamed_inOrder() {
        let all = BackgroundWork(shells: 1, subagents: 2, others: 1)
        #expect(BackgroundWorkText.sentence(all, locale: Self.english)
            == "1 shell, 2 subagents, and 1 other item still running in the background")
        #expect(BackgroundWorkText.sentence(all, locale: Self.japanese)
            == "バックグラウンドでシェル 1 件、サブエージェント 2 件、作業 1 件が実行中")
        #expect(BackgroundWorkText.sentence(BackgroundWork(others: 3), locale: Self.english)
            == "3 other items still running in the background")
        #expect(BackgroundWorkText.sentence(BackgroundWork(), locale: Self.english) == nil)
    }

    @Test func withoutBackgroundWork_theReceiptIsAsItWas() {
        let turn = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let bar = Self.model(.init(agent: Self.resting, lastTurn: turn))
        #expect(bar.text == "T3 · No file changes")
        #expect(bar.content.backgroundWork == nil)
        // An empty count says nothing either.
        #expect(Self.model(.init(agent: Self.resting, lastTurn: turn, backgroundWork: Self.ofRun(BackgroundWork())))
            .text == "T3 · No file changes")
    }

    /// Read from the pane's run, the one whose last turn the bar's receipt
    /// gives, through the window's sources.
    @Test func paneBar_readsTheWorkFromThePanesRun() throws {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let conversation = TurnSummaryFixture.conversation
        let otherConversation = TurnSummaryFixture.conversation("other")
        let turn = try TurnSummaryFixture.turn("T4", number: 4)
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = "other"
        let otherTurn = try TurnSummaryFixture.turn("T9", number: 9, extras: extras)
        func bar(_ work: BackgroundWork?) -> DecisionBarModel? {
            var badge = AgentBadge(state: .finished, updatedAt: Date())
            badge.backgroundWork = work
            let runtime = AgentRuntimePresentation.test(badge: badge, paneIDs: [pane], conversation: conversation)
            let other = AgentRuntimePresentation.test(
                runID: "other",
                badge: Self.badge(.finished, backgroundWork: BackgroundWork(shells: 5)),
                paneIDs: [UUID()],
                conversation: otherConversation
            )
            var sources = DecisionBarModel.Sources(
                session: session,
                window: ProjectWindowState(selection: session.primarySelection),
                queue: AttentionQueue(),
                runtimes: [other, runtime],
                approvals: ApprovalLedger(),
                next: nil
            )
            sources.history = [conversation: [turn], otherConversation: [otherTurn]]
            return DecisionBarModel(paneID: pane, sources: sources, locale: Self.english)
        }
        #expect(bar(BackgroundWork(subagents: 1))?.text == "T4 · No file changes · 1 subagent still running in the background")
        #expect(bar(nil)?.text == "T4 · No file changes")
        #expect(bar(nil)?.content.backgroundWork == nil)
    }

    /// A request, a stop, or a line after something was done is what the
    /// person acts on; the work behind a finished turn is not said there.
    @Test func onlyATurnsReceipt_saysIt() throws {
        let fact = ApprovalFact.test()
        let prompt = PromptWait(detail: "Allow edit?")
        let approval = try #require(AttentionItem.testList([.approval(fact)], pane: Self.pane, filesRequestsByKey: true).first)
        let cases: [(AttentionItem, DecisionBarContent.Body)] = [
            (approval, .approval(provider: fact.provider, action: .other, answer: .card(heldUntil: fact.deadline))),
            (.testPrompt(prompt, pane: Self.pane), .prompt(provider: .claude, wait: prompt)),
            (.testStop(pane: Self.pane), .stopped(.processExited, resume: .unavailable))
        ]
        for (item, body) in cases {
            let items = [item]
            let work = Self.ofRun(BackgroundWork(shells: 1), of: items)
            let bar = Self.model(.init(items: items, agent: Self.resting, backgroundWork: work))
            #expect(bar.content.body == body)
            #expect(bar.content.itemID == item.id)
            #expect(bar.content.backgroundWork == nil)
        }

        let work = Self.ofRun(BackgroundWork(shells: 1))
        let summary = Self.model(.init(agent: Self.resting, backgroundWork: work))
        #expect(summary.content.body == .summary(.idle))
        #expect(summary.content.backgroundWork == nil)
        let done = Self.model(.init(agent: Self.resting, done: .init(result: .answeredInTerminal, next: nil), backgroundWork: work))
        #expect(done.content.body == .done(.answeredInTerminal, next: nil))
        #expect(done.content.backgroundWork == nil)
    }

    // MARK: - Work after a turn

    private static func badge(
        _ state: AgentState,
        runStartedAt: Date? = nil,
        backgroundWork: BackgroundWork? = nil
    ) -> AgentBadge {
        var badge = AgentBadge(state: state, runStartedAt: runStartedAt, updatedAt: Date())
        badge.backgroundWork = backgroundWork
        return badge
    }

    private static func agent(
        _ state: AgentState,
        _ work: BackgroundWork? = nil,
        provider: AgentKind = .claude,
        detail: String? = nil,
        runtimeID: String? = nil
    ) -> SessionRowFact.Agent {
        SessionRowFact.Agent(provider: provider, state: state, detail: detail, backgroundWork: work, runtimeID: runtimeID)
    }

    /// Only a finished run with work counted is at work after its turn: a
    /// turn, work outside a turn, compacting, a plain rest, and an empty
    /// count are not.
    @Test func agent_isWorkingAfterTurn_onlyFinishedWithWorkCounted() {
        #expect(Self.agent(.finished, BackgroundWork(shells: 1)).isWorkingAfterTurn)
        #expect(Self.agent(.finished, BackgroundWork(others: 2)).isWorkingAfterTurn)
        #expect(!Self.agent(.finished).isWorkingAfterTurn)
        #expect(!Self.agent(.finished, BackgroundWork()).isWorkingAfterTurn)
        for state in AgentState.allCases where state != .finished {
            #expect(!Self.agent(state, BackgroundWork(shells: 1)).isWorkingAfterTurn, "\(state)")
        }
        #expect(Self.agent(.running).state.isWorking)
        #expect(Self.agent(.compacting).state.isWorking)
        #expect(!Self.agent(.finished, BackgroundWork(shells: 1)).state.isWorking)
    }

    /// A run reaches the row's rules with its work and its id.
    @Test func rowAgent_readsTheRun() {
        let runtime = AgentRuntimePresentation.test(
            runID: "r1",
            badge: Self.badge(.finished, backgroundWork: BackgroundWork(subagents: 1))
        )
        let agent = SessionRowFact.Agent(runtime: runtime)
        #expect(agent.backgroundWork == BackgroundWork(subagents: 1))
        #expect(agent.runtimeID == runtime.id)
        #expect(agent.isWorkingAfterTurn)
    }

    private static let leftRunning = SessionRowFact.Agent(
        provider: .claude, state: .finished, detail: nil, backgroundWork: BackgroundWork(shells: 1), runtimeID: "claude:run"
    )
    private static let inATurn = SessionRowFact.Agent(provider: .codex, state: .running, detail: "Edit")
    private static let unreadTurn = UnreadTurn(
        turnID: TurnID("T2"), numbers: 2...2, changes: .changed(files: 1, added: 3, removed: 0)
    )

    private static func unreadItems(_ turn: UnreadTurn, runtime: String, provider: AgentKind) -> [AttentionItem] {
        var queue = AttentionQueue()
        queue.insert(
            id: .unread(turn.turnID),
            kind: .unread(turn),
            subject: .runtime(id: runtime, provider: provider, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        return queue.items
    }

    /// The unread turn of Claude's run in the pane.
    private static func unread(of runtimeID: String) -> [AttentionItem] {
        unreadItems(unreadTurn, runtime: runtimeID, provider: .claude)
    }

    /// Work outside a turn (running with no turn start) is the agent's own
    /// work in the foreground, such as a stop hook's continuation: a
    /// running turn, as before.
    @Test(arguments: [(AgentState.running, SessionRowFact.Fact.running(nil)), (.compacting, .compacting)])
    func row_workOutsideATurnAndCompacting_areRunning(state: AgentState, fact: SessionRowFact.Fact) {
        let runtime = AgentRuntimePresentation.test(badge: Self.badge(state))
        let agent = SessionRowFact.Agent(runtime: runtime)
        #expect(!agent.isWorkingAfterTurn)
        let row = SessionRowFact.make(.init(agents: [agent]))
        #expect(row == SessionRowFact(glyph: .running, fact: fact, badge: .agent(.claude)))
        #expect(PaneHeaderRules.mark(paneItems: [], shown: [runtime])?.glyph == .running)
    }

    /// A finished run with work left running rests with the mark of it.
    /// With no Git fact the line says what still runs, never "Idle"; a Git
    /// fact still goes first, as at any rest.
    @Test func row_finishedWithWorkLeftRunning_saysWhatStillRuns() {
        let row = SessionRowFact.make(.init(agents: [Self.leftRunning]))
        #expect(row == SessionRowFact(glyph: .workingAfterTurn, fact: .workingAfterTurn(BackgroundWork(shells: 1)), badge: .agent(.claude)))
        #expect(!SessionRowFact.repeatsGlyph(row.fact))
        #expect(SessionRowFactText.make(row.fact, locale: Self.english) == "1 shell still running in the background")
        #expect(SessionRowFactText.make(row.fact, locale: Self.japanese) == "バックグラウンドでシェル 1 件が実行中")

        let uncommitted = SessionRowFact.make(.init(agents: [Self.leftRunning], uncommittedFiles: 3))
        #expect(uncommitted.glyph == .workingAfterTurn)
        #expect(uncommitted.fact == .uncommitted(files: 3))
        // Without the work, the rest as it was.
        #expect(SessionRowFact.make(.init(agents: [Self.agent(.finished)])) == SessionRowFact(
            glyph: .idle, fact: .idle, badge: .agent(.claude)
        ))
    }

    /// An unread turn wears the unread mark of work only when its own run
    /// left the work; another run's work in the row does not mark it.
    @Test func row_unreadTurn_isMarkedWithItsOwnRunsWorkOnly() {
        let receipt = SessionRowFact.Fact.unread(.changed(files: 1, added: 3, removed: 0))
        let sameProvider = Self.agent(.finished, runtimeID: "claude:other")
        let cases: [(SessionRowFact.Agent, SessionRowFact.Glyph)] = [
            (Self.leftRunning, .unreadWorkingAfterTurn),
            (Self.agent(.finished, BackgroundWork(shells: 1), runtimeID: "claude:another"), .unread),
            (Self.agent(.finished, BackgroundWork(shells: 1)), .unread)
        ]
        for (agent, glyph) in cases {
            let row = SessionRowFact.make(.init(items: Self.unread(of: "claude:run"), agents: [sameProvider, agent]))
            #expect(row == SessionRowFact(glyph: glyph, fact: receipt, badge: .agent(.claude)))
        }

        let codex = Self.unreadItems(Self.unreadTurn, runtime: "codex:other", provider: .codex)
        let other = Self.agent(.finished, provider: .codex, runtimeID: "codex:other")
        let crossProvider = SessionRowFact.make(.init(items: codex, agents: [Self.leftRunning, other]))
        #expect(crossProvider == SessionRowFact(glyph: .unread, fact: receipt, badge: .agent(.codex)))

        let approval = AttentionItem.testList([.approval(ApprovalFact.test())], pane: Self.pane, filesRequestsByKey: true)
        let waiting = SessionRowFact.make(.init(items: Self.unread(of: "claude:run") + approval, agents: [Self.leftRunning]))
        #expect(waiting.glyph == .needsApproval)
        #expect(waiting.badge == .agent(.claude))
    }

    /// A turn in progress goes before work left running, whichever comes
    /// first, and its agent is the one the row speaks for.
    @Test func row_aTurnInProgress_goesFirst() {
        for agents in [[Self.leftRunning, Self.inATurn], [Self.inATurn, Self.leftRunning]] {
            let row = SessionRowFact.make(.init(agents: agents))
            #expect(row.glyph == .running)
            #expect(row.fact == .running("Edit"))
            #expect(row.badge == .agent(.codex))
            #expect(SessionRowFact.leadAgentIndex(of: agents).map { agents[$0] } == Self.inATurn)
        }
        let unread = SessionRowFact.make(.init(items: Self.unread(of: "claude:run"), agents: [Self.leftRunning, Self.inATurn]))
        #expect(unread.glyph == .running)
    }

    /// Of agents at rest, the one with work left running is the one the row
    /// speaks for, so the mark and the line are the same agent's.
    @Test func row_leadAgent_isTheOneWithWorkLeftRunning() {
        let resting = Self.agent(.finished, provider: .codex)
        let agents = [resting, Self.leftRunning]
        #expect(SessionRowFact.leadAgentIndex(of: agents) == 1)
        let row = SessionRowFact.make(.init(agents: agents))
        #expect(row.glyph == .workingAfterTurn)
        #expect(row.badge == .agent(.claude))
        #expect(SessionRowFact.leadAgentIndex(of: [resting]) == 0)
        #expect(SessionRowFact.leadAgentIndex(of: []) == nil)
    }

    /// The pane's header and its tab mark work left running too: a tab
    /// never shows unread, so it shows the work alone, and a run in any of
    /// its panes still goes first.
    @Test func paneHeaderAndTab_markWorkLeftRunning() {
        let pane = UUID()
        let left = AgentRuntimePresentation.test(badge: Self.badge(.finished, backgroundWork: BackgroundWork(shells: 1)), paneIDs: [pane])
        #expect(PaneHeaderRules.mark(paneItems: [], shown: [left])?.glyph == .workingAfterTurn)
        let rest = AgentRuntimePresentation.test(badge: Self.badge(.finished), paneIDs: [pane])
        #expect(PaneHeaderRules.mark(paneItems: [], shown: [rest]) == nil)

        #expect(PaneStripModel.tabGlyph([.unreadWorkingAfterTurn], items: []) == .workingAfterTurn)
        #expect(PaneStripModel.tabGlyph([.workingAfterTurn], items: []) == .workingAfterTurn)
        #expect(PaneStripModel.tabGlyph([.workingAfterTurn, .running], items: []) == .running)
        #expect(PaneStripModel.tabGlyph([.unread], items: []) == nil)
    }

    /// Each name in English and Japanese, said the same by the row's words
    /// and the glyph's label.
    @Test func names_inEnglishAndJapanese() {
        let names: [SessionRowFact.Glyph: (english: String, japanese: String)] = [
            .workingAfterTurn: ("Working in the background", "バックグラウンドで作業中"),
            .unreadWorkingAfterTurn: ("Unread, working in the background", "未読、バックグラウンドで作業中")
        ]
        for (glyph, (english, japanese)) in names {
            #expect(SessionRowFactText.stateName(glyph, locale: Self.english) == english)
            #expect(SessionRowFactText.stateName(glyph, locale: Self.japanese) == japanese)
            #expect(StateGlyph.Kind(glyph).name.resolved(in: Self.english) == english)
            #expect(StateGlyph.Kind(glyph).name.resolved(in: Self.japanese) == japanese)
        }
    }

    /// The all projects sheet holds the run finished, as the attention list
    /// does: work left running is at rest, its unread turn needs the person.
    @Test func allProjectsSections() {
        #expect(AllProjectsModel.Section.of(.unreadWorkingAfterTurn) == .needsAttention)
        #expect(AllProjectsModel.Section.of(.workingAfterTurn) == .idle)
    }
}
