// SessionRowFactTests.swift
// Weir — a session row shows the agent that most needs the person, in one order for the app.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct SessionRowFactTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()

    private static func queue(_ kinds: [AttentionItemKind], provider: AgentKind = .claude) -> [AttentionItem] {
        var queue = AttentionQueue()
        for (index, kind) in kinds.enumerated() {
            let agent = kind.approvalFact?.provider ?? provider
            let run = "\(agent.rawValue):r\(index)"
            let episode = EpisodeKey(origin: .runtime(run), episodeToken: "1")
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
                subject: .runtime(id: run, provider: agent, paneID: pane, tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        return queue.items
    }

    private static let unread = AttentionItemKind.unread(
        UnreadTurn(turnID: TurnID("t"), changes: .changed(files: 2, added: 94, removed: 2))
    )

    @Test func theRowUsesTheHighestPriorityItemAndItsCompleteFact() {
        let question = ApprovalFact.test(isQuestion: true, provider: .codex, supportsNativeAnswer: false)
        let approval = ApprovalFact.test()
        let items = Self.queue([Self.unread, .stop(.processExited), .approval(approval), .question(question)])
        let expected: [SessionRowFact] = [
            .init(glyph: .unread, fact: .unread(.changed(files: 2, added: 94, removed: 2)), badge: .agent(.claude)),
            .init(glyph: .stopped, fact: .stopped(.processExited), badge: .agent(.claude)),
            .init(glyph: .needsApproval, fact: .approval("swift test"), badge: .agent(.claude)),
            .init(glyph: .needsAnswer, fact: .question("Which branch?"), badge: .agent(.codex))
        ]
        for (index, row) in expected.enumerated() {
            let fact = SessionRowFact.make(.init(
                items: Array(items.prefix(index + 1)),
                requestText: [question.key: "Which branch?", approval.key: "swift test"]
            ))
            #expect(fact == row)
        }
    }

    @Test(arguments: [
        (
            PromptWait(detail: "Bash: swift test"),
            SessionRowFact.Glyph.needsApproval,
            "Waiting for approval: swift test",
            "承認待ち：swift test"
        ),
        (
            PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor"),
            .needsApproval,
            "Waiting for approval: Monitor",
            "承認待ち：Monitor"
        ),
        (.question(detail: "Which color?"), .needsAnswer, "Question: Which color?", "質問：Which color?"),
        (.question(detail: nil), .needsAnswer, "Needs answer", "回答待ち"),
        (.unclassified(detail: "Which color?"), .needsResponse, "Needs response: Which color?", "応答待ち：Which color?")
    ])
    func aPromptWithoutARequest_hasItsOwnGlyphFactAndLocalizedWording(
        wait: PromptWait,
        glyph: SessionRowFact.Glyph,
        english: String,
        japanese: String
    ) {
        let row = SessionRowFact.make(.init(items: Self.queue([.prompt(wait)], provider: .codex)))
        #expect(row == SessionRowFact(glyph: glyph, fact: .prompt(wait), badge: .agent(.codex)))
        #expect(SessionRowFactText.make(row.fact, locale: Self.english) == english)
        #expect(SessionRowFactText.make(row.fact, locale: Self.japanese) == japanese)
        if glyph == .needsResponse {
            #expect(SessionRowFactText.stateName(row.glyph, locale: Self.japanese) == "応答待ち")
        }
    }

    @Test(arguments: [
        ("Write: /Users/me/repo/notes.txt", "Waiting for approval: notes.txt", "承認待ち：notes.txt"),
        ("Bash: swift   test", "Waiting for approval: swift test", "承認待ち：swift test"),
        ("Bash", "Waiting for approval: Bash", "承認待ち：Bash"),
        ("permission", "Needs approval", "承認待ち"),
        ("Which color?", "Needs response: Which color?", "応答待ち：Which color?"),
        (String?.none, "Needs response", "応答待ち")
    ])
    func aWaitWithNoRequest_isWordedAsAnApproval_orAWaitForAResponse(detail: String?, english: String, japanese: String) {
        let fact = SessionRowFact.Fact.prompt(PromptWait(detail: detail))
        #expect(SessionRowFactText.make(fact, locale: Locale(identifier: "en")) == english)
        #expect(SessionRowFactText.make(fact, locale: Locale(identifier: "ja")) == japanese)
    }

    @Test func withNothingWaiting_aRunningAgent_showsWhatItIsDoing() {
        let fact = SessionRowFact.make(.init(agents: [
            .init(provider: .claude, state: .idle, detail: nil),
            .init(provider: .codex, state: .running, detail: "Bash: swift test")
        ]))
        #expect(fact == SessionRowFact(glyph: .running, fact: .running("Bash: swift test"), badge: .agent(.codex)))
        #expect(SessionRowFact.make(.init(agents: [.init(provider: .claude, state: .compacting, detail: nil)])).fact == .compacting)
    }

    struct AttachedCase: Sendable, CustomTestStringConvertible {
        let items: [AttentionItemKind]
        let state: AgentState?
        let glyph: SessionRowFact.Glyph
        let fact: SessionRowFact.Fact
        var backgroundWork: BackgroundWork?
        var putsPullRequestOnSecondLine = false

        var testDescription: String {
            "\(glyph)"
        }
    }

    private static let work = BackgroundWork(shells: 1)
    private static let response = PromptWait.unclassified(detail: nil)

    @Test(arguments: [
        AttachedCase(items: [.approval(ApprovalFact.test())], state: .idle, glyph: .needsApproval, fact: .approval(nil)),
        AttachedCase(items: [.question(ApprovalFact.test(isQuestion: true))], state: .idle, glyph: .needsAnswer, fact: .question(nil)),
        AttachedCase(items: [.prompt(response)], state: .needsInput, glyph: .needsResponse, fact: .prompt(response)),
        AttachedCase(items: [.prompt(.signIn)], state: .needsInput, glyph: .needsSignIn, fact: .prompt(.signIn)),
        AttachedCase(items: [.stop(.processExited)], state: .error, glyph: .stopped, fact: .stopped(.processExited)),
        AttachedCase(items: [unread], state: .finished, glyph: .unread, fact: .unread(.changed(files: 2, added: 94, removed: 2))),
        AttachedCase(
            items: [unread],
            state: .finished,
            glyph: .unreadWorkingAfterTurn,
            fact: .unread(.changed(files: 2, added: 94, removed: 2)),
            backgroundWork: work
        ),
        AttachedCase(items: [], state: .running, glyph: .running, fact: .running(nil)),
        AttachedCase(
            items: [],
            state: .finished,
            glyph: .workingAfterTurn,
            fact: .workingAfterTurn(work),
            backgroundWork: work,
            putsPullRequestOnSecondLine: true
        ),
        AttachedCase(items: [], state: .idle, glyph: .idle, fact: .idle, putsPullRequestOnSecondLine: true),
        AttachedCase(items: [], state: .unknown, glyph: .unknown, fact: .unknown, putsPullRequestOnSecondLine: true),
        AttachedCase(items: [], state: nil, glyph: .shell, fact: .idle, putsPullRequestOnSecondLine: true)
    ])
    func everyState_keepsItsGlyph_andShowsThePullRequestOnlyWhenThereIsOne(_ test: AttachedCase) {
        let items = Self.queue(test.items)
        let agents = test.state.map {
            [SessionRowFact.Agent(provider: .claude, state: $0, detail: nil, backgroundWork: test.backgroundWork, runtimeID: "claude:r0")]
        } ?? []
        let badge: SessionRowFact.Badge = test.state == nil ? .shell : .agent(.claude)
        let without = SessionRowFact.make(.init(items: items, agents: agents))
        #expect(without == SessionRowFact(glyph: test.glyph, fact: test.fact, badge: badge))

        let requests = [
            SessionRowFact.PullRequest(number: 128, state: .open, isDraft: false),
            SessionRowFact.PullRequest(number: 7, state: .merged, isDraft: false)
        ]
        for request in requests {
            let with = SessionRowFact.make(.init(items: items, agents: agents, pullRequest: request))
            let withFact: SessionRowFact.Fact = test.putsPullRequestOnSecondLine
                ? .pullRequest(number: request.number, state: request.state, isDraft: request.isDraft)
                : test.fact
            #expect(with == SessionRowFact(glyph: test.glyph, fact: withFact, badge: badge, pullRequest: request))
        }
    }

    /// The glyph and the line agree: an agent not matched yet is unknown
    /// in both, never an unknown mark over "Idle".
    @Test func agentsNotMatchedYet_readAsUnknown_notIdle() {
        let fact = SessionRowFact.make(.init(agents: [.init(provider: .claude, state: .unknown, detail: nil)]))
        #expect(fact.glyph == .unknown)
        #expect(fact.fact == .unknown)
        #expect(SessionRowFactText.make(fact.fact, locale: Self.english) == "Unknown")
        #expect(SessionRowFactText.make(fact.fact, locale: Self.japanese) == "不明")
        #expect(SessionRowFactText.stateName(fact.glyph, locale: Self.japanese) == "不明")
    }

    /// One agent matched is enough for the row to be at rest; a Git fact
    /// still takes the line from the unknown state, as it does from idle.
    @Test func anUnknownRow_statesItsGitFact_andOneMatchedAgentMakesItIdle() {
        let unknown = SessionRowFact.Agent(provider: .claude, state: .unknown, detail: nil)
        let uncommitted = SessionRowFact.make(.init(agents: [unknown], uncommittedFiles: 3))
        #expect(uncommitted.glyph == .unknown)
        #expect(uncommitted.fact == .uncommitted(files: 3))
        let mixed = SessionRowFact.make(.init(agents: [unknown, .init(provider: .codex, state: .idle, detail: nil)]))
        #expect(mixed.glyph == .idle)
        #expect(mixed.fact == .idle)
        // A row with no agent is never unknown: the shell has no state.
        #expect(SessionRowFact.make(.init()).fact == .idle)
    }

    // MARK: - A pane's glyph

    /// The adapter maps each row glyph to the corresponding icon kind.
    /// The shell's icon is selected separately by its view.
    @Test(arguments: [
        (SessionRowFact.Glyph.needsAnswer, StateGlyph.Kind.needsAnswer),
        (.needsApproval, .needsApproval),
        (.needsResponse, .needsResponse),
        (.needsSignIn, .needsSignIn),
        (.stopped, .stopped),
        (.unread, .unread),
        (.unreadWorkingAfterTurn, .unreadWorkingAfterTurn),
        (.running, .running),
        (.idle, .idle),
        (.workingAfterTurn, .workingAfterTurn),
        (.unknown, .unknown),
        (.shell, .unknown)
    ])
    func rowGlyphs_mapToStateIconKinds(glyph: SessionRowFact.Glyph, kind: StateGlyph.Kind) {
        #expect(StateGlyph.Kind(glyph) == kind)
    }

    /// A pane header wears what the row of a session holding only that pane
    /// wears, through the row's own function: a running agent over an
    /// unread turn, an unread turn over a resting agent, a wait over a
    /// running one, and two runs in one pane weighed as the row weighs them.
    struct PaneCase: Sendable {
        let items: [AttentionItemKind]
        let states: [AgentState]
        let kind: StateGlyph.Kind
        var hasHeaderMark = true
    }

    @Test(arguments: [
        PaneCase(items: [Self.unread], states: [.running], kind: .running),
        PaneCase(items: [Self.unread], states: [.idle], kind: .unread),
        PaneCase(items: [.approval(ApprovalFact.test())], states: [.running], kind: .needsApproval),
        PaneCase(items: [.question(ApprovalFact.test(isQuestion: true))], states: [.needsInput], kind: .needsAnswer),
        PaneCase(items: [.prompt(PromptWait(detail: nil))], states: [.needsInput], kind: .needsResponse),
        PaneCase(items: [.stop(.processExited)], states: [.error], kind: .stopped),
        PaneCase(items: [], states: [.running], kind: .running),
        PaneCase(items: [], states: [.compacting], kind: .running),
        PaneCase(items: [], states: [.finished], kind: .idle, hasHeaderMark: false),
        PaneCase(items: [], states: [.idle], kind: .idle, hasHeaderMark: false),
        PaneCase(items: [], states: [.unknown], kind: .unknown, hasHeaderMark: false),
        // Two runs in one pane: a finished Claude beside a running Codex,
        // and a stop beside a running run.
        PaneCase(items: [], states: [.finished, .running], kind: .running),
        PaneCase(items: [Self.unread], states: [.finished, .running], kind: .running),
        PaneCase(items: [.stop(.processExited)], states: [.error, .running], kind: .stopped),
        PaneCase(items: [], states: [.unknown, .running], kind: .running)
    ])
    func aPanesGlyph_isTheGlyphOfItsOnePaneRow(_ test: PaneCase) {
        let providers: [AgentKind] = [.claude, .codex]
        let runtimes = test.states.enumerated().map { index, state in
            AgentRuntimePresentation.test(
                kind: providers[index % providers.count],
                runID: "r\(index)",
                badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: TimeInterval(index))),
                paneIDs: [Self.pane]
            )
        }
        let items = Self.queue(test.items)
        let row = SessionRowFact.make(.init(items: items, agents: runtimes.map(SessionRowFact.Agent.init(runtime:))))
        let mark = PaneHeaderRules.mark(paneItems: items, shown: runtimes)

        #expect(StateGlyph.Kind(row.glyph) == test.kind)
        #expect(mark.map { StateGlyph.Kind($0.glyph) } == (test.hasHeaderMark ? test.kind : nil))
    }

    @Test func atRest_theSecondLineStatesUncommittedFiles_elseThePullRequest_elseCommits_elseNoChanges() {
        let agent = SessionRowFact.Agent(provider: .claude, state: .idle, detail: nil)
        let pullRequest = SessionRowFact.PullRequest(number: 7, state: .open, isDraft: false)
        func fact(_ request: SessionRowFact.PullRequest?, uncommitted: Int, commits: Int, isKnown: Bool = true) -> SessionRowFact {
            SessionRowFact.make(.init(
                agents: [agent],
                pullRequest: request,
                uncommittedFiles: uncommitted,
                proposedCommits: commits,
                hasGitFacts: isKnown
            ))
        }
        // What is not committed goes before the request, whose mark stays.
        let both = fact(pullRequest, uncommitted: 2, commits: 3)
        #expect(both.fact == .uncommitted(files: 2))
        #expect(both.pullRequest == pullRequest)
        #expect(fact(pullRequest, uncommitted: 0, commits: 3).fact == .pullRequest(number: 7, state: .open, isDraft: false))
        #expect(fact(nil, uncommitted: 2, commits: 3) == SessionRowFact(glyph: .idle, fact: .uncommitted(files: 2), badge: .agent(.claude)))
        #expect(fact(nil, uncommitted: 0, commits: 3).fact == .commits(3))
        #expect(fact(nil, uncommitted: 0, commits: 0).fact == .noChanges)
        // Facts not read yet claim nothing: the line names the rest.
        #expect(fact(nil, uncommitted: 0, commits: 0, isKnown: false).fact == .idle)
        let shell = SessionRowFact.make(.init(hasGitFacts: true))
        #expect(shell == SessionRowFact(glyph: .shell, fact: .noChanges, badge: .shell))
        // Not while something needs the person or the agent runs.
        let running = SessionRowFact.make(.init(
            agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")],
            uncommittedFiles: 2
        ))
        #expect(running.fact == .running("Bash: swift test"))
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(SessionRowFactText.make(.uncommitted(files: 2), locale: english) == "2 files uncommitted")
        #expect(SessionRowFactText.make(.uncommitted(files: 1), locale: english) == "1 file uncommitted")
        #expect(SessionRowFactText.make(.uncommitted(files: 6), locale: japanese) == "未コミット 6 ファイル")
        #expect(SessionRowFactText.make(.commits(1), locale: english) == "+1 commit")
        #expect(SessionRowFactText.make(.commits(3), locale: japanese) == "+3 コミット")
        #expect(SessionRowFactText.make(.noChanges, locale: english) == "No changes")
        #expect(SessionRowFactText.make(.noChanges, locale: japanese) == "変更なし")
    }

    // MARK: - The second line's words

    @Test func secondLines_sayEachFact() {
        #expect(SessionRowFactText.make(.question("Which branch?"), locale: Self.japanese) == "質問：Which branch?")
        #expect(SessionRowFactText
            .make(.unread(.changed(files: 2, added: 9, removed: 1)), locale: Self.english) == "Unread · 2 files changed")
        #expect(SessionRowFactText.make(.unread(.unchanged), locale: Self.japanese) == "未読 · ファイルの変更なし")
        #expect(SessionRowFactText.make(.unread(.unknown), locale: Self.english) == "Unread")
        #expect(SessionRowFactText.make(.pullRequest(number: 128, state: .open, isDraft: false), locale: Self.english) == "PR #128 · Open")
        #expect(SessionRowFactText.make(.pullRequest(number: 128, state: .open, isDraft: true), locale: Self.japanese) == "PR #128 · ドラフト")
        #expect(SessionRowFactText.make(.stopped(.processExited), locale: Self.japanese) == "停止：プロセスが異常終了しました。")
        #expect(SessionRowFactText.badge(.agent(.codex), locale: Self.english) == "Cx")
        #expect(SessionRowFactText.badge(.agent(.claude), locale: Self.japanese) == "Cl")
        for locale in [Self.english, Self.japanese] {
            #expect(SessionRowFactText.badge(.shell, locale: locale).isEmpty)
        }
    }

    @Test func theTime_isTheLargestWholeUnit_inTheUnitsATurnsDurationHas() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func elapsed(_ seconds: TimeInterval, _ locale: Locale = Self.english) -> String {
            SessionRowFactText.elapsed(since: now.addingTimeInterval(-seconds), now: now, locale: locale)
        }
        #expect(elapsed(12 * 60) == "12m")
        #expect(elapsed(3 * 3600 + 60) == "3h")
        #expect(elapsed(2 * 86400 + 3600) == "2d")
        #expect(elapsed(0) == "now")
        // A clock that went back reads as no time, not a negative one.
        #expect(elapsed(-60) == "now")
        // Rounded down, as the tooltip's minutes are.
        #expect(elapsed(12 * 60 + 40) == "12m")
        #expect(elapsed(59 * 60 + 30) == "59m")
        #expect(elapsed(3 * 3600 + 59 * 60) == "3h")
        // Japanese says its units, as a turn card's duration does.
        #expect(elapsed(12 * 60, Self.japanese) == "12分")
        #expect(elapsed(3 * 3600, Self.japanese) == "3時間")
        #expect(elapsed(2 * 86400, Self.japanese) == "2日")
        #expect(elapsed(30, Self.japanese) == "今")
        #expect(ChangesPanelText.compactDuration(12 * 60, locale: Self.japanese) == elapsed(12 * 60, Self.japanese))
    }

}
