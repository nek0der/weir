// DecisionBarModelTests.swift
// Weir — what an agent pane's decision bar says, and which of the pane's items it is on.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct DecisionBarModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()

    /// Items in arrival order, with approvals and questions filed under their request keys.
    private static func items(_ kinds: [AttentionItemKind], provider: AgentKind = .claude) -> [AttentionItem] {
        AttentionItem.testList(kinds, pane: pane, provider: provider, filesRequestsByKey: true)
    }

    private static func itemsInArrivalOrder(_ entries: [(AttentionItemID, AttentionItemKind)]) throws -> [AttentionItem] {
        let subject = AttentionSubject.runtime(id: "agent", provider: .claude, paneID: pane, tabID: nil, projectID: nil)
        var queue = AttentionQueue()
        for (index, (id, kind)) in entries.enumerated() {
            let inserted = queue.insert(id: id, kind: kind, subject: subject, arrivedAt: Date(timeIntervalSince1970: Double(index)))
            try #require(inserted)
        }
        return queue.items
    }

    private static func model(_ input: DecisionBarContent.Input, locale: Locale = english) -> DecisionBarModel {
        DecisionBarModel(content: DecisionBarContent.make(input), locale: locale)
    }

    @Test(arguments: [
        (AgentKind.claude, AgentState.unknown, nil as String?, "Unknown", "不明"),
        (.codex, .idle, nil, "Idle", "待機中"),
        (.claude, .running, "Bash: swift test", "Bash: swift test", "Bash: swift test")
    ])
    func summary_namesTheAgentsStateWithoutATag(
        provider: AgentKind, state: AgentState, detail: String?, english: String, japanese: String
    ) {
        let agent = SessionRowFact.Agent(provider: provider, state: state, detail: detail)
        for (locale, text) in [(Self.english, english), (Self.japanese, japanese)] {
            let bar = Self.model(.init(agent: agent), locale: locale)
            #expect(bar.tag == nil)
            #expect(bar.countText == nil)
            #expect(bar.tone == .muted)
            #expect(bar.text == text)
        }
    }

    @Test(arguments: [
        (AgentKind.claude, "Answer in the terminal or on the card"),
        (.opencode, "Answer in the terminal or on the card"),
        (.codex, "Answer on the card")
    ])
    func aHeldRequest_namesTheTerminalToo_whereTheAgentShowsItsOwnPrompt(provider: AgentKind, instruction: String) {
        let fact = ApprovalFact.test(provider: provider)
        let model = Self.model(.init(items: Self.items([.approval(fact)], provider: provider)))
        #expect(model.instruction == instruction)
        #expect(model.shortInstruction == instruction)
    }

    @Test(arguments: [
        (AgentKind.claude, PromptApproval.Action?.some(.other), "en", "Claude is asking for approval."),
        (.claude, .other, "ja", "Claude が承認を求めています。"),
        (.claude, .command, "en", "Claude wants to run a command."),
        (.claude, nil, "en", "Claude is asking for approval."),
        (.codex, .fileChange, "ja", "Codex がファイルの変更を求めています。")
    ])
    func approvalWordingFollowsItsToolBeforeAndAfterHandoff(
        provider: AgentKind, action: PromptApproval.Action?, language: String, text: String
    ) {
        let now = SuspendingClock().now
        let locale = Locale(identifier: language)
        for state in [ApprovalRequestState.held, .handedToTerminal(since: now)] {
            let approval = ApprovalFact.test(provider: provider, state: state)
            let actions = action.map { [approval.key: $0] } ?? [:]
            let input = DecisionBarContent.Input(items: Self.items([.approval(approval)], provider: provider), approvalActions: actions)
            let model = Self.model(input, locale: locale)
            #expect(model.text == text)
            if state == .held, provider == .codex {
                #expect(model.instruction == "カードで回答")
            }
        }
    }

    /// A wait in a tool's words reads as an approval, a file change or a
    /// command as the tool is one; a tool no list knows, which the record
    /// says is an approval, is one too. A question the record names reads as
    /// a held one does, whatever its words look like; a wait with no words
    /// is the state's own word.
    @Test(arguments: [
        (PromptWait(detail: "Write: /Users/me/repo/notes.txt"), AgentKind.claude, "en", "Approval", "Claude wants to change files."),
        (PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor"), .claude, "ja", "承認", "Claude が承認を求めています。"),
        (PromptWait(detail: "Read: which file?", kind: .question, tool: nil), .claude, "en", "Question", "Claude is asking a question."),
        (PromptWait(detail: nil, kind: .question, tool: nil), .claude, "ja", "質問", "Claude が質問しています。"),
        (PromptWait(detail: "Bash"), .codex, "en", "Approval", "Codex wants to run a command."),
        (PromptWait(detail: "WebFetch"), .claude, "en", "Approval", "Claude is asking for approval."),
        (PromptWait(detail: "Edit: /a/b.swift"), .claude, "ja", "承認", "Claude がファイルの変更を求めています。"),
        (PromptWait(detail: "Read"), .claude, "ja", "承認", "Claude が承認を求めています。"),
        (PromptWait(detail: nil), .claude, "ja", "応答", "Claude が応答を待っています。"),
        (PromptWait.signIn, .codex, "en", "Sign-in", "Codex needs you to sign in."),
        (PromptWait.signIn, .claude, "ja", "サインイン", "Claude のサインインが必要です。")
    ])
    func aWaitWeirDoesNotHold_isTaggedAndWorded_byItsKindAndTool(
        wait: PromptWait,
        provider: AgentKind,
        language: String,
        tag: String,
        text: String
    ) {
        let model = Self.model(.init(items: Self.items([.prompt(wait)], provider: provider)), locale: Locale(identifier: language))
        #expect(model.tag == tag)
        #expect(model.text == text)
    }

    /// The tool's words are in the tooltip rather than pushing the
    /// instruction out, and the bar's own sentence is cut at its end, like
    /// any.
    @Test func aWaitInAToolsWords_keepsThemInTheTooltip_andTheInstructionWhole() {
        let write = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Write: /Users/me/repo/notes.txt"))])))
        #expect(write.tone == .waiting)
        #expect(write.instruction == "Answer in the terminal")
        #expect(write.textHelp == "Write: /Users/me/repo/notes.txt")
        #expect(!write.cutsTextInMiddle)
        #expect(write.shortInstruction == "Answer in terminal")

        let monitor = Self.model(
            .init(items: Self.items([.prompt(PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor"))])),
            locale: Self.japanese
        )
        #expect(monitor.shortInstruction == "ターミナルで回答")
        let asked = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Read: which file?", kind: .question, tool: nil))])))
        #expect(asked.instruction == "Answer in the terminal")
        #expect(asked.textHelp == "Read: which file?")
        #expect(!asked.cutsTextInMiddle)
        let japanese = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Edit: /a/b.swift"))])), locale: Self.japanese)
        #expect(japanese.instruction == "ターミナルで回答してください")

        let prompt = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: nil))], provider: .codex)))
        // Neither an approval nor a question we know of: the state's own word.
        #expect(prompt.tag == "Response")
        #expect(prompt.shortInstruction == "Answer in terminal")
        #expect(prompt.text == "Codex is waiting for a response.")
        #expect(prompt.instruction == "Answer in the terminal")
        // A sign-in is not answered, so the bar says where to sign in, in
        // full even when short of room.
        let signIn = Self.model(.init(items: Self.items([.prompt(.signIn)], provider: .codex)))
        #expect(signIn.tone == .waiting)
        #expect(signIn.instruction == "Sign in in the terminal")
        #expect(signIn.shortInstruction == "Sign in in the terminal")
        #expect(signIn.textHelp == nil)
        let worded = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Allow network access?"))])))
        #expect(worded.text == "Allow network access?")
        #expect(worded.textHelp == "Allow network access?")
        #expect(worded.cutsTextInMiddle)
    }

    @Test func stop_statesItsReasonWithoutAnInstruction() {
        let stop = Self.model(.init(items: Self.items([.stop(.processExited)])))
        #expect(stop.tag == "Stopped")
        #expect(stop.tone == .stopped)
        #expect(stop.instruction == nil)
        #expect(stop.shortInstruction == nil)
        // Only a prompt's own words are cut in the middle or put in the tooltip.
        #expect(!stop.cutsTextInMiddle)
        #expect(stop.textHelp == nil)
        // The tag says "Stopped"; the words say why, once.
        #expect(stop.text == "The process exited unexpectedly.")
        #expect(stop.runs == [ReceiptRun(text: stop.text, role: .emphasized)])
        let unworded = Self.model(.init(items: Self.items([.stop(.error(nil))])), locale: Self.japanese)
        #expect(unworded.text == "エージェントが停止しました。", "never an empty line, nor 停止 twice")
    }

    @Test func rightAfterAnAnswerInTheTerminal_theBarSaysSo_andWhereCommandJGoesNext() {
        let nextID = AttentionItemID.stop(EpisodeKey(origin: .runtime("build"), episodeToken: "1"))
        let next = DecisionBarModel(
            content: DecisionBarContent.make(.init(done: .init(result: .answeredInTerminal, next: nextID))),
            locale: Self.english
        ) { $0 == nextID ? "build" : nil }
        // The row leads with a muted checkmark (`everyDoneLine_hasNoTag`),
        // and the sentence says what happened.
        #expect(next.text == "Answered in the terminal. Next: “build” (⌘J).")

        let none = Self.model(.init(done: .init(result: .answeredInTerminal, next: nil)), locale: Self.japanese)
        #expect(none.text == "ターミナルで回答しました。要対応はありません。")
        #expect(Self.model(.init(done: .init(result: .answeredInTerminal, next: nil))).text
            == "Answered in the terminal. Nothing needs attention.")
        let nextInJapanese = DecisionBarModel(
            content: DecisionBarContent.make(.init(done: .init(result: .answeredInTerminal, next: nextID))),
            locale: Self.japanese
        ) { $0 == nextID ? "build" : nil }
        #expect(nextInJapanese.text == "ターミナルで回答しました。次は「build」（⌘J）。")
    }

    /// Every line after an item was handled leads with the muted check in
    /// place of a tag (muted, not green, since no state is drawn in green),
    /// in either language.
    @Test(arguments: [
        DecisionBarContent.DoneResult.answeredInTerminal,
        .declinedInTerminal,
        .markedViewed(ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())),
        .insertedReview(agent: .codex),
        .resumed,
        .restored(RestoreDone(opID: "OP", root: "/repo", turnNumber: 3))
    ])
    func everyDoneLine_hasNoTag(_ result: DecisionBarContent.DoneResult) {
        for locale in [Self.english, Self.japanese] {
            let model = Self.model(.init(done: .init(result: result, next: nil)), locale: locale)
            #expect(model.tag == nil)
            #expect(model.tone == .done)
            #expect(!model.text.isEmpty)
        }
    }

    @Test func doneLineReflectsATerminalAnswerOrDecline_onlyWhenNothingElseWaits() throws {
        let handed = try #require(Self.items([.approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now)))]).first)
        let held = try #require(Self.items([.approval(ApprovalFact.test())]).first)
        let stop = try #require(Self.items([.stop(.processExited)]).first)
        let prompt = try #require(Self.items([.prompt(PromptWait(detail: nil))]).first)
        let timedOut = try #require(Self.items([.approval(ApprovalFact.test(state: .timedOut))]).first)

        for shown in [handed, prompt] {
            #expect(DecisionBarModel.doneUpdate(lastShown: shown, items: [], hasMovedOnSinceShown: false, isDeclined: true)
                == .set(.declinedInTerminal))
            #expect(DecisionBarModel.doneUpdate(lastShown: shown, items: [], hasMovedOnSinceShown: false)
                == .set(.answeredInTerminal))
            #expect(DecisionBarModel.doneUpdate(lastShown: shown, items: [], hasMovedOnSinceShown: true, isDeclined: true) == .keep)
            #expect(DecisionBarModel.doneUpdate(lastShown: shown, items: [], hasMovedOnSinceShown: true) == .keep)
        }
        #expect(DecisionBarModel.doneUpdate(lastShown: timedOut, items: [], hasMovedOnSinceShown: false) == .set(.answeredInTerminal))
        #expect(DecisionBarModel.doneUpdate(lastShown: held, items: [], hasMovedOnSinceShown: false, isDeclined: true) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: held, items: [], hasMovedOnSinceShown: false) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: stop, items: [], hasMovedOnSinceShown: false) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: handed, items: [stop], hasMovedOnSinceShown: false) == .clear)
        #expect(DecisionBarModel.doneUpdate(lastShown: nil, items: [], hasMovedOnSinceShown: false) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: handed, items: [prompt], hasMovedOnSinceShown: true) == .clear)
    }

    @Test func afterAnInsert_theBarSaysWhereTheCommentsWent_overThePanesItems() throws {
        let items = Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown))])
        let done = DecisionBarContent.Done(result: .insertedReview(agent: .claude), next: nil)

        let model = Self.model(.init(items: items, done: done))
        #expect(model.tag == nil)
        #expect(model.tone == .done)
        #expect(model.text == "Inserted the comments into Claude’s input. Press Return to send.")
        #expect(model.primaryAction == nil, "Return sends them; ⌘⏎ has nothing to press here")
        let japanese = Self.model(.init(items: items, done: done), locale: Self.japanese)
        #expect(japanese.text == "コメントを Claude の入力欄に挿入しました。Return を押すと送信されます。")
        // An item the person chose takes the bar back.
        let unreadID = try #require(items.first?.id)
        let chosen = Self.model(.init(items: items, selected: unreadID, done: done))
        #expect(chosen.content.itemID == unreadID)
        #expect(chosen.tag == "Unread")
        // Never over anything but unread turns: an approval, a stop, or a
        // prompt that Return would answer keeps the bar.
        let approval = Self.model(.init(items: Self.items([.approval(ApprovalFact.test())]), done: done))
        #expect(approval.tag == "Approval")
        let stopped = Self.model(.init(items: Self.items([.stop(.processExited)]), done: done))
        #expect(stopped.tag == "Stopped")
        let needsInput = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Allow edit?"))]), done: done))
        #expect(needsInput.tone != .done, "a permission the terminal asks itself is answered with Return")
        #expect(!DecisionBarContent.shows(.insertedReview(agent: .claude), over: Self.items([.prompt(PromptWait(detail: nil))])))
    }

    @Test(arguments: [
        (ChangeSummary.changed(files: 1, added: 1, removed: 0), true),
        (.unknown, true),
        (.pending, true),
        (.unchanged, false),
        (.unavailable(reason: "notGit"), false)
    ])
    func unreadTurnActions_requirePossibleFileChanges(changes: ChangeSummary, offersActions: Bool) throws {
        let turnID = TurnID("t")
        let itemID = AttentionItemID.unread(turnID)
        let conversation = TurnSummaryFixture.conversation
        var queue = AttentionQueue()
        queue.insert(
            id: itemID,
            kind: .unread(UnreadTurn(turnID: turnID, changes: changes, conversation: conversation)),
            subject: .runtime(id: "recorded", provider: .claude, paneID: Self.pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 1)
        )
        let item = try #require(queue.items.first)
        let bar = Self.model(.init(items: [item], agent: .init(provider: .codex, state: .idle, detail: nil)))
        #expect(bar.primaryAction == (offersActions ? .markReviewed(itemID, throughTurn: nil) : nil))
        #expect(bar.offersReview == offersActions)
        if offersActions {
            #expect(bar.reviewConversation == conversation)
        }
    }

    @Test func reviewIsUnavailableWithoutAnEligibleUnreadTurn() {
        let approval = Self.model(.init(items: Self.items([.approval(ApprovalFact.test())])))
        #expect(!approval.offersReview)
        #expect(approval.reviewConversation == nil)
        let stopped = Self.model(.init(items: Self.items([.stop(.processExited)])))
        #expect(stopped.primaryAction == nil)
        #expect(!stopped.offersReview)
        let empty = Self.model(.init())
        #expect(empty.primaryAction == nil)
        #expect(!empty.offersReview)
    }

    @Test func recordedTurns_areTaggedWithTheirNumbers_andGiveTheirReceipt() {
        let check = CheckSummary(command: "make test", isFiltered: true, exitCode: 0)
        let changed = UnreadTurn(
            turnID: TurnID("T6"),
            numbers: 6...7,
            changes: .changed(files: 2, added: 94, removed: 2),
            check: check,
            conversation: TurnSummaryFixture.conversation
        )
        let bar = Self.model(.init(items: Self.items([.unread(changed)])))
        #expect(bar.tag == "T6–T7")
        #expect(bar.text == "2 files +94 −2 · ✓ Tests (filtered)")
        // VoiceOver hears the turns as words and the facts as a list.
        #expect(bar.spokenTag == "Turns 6 to 7")
        #expect(bar.spokenText == "2 files +94 −2, ✓ Tests (filtered)")
        let japanese = Self.model(.init(items: Self.items([.unread(changed)])), locale: Self.japanese)
        #expect(japanese.spokenTag == "ターン 6 から 7")
        #expect(Self.model(.init(items: Self.items([.unread(changed)])), locale: Self.japanese).tag == "T6〜T7")

        let untaken = UnreadTurn(turnID: TurnID("T5"), numbers: 5...5, changes: .unavailable(reason: "notGit"))
        let notTaken = Self.model(.init(items: Self.items([.unread(untaken)])))
        #expect(notTaken.text == "Couldn’t get the changes")
        #expect(notTaken.primaryAction == nil)

        let unread = Self.model(.init(items: Self.items([.unread(UnreadTurn(
            turnID: TurnID("t"),
            changes: .unknown
        ))])))
        #expect(unread.tag == "Unread")
        #expect(unread.text == "The turn finished", "the tag already says unread")
    }

    @Test func aTurnThatOnlyAnswered_isNoItemOfTheBar_whichGivesItsReceiptAtRest() {
        let answered = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let resting = SessionRowFact.Agent(provider: .claude, state: .finished, detail: nil)

        let bar = Self.model(.init(items: Self.items([.unread(answered)]), agent: resting, lastTurn: answered))

        #expect(bar.content.itemID == nil)
        #expect(bar.tag == nil)
        #expect(bar.tone == .muted)
        #expect(bar.text == "T3 · No file changes")
        #expect(bar.spokenText == "Turn 3, No file changes")
        #expect(Self.model(.init(items: Self.items([.unread(answered)]), agent: resting, lastTurn: answered), locale: Self.japanese)
            .spokenText == "ターン 3、ファイルの変更なし")
        // While the agent works, what it does says more.
        let working = SessionRowFact.Agent(provider: .claude, state: .running, detail: "Bash: swift test")
        let running = Self.model(.init(items: Self.items([.unread(answered)]), agent: working, lastTurn: answered))
        #expect(running.content.itemID == nil)
        #expect(running.text == "Bash: swift test")
    }

    @Test func aTurnThatOnlyAnswered_isNeitherCountedNorStepped_beside_aChange() throws {
        let changed = UnreadTurn(turnID: TurnID("T5"), numbers: 5...5, changes: .changed(files: 1, added: 1, removed: 0))
        let answered = UnreadTurn(turnID: TurnID("T6"), numbers: 6...6, changes: .unchanged)
        let items = try Self.itemsInArrivalOrder([
            (.unread(changed.turnID), .unread(changed)),
            (.unread(answered.turnID), .unread(answered))
        ])

        let bar = Self.model(.init(items: items))

        #expect(bar.content.itemID == .unread(TurnID("T5")))
        #expect(bar.countText == nil, "one item for the bar")
        #expect(bar.content.position == nil)
    }

    @Test func markAsViewed_targetsTheLastTurnInTheShownReceipt() throws {
        let shown = UnreadTurn(turnID: TurnID("T6"), numbers: 6...7, changes: .changed(files: 2, added: 2, removed: 0))
        let grown = UnreadTurn(turnID: TurnID("T6"), numbers: 6...8, changes: .changed(files: 3, added: 3, removed: 0))
        let before = Self.model(.init(items: Self.items([.unread(shown)])))
        let after = Self.model(.init(items: Self.items([.unread(grown)])))
        let itemID = try #require(before.content.itemID)

        #expect(before.primaryAction == .markReviewed(itemID, throughTurn: 7))
        #expect(after.primaryAction == .markReviewed(itemID, throughTurn: 8))
    }

    @Test func rightAfterMarkingViewed_theBarSaysSo_withUndo() {
        let undo = ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())
        let english = Self.model(.init(done: .init(result: .markedViewed(undo), next: nil)))
        #expect(english.text == "Marked as viewed. Nothing needs attention.")
        #expect(english.undo == undo)
        #expect(english.primaryAction == nil)
        #expect(english.fits(locale: Self.english) == [.full, .minimal, .wordsOnly])
        #expect(english.shape(.full, locale: Self.english).moreSections.isEmpty)
        #expect(english.shape(.minimal, locale: Self.english).showsButtons)
        #expect(!english.shape(.wordsOnly, locale: Self.english).showsButtons)

        let japanese = Self.model(.init(done: .init(result: .markedViewed(undo), next: nil)), locale: Self.japanese)
        #expect(japanese.text == "確認済みにしました。要対応はありません。")
        #expect(Self.model(.init(done: .init(result: .answeredInTerminal, next: nil))).undo == nil)
    }

    @Test func aPaneWithNoAgent_hasNoBar() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let window = ProjectWindowState(selection: session.primarySelection)
        let sources = DecisionBarModel.Sources(
            session: session,
            window: window,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            next: nil
        )
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english) == nil)

        session.update(session.tab(containing: pane)?.id ?? UUID()) { tab in
            tab.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date())]
        }
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english)?.text == "Idle")
    }

    /// When the runtimes list an idle run before a running one in the same
    /// pane, the bar speaks for the running one, as the pane's header mark
    /// does.
    @Test func aPaneWithAnIdleRunListedBeforeARunningOne_speaksForTheRunningOne() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let finished = AgentRuntimePresentation.test(
            kind: .claude,
            runID: "a",
            badge: AgentBadge(state: .idle, updatedAt: Date()),
            paneIDs: [pane]
        )
        let running = AgentRuntimePresentation.test(
            kind: .codex,
            runID: "b",
            badge: AgentBadge(state: .running, detail: "Bash: make test", updatedAt: Date()),
            paneIDs: [pane]
        )
        let sources = DecisionBarModel.Sources(
            session: session,
            window: ProjectWindowState(selection: session.primarySelection),
            queue: AttentionQueue(),
            runtimes: [finished, running],
            approvals: ApprovalLedger(),
            next: nil
        )
        #expect(DecisionBarModel.runtime(in: pane, runtimes: sources.runtimes)?.id == running.id)
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english)?.text == "Bash: make test")
    }

    @Test func theNextItem_namesItsProject_onlyWhenItIsAnotherProjects() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) { $0.titleOverride = "build" }
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date())] }
        let window = ProjectWindowState(selection: session.primarySelection)
        window.decisionBarDone[pane] = .answeredInTerminal
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: tab.id, projectID: project.id),
            arrivedAt: Date()
        )
        let next = try #require(queue.items.first)

        func model(windowProjectID: UUID?) -> DecisionBarModel? {
            DecisionBarModel(
                paneID: pane,
                sources: .init(
                    session: session,
                    window: window,
                    queue: AttentionQueue(),
                    runtimes: [],
                    approvals: ApprovalLedger(),
                    next: (next, windowProjectID)
                ),
                locale: Self.english
            )
        }
        func text(windowProjectID: UUID?) -> String? {
            model(windowProjectID: windowProjectID)?.text
        }
        // The row is named, so its place adds its folder: the fixture's
        // folder is not the project's name.
        let folder = project.rootURL.lastPathComponent
        #expect(text(windowProjectID: project.id) == "Answered in the terminal. Next: “build” (⌘J).")
        let other = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("other"), suggestedName: "other"
        )
        #expect(text(windowProjectID: other.id) == "Answered in the terminal. Next: “build · weir / \(folder)” (⌘J).")
        #expect(text(windowProjectID: nil) == "Answered in the terminal. Next: “build · weir / \(folder)” (⌘J).")
        // VoiceOver hears neither the key's symbols nor the separator.
        #expect(model(windowProjectID: nil)?.spokenText == "Answered in the terminal. Next: “build, weir / \(folder)”.")
    }

    // MARK: - Usage limit stops

    private static let usageLimitReset = Date(timeIntervalSince1970: 1_790_003_600)
    private static let usageLimit = UsageLimit(resetAt: usageLimitReset, window: "five_hour")
    /// An hour before the reset, so the bar names it.
    private static let beforeReset = usageLimitReset.addingTimeInterval(-3600)

    private static func usageLimitBar(
        _ notice: UsageLimitResetNotice?,
        now: Date = beforeReset,
        locale: Locale = english
    ) -> DecisionBarModel {
        let item = AttentionItem.testUsageLimitStop(usageLimit, arrivedAt: Self.beforeReset)
        let content = DecisionBarContent.make(.init(
            items: [item],
            agent: .init(provider: .claude, state: .error, detail: nil),
            stopResumes: [item.id: .available]
        ))
        return DecisionBarModel(content: content, resetNotice: notice, now: now, locale: locale)
    }

    @Test func aLimitInTheAgentsOwnWords_endsWithOneFullStop() {
        // As recorded in fixtures/opencode/2026-11/free-limit.
        let words = "Free usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models."
        let item = AttentionItem.testUsageLimitStop(
            UsageLimit(scope: .upstream, label: words), provider: .opencode, arrivedAt: Self.beforeReset
        )
        let content = DecisionBarContent.make(.init(
            items: [item],
            agent: .init(provider: .opencode, state: .error, detail: nil),
            stopResumes: [item.id: .available]
        ))
        let bar = DecisionBarModel(content: content, resetNotice: nil, now: Self.beforeReset, locale: Self.english)
        #expect(bar.text == words + " The conversation is saved.")
        #expect(bar.runs == [
            ReceiptRun(text: words, role: .emphasized),
            ReceiptRun(text: " The conversation is saved.", role: .plain)
        ])
    }

    @Test func usageLimitStop_offersTheNoticeInPlaceOfResumingWhileTheLimitHolds() throws {
        let offered = Self.usageLimitBar(.offered)
        let itemID = try #require(offered.content.itemID)
        #expect(offered.primaryAction == .notifyAtReset(itemID))
        #expect(!offered.text.contains("The conversation is saved."))

        let requested = Self.usageLimitBar(.requested)
        #expect(requested.primaryAction == nil)
        let resetTime = StopReasonText.resetTime(Self.usageLimitReset, locale: Self.english, now: Self.beforeReset)
        #expect(requested.text == "5-hour limit reached · resets \(resetTime). You’ll be notified when it resets.")
        let japaneseTime = StopReasonText.resetTime(Self.usageLimitReset, locale: Self.japanese, now: Self.beforeReset)
        #expect(
            Self.usageLimitBar(.requested, locale: Self.japanese).text
                == "5 時間枠の上限に達しました · \(japaneseTime) に解除。解除されたら通知します。"
        )
        // The bar is worded at the time it is given: past the reset, the
        // time goes from the limit's sentence.
        let past = Self.usageLimitBar(nil, now: Self.usageLimitReset.addingTimeInterval(1))
        #expect(past.text == "5-hour limit reached. The conversation is saved.")
        // Only the reason is set apart; what follows it reads plain.
        #expect(past.runs == [
            ReceiptRun(text: "5-hour limit reached", role: .emphasized),
            ReceiptRun(text: ". The conversation is saved.", role: .plain)
        ])

        // Once the provider is free (or with no time known) it resumes as
        // any stop, the sentences set apart.
        let free = Self.usageLimitBar(nil)
        #expect(free.primaryAction == .resume(itemID))
        #expect(free.text.contains(". The conversation is saved."))
    }

    // MARK: - The unread turns' ⋯

    @Test func unreadTurnsThatMayHaveChangedFiles_offerARestoreToTheFirstOfThem() {
        let changed = ChangeSummary.changed(files: 1, added: 3, removed: 1)
        func entry(numbers: ClosedRange<Int>?, changes: ChangeSummary, conversation: ConversationKey?) -> DecisionBarModel.RestoreEntry? {
            let unread = UnreadTurn(turnID: TurnID("T5"), numbers: numbers, changes: changes, conversation: conversation)
            return Self.model(.init(items: Self.items([.unread(unread)]))).restoreEntry(locale: Self.english)
        }
        let conversation = TurnSummaryFixture.conversation

        let one = entry(numbers: 5...5, changes: changed, conversation: conversation)
        #expect(one?.turnID == TurnID("T5"))
        #expect(one?.title == "Restore Code to Before This Turn…")
        // Several turns: "this turn" would not say which.
        #expect(entry(numbers: 5...7, changes: changed, conversation: conversation) == .init(
            turnID: TurnID("T5"), turnNumber: 5, title: "Restore Code to Before T5…"
        ))
        #expect(entry(numbers: 5...5, changes: .unchanged, conversation: conversation) == nil, "nothing to take back")
        #expect(entry(numbers: 5...5, changes: .unavailable(reason: "notGit"), conversation: conversation) == nil)
        #expect(entry(numbers: nil, changes: changed, conversation: conversation) == nil)
        #expect(entry(numbers: 5...5, changes: changed, conversation: nil) == nil)
    }

    // MARK: - The row in each fit

    /// Unread turns: folded, "Review Unviewed" heads the ⋯ and "⌘⏎" goes;
    /// at the least, the tag goes too and the count moves into the ⋯,
    /// above what shows something, with the restore apart at the end.
    @Test func unreadTurns_foldIntoTheMoreMenu_inTurn() throws {
        let unread = UnreadTurn(
            turnID: TurnID("T5"),
            numbers: 5...5,
            changes: .changed(files: 1, added: 3, removed: 1),
            conversation: TurnSummaryFixture.conversation
        )
        let items = try Self.itemsInArrivalOrder([
            (.unread(unread.turnID), .unread(unread)),
            (.stop(EpisodeKey(origin: .runtime("agent"), episodeToken: "exit")), .stop(.processExited))
        ])
        let bar = Self.model(.init(items: items, selected: .unread(TurnID("T5"))))
        #expect(bar.content.itemID == .unread(TurnID("T5")))
        let entry = try #require(bar.restoreEntry(locale: Self.english))
        #expect(bar.countText != nil)
        #expect(bar.fits(locale: Self.english) == DecisionBarModel.Fit.allCases)

        let full = bar.shape(.full, locale: Self.english)
        #expect(full.showsTag && full.showsCount && full.showsReview && full.showsKeyHint)
        #expect(full.moreSections == [[.restore(entry)]])

        let folded = bar.shape(.folded, locale: Self.english)
        #expect(folded.showsTag && folded.showsCount)
        #expect(!folded.showsReview && !folded.showsKeyHint)
        #expect(folded.moreSections == [[.review], [.restore(entry)]])

        let minimal = bar.shape(.minimal, locale: Self.english)
        #expect(!minimal.showsTag && !minimal.showsCount)
        // "Mark as Viewed" is short as it is.
        #expect(!minimal.usesShortLabels)
        #expect(minimal.moreSections == [[.showNext], [.review], [.restore(entry)]])
        #expect(minimal.showsButtons && !minimal.keepsWordsFloor)
        #expect(full.keepsWordsFloor && folded.keepsWordsFloor)

        // Too narrow for any button: the words alone, and no ⋯; ⌘⏎ still
        // presses the primary action.
        let wordsOnly = bar.shape(.wordsOnly, locale: Self.english)
        #expect(!wordsOnly.showsButtons && !wordsOnly.showsTag && !wordsOnly.showsCount)
        #expect(wordsOnly.moreSections.isEmpty)
        #expect(bar.primaryAction != nil)
    }

    /// A workspace whose worktree is gone offers to close its tabs, and
    /// nothing a stopped conversation offers: there is no folder to resume
    /// or start in.
    @Test func aMissingWorktree_offersToCloseItsTabs() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, isMissing: true, admission: .opened)
        let missing = session.openTab(container: .worktree(projectID: project.id, worktreeID: worktree.id))
        let elsewhere = session.openTab(container: .project(project.id))
        let shell = session.openTab(container: .worktree(projectID: project.id, worktreeID: worktree.id))
        let pane = try #require(missing.splitTree.allLeafIDs().first)
        let otherPane = try #require(elsewhere.splitTree.allLeafIDs().first)
        let shellPane = try #require(shell.splitTree.allLeafIDs().first)
        for (tab, id) in [(missing, pane), (elsewhere, otherPane)] {
            session.update(tab.id) { $0.agentBadges[.claude] = [id: AgentBadge(state: .idle, updatedAt: .distantPast)] }
        }
        let root = try #require(session.rootDirectory(of: missing.container))
        let subject = AttentionSubject.sessionRow(projectID: project.id, worktreeRoot: root)
        let itemID = AttentionItemID.stop(EpisodeKey(origin: .sessionRow(worktreeRoot: root), episodeToken: "missing"))
        var queue = AttentionQueue()
        queue.insert(id: itemID, kind: .stop(.worktreeMissing), subject: subject, arrivedAt: .distantPast)
        let sources = DecisionBarModel.Sources(
            session: session, window: ProjectWindowState(selection: session.primarySelection),
            queue: queue, runtimes: [], approvals: ApprovalLedger(), next: nil
        )

        let bar = try #require(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english))
        #expect(bar.tag == "Stopped")
        #expect(bar.text == "Worktree not found.")
        #expect(bar.primaryAction == .closeAllTabs(itemID))
        #expect(bar.stopItem == nil)
        #expect(bar.shape(.full, locale: Self.english).moreSections.isEmpty)
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.japanese)?.text == "ワークツリーが見つかりません。")
        let other = try #require(DecisionBarModel(paneID: otherPane, sources: sources, locale: Self.english))
        #expect(other.text == "Idle")
        #expect(other.primaryAction == nil)
        #expect(DecisionBarModel(paneID: shellPane, sources: sources, locale: Self.english) == nil)
    }

    /// A bar with no buttons has one fit, so it draws its row once.
    @Test func barsWithoutButtons_haveOneFit() {
        let bars = [
            Self.model(.init()),
            Self.model(.init(items: Self.items([.approval(ApprovalFact.test(state: .timedOut))]))),
            Self.model(.init(items: Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: .unchanged))])))
        ]
        for bar in bars {
            #expect(bar.fits(locale: Self.english) == [.full], "\(bar.text)")
            #expect(bar.shape(.full, locale: Self.english).moreSections.isEmpty, "\(bar.text)")
        }
    }

}

