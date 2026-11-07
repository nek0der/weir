// AttentionQueueTests.swift
// Weir — the attention list's order, numbering, and per-pane priority.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct AttentionQueueTests {
    private static let pane = UUID()
    private static let otherPane = UUID()
    private static let start = Date(timeIntervalSince1970: 1000)
    private static let tab = UUID()
    private static let otherTab = UUID()

    private static func subject(pane: UUID = pane) -> AttentionSubject {
        .runtime(id: "run", provider: .claude, paneID: pane, tabID: pane == Self.pane ? tab : otherTab, projectID: nil)
    }

    private static func approvalKey() -> ApprovalKey {
        ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
    }

    private static func fact(
        _ key: ApprovalKey,
        isQuestion: Bool = false,
        provider: AgentKind = .claude,
        supportsNativeAnswer: Bool = true,
        state: ApprovalRequestState = .timedOut
    ) -> ApprovalFact {
        ApprovalFact(
            key: key,
            provider: provider,
            isQuestion: isQuestion,
            supportsNativeAnswer: supportsNativeAnswer,
            state: state,
            deadline: nil
        )
    }

    private static func stopID(_ token: String) -> AttentionItemID {
        .stop(EpisodeKey(origin: .runtime("run"), episodeToken: token))
    }

    private static func unread(_ id: String) -> (AttentionItemID, AttentionItemKind) {
        let turn = TurnID(id)
        return (.unread(turn), .unread(UnreadTurn(turnID: turn, changes: .unknown)))
    }

    @Test func insert_numbersArrivalsAndPreservesTheFirstItemOnDuplicate() {
        var queue = AttentionQueue()
        let first = Self.approvalKey()
        let firstKind = AttentionItemKind.approval(Self.fact(first, state: .held))
        let second = Self.unread("b")
        let firstSubject = Self.subject()
        let insertedFirst = queue.insert(id: .approval(first), kind: firstKind, subject: firstSubject, arrivedAt: Self.start)
        let insertedSecond = queue.insert(
            id: second.0,
            kind: second.1,
            subject: Self.subject(),
            arrivedAt: Self.start.addingTimeInterval(-1)
        )
        #expect(insertedFirst)
        #expect(insertedSecond)
        let before = queue.items

        let insertedDuplicate = queue.insert(
            id: .approval(first),
            kind: .approval(Self.fact(first, state: .withdrawn)),
            subject: Self.subject(pane: Self.otherPane),
            arrivedAt: Self.start.addingTimeInterval(1)
        )
        #expect(!insertedDuplicate)
        #expect(queue.items == before)
        let third = Self.unread("c")
        let insertedThird = queue.insert(id: third.0, kind: third.1, subject: Self.subject(), arrivedAt: Self.start)
        #expect(insertedThird)
        #expect(queue.items.map(\.id) == [.approval(first), second.0, third.0])
        #expect(queue.items.map(\.arrivalSequence) == [1, 2, 3])
        #expect(queue.items.first == AttentionItem(
            id: .approval(first), kind: firstKind, subject: firstSubject, arrivalSequence: 1, arrivedAt: Self.start
        ))
    }

    @Test(arguments: [false, true])
    func update_changesContentAndOptionallyTheSubjectWithoutMovingTheItem(movesPane: Bool) {
        var queue = AttentionQueue()
        let key = Self.approvalKey()
        let id = AttentionItemID.approval(key)
        let (other, otherKind) = Self.unread("a")
        let source = Self.subject()
        let target = AttentionSubject.runtime(id: "run", provider: .claude, paneID: Self.otherPane, tabID: UUID(), projectID: UUID())
        queue.insert(id: id, kind: .approval(Self.fact(key, state: .held)), subject: source, arrivedAt: Self.start)
        queue.insert(id: other, kind: otherKind, subject: Self.subject(), arrivedAt: Self.start)
        let originalSecond = queue.items.last
        let newKind = AttentionItemKind.approval(Self.fact(key, state: .timedOut))

        queue.update(id: id, kind: newKind, subject: movesPane ? target : nil)

        #expect(queue.items.map(\.id) == [id, other])
        #expect(queue.items.first == AttentionItem(
            id: id, kind: newKind, subject: movesPane ? target : source, arrivalSequence: 1, arrivedAt: Self.start
        ))
        #expect(queue.items.last == originalSecond)
        #expect(queue.items(inPane: Self.pane).map(\.id) == (movesPane ? [other] : [id, other]))
        #expect(queue.items(inPane: Self.otherPane).map(\.id) == (movesPane ? [id] : []))
    }

    @Test func update_unknownID_doesNothing() {
        var queue = AttentionQueue()
        let (existing, existingKind) = Self.unread("existing")
        let (unknown, unknownKind) = Self.unread("unknown")
        queue.insert(id: existing, kind: existingKind, subject: Self.subject(), arrivedAt: Self.start)
        let before = queue.items

        queue.update(id: unknown, kind: unknownKind, subject: Self.subject(pane: Self.otherPane))

        #expect(queue.items == before)
        queue.insert(id: unknown, kind: unknownKind, subject: Self.subject(), arrivedAt: Self.start)
        #expect(queue.items.map(\.id) == [existing, unknown])
        #expect(queue.items.map(\.arrivalSequence) == [1, 2])
    }

    @Test func remove_keepsTheRestInOrderAndNumbersAreNotReused() {
        var queue = AttentionQueue()
        let ids = ["a", "b", "c"].map(Self.unread)
        for (id, kind) in ids {
            queue.insert(id: id, kind: kind, subject: Self.subject(), arrivedAt: Self.start)
        }
        queue.remove(ids[1].0)
        let (late, lateKind) = Self.unread("d")
        queue.insert(id: late, kind: lateKind, subject: Self.subject(), arrivedAt: Self.start)

        #expect(queue.items.map(\.id) == [ids[0].0, ids[2].0, late])
        #expect(queue.items.map(\.arrivalSequence) == [1, 3, 4])
    }

    @Test func itemsInPane_leavesOutOtherPanesAndSessionRows() {
        var queue = AttentionQueue()
        let (mine, mineKind) = Self.unread("a")
        let (theirs, theirsKind) = Self.unread("b")
        queue.insert(id: mine, kind: mineKind, subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: theirs, kind: theirsKind, subject: Self.subject(pane: Self.otherPane), arrivedAt: Self.start)
        queue.insert(
            id: .stop(EpisodeKey(origin: .sessionRow(worktreePath: "/tmp/w"), episodeToken: "worktreeMissing")),
            kind: .stop(.worktreeMissing),
            subject: .sessionRow(projectID: nil, worktreeRoot: URL(fileURLWithPath: "/tmp/w")),
            arrivedAt: Self.start
        )

        #expect(queue.items(inPane: Self.pane).map(\.id) == [mine])
    }

    private static func id(for kind: AttentionItemKind, runtimeID: String) -> AttentionItemID {
        let episode = EpisodeKey(origin: .runtime(runtimeID), episodeToken: "1")
        return switch kind {
        case let .approval(fact): .approval(fact.key)
        case let .question(fact): .question(fact.key)
        case .prompt: .prompt(episode)
        case .stop: .stop(episode)
        case let .unread(turn): .unread(turn.turnID)
        }
    }

    @Test func counts_classifiesEachKindAndWhetherItBlocks() {
        let approval = AttentionItemKind.approval(Self.fact(Self.approvalKey(), state: .held))
        let question = AttentionItemKind.question(Self.fact(Self.approvalKey(), isQuestion: true, state: .held))
        let tool = AttentionItemKind.prompt(PromptWait(detail: "Bash: ls"))
        let namedQuestion = AttentionItemKind.prompt(.question(detail: "Which color?"))
        let response = AttentionItemKind.prompt(PromptWait(detail: "Which color?"))
        let stop = AttentionItemKind.stop(.processExited)
        let unread = Self.unread("a").1
        func check(_ kinds: [AttentionItemKind], _ expected: AttentionCounts, blocks: Bool = true) {
            var queue = AttentionQueue()
            for (offset, kind) in kinds.enumerated() {
                let runtimeID = "claude:r\(offset)"
                queue.insert(
                    id: Self.id(for: kind, runtimeID: runtimeID),
                    kind: kind,
                    subject: .runtime(id: runtimeID, provider: .claude, paneID: Self.pane, tabID: nil, projectID: nil),
                    arrivedAt: Self.start
                )
            }
            let counts = queue.counts()
            #expect(counts == expected)
            #expect(counts.total == kinds.count)
            #expect(counts.hasBlockingItems == blocks)
        }
        check([], AttentionCounts(), blocks: false)
        check([unread], AttentionCounts(unread: 1), blocks: false)
        check([approval], AttentionCounts(approvals: 1))
        check([question], AttentionCounts(questions: 1))
        check([tool], AttentionCounts(approvals: 1))
        check([namedQuestion], AttentionCounts(questions: 1))
        check([response], AttentionCounts(prompts: 1))
        check([stop], AttentionCounts(stops: 1))
        check(
            [approval, tool, question, namedQuestion, response, stop, unread],
            AttentionCounts(approvals: 2, questions: 2, prompts: 1, stops: 1, unread: 1)
        )
    }

    /// A sign-in is counted on its own, so the count names it rather than
    /// calling it a response.
    @Test func counts_aSignIn_onItsOwn() {
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("run"), episodeToken: "1")),
            kind: .prompt(.signIn),
            subject: Self.subject(),
            arrivedAt: Self.start
        )
        #expect(queue.counts() == AttentionCounts(signIns: 1))
        #expect(AttentionSummaryText.breakdown(queue.counts(), locale: Locale(identifier: "en")) == ["1 Sign-in"])
        #expect(AttentionSummaryText.breakdown(queue.counts(), locale: Locale(identifier: "ja")) == ["サインイン 1"])
        #expect(queue.counts().hasBlockingItems)
    }

    @Test func dominant_questionThenApprovalThenStopThenUnread() {
        var queue = AttentionQueue()
        let approval = Self.approvalKey()
        let question = Self.approvalKey()
        let (unread, unreadKind) = Self.unread("a")
        // Inserted lowest rank first, so arrival order alone would pick wrongly.
        queue.insert(id: unread, kind: unreadKind, subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: Self.stopID("1"), kind: .stop(.processExited), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: .approval(approval), kind: .approval(Self.fact(approval)), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(
            id: .question(question),
            kind: .question(Self.fact(question, isQuestion: true)),
            subject: Self.subject(),
            arrivedAt: Self.start
        )

        var items = queue.items(inPane: Self.pane)
        #expect(PanePriority.dominant(items)?.id == .question(question))
        items.removeAll { $0.id == .question(question) }
        #expect(PanePriority.dominant(items)?.id == .approval(approval))
        items.removeAll { $0.id == .approval(approval) }
        #expect(PanePriority.dominant(items)?.id == Self.stopID("1"))
        items.removeAll { $0.id == Self.stopID("1") }
        #expect(PanePriority.dominant(items)?.id == unread)
        #expect(PanePriority.dominant([]) == nil)
    }

    @Test func dominant_amongEqualRanks_theEarliestArrival() {
        var queue = AttentionQueue()
        queue.insert(id: Self.stopID("1"), kind: .stop(.processExited), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: Self.stopID("2"), kind: .stop(.error("offline")), subject: Self.subject(), arrivedAt: Self.start)
        #expect(PanePriority.dominant(queue.items.reversed())?.id == Self.stopID("1"))
    }

    @Test func canAnswerInWeir_followsTheRequestStateAndNativeAnswerCapability() {
        func item(_ fact: ApprovalFact) -> AttentionItem {
            AttentionItem(
                id: fact.isQuestion ? .question(fact.key) : .approval(fact.key),
                kind: fact.isQuestion ? .question(fact) : .approval(fact),
                subject: .runtime(
                    id: "\(fact.provider.rawValue):r",
                    provider: fact.provider,
                    paneID: Self.pane,
                    tabID: nil,
                    projectID: nil
                ),
                arrivalSequence: 1,
                arrivedAt: Self.start
            )
        }
        let key = Self.approvalKey()
        #expect(item(Self.fact(key, state: .sendFailed(.allowOnce, error: "offline"))).canAnswerInWeir)
        #expect(!item(Self.fact(key, state: .timedOut)).canAnswerInWeir)
        #expect(!item(Self.fact(key, state: .answered(.deny))).canAnswerInWeir)
        #expect(item(Self.fact(key, isQuestion: true, state: .held)).canAnswerInWeir)
        let codexQuestion = Self.fact(
            key, isQuestion: true, provider: .codex, supportsNativeAnswer: false, state: .sendFailed(.deny, error: "offline")
        )
        #expect(!item(codexQuestion).canAnswerInWeir)
        #expect(item(codexQuestion).requiresTerminalAnswer)
        let stop = AttentionItem(
            id: Self.stopID("1"), kind: .stop(.processExited), subject: Self.subject(), arrivalSequence: 1, arrivedAt: Self.start
        )
        #expect(!stop.canAnswerInWeir)
    }

    @Test func itemID_roundTripsAndPreservesRecordedEpisodeJSON() throws {
        let recorded = Data(#"""
        [{"stop":{"_0":{"origin":{"runtime":{"_0":"claude:r"}},"episodeToken":"1"}}},
         {"stop":{"_0":{"origin":{"sessionRow":{"worktreePath":"/tmp/w"}},"episodeToken":"7"}}},
         {"prompt":{"_0":{"origin":{"runtime":{"_0":"codex:r"}},"episodeToken":"2"}}}]
        """#.utf8)
        let episodes: [AttentionItemID] = [
            .stop(EpisodeKey(origin: .runtime("claude:r"), episodeToken: "1")),
            .stop(EpisodeKey(origin: .sessionRow(worktreePath: "/tmp/w"), episodeToken: "7")),
            .prompt(EpisodeKey(origin: .runtime("codex:r"), episodeToken: "2"))
        ]
        #expect(try JSONDecoder().decode([AttentionItemID].self, from: recorded) == episodes)
        let encoded = try JSONEncoder().encode(episodes)
        let output = try #require(JSONSerialization.jsonObject(with: encoded) as? NSArray)
        let expected = try #require(JSONSerialization.jsonObject(with: recorded) as? NSArray)
        #expect(output == expected)

        let ids = episodes + [.approval(Self.approvalKey()), .question(Self.approvalKey()), .unread(TurnID("t1"))]
        let data = try JSONEncoder().encode(ids)
        #expect(try JSONDecoder().decode([AttentionItemID].self, from: data) == ids)
    }

    @Test func episodeKeyForASessionRow_ignoresATrailingSlash() {
        let withSlash = EpisodeKey.Origin.sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/w/", isDirectory: true))
        let without = EpisodeKey.Origin.sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/w", isDirectory: false))
        let dotted = EpisodeKey.Origin.sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/x/../w"))
        #expect(withSlash == without)
        #expect(dotted == without)
        #expect(without == .sessionRow(worktreePath: "/tmp/w"))
    }

    @Test func conversationKey_readsTheRustSpelling() throws {
        let json = Data(#"{"provider":"codex","conversationId":"abc","isFallback":true}"#.utf8)
        let key = try JSONDecoder().decode(ConversationKey.self, from: json)
        #expect(key == ConversationKey(provider: .codex, conversationID: "abc", isFallback: true))
        #expect(try JSONDecoder().decode(TurnID.self, from: Data(#""t9""#.utf8)) == TurnID("t9"))
    }

    @Test func aProjectsCounts_areItsItemsAlone_andTheOthers_leaveOutItemsInNoProject() {
        let here = UUID()
        let there = UUID()
        let unread = UnreadTurn(turnID: TurnID("b#1"), changes: .unknown)
        var queue = AttentionQueue()
        for (offset, (name, project, kind)) in [
            ("a", Optional(here), AttentionItemKind.stop(.processExited)),
            ("b", there, .unread(unread)),
            ("c", here, .prompt(PromptWait(detail: nil))),
            ("d", nil, .stop(.error(nil)))
        ].enumerated() {
            queue.insert(
                id: Self.id(for: kind, runtimeID: name),
                kind: kind,
                subject: .runtime(id: name, provider: .claude, paneID: UUID(), tabID: nil, projectID: project),
                arrivedAt: Self.start.addingTimeInterval(TimeInterval(offset))
            )
        }

        #expect(queue.counts(inProject: here) == AttentionCounts(prompts: 1, stops: 1))
        #expect(queue.counts(inProject: there) == AttentionCounts(unread: 1))
        #expect(queue.counts(inProjectsOtherThan: here) == AttentionCounts(unread: 1))
        #expect(queue.counts(inProjectsOtherThan: nil) == AttentionCounts(prompts: 1, stops: 1, unread: 1))
    }

}
