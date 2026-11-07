// DomainRuleOwnerTests.swift
// Weir — each agent-state, attention, turn, and lookup rule read from its one owner.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct DomainRuleOwnerTests {

    // MARK: - Agent states

    @Test func theStatePredicates_coverTheExactLifecycleStates() {
        let states = AgentState.allCases
        #expect(Set(states.filter(\.isWorking)) == [.running, .compacting])
        #expect(Set(states.filter(\.isAtPrompt)) == [.idle, .finished])
        #expect(Set(states.filter(\.isMidTurn)) == [.running, .compacting, .needsInput])
    }

    // MARK: - Attention kinds

    /// One kind and what the rules say of it.
    struct KindCase {
        let kind: AttentionItemKind
        let category: AttentionCategory
        let asksPerson: Bool
        let isBlocking: Bool
    }

    private static let kinds: [KindCase] = [
        KindCase(kind: .approval(.test()), category: .approval, asksPerson: true, isBlocking: true),
        KindCase(kind: .question(.test(isQuestion: true)), category: .question, asksPerson: true, isBlocking: true),
        KindCase(
            kind: .prompt(.approval(PromptApproval(recorded: "Bash", tool: "Bash"))),
            category: .approval,
            asksPerson: true,
            isBlocking: true
        ),
        KindCase(kind: .prompt(.question(detail: "Which?")), category: .question, asksPerson: true, isBlocking: true),
        KindCase(kind: .prompt(.unclassified(detail: nil)), category: .response, asksPerson: true, isBlocking: true),
        KindCase(kind: .prompt(.signIn), category: .signIn, asksPerson: true, isBlocking: true),
        KindCase(kind: .stop(.processExited), category: .stop, asksPerson: false, isBlocking: true),
        KindCase(
            kind: .unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown)),
            category: .unread,
            asksPerson: false,
            isBlocking: false
        )
    ]

    @Test func eachKind_hasItsCategory_andWhetherItAsksOrBlocks() {
        for entry in Self.kinds {
            #expect(entry.kind.category == entry.category, "\(entry.kind)")
            #expect(entry.kind.asksPerson == entry.asksPerson, "\(entry.kind)")
            #expect(entry.kind.isBlocking == entry.isBlocking, "\(entry.kind)")
        }
    }

    /// The glyph, the Needs Attention list's row, the counts, and the pane's
    /// frame each read the category, so a kind is the same thing on every
    /// one of them.
    @Test func everyReader_sortsAKindByItsCategory() {
        let items = AttentionItem.testList(Self.kinds.map(\.kind))
        let rows = NeedsAttentionListModel(
            items: items,
            names: { _ in NeedsAttentionListModel.Names(title: "s", place: nil) },
            request: { _ in nil },
            windowProjectID: .none,
            locale: Locale(identifier: "en")
        ).rows
        #expect(rows.map(\.id) == items.map(\.id), "one row per item, in the list's order")
        for (entry, (item, row)) in zip(Self.kinds, zip(items, rows)) {
            let (kind, category) = (entry.kind, entry.category)
            let glyph = SessionRowFact.glyph(of: kind)
            let counts = AttentionQueue.counts(of: [item])
            // The item alone in its pane, so the frame is this kind's.
            let frame = PaneAttention.of([item])
            switch category {
            case .question:
                #expect(glyph == .needsAnswer && row.state == .question && counts.questions == 1 && frame == .needsAnswer, "\(kind)")
            case .approval:
                #expect(glyph == .needsApproval && row.state == .approval && counts.approvals == 1 && frame == .needsApproval, "\(kind)")
            case .response:
                #expect(glyph == .needsResponse && row.state == .response && counts.prompts == 1 && frame == .needsResponse, "\(kind)")
            case .signIn:
                #expect(glyph == .needsSignIn && row.state == .signIn && counts.signIns == 1 && frame == .needsSignIn, "\(kind)")
            case .stop:
                #expect(glyph == .stopped && row.state == .stopped && counts.stops == 1 && frame == .stopped, "\(kind)")
            case .unread:
                #expect(glyph == .unread && row.state == .unread && counts.unread == 1 && frame == nil, "\(kind)")
            }
            #expect(counts.hasBlockingItems == kind.isBlocking, "\(kind)")
        }
    }

    /// A question comes first, then every other wait, then a stop, then an
    /// unread turn, whatever order they arrived in.
    @Test func thePanesPriority_followsTheCategories() {
        let items = AttentionItem.testList([
            .unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown)),
            .stop(.processExited),
            .prompt(.signIn),
            .prompt(.question(detail: nil))
        ])
        #expect(PanePriority.dominant(items)?.kind.category == .question)
        #expect(PanePriority.dominant(Array(items.prefix(3)))?.kind.category == .signIn)
        #expect(PanePriority.dominant(Array(items.prefix(2)))?.kind.category == .stop)
        #expect(PanePriority.dominant(Array(items.prefix(1)))?.kind.category == .unread)
        #expect(PanePriority.dominant([]) == nil)
    }

    /// An approval, a wait we cannot name, and a sign-in share one rank, so
    /// among them the one that arrived first leads, in either order.
    @Test func theWaitsRankedWithApprovals_leadByArrival() {
        let waits: [AttentionItemKind] = [.approval(.test()), .prompt(.unclassified(detail: nil)), .prompt(.signIn)]
        for order in [waits, waits.reversed()] {
            let items = AttentionItem.testList(order)
            #expect(PanePriority.dominant(items)?.id == items.first?.id, "\(order.map(\.category))")
            #expect(PanePriority.dominant(Array(items.dropFirst()))?.id == items.dropFirst().first?.id)
        }
    }

    /// The restore strip yields to what asks the person, and "Create PR"
    /// waits on what blocks; a stop is the one kind that does one and not
    /// the other.
    @Test func aStop_blocksCreatePR_butLeavesTheRestoreStrip() {
        let stop = AttentionItem.testList([.stop(.processExited)])
        #expect(!RestoreStrip.yields(to: stop))
        #expect(CommitAndPRModel.isWaiting(stop))
        let unread = AttentionItem.testList([.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown))])
        #expect(!RestoreStrip.yields(to: unread))
        #expect(!CommitAndPRModel.isWaiting(unread))
        let prompt = AttentionItem.testList([.prompt(.signIn)])
        #expect(RestoreStrip.yields(to: prompt))
        #expect(CommitAndPRModel.isWaiting(prompt))
    }

    // MARK: - Turns

    @Test func aTurn_isEndedAndPrompted_onlyOnceOverAndAskedFor() throws {
        #expect(try TurnSummaryFixture.turn("a", phase: "finished").isEndedAndPrompted)
        #expect(try TurnSummaryFixture.turn("b", phase: "unknown").isEndedAndPrompted, "an overtaken turn is over")
        #expect(try !TurnSummaryFixture.turn("c", phase: "started").isEndedAndPrompted)
        #expect(try !TurnSummaryFixture.turn("d", phase: "finished", hasPrompt: false).isEndedAndPrompted)
    }

    @Test func aTurn_isReviewable_whenEndedPromptedAndMayHaveChanged() throws {
        let changed = #"{"kind":"changed","files":1,"added":1,"removed":0}"#
        let pending = #"{"kind":"pending"}"#
        let unavailable = #"{"kind":"unavailable","reason":"endMissing"}"#
        #expect(try TurnSummaryFixture.turn("a", changes: changed).isReviewable)
        #expect(try TurnSummaryFixture.turn("b", changes: pending).isReviewable)
        #expect(try !TurnSummaryFixture.turn("c").isReviewable, "nothing changed")
        #expect(try !TurnSummaryFixture.turn("d", changes: unavailable).isReviewable)
        #expect(try !TurnSummaryFixture.turn("e", phase: "started", changes: changed).isReviewable)
        #expect(try !TurnSummaryFixture.turn("f", changes: changed, hasPrompt: false).isReviewable)
    }

    // MARK: - Lookups

    @Test func aSessionRowsWorktree_isFoundByItsFolder_withOrWithoutATrailingSlash() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let plain = AttentionSubject.sessionRow(projectID: project.id, worktreeRoot: worktree.workingDirectory)
        let slashed = AttentionSubject.sessionRow(
            projectID: project.id,
            worktreeRoot: URL(fileURLWithPath: worktree.workingDirectory.path + "/")
        )
        #expect(session.worktree(forSessionRow: plain)?.id == worktree.id)
        #expect(session.worktree(forSessionRow: slashed)?.id == worktree.id)
        #expect(session.worktree(forSessionRow: .sessionRow(projectID: nil, worktreeRoot: worktree.workingDirectory)) == nil)
        #expect(session.worktree(forSessionRow: .sessionRow(projectID: UUID(), worktreeRoot: worktree.workingDirectory)) == nil)
        #expect(session.worktree(forSessionRow: .unplaced(provider: .claude)) == nil)
    }

    @Test func aWorktree_isFoundInItsProject_byTheSessionOrTheProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let current = try #require(session.project(project.id))
        #expect(current.worktree(worktree.id)?.id == worktree.id)
        #expect(current.worktree(UUID()) == nil)
        #expect(session.worktree(projectID: project.id, worktreeID: worktree.id)?.id == worktree.id)
        #expect(session.worktree(projectID: UUID(), worktreeID: worktree.id) == nil)
    }

    @Test func aWindowsFocusedPane_isItsTabsFocusedLeaf() {
        let (session, tab, paneID) = WorkspaceSessionFixture.withLooseTab()
        #expect(session.focusedPaneID(in: session.primaryWindowID) == paneID)
        #expect(session.focusedPaneID(in: session.primaryWindowID) == tab.splitTree.effectiveFocusedLeafID)
        #expect(session.focusedPaneID(in: WindowID()) == nil, "a window the session does not know shows no tab")
    }

    /// The model's agent and `hasBar` are one test: a pane with neither a
    /// run nor a stop has no bar, and a stop of an agent gives it one.
    @Test func aPanesBarAgent_isWhatHasBarReads() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        #expect(DecisionBarModel.barAgent(in: pane, items: [], runtimes: [], session: session) == nil)
        #expect(!DecisionBarModel.hasBar(in: pane, runtimes: [], session: session, queue: AttentionQueue()))

        var queue = AttentionQueue()
        let stop = AttentionItem.testStop(pane: pane)
        queue.insert(id: stop.id, kind: stop.kind, subject: stop.subject, arrivedAt: Date())
        let agent = DecisionBarModel.barAgent(in: pane, items: queue.items(inPane: pane), runtimes: [], session: session)
        #expect(agent?.provider == .claude)
        #expect(DecisionBarModel.hasBar(in: pane, runtimes: [], session: session, queue: queue))
    }

    @Test func aDeleteTarget_isNamedAndPlacedAsItsWorktree() {
        let projectID = UUID()
        let worktree = WorktreeFixture.make(label: "feat/login")
        let target = DeleteWorktreeTarget(projectID: projectID, worktree: worktree)
        #expect(target.projectID == projectID)
        #expect(target.worktreeID == worktree.id)
        #expect(target.label == "feat/login")
        #expect(target.path == worktree.workingDirectory)
    }

    @Test func aBranchsWorktreeFolder_isNoneForAnEmptyBranch() {
        let (_, project) = WorkspaceSessionFixture.withProject()
        #expect(project.worktreeURL(forBranch: "") == nil)
        #expect(project.worktreeURL(forBranch: "feat/a") == project.resolvedWorktreeURL(branchLeaf: "feat-a"))
    }
}