// MARK: - Item navigation

extension DecisionBarModelTests {
    @Test func aPaneWithTwoItems_countsThemInTheOrderTheyArrived() throws {
        // The stop arrived first, the approval after it.
        let handed = ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now))
        let items = Self.items([.stop(.processExited), .approval(handed)])
        let stopID = try #require(items.first?.id)
        let approvalID = try #require(items.last?.id)

        let reversed = Array(items.reversed())
        let unchosen = Self.model(.init(items: reversed))
        #expect(unchosen.tag == "Approval", "unchosen, the highest-ranked item")
        #expect(unchosen.countText == "2 / 2")

        let onStop = Self.model(.init(items: reversed, selected: stopID))
        #expect(onStop.tag == "Stopped")
        #expect(onStop.countText == "1 / 2")
        #expect(onStop.countSpokenText == "Needs Attention in this pane: 1 of 2")
        #expect(Self.model(.init(items: reversed, selected: stopID), locale: Self.japanese).countSpokenText
            == "このペインの要対応、2 件中 1 件目")

        #expect(onStop.content.position?.next == approvalID)
        #expect(onStop.content.position?.previous == approvalID)
        #expect(unchosen.content.position?.next == stopID, "it wraps")
    }

    @Test func threeItems_stepBothWays_inTheOrderTheyArrived() throws {
        let approval = ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now))
        let turn = UnreadTurn(turnID: TurnID("T1"), numbers: 1...1, changes: .changed(files: 1, added: 1, removed: 0))
        let stopID = AttentionItemID.stop(EpisodeKey(origin: .runtime("agent"), episodeToken: "exit"))
        let approvalID = AttentionItemID.approval(approval.key)
        let unreadID = AttentionItemID.unread(TurnID("T1"))
        let items = try Self.itemsInArrivalOrder([
            (stopID, .stop(.processExited)), (approvalID, .approval(approval)), (unreadID, .unread(turn))
        ])
        let shuffled = try [unreadID, stopID, approvalID].map { id in
            try #require(items.first { $0.id == id })
        }
        let positions: [(AttentionItemID, DecisionBarContent.Position)] = [
            (stopID, .init(index: 1, count: 3, previous: unreadID, next: approvalID)),
            (approvalID, .init(index: 2, count: 3, previous: stopID, next: unreadID)),
            (unreadID, .init(index: 3, count: 3, previous: approvalID, next: stopID))
        ]
        for (selected, position) in positions {
            let content = Self.model(.init(items: shuffled, selected: selected)).content
            #expect(content.itemID == selected)
            #expect(content.position == position)
        }
    }
}

