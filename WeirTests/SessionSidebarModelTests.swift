// SessionSidebarModelTests.swift
// Weir — the sidebar's rows: their order, names, words, and the rows ⌃⌘n and ⌘[ ⌘] open.

import AppKit
import Foundation
import Observation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct SessionSidebarModelTests {
    static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    static func project() -> (session: WorkspaceSession, project: Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].mainBranchName = "main"
        session.projects[index].worktrees = [
            Worktree(
                label: "spike",
                workingDirectory: URL(fileURLWithPath: "/tmp/spike"),
                gitRef: GitRef(branchName: "feat/spike"),
                origin: .gitWorktree
            ),
            Worktree(label: "old", workingDirectory: URL(fileURLWithPath: "/tmp/old"), origin: .gitWorktree, isHidden: true),
            Worktree(
                label: "gone",
                workingDirectory: URL(fileURLWithPath: "/tmp/gone"),
                origin: .gitWorktree,
                missingSince: Date(timeIntervalSince1970: 0)
            )
        ]
        return (session, session.projects[index])
    }

    /// The project with no branch known for its folder, so the folder's
    /// row is named by its conversation, as a detached HEAD's is.
    private static func unbranchedProject() -> (session: WorkspaceSession, project: Project) {
        let (session, project) = project()
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].mainBranchName = nil
        return (session, session.projects[index])
    }

    static func model(
        _ session: WorkspaceSession,
        _ project: Project,
        locale: Locale = english,
        gitFacts: @escaping (ContainerID) -> GitFacts? = { _ in nil }
    ) -> SessionSidebarModel {
        SessionSidebarModel(
            project: project,
            session: session,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: gitFacts,
            locale: locale
        )
    }

    @Test func rows_areTheFolder_thenTheShownWorktreesInTheOrderTheyWereMade() throws {
        let (session, project) = Self.project()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let peer = Worktree(
            label: "aaa", workingDirectory: URL(fileURLWithPath: "/tmp/weir-sidebar-aaa"),
            gitRef: GitRef(branchName: "feat/aaa"), origin: .gitWorktree, admission: .created
        )
        session.projects[index].worktrees.append(peer)
        let rows = Self.model(session, session.projects[index]).rows

        // Working peers keep their original order even when their names sort differently.
        #expect(rows.map(\.name) == ["main", "feat/spike", "feat/aaa", "gone"])
        #expect(rows.map(\.isMainFolder) == [true, false, false, false])
        #expect(rows.map(\.isMissing) == [false, false, false, true])
    }

    @Test func aRowsName_isTheNameAPersonGave_beforeTheBranch() {
        let (session, project) = Self.project()
        let tab = session.openTab(container: .project(project.id))
        session.update(tab.id) { $0.titleOverride = "Release prep" }

        let rows = Self.model(session, project).rows

        #expect(rows.first { $0.isMainFolder }?.name == "Release prep")
        #expect(rows.first { $0.isMainFolder }?.isActive == true)
    }

    // MARK: - Names

    private static func conversation(
        _ name: String,
        startedAt seconds: TimeInterval?,
        provider: AgentKind = .claude
    ) -> ConversationName {
        ConversationName(
            name: name,
            provider: provider,
            paneID: UUID(),
            conversationID: UUID().uuidString,
            startedAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test func aRowsName_doesNotFollowItsTabsTitle() {
        let (session, project) = Self.unbranchedProject()
        let tab = session.openTab(container: .project(project.id))
        session.update(tab.id) {
            $0.conversationName = Self.conversation("Append a line to notes.txt", startedAt: 0)
            $0.title = "claude --continue"
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Append a line to notes.txt")

        // The agent, then the shell it leaves, set the title again (OSC 2).
        for title in ["✳ Appending", "…/demo-repos/alpha", "zsh"] {
            session.update(tab.id) { $0.title = title }
            #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Append a line to notes.txt")
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.nameTruncation == .name)
    }

    /// A row stands for its worktree: its branch names it even while an
    /// agent's conversation runs there, which the pane strip names.
    @Test func aRowWithAConversation_isNamedByItsBranch() {
        let (session, project) = Self.project()
        let tab = session.openTab(container: .project(project.id))
        session.update(tab.id) { $0.conversationName = Self.conversation("Add tests", startedAt: 0) }

        let row = Self.model(session, project).rows.first { $0.isMainFolder }
        #expect(row?.name == "main")
        #expect(row?.nameTruncation == .branch)
    }

    @Test func aRowWithoutAConversation_isNamedByItsBranch_whateverItsTabsAreCalled() {
        let (session, project) = Self.project()
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        let tab = session.openTab(container: spike)
        session.update(tab.id) { $0.title = "claude --continue" }

        let row = Self.model(session, project).rows[1]

        #expect(row.name == "feat/spike")
        // A branch differs from its neighbors at its end.
        #expect(row.nameTruncation == .branch)
    }

    @Test func aFolderWithoutABranch_isNamedByItsFolder_asAName() throws {
        let (session, project) = Self.project()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].mainBranchName = nil
        let unbranched = session.projects[index]

        let row = try #require(Self.model(session, unbranched).rows.first { $0.isMainFolder })

        #expect(row.name == unbranched.rootURL.lastPathComponent)
        #expect(row.nameTruncation == .name)
        // A worktree whose branch is not known yet is named by its label,
        // as a name; one with a known branch by the branch.
        let rows = Self.model(session, unbranched).rows
        #expect(rows.map(\.name) == [unbranched.rootURL.lastPathComponent, "feat/spike", "gone"])
        #expect(rows.map(\.nameTruncation) == [.name, .branch, .name])
    }

    @Test func anEmptyNameAPersonGave_handsTheRowToItsConversation() {
        let (session, project) = Self.unbranchedProject()
        let cleared = session.openTab(container: .project(project.id))
        let named = session.openTab(container: .project(project.id))
        session.update(cleared.id) { $0.titleOverride = "" }
        session.update(named.id) { $0.conversationName = Self.conversation("Add tests", startedAt: 0) }

        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Add tests")

        session.update(named.id) { $0.conversationName = nil }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == project.rootURL.lastPathComponent)
    }

    @Test func theHeaderAndTheCard_cutTheNameAsTheRowDoes() throws {
        let (session, project) = Self.unbranchedProject()
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        _ = session.openTab(container: spike)
        let named = session.openTab(container: .project(project.id))
        session.update(named.id) { $0.conversationName = Self.conversation("Add tests", startedAt: 0) }
        let rows = Self.model(session, project).rows
        let folder = try #require(rows.first { $0.isMainFolder })

        #expect(SessionHeaderModel(row: folder, pullRequestNumber: nil, locale: Self.english).nameTruncation == .name)
        let spikeRow = try #require(rows.first { $0.id == spike })
        #expect(SessionHeaderModel(row: spikeRow, pullRequestNumber: nil, locale: Self.english).nameTruncation == .branch)

        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
            session: session, window: session.primaryWindowID, registry: registry, queue: AttentionQueue(),
            runtimes: [], approvals: ApprovalLedger(), pullRequest: { _ in nil }, gitFacts: { _ in nil },
            locale: Self.english
        ))
        #expect(cards.map(\.name) == ["Add tests", "feat/spike"])
        #expect(cards.map(\.nameTruncation) == [.name, .branch])
    }

    @Test func aRowKeepsItsConversationsName_afterTheAgentLeaves() throws {
        let (session, project) = Self.unbranchedProject()
        let tab = session.openTab(container: .project(project.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let running = AgentBadge(
            state: .running,
            updatedAt: Date(),
            firstPrompt: "Run sleep 15 with a timer",
            conversationID: "thread",
            sessionStartedAt: Date(timeIntervalSince1970: 0)
        )
        session.update(tab.id) {
            $0.agentBadges[.codex] = [pane: running]
            $0.rememberConversationName()
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Run sleep 15 with a timer")

        // The run is gone, and the shell names the tab by its folder.
        session.update(tab.id) {
            $0.agentBadges = [:]
            $0.title = "~/projects/sample-reviews/demo-repos/alpha"
            $0.rememberConversationName()
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Run sleep 15 with a timer")
    }

    @Test func aRowWithSeveralConversations_isNamedByTheFirstToStart() {
        let (session, project) = Self.unbranchedProject()
        let shell = session.openTab(container: .project(project.id))
        let later = session.openTab(container: .project(project.id))
        let earlier = session.openTab(container: .project(project.id))
        session.update(shell.id) { $0.title = "zsh" }
        session.update(later.id) { $0.conversationName = Self.conversation("Write the release notes", startedAt: 200) }
        session.update(earlier.id) {
            $0.conversationName = Self.conversation("Review the store", startedAt: 100, provider: .codex)
        }

        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Review the store")

        // A name the person gave still comes first.
        session.update(later.id) { $0.titleOverride = "Release prep" }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Release prep")
    }

    @Test func aRowAtRest_readsIdle_asAShell_inTheWindowsLanguage() {
        let (session, project) = Self.project()

        let english = Self.model(session, project).rows[0]
        #expect(english.factText == "Idle")
        #expect(english.fact.badge == .shell)
        #expect(english.tone == .muted)
        #expect(english.lastActivity == nil)
        #expect(Self.model(session, project, locale: Self.japanese).rows[0].factText == "待機中")
    }

    @Test func aRowAtRest_statesItsFoldersGitFacts_eachRowItsOwn() throws {
        let (session, project) = Self.project()
        let folder = ContainerID.project(project.id)
        let spike = try ContainerID.worktree(projectID: project.id, worktreeID: #require(project.worktrees.first?.id))
        let gone = try ContainerID.worktree(projectID: project.id, worktreeID: #require(project.worktrees.last?.id))
        let facts: [ContainerID: GitFacts] = [
            folder: GitFactsFixture.make(branch: "main", commits: nil, unpushed: nil, uncommitted: 2, base: nil),
            spike: GitFactsFixture.make(branch: "feat/spike", commits: nil, unpushed: nil, uncommitted: 5, base: nil)
        ]
        let rows = Self.model(session, project) { facts[$0] }.rows

        #expect(rows.map(\.id) == [folder, spike, gone])
        #expect(rows.map(\.factText) == ["2 files uncommitted", "5 files uncommitted", "Idle"])
    }

    @Test func anApprovalsCommand_isFoundInItsLine_whateverTheLanguage() throws {
        let approval = ApprovalFact.test()
        let items = Self.items([.approval(approval)])
        func row(isCommand: Bool, locale: Locale) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(fact: .init(items: items, requestText: [approval.key: "swift test"]))
            input.commandRequests = isCommand ? [approval.key] : []
            return .test(input, locale: locale)
        }
        for locale in [Self.english, Self.japanese] {
            let command = row(isCommand: true, locale: locale)
            let range = try #require(SessionRowFactText.commandRange(in: command.factText, for: command))
            #expect(command.factText[range] == "swift test")
        }
        // A request that is not a command, and a row at rest, keep the line's own face.
        let summary = row(isCommand: false, locale: Self.english)
        #expect(SessionRowFactText.commandRange(in: summary.factText, for: summary) == nil)
        let idle = Self.row([])
        #expect(SessionRowFactText.commandRange(in: idle.factText, for: idle) == nil)
    }

    @Test func aWaitWeirDoesNotHold_setsItsCommand_asAHeldOnesIs() throws {
        func row(_ wait: PromptWait, locale: Locale) -> SessionSidebarModel.Row {
            .test(.test(fact: .init(items: Self.items([.prompt(wait)]))), locale: locale)
        }
        for locale in [Self.english, Self.japanese] {
            let command = row(PromptWait(detail: "Bash: swift test", kind: .approval, tool: "Bash"), locale: locale)
            #expect(command.isFactCommand)
            let range = try #require(SessionRowFactText.commandRange(in: command.factText, for: command))
            #expect(command.factText[range] == "swift test")
        }
        // A file, a tool alone, and a wait for an answer keep the line's face.
        for wait in [
            PromptWait(detail: "Write: /repo/notes.txt"),
            PromptWait(detail: "Bash"),
            PromptWait(detail: "Which color?")
        ] {
            let other = row(wait, locale: Self.english)
            #expect(!other.isFactCommand)
            #expect(SessionRowFactText.commandRange(in: other.factText, for: other) == nil)
        }
    }

    @Test func theTooltip_namesTheBranch_unlessTheRowIsNamedByIt() {
        func row(name: String, branch: String) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(name: name)
            input.branch = branch
            return .test(input)
        }

        #expect(SessionRowFactText.tooltip(for: row(name: "Release prep", branch: "feat/release"), now: .now, locale: Self.english)
            == "Release prep · feat/release")
        #expect(SessionRowFactText.tooltip(for: row(name: "main", branch: "main"), now: .now, locale: Self.english) == "main")
    }

    @Test func aRowCountsItsAgents() {
        let agents = SessionSidebarModel.Row.test(.test(fact: .init(agents: [
            .init(provider: .claude, state: .running, detail: nil),
            .init(provider: .claude, state: .idle, detail: nil),
            .init(provider: .codex, state: .idle, detail: nil)
        ])))

        #expect(agents.agentCount == 3)
        #expect(Set(agents.agentKinds) == [.claude, .codex])
        #expect(SessionSidebarModel.Row.test(.test(name: "shell")).agentCount == 0)
    }

    private static func items(_ kinds: [AttentionItemKind]) -> [AttentionItem] {
        var queue = AttentionQueue()
        for (offset, kind) in kinds.enumerated() {
            let run = "r\(offset)"
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
                subject: .runtime(id: run, provider: kind.approvalFact?.provider ?? .claude, paneID: UUID(), tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }
        return queue.items
    }

    private static func row(
        _ items: [AttentionItem],
        requestText: [ApprovalKey: String] = [:],
        heldRequests: Set<ApprovalKey> = [],
        lastActivity: Date? = nil,
        agents: [SessionRowFact.Input] = []
    ) -> SessionSidebarModel.Row {
        var input = SessionSidebarModel.RowInput.test(fact: .init(items: items, requestText: requestText), lastActivity: lastActivity)
        input.agents = agents
        input.heldRequests = heldRequests
        return .test(input)
    }

    @Test func aRowOffersAnswer_onlyForARequestWeirCanStillAnswer() {
        let approval = ApprovalFact.test()
        let held = Self.row(
            Self.items([.approval(approval)]),
            requestText: [approval.key: "swift test"],
            heldRequests: [approval.key]
        )
        #expect(held.answerKey == approval.key)
        #expect(held.tone == .waiting)
        #expect(held.factText == "Waiting for approval: swift test")
        // The ledger does not hold it: the card would have nothing to show.
        #expect(Self.row(Self.items([.approval(approval)]), requestText: [approval.key: "swift test"]).answerKey == nil)

        // Codex's questions are answered in the TUI.
        let codex = ApprovalFact.test(isQuestion: true, provider: .codex, supportsNativeAnswer: false)
        let unsupported = Self.row(Self.items([.question(codex)]), heldRequests: [codex.key])
        #expect(unsupported.leadItemID == .question(codex.key))
        #expect(unsupported.answerKey == nil)
        #expect(unsupported.requiresTerminalAnswer)
    }

    /// A row waiting on a request Weir does not hold offers no "Answer…";
    /// choosing the row goes to the pane, which its tooltip says.
    @Test func aRowWaitingOnTheTerminal_saysToOpenThePane_inItsTooltip() {
        let waits: [AttentionItemKind] = [
            .prompt(PromptWait(detail: "Edit: /repo/App.swift")),
            .approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now))),
            .approval(ApprovalFact.test(state: .timedOut)),
            .question(ApprovalFact.test(isQuestion: true, provider: .codex))
        ]
        let now = Date(timeIntervalSince1970: 600)
        for kind in waits {
            let row = Self.row(Self.items([kind]), lastActivity: Date(timeIntervalSince1970: 0))
            #expect(row.answerKey == nil)
            #expect(row.requiresTerminalAnswer)
            // A line of its own after the facts, not one of them.
            #expect(SessionRowFactText.tooltip(for: row, now: now, locale: Self.english)
                == "main · 10 min since last activity\nOpen the pane to answer in the terminal")
            #expect(SessionRowFactText.tooltip(for: row, now: now, locale: Locale(identifier: "ja"))
                .hasSuffix("\nペインを開いてターミナルで回答"))
        }

        // One Weir holds is answered from the row's own "Answer…".
        let approval = ApprovalFact.test()
        let held = Self.row(Self.items([.approval(approval)]), heldRequests: [approval.key])
        #expect(held.answerKey == approval.key)
        #expect(!held.requiresTerminalAnswer)
        #expect(SessionRowFactText.tooltip(for: held, now: .now, locale: Self.english) == "main")
    }

    /// The row open in the window, with the waiting pane in the tab it
    /// shows: the person sees the prompt already, so the tooltip does not
    /// send them there. The same row with its pane out of view does.
    @Test func aRowWhosePaneIsInView_doesNotSayToOpenIt() throws {
        let container = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let items = Self.items([.prompt(PromptWait(detail: nil))])
        let paneID = try #require(items[0].subject.paneID)
        var input = SessionSidebarModel.RowInput.test(container: container, fact: .init(items: items))
        input.leadPaneID = paneID
        let model = { (active: ContainerID, shown: Set<UUID>) in
            SessionSidebarModel.Row.test(input, activeContainer: active, shownPanes: shown)
        }

        let inView = model(container, [paneID])
        #expect(inView.requiresTerminalAnswer)
        #expect(SessionRowFactText.tooltip(for: inView, now: .now, locale: Self.english) == "main")
        // Another tab of the same row shown, or another row open.
        #expect(SessionRowFactText.tooltip(for: model(container, [UUID()]), now: .now, locale: Self.english)
            == "main\nOpen the pane to answer in the terminal")
        #expect(model(.loose, [paneID]).suggestsOpeningPane)
    }

    /// The panes in view are those of the tab the window shows.
    @Test @MainActor func theWindowsShownTab_putsTheRowsPaneInView() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id))
        let other = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: nil)),
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        func row() throws -> SessionSidebarModel.Row {
            try #require(SessionSidebarModel(
                project: project, session: session, queue: queue, runtimes: [], approvals: ApprovalLedger(),
                pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Self.english
            ).rows.first)
        }

        session.setActiveTab(tab.id)
        let inView = try row()
        #expect(inView.isActive)
        #expect(inView.leadPaneID == paneID)
        #expect(inView.isLeadPaneShown)
        #expect(!inView.suggestsOpeningPane)

        session.setActiveTab(other.id)
        let outOfView = try row()
        #expect(outOfView.isActive)
        #expect(outOfView.leadPaneID == paneID)
        #expect(!outOfView.isLeadPaneShown)
        #expect(outOfView.suggestsOpeningPane)
    }

    @Test func aStop_takesTheStoppedTone_andKeepsTheUnreadCount() {
        let first = TurnID("first")
        let second = TurnID("second")
        let items = Self.items([
            .unread(UnreadTurn(turnID: first, changes: .unknown)),
            .stop(.processExited),
            .unread(UnreadTurn(turnID: second, changes: .unknown))
        ])
        #expect(items.map(\.id) == [.unread(first), .stop(EpisodeKey(origin: .runtime("r1"), episodeToken: "1")), .unread(second)])
        let row = Self.row(items)
        #expect(row.tone == .stopped)
        #expect(row.unreadCount == 2)
        #expect(SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english) == "main · 2 unread turns")
    }

    @Test func aRowWithTwoAgents_namesEachInItsTooltip() {
        let row = Self.row([], agents: [
            .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")]),
            .init(agents: [.init(provider: .codex, state: .idle, detail: nil)])
        ])
        // A slash between agents, as a fact may hold a dot of its own.
        #expect(row.agentSummary == "Claude: Bash: swift test / Codex: Idle")
        #expect(Self.row([]).agentSummary == nil)
    }

    @Test func voiceOver_readsState_name_project_fact_agent_andTime() {
        let now = Date(timeIntervalSince1970: 10000)
        let row = SessionSidebarModel.Row.test(.test(
            name: "Release prep",
            fact: .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")]),
            lastActivity: now.addingTimeInterval(-12 * 60)
        ))

        #expect(SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: now, locale: Self.english)
            == "Running, Release prep, weir, Bash: swift test, Claude, 12 min since last activity")
        // The row's column says "12m"; VoiceOver and the tooltip say the
        // minutes in words.
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-12 * 60), now: now, locale: Self.english) == "12m")
    }

    @Test func aPullRequestRow_readsItsState_thenTheRequestAndItsChecks_inWords() {
        let checks = PRChecks(conclusion: .failure, counts: .init(passed: 3, total: 4))
        func checkedRow(_ fact: SessionRowFact.Input) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(fact: fact)
            input.pullRequestChecks = (checks, .gitHub)
            return .test(input)
        }
        let row = checkedRow(.init(pullRequest: .init(number: 128, state: .open, isDraft: false)))

        #expect(row.fact.glyph == .shell, "a row with no agent keeps the shell glyph")
        #expect(row.checksText == "Checks failed, 3 of 4 passed", "VoiceOver reads 3/4 as a date")
        #expect(
            SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: .now, locale: Self.english)
                == "Shell, main, weir, PR #128, Open, Checks failed, 3 of 4 passed",
            "a shell says Shell once"
        )

        let agentRow = checkedRow(.init(
            agents: [.init(provider: .claude, state: .idle, detail: nil)],
            pullRequest: .init(number: 128, state: .open, isDraft: false)
        ))
        #expect(agentRow.fact.glyph == .idle)
        #expect(SessionRowFactText.spokenLabel(for: agentRow, projectName: "weir", now: .now, locale: Self.english)
            == "Idle, main, weir, PR #128, Open, Checks failed, 3 of 4 passed, Claude")
    }

    @Test func sessionKeys_openWorkingRows_andOnlyCyclingIncludesScratch() throws {
        let (session, project) = Self.project()
        let window = ProjectWindowState(selection: session.primarySelection)
        session.primarySelection.projectID = project.id
        let folder = ContainerID.project(project.id)
        let spike = try ContainerID.worktree(projectID: project.id, worktreeID: #require(project.worktrees.first?.id))
        let sections = SidebarPresentedSections.computed(
            project: project, session: session, window: window.id, queue: AttentionQueue(),
            pullRequest: { _ in nil }, gitFacts: { _ in nil }
        )
        #expect(SessionRowNavigation.workingRows(in: window, session: session, sections: sections) == [folder, spike])
        #expect(SessionRowNavigation.rows(in: window, session: session, sections: sections) == [folder, spike, .loose])

        session.setActiveContainer(spike, in: window.id, intent: .repair)
        try #require(window.selection.activeContainerID == spike)
        SessionRowNavigation.activate(at: 0, in: window, session: session, sections: sections)
        #expect(window.selection.activeContainerID == folder)
        SessionRowNavigation.cycle(forward: true, in: window, session: session, sections: sections)
        #expect(window.selection.activeContainerID == spike)
        SessionRowNavigation.cycle(forward: true, in: window, session: session, sections: sections)
        #expect(window.selection.activeContainerID == .loose)
        SessionRowNavigation.activate(at: 2, in: window, session: session, sections: sections)
        #expect(window.selection.activeContainerID == .loose)
        SessionRowNavigation.cycle(forward: true, in: window, session: session, sections: sections)
        #expect(window.selection.activeContainerID == folder)
    }

    /// ⌃⌘n and ⌘[ ⌘] count the rows the sidebar shows, in the sections it
    /// shows them in: a row folded away is skipped, and one held among the
    /// working rows while its section changed is counted where it is seen.
    @Test func sessionKeys_countTheWorkingRowsTheSidebarShows() {
        let (session, project) = Self.project()
        let window = ProjectWindowState(selection: session.primarySelection)
        session.primarySelection.projectID = project.id
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        let gone = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[2].id)
        let folded = SidebarPresentedSections(sections: [spike: .other, gone: .working, .project(project.id): .working])

        #expect(SessionRowNavigation.rows(in: window, session: session, sections: folded) == [.project(project.id), gone, .loose])
        SessionRowNavigation.activate(at: 1, in: window, session: session, sections: folded)
        #expect(session.primarySelection.activeContainerID == gone)

        // Held where it was drawn while it would now fold away.
        window.present(SidebarPresentedSections(sections: [spike: .working, gone: .working, .project(project.id): .working]))
        window.isPointerInSidebar = true
        let held = window.presentedSections(computed: folded, isDragging: false)
        SessionRowNavigation.activate(at: 1, in: window, session: session, sections: held)
        #expect(session.primarySelection.activeContainerID == spike)
    }

    /// The menus that count the working rows follow the rows the sidebar
    /// drew among them (`presentedWorkingRows`, which they observe), and a
    /// drawing that moves no row in or out leaves the value as it was.
    @Test func theDrawnWorkingRows_followARowMovingInOrOut() {
        let (session, project) = Self.project()
        let window = ProjectWindowState(selection: session.primarySelection)
        session.primarySelection.projectID = project.id
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        let folder = ContainerID.project(project.id)

        window.present(SidebarPresentedSections(sections: [spike: .other, folder: .working]))
        #expect(window.presentedWorkingRows == [folder])
        #expect(
            SessionRowNavigation.workingRows(in: window, session: session, sections: window.presentedSections).count == 2,
            "and the missing worktree, which the drawing does not name"
        )

        window.present(SidebarPresentedSections(sections: [spike: .working, folder: .working]))
        #expect(window.presentedWorkingRows == [spike, folder])
        #expect(SessionRowNavigation.workingRows(in: window, session: session, sections: window.presentedSections).count == 3)
        #expect(SessionRowNavigation.hasRow(number: 3, workingRowCount: 3))

        // The same rows drawn again move none in or out: no menu rebuilds.
        let notified = Recorded(false)
        withObservationTracking {
            _ = window.presentedWorkingRows
        } onChange: {
            notified.value = true
        }
        window.present(SidebarPresentedSections(sections: [spike: .working, folder: .working]))
        #expect(!notified.value)

        // Control: the tracking is live, so a row moving out is heard.
        window.present(SidebarPresentedSections(sections: [spike: .other, folder: .working]))
        #expect(notified.value)
    }

    @Test func theActiveRow_isTheOneOfTheWindowDrawingTheSidebar() {
        let (session, project) = Self.project()
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        // The primary shows no project, so another window can show this one.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)

        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(spike, in: other)

        let model = SessionSidebarModel(
            project: project,
            session: session,
            window: other,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Self.english
        )

        #expect(model.rows.filter(\.isActive).map(\.name) == ["feat/spike"])
        // The primary, on the scratch row, has no row of the project active.
        #expect(Self.model(session, project).rows.filter(\.isActive).isEmpty)
    }

    // MARK: - A row's lead

    @Test func aRowsLeadAgent_prefersActiveThenBackgroundWork_thenTheFirstAgent() {
        func lead(_ states: [AgentState]) -> Int? {
            SessionRowFact.leadAgentIndex(of: states.map { SessionRowFact.Agent(provider: .claude, state: $0, detail: nil) })
        }
        #expect(lead([.idle, .running]) == 1)
        #expect(lead([.idle, .compacting, .running]) == 1)
        let idle = SessionRowFact.Agent(provider: .claude, state: .idle, detail: nil)
        let background = SessionRowFact.Agent(provider: .codex, state: .finished, detail: nil, backgroundWork: .init(shells: 1))
        let running = SessionRowFact.Agent(provider: .claude, state: .running, detail: nil)
        #expect(SessionRowFact.leadAgentIndex(of: [idle, background]) == 1)
        #expect(SessionRowFact.leadAgentIndex(of: [idle, background, running]) == 2)
        #expect(lead([.idle, .unknown]) == 0)
        #expect(lead([]) == nil)
    }

    @Test func aFolderWithNothingOpen_isARowWithoutTabs_andItsTabsFocusedPaneLeads() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let empty = SessionSidebarModel(
            project: project, session: session, queue: AttentionQueue(), runtimes: [], approvals: ApprovalLedger(),
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Locale(identifier: "en")
        )
        #expect(empty.rows.first?.hasTabs == false)
        #expect(empty.rows.first?.leadPaneID == nil)

        let tab = session.openTab(container: .project(project.id))
        let first = try #require(tab.splitTree.allLeafIDs().first)
        let split = tab.splitTree.insert(at: first, direction: .horizontal)
        try #require(split.tree.allLeafIDs() == [first, split.newLeafID])
        session.update(tab.id) {
            $0.splitTree = split.tree
            $0.splitTree.focusedLeafID = split.newLeafID
        }
        let opened = SessionSidebarModel(
            project: project, session: session, queue: AttentionQueue(), runtimes: [], approvals: ApprovalLedger(),
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Locale(identifier: "en")
        )
        #expect(opened.rows.first?.hasTabs == true)
        #expect(opened.rows.first?.leadPaneID == split.newLeafID)
        #expect(opened.rows.first?.leadItemID == nil)
    }
}

