// NeedsAttentionListModelTests.swift
// Weir — the Needs Attention list's rows: their facts and their buttons.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct NeedsAttentionListModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    private static func runtime(_ name: String, provider: AgentKind = .claude) -> AttentionSubject {
        .runtime(id: name, provider: provider, paneID: UUID(), tabID: nil, projectID: nil)
    }

    private struct Entry {
        let id: AttentionItemID
        let kind: AttentionItemKind
        let subject: AttentionSubject

        init(_ id: AttentionItemID, _ kind: AttentionItemKind, _ subject: AttentionSubject) {
            self.id = id
            self.kind = kind
            self.subject = subject
        }
    }

    /// The items in the order given; the first arrives first.
    private static func queue(_ entries: [Entry], arrivalTimes: [TimeInterval]? = nil) -> AttentionQueue {
        var queue = AttentionQueue()
        for (offset, entry) in entries.enumerated() {
            queue.insert(
                id: entry.id,
                kind: entry.kind,
                subject: entry.subject,
                arrivedAt: Date(timeIntervalSince1970: arrivalTimes?[offset] ?? TimeInterval(offset))
            )
        }
        return queue
    }

    private static func episode(_ name: String) -> EpisodeKey {
        EpisodeKey(origin: .runtime(name), episodeToken: "1")
    }

    private static func model(
        _ queue: AttentionQueue,
        requests: [ApprovalKey: NeedsAttentionListModel.RequestText] = [:],
        locale: Locale = english,
        sharedTitle: String? = nil
    ) -> NeedsAttentionListModel {
        NeedsAttentionListModel(
            items: queue.items,
            names: { item in
                NeedsAttentionListModel.Names(title: sharedTitle ?? "session \(item.arrivalSequence)", place: "weir")
            },
            request: { requests[$0] },
            windowProjectID: nil,
            locale: locale
        )
    }

    // MARK: - Rows

    @Test func everyItem_isOneRow_inArrivalOrder_underTheCount() {
        let approval = ApprovalFact.test()
        let queue = Self.queue([
            Entry(.stop(Self.episode("a")), .stop(.error("boom")), Self.runtime("a")),
            Entry(.approval(approval.key), .approval(approval), Self.runtime("b")),
            Entry(
                .unread(TurnID("c#1")),
                .unread(UnreadTurn(turnID: TurnID("c#1"), changes: .unknown)),
                Self.runtime("c")
            )
        ], arrivalTimes: [60, 10, 10])
        let model = Self.model(queue)

        #expect(model.rows.map(\.id) == [.stop(Self.episode("a")), .approval(approval.key), .unread(TurnID("c#1"))])
        #expect(model.rows.map(\.arrivedAt.timeIntervalSince1970) == [60, 10, 10])
        #expect(model.count == 3)
        #expect(model.rows.map(\.state) == [.stopped, .approval, .unread])
        #expect(model.rows.map(\.title) == ["session 1", "session 2", "session 3"])
        #expect(model.heading.resolved(in: Self.english) == "Needs Attention 3 · All Projects · In Order of Arrival")
        #expect(model.heading.resolved(in: Self.japanese) == "要対応 3 · 全プロジェクト · 到着順")
    }

    /// An empty list has no count, reach, or order to tell, and its empty
    /// state says the rest: the heading is only the list's name.
    @Test func anEmptyList_isHeadedByItsNameAlone() {
        let model = Self.model(Self.queue([]))

        #expect(model.rows.isEmpty)
        #expect(model.count == 0)
        #expect(model.heading.resolved(in: Self.english) == "Needs Attention")
        #expect(model.heading.resolved(in: Self.japanese) == "要対応")
    }

    @Test func anUnreadRow_namesItsTurns_andWhatTheyChanged() {
        let changed = UnreadTurn(
            turnID: TurnID("T6"),
            numbers: 6...7,
            changes: .changed(files: 2, added: 94, removed: 2),
            conversation: TurnSummaryFixture.conversation
        )
        let answered = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let queue = Self.queue([
            Entry(.unread(changed.turnID), .unread(changed), Self.runtime("a")),
            Entry(.unread(answered.turnID), .unread(answered), Self.runtime("b"))
        ])

        #expect(Self.model(queue).rows.map(\.fact) == ["T6–T7 Unread · 2 files +94 −2", "T3 Unread · No file changes"])
        #expect(Self.model(queue, locale: Self.japanese).rows.map(\.fact) == ["T6〜T7 未読 · 2 ファイル +94 −2", "T3 未読 · ファイルの変更なし"])
        #expect(Self.model(queue).rows.map(\.spokenDetail)
            == ["weir, Turns 6 to 7, Unread, 2 files +94 −2", "weir, Turn 3, Unread, No file changes"])
        #expect(Self.model(queue, locale: Self.japanese).rows.map(\.spokenDetail)
            == ["weir、ターン 6 から 7、未読、2 ファイル +94 −2", "weir、ターン 3、未読、ファイルの変更なし"])
    }

    /// The list, not a row, holds the keyboard, so the row the keys are on
    /// is the list's value: VoiceOver hears it as the row reads, with the
    /// fact that says its state, so a stop is told from a request without
    /// the glyph's color.
    @Test(arguments: [
        (english, [
            "Shared title, Claude, weir, Waiting for approval: swift test",
            "Shared title, Claude, weir, Stopped: Rate limited",
            "Shared title, Claude, weir, Needs sign-in"
        ]),
        (japanese, [
            "Shared title、Claude、weir、承認待ち：swift test",
            "Shared title、Claude、weir、停止：Rate limited",
            "Shared title、Claude、weir、サインイン待ち"
        ])
    ])
    func theListsValue_saysTheRowsState(locale: Locale, expected: [String]) {
        let approval = ApprovalFact.test()
        let queue = Self.queue([
            Entry(.approval(approval.key), .approval(approval), Self.runtime("a")),
            Entry(.stop(Self.episode("b")), .stop(.error("Rate limited")), Self.runtime("b")),
            Entry(.prompt(Self.episode("c")), .prompt(.signIn), Self.runtime("c"))
        ])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: nil, toolName: "Bash")
        let rows = Self.model(queue, requests: [approval.key: request], locale: locale, sharedTitle: "Shared title").rows
        var selection = NeedsAttentionListSelection(rows: rows)
        let ids: [AttentionItemID] = [.approval(approval.key), .stop(Self.episode("b")), .prompt(Self.episode("c"))]
        #expect(rows.map(\.title) == Array(repeating: "Shared title", count: ids.count))
        for (id, spoken) in zip(ids, expected) {
            #expect(selection.rowID == id)
            #expect(selection.spokenRow(in: rows, locale: locale) == spoken)
            selection.move(forward: true, in: rows)
        }
    }

    @Test func anApprovalWeirStillHolds_offersAnswer_andNamesItsCommand() {
        let approval = ApprovalFact.test()
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), Self.runtime("a"))])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: nil, toolName: "Bash")
        let model = Self.model(queue, requests: [approval.key: request])

        #expect(model.rows.map(\.id) == [.approval(approval.key)])
        #expect(model.rows.map(\.state) == [.approval])
        #expect(model.rows.first?.action == .answer(approval.key))
        #expect(model.rows.first?.fact == "Waiting for approval: swift test")
        #expect(Self.model(queue, requests: [approval.key: request], locale: Self.japanese).rows.first?.fact == "承認待ち：swift test")
    }

    enum RequestScenario: Sendable {
        case placedApproval
        case placedQuestion
        case unplacedApproval
        case approvalRetry
    }

    @Test(arguments: [
        (ApprovalRequestState.handedToTerminal(since: SuspendingClock().now), RequestScenario.placedApproval),
        (.handedToTerminal(since: SuspendingClock().now), .placedQuestion),
        (.timedOut, .placedApproval),
        (.timedOut, .placedQuestion),
        (.timedOut, .unplacedApproval),
        (.sending(.allowOnce, since: SuspendingClock().now), .placedApproval),
        (.sendFailed(.allowOnce, error: "gone"), .approvalRetry)
    ])
    func aRequestState_controlsItsAnswerAction(_ state: ApprovalRequestState, scenario: RequestScenario) {
        let isQuestion = scenario == .placedQuestion
        let fact = ApprovalFact.test(isQuestion: isQuestion, state: state)
        let kind: AttentionItemKind = isQuestion ? .question(fact) : .approval(fact)
        let id: AttentionItemID = isQuestion ? .question(fact.key) : .approval(fact.key)
        let subject: AttentionSubject = scenario == .unplacedApproval ? .unplaced(provider: .claude) : Self.runtime("a")
        let queue = Self.queue([Entry(id, kind, subject)])
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: "Which branch?", toolName: "Bash")

        let rows = Self.model(queue, requests: [fact.key: request]).rows
        #expect(rows.map(\.id) == [id])
        #expect(rows.map(\.state) == [isQuestion ? .question : .approval])
        #expect(rows.map(\.fact) == [isQuestion ? "Question: Which branch?" : "Waiting for approval: swift test"])
        #expect(rows.map(\.action) == [scenario == .approvalRetry ? .answer(fact.key) : nil])
    }

    @Test func aWaitAtTheAgentsPrompt_aStop_andAnUnreadTurn_offerNoButton() {
        let queue = Self.queue([
            Entry(.prompt(Self.episode("a")), .prompt(PromptWait(detail: nil)), Self.runtime("a")),
            Entry(.stop(Self.episode("b")), .stop(.processExited), Self.runtime("b")),
            Entry(
                .unread(TurnID("c#1")),
                .unread(UnreadTurn(turnID: TurnID("c#1"), changes: .unknown)),
                Self.runtime("c")
            )
        ])

        let rows = Self.model(queue).rows
        #expect(rows.map(\.id) == [.prompt(Self.episode("a")), .stop(Self.episode("b")), .unread(TurnID("c#1"))])
        #expect(rows.map(\.state) == [.response, .stopped, .unread])
        #expect(rows.map(\.action) == [nil, nil, nil])
    }

    @Test func aRequestTheLedgerForgot_offersNoCard_andSaysWhatItWaitsFor() {
        let approval = ApprovalFact.test()
        let queue = Self.queue([Entry(.approval(approval.key), .approval(approval), Self.runtime("a"))])
        let other = ApprovalFact.test()
        let request = NeedsAttentionListModel.RequestText(summary: "swift test", question: nil, toolName: "Bash")
        let missing = Self.model(queue, requests: [other.key: request]).rows

        #expect(missing.map(\.id) == [.approval(approval.key)])
        #expect(missing.map(\.state) == [.approval])
        #expect(missing.map(\.action) == [nil])
        #expect(missing.map(\.fact) == ["Needs approval"])
        let held = Self.model(queue, requests: [approval.key: request, other.key: request]).rows
        #expect(held.map(\.action) == [.answer(approval.key)])
        #expect(held.map(\.fact) == ["Waiting for approval: swift test"])
    }

    @Test func aClaudeQuestion_offersAnswer_andACodexQuestion_offersNoButton() {
        let claude = ApprovalFact.test(isQuestion: true)
        let codex = ApprovalFact.test(isQuestion: true, provider: .codex)
        let unplacedCodex = ApprovalFact.test(isQuestion: true, provider: .codex)
        let queue = Self.queue([
            Entry(.question(claude.key), .question(claude), Self.runtime("a")),
            Entry(.question(codex.key), .question(codex), Self.runtime("b", provider: .codex)),
            Entry(.question(unplacedCodex.key), .question(unplacedCodex), .unplaced(provider: .codex))
        ])
        let question = NeedsAttentionListModel.RequestText(summary: nil, question: "Which branch?", toolName: "AskUserQuestion")
        let model = Self.model(queue, requests: [claude.key: question, codex.key: question, unplacedCodex.key: question])

        #expect(model.rows.map(\.id) == [.question(claude.key), .question(codex.key), .question(unplacedCodex.key)])
        #expect(model.rows.map(\.agent) == [.claude, .codex, .codex])
        #expect(model.rows.map(\.action) == [.answer(claude.key), nil, nil])
        #expect(model.rows.map(\.state) == [.question, .question, .question])
        #expect(model.rows.map(\.fact) == Array(repeating: "Question: Which branch?", count: 3))
    }

    @Test func aWaitAtTheAgentsPrompt_isListedAsTheSessionRowWordsIt() {
        let queue = Self.queue([
            Entry(.prompt(Self.episode("a")), .prompt(PromptWait(detail: "Claude needs your permission to use Bash")), Self.runtime("a")),
            Entry(.prompt(Self.episode("b")), .prompt(PromptWait(detail: "Edit: /repo/Sources/App.swift")), Self.runtime("b")),
            Entry(.prompt(Self.episode("c")), .prompt(PromptWait(detail: nil)), Self.runtime("c")),
            Entry(.prompt(Self.episode("d")), .prompt(.question(detail: "Which branch?")), Self.runtime("d")),
            Entry(.prompt(Self.episode("e")), .prompt(.signIn), Self.runtime("e"))
        ])
        let model = Self.model(queue)

        #expect(model.rows.map(\.state) == [.approval, .approval, .response, .question, .signIn])
        #expect(model.rows.map(\.fact) == [
            "Waiting for approval: Bash",
            "Waiting for approval: App.swift",
            "Needs response",
            "Question: Which branch?",
            "Needs sign-in"
        ])
        // Weir holds none of them, so each is answered in its pane, which
        // the row itself goes to.
        #expect(model.rows.map(\.action) == [nil, nil, nil, nil, nil])
    }

    @Test func aStop_saysWhy_inTheListsLanguage() {
        let queue = Self.queue([
            Entry(.stop(Self.episode("a")), .stop(.processExited), Self.runtime("a")),
            Entry(.stop(Self.episode("b")), .stop(.error("rate limited")), Self.runtime("b")),
            Entry(.stop(Self.episode("c")), .stop(.error(nil)), Self.runtime("c"))
        ])

        #expect(Self.model(queue).rows.map(\.fact) == [
            "Stopped: The process exited unexpectedly.",
            "Stopped: rate limited",
            "Stopped"
        ])
        #expect(Self.model(queue, locale: Self.japanese).rows.map(\.fact) == [
            "停止：プロセスが異常終了しました。",
            "停止：rate limited",
            "停止"
        ])
    }

    @Test @MainActor func aPlacedItem_usesItsRowName_andUnresolvedItemsUseTheAgentName() throws {
        let root = WorkspaceSessionFixture.projectRootURL("naming").appendingPathComponent("sandbox-folder")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir", rootURL: root)
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let approval = ApprovalFact.test(provider: .opencode)
        let queue = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            ),
            Entry(.approval(approval.key), .approval(approval), .unplaced(provider: .opencode)),
            Entry(
                .stop(Self.episode("c")),
                .stop(.processExited),
                .runtime(id: "c", provider: .opencode, paneID: UUID(), tabID: UUID(), projectID: project.id)
            )
        ])

        let expected = [
            NeedsAttentionListModel.Names(title: "sandbox-folder", place: "weir"),
            NeedsAttentionListModel.Names(title: "OpenCode", place: nil),
            NeedsAttentionListModel.Names(title: "OpenCode", place: nil)
        ]
        for locale in [Self.english, Self.japanese] {
            #expect(queue.items.map { NeedsAttentionListModel.names(of: $0, in: session, locale: locale) } == expected)
        }
    }

    @Test @MainActor func aPanesItem_isNamedAsItsSidebarRowIs_notByTheTerminalsTitle() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        // The agent's OSC 2 title, and the conversation the row is named by.
        session.update(tab.id) {
            $0.title = "✳ claude --continue"
            $0.conversationName = ConversationName(
                name: "Add tests",
                provider: .claude,
                paneID: paneID,
                conversationID: "c1",
                startedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let item = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            )
        ]).items[0]

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "Add tests", place: "weir"))
    }

    /// A worktree's item is named as its row is and placed by its project:
    /// the row's name is not said twice, as "weir / feat-x" after it.
    @Test @MainActor func aWorktreesItem_isNamedAsItsRow_andPlacedByItsProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let folder = WorkspaceSessionFixture.projectRootURL("trees").appendingPathComponent("review-folder")
        let worktree = WorktreeFixture.make(workingDirectory: folder, admission: .created)
        let projectIndex = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[projectIndex].worktrees.append(worktree)
        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: worktree.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let item = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            )
        ]).items[0]

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "review-folder", place: "weir"))
        // A notification's place names the row the same way.
        #expect(session.containerLabel(for: tab.container, locale: Self.english)
            == "weir / review-folder")
    }

    @Test @MainActor func aSessionRowsItem_isNamedByItsWorktreeFolder_inItsProject() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let folder = URL(fileURLWithPath: "/tmp/weir-feature")
        let episode = EpisodeKey(origin: .sessionRow(worktreeRoot: folder), episodeToken: "worktreeMissing")
        let item = Self.queue([
            Entry(.stop(episode), .stop(.worktreeMissing), .sessionRow(projectID: project.id, worktreeRoot: folder))
        ]).items[0]

        #expect(NeedsAttentionListModel.names(of: item, in: session, locale: Self.english)
            == NeedsAttentionListModel.Names(title: "weir-feature", place: "weir"))
    }

    /// A row the person labeled is placed by its branch too, as its sidebar
    /// row shows it, so the list still says which worktree the item is in;
    /// one with no branch known, by its folder.
    @Test @MainActor func aLabeledRowsItem_isPlacedByItsProjectAndBranch_orItsFolder() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let folder = WorkspaceSessionFixture.projectRootURL("trees").appendingPathComponent("login-folder")
        let worktree = WorktreeFixture.make(workingDirectory: folder, admission: .created)
        let projectIndex = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[projectIndex].worktrees.append(worktree)
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        let tab = session.openTab(container: container)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let queue = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id)
            ),
            Entry(
                .stop(EpisodeKey(origin: .sessionRow(worktreeRoot: folder), episodeToken: "worktreeMissing")),
                .stop(.worktreeMissing),
                .sessionRow(projectID: project.id, worktreeRoot: folder)
            )
        ])

        func rows() -> [NeedsAttentionListModel.Row] {
            NeedsAttentionListModel(
                items: queue.items,
                names: { NeedsAttentionListModel.names(of: $0, in: session, locale: Self.english) },
                request: { _ in nil },
                windowProjectID: .some(project.id),
                locale: Self.english
            ).rows
        }

        let unlabeledFolder = rows()
        #expect(unlabeledFolder.map(\.title) == ["login-folder", "login-folder"])
        #expect(unlabeledFolder.map(\.placeLead) == ["weir · ", "weir · "])

        session.renameRow(container, to: "Login work", runtimes: [])
        let labeledFolder = rows()
        #expect(labeledFolder.map(\.title) == ["Login work", "Login work"])
        #expect(labeledFolder.map(\.placeLead) == ["weir / login-folder · ", "weir / login-folder · "])
        #expect(labeledFolder.map(\.spokenDetail) == [
            "weir, login-folder, Stopped: The process exited unexpectedly.",
            "weir, login-folder, Stopped: Worktree not found."
        ])

        let worktreeIndex = try #require(session.projects[projectIndex].worktrees.firstIndex { $0.id == worktree.id })
        session.projects[projectIndex].worktrees[worktreeIndex].gitRef = GitRef(branchName: "feat/login")
        let labeledBranch = rows()
        #expect(labeledBranch.map(\.title) == ["Login work", "Login work"])
        #expect(labeledBranch.map(\.placeLead) == ["weir / feat/login · ", "weir / feat/login · "])
        #expect(labeledBranch.map(\.spokenDetail) == [
            "weir, feat/login, Stopped: The process exited unexpectedly.",
            "weir, feat/login, Stopped: Worktree not found."
        ])

        session.renameRow(container, to: "", runtimes: [])
        let unlabeledBranch = rows()
        #expect(unlabeledBranch.map(\.title) == ["feat/login", "feat/login"])
        #expect(unlabeledBranch.map(\.placeLead) == ["weir · ", "weir · "])
    }

    @Test func theSecondLine_placesTheItem_andSaysWhenAnotherWindowShowsItsProject() {
        let shown = UUID()
        let other = UUID()
        let inNoWindow = UUID()
        let queue = Self.queue([
            Entry(
                .stop(Self.episode("a")),
                .stop(.processExited),
                .runtime(id: "a", provider: .claude, paneID: UUID(), tabID: nil, projectID: shown)
            ),
            Entry(
                .stop(Self.episode("b")),
                .stop(.processExited),
                .runtime(id: "b", provider: .claude, paneID: UUID(), tabID: nil, projectID: other)
            ),
            Entry(
                .stop(Self.episode("c")),
                .stop(.processExited),
                .runtime(id: "c", provider: .claude, paneID: UUID(), tabID: nil, projectID: inNoWindow)
            ),
            Entry(
                .stop(Self.episode("d")),
                .stop(.processExited),
                .runtime(id: "d", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil)
            )
        ])
        func leads(_ locale: Locale, window: UUID??, otherWindows: Set<UUID>) -> [String] {
            NeedsAttentionListModel(
                items: queue.items,
                names: { item in
                    let place = switch item.subject.projectID {
                    case shown: "Current"
                    case other: "Elsewhere"
                    case inNoWindow: "Unshown"
                    default: ""
                    }
                    return NeedsAttentionListModel.Names(title: "session", place: place.isEmpty ? nil : place)
                },
                request: { _ in nil },
                projectsInOtherWindows: otherWindows,
                windowProjectID: window,
                locale: locale
            ).rows.map(\.placeLead)
        }

        #expect(leads(Self.english, window: .some(shown), otherWindows: [other])
            == ["Current · ", "Elsewhere (another window) · ", "Unshown · ", ""])
        #expect(leads(Self.japanese, window: .some(shown), otherWindows: [other])
            == ["Current · ", "Elsewhere（別のウインドウ） · ", "Unshown · ", ""])
        #expect(leads(Self.english, window: .some(nil), otherWindows: [shown, other])
            == ["Current (another window) · ", "Elsewhere (another window) · ", "Unshown · ", ""])
        for locale in [Self.english, Self.japanese] {
            #expect(leads(locale, window: nil, otherWindows: []) == ["Current · ", "Elsewhere · ", "Unshown · ", ""])
        }
    }
}