// MARK: - Request location

extension DecisionBarModelTests {
    private struct ApprovalLocationCase {
        let state: ApprovalRequestState
        let place: DecisionBarContent.AnswerPlace
        let instruction: String
        let shortInstruction: String

        init(_ state: ApprovalRequestState, _ place: DecisionBarContent.AnswerPlace, _ instruction: String, short: String? = nil) {
            self.state = state
            self.place = place
            self.instruction = instruction
            shortInstruction = short ?? instruction
        }
    }

    @Test func approvalLocation_decidesItsDeadlineAndActions() {
        let now = SuspendingClock().now
        let deadline = ServiceDeadline(deadlineMs: 522_000, serviceNowMs: 0, receivedAt: now)
        let cases: [ApprovalLocationCase] = [
            .init(.held, .card(heldUntil: deadline), "Answer in the terminal or on the card"),
            .init(.sendFailed(.deny, error: "offline"), .card(heldUntil: deadline), "Answer in the terminal or on the card"),
            .init(.handedToTerminal(since: now), .terminal, "Answer in the terminal", short: "Answer in terminal"),
            .init(.timedOut, .terminalAfterTimeout, "Timed out. Answer in the terminal.", short: "Timed out — answer in terminal"),
            .init(.sending(.delegate, since: now), .terminal, "Answer in the terminal", short: "Answer in terminal"),
            .init(.sending(.allowOnce, since: now), .sending, "Sending…")
        ]
        for row in cases {
            let fact = ApprovalFact.test(state: row.state, deadline: deadline)
            let itemID = AttentionItemID.approval(fact.key)
            let input = DecisionBarContent.Input(items: Self.items([.approval(fact)]), approvalActions: [fact.key: .command])
            let bar = Self.model(input)
            #expect(bar.content.body == .approval(provider: .claude, action: .command, answer: row.place))
            #expect(bar.content.itemID == itemID)
            #expect(bar.tag == "Approval")
            #expect(bar.tone == .waiting)
            #expect(bar.text == "Claude wants to run a command.")
            #expect(bar.instruction == row.instruction)
            #expect(bar.shortInstruction == row.shortInstruction)
            let full = bar.shape(.full, locale: Self.english)
            if case .card = row.place {
                #expect(bar.isAnsweredOnCard)
                #expect(bar.heldUntil == deadline)
                #expect(bar.primaryAction == .openCard(itemID))
                #expect(full.moreSections == [[.answerInTerminal(itemID)]])
                #expect(full.showsKeyHint)
            } else {
                #expect(!bar.isAnsweredOnCard)
                #expect(bar.heldUntil == nil)
                #expect(bar.primaryAction == nil)
                #expect(full.moreSections.isEmpty)
                #expect(!full.showsKeyHint)
            }
        }
        let timedOut = ApprovalFact.test(state: .timedOut, deadline: deadline)
        let japanese = Self.model(.init(items: Self.items([.approval(timedOut)])), locale: Self.japanese)
        #expect(japanese.shortInstruction == "時間切れ（ターミナルで回答）")
    }