extension SessionSidebarModelTests {
    /// A worktree deleted outside Weir stops its row, which says why.
    @Test func aMissingWorktreesRow_saysItsWorktreeIsNotFound() throws {
        let (session, project) = Self.project()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let hidden = try #require(project.worktrees.firstIndex { $0.isHidden })
        session.projects[index].worktrees[hidden].missingSince = Date(timeIntervalSince1970: 0)
        let input = AttentionQueueStore.makeInput(
            runtimes: [],
            isRead: { _ in false },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: input)
        let model = SessionSidebarModel(
            project: session.projects[index],
            session: session,
            queue: queue,
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Self.english
        )
        let gone = try #require(model.rows.first { $0.isMissing })
        #expect(gone.name == "gone")
        #expect(gone.factText == "Stopped: Worktree not found.")
        let expected = AttentionItemID.stop(EpisodeKey(
            origin: .sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/gone")), episodeToken: "worktreeMissing"
        ))
        #expect(gone.leadItemID == expected)
        #expect(queue.items.map(\.id) == [expected])
        #expect(!model.rows.contains { $0.name == "old" })
    }
}

/// A row whose second line states something other than its request still
/// shows the request's mark, so VoiceOver reads the request too.
struct SessionRowAttachedPullRequestTests {
    private static let english = Locale(identifier: "en")

    @Test func aStoppedRow_readsTheStop_thenItsPullRequest() {
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        var input = SessionSidebarModel.RowInput.test(fact: .init(
            items: queue.items,
            agents: [.init(provider: .claude, state: .error, detail: nil)],
            pullRequest: .init(number: 128, state: .open, isDraft: false)
        ))
        input.pullRequestChecks = (PRChecks(conclusion: .failure, counts: .init(passed: 3, total: 4)), .gitHub)
        let row = SessionSidebarModel.Row.test(input)
        #expect(row.fact.glyph == .stopped)
        #expect(row.pullRequestText == "PR #128 · Open")
        let spoken = SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: .now, locale: Self.english)
        #expect(spoken ==
            "Stopped, main, weir, Stopped: The process exited unexpectedly., PR #128, Open, Checks failed, 3 of 4 passed, Claude")
    }
}

extension SessionSidebarModelTests {
    /// A question the ledger holds offers Answer… even when it has no text
    /// to show: an empty first prompt and no summary.
    @Test func aSidebarRowsHeldQuestionWithNoText_stillOffersAnswer() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let request = ApprovalPresentation.test(
            summary: nil,
            questions: [ApprovalQuestion(header: nil, prompt: "", options: [], isMultiSelect: false)]
        )
        #expect(ApprovalRequestText(request).questionText == nil)
        let ledger = ApprovalLedger()
        ledger.observe(pending: [request], epoch: request.epoch)
        var queue = AttentionQueue()
        queue.insert(
            id: .question(request.key),
            kind: .question(ApprovalFact.test(key: request.key, isQuestion: true)),
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let row = try #require(SessionSidebarModel(
            project: project, session: session, queue: queue, runtimes: [], approvals: ledger,
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Locale(identifier: "en")
        ).rows.first)

        #expect(row.answerKey == request.key)
    }

}