    @Test func questionLocation_followsNativeSupportAndHandoff() {
        let native = ApprovalFact.test(isQuestion: true)
        let held = Self.model(.init(items: Self.items([.question(native)])))
        #expect(held.primaryAction == .openCard(.question(native.key)))

        let codex = ApprovalFact.test(isQuestion: true, provider: .codex)
        let unsupported = Self.model(.init(items: Self.items([.question(codex)], provider: .codex)))
        #expect(unsupported.primaryAction == nil)
        #expect(unsupported.instruction == "Answer in the terminal")

        let handed = ApprovalFact.test(isQuestion: true, state: .handedToTerminal(since: SuspendingClock().now))
        let terminal = Self.model(.init(items: Self.items([.question(handed)])))
        #expect(terminal.tag == "Question")
        #expect(terminal.text == "Claude is asking a question.")
        #expect(terminal.instruction == "Answer in the terminal")
        #expect(terminal.shortInstruction == "Answer in terminal")
        #expect(!terminal.cutsTextInMiddle)
        #expect(terminal.textHelp == nil)
        #expect(terminal.primaryAction == nil)
    }
}

@MainActor
extension DecisionBarModelTests {
    @Test func aQuestionsBody_namesItsExactAnswerDestination() {
        let now = SuspendingClock.now
        let deadline = ServiceDeadline(deadlineMs: 522_000, serviceNowMs: 0, receivedAt: now)
        let rows: [(ApprovalRequestState, DecisionBarContent.AnswerPlace)] = [
            (.held, .card(heldUntil: deadline)),
            (.sendFailed(.deny, error: "offline"), .card(heldUntil: deadline)),
            (.sending(.allowOnce, since: now), .sending),
            (.sending(.delegate, since: now), .terminal),
            (.handedToTerminal(since: now), .terminal),
            (.timedOut, .terminalAfterTimeout),
            (.withdrawn, .terminal),
            (.unknownResult, .terminal),
            (.answered(.allowOnce), .terminal)
        ]
        for (state, native) in rows {
            for provider in [AgentKind.claude, .codex] {
                let fact = ApprovalFact.test(isQuestion: true, provider: provider, state: state, deadline: deadline)
                var queue = AttentionQueue()
                queue.insert(
                    id: .question(fact.key),
                    kind: .question(fact),
                    subject: .unplaced(provider: provider),
                    arrivedAt: Date(timeIntervalSince1970: 0)
                )
                let content = DecisionBarContent.make(.init(
                    items: queue.items, agent: SessionRowFact.Agent(provider: provider, state: .needsInput, detail: nil)
                ))
                #expect(
                    content.body == .question(provider: provider, answer: provider == .claude ? native : .terminal),
                    "\(state), \(provider)"
                )
            }
        }
    }
}
