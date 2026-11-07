// SupervisionTruncationTests.swift
// Weir — the one rule for where the supervision window cuts a line, and the models that name their lines' kinds.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct SupervisionTruncationTests {
    /// Prose and names keep their start; a path, a subject, and a branch keep
    /// their two ends; a breadcrumb and a title that reads as a path keep their
    /// end.
    @Test func eachKindOfLine_isCutAtItsOwnEdge() {
        let edges: [(SupervisionTruncation, SupervisionTruncation.Edge)] = [
            (.sentence, .tail),
            (.name, .tail),
            (.path, .middle),
            (.subject, .middle),
            (.branch, .middle),
            (.breadcrumb, .head),
            (.pathTitle, .head)
        ]
        for (content, edge) in edges {
            #expect(content.edge == edge, "\(content)")
        }
    }

    /// A menu cannot cut its own lines, so a line is cut by its width: one
    /// that fits stays whole, and Japanese, about twice as wide per
    /// character, gets no wider a menu than English.
    @Test func aLineInAMenu_isCutByItsWidth_whateverItsLanguage() {
        let english = String(repeating: "Review every patch ", count: 20)
        let japanese = String(repeating: "フォークのパッチをすべて確認する", count: 20)
        for line in [english, japanese] {
            let cut = MenuLine.fit(line)
            #expect(cut.hasSuffix("…"))
            #expect(MenuLine.width(of: cut) <= MenuLine.maxWidth)
            #expect(MenuLine.width(of: cut) > MenuLine.maxWidth * 0.9, "nearly all the room is used")
        }
        #expect(MenuLine.fit(japanese).count < MenuLine.fit(english).count)
        let short = "Fix tests"
        #expect(MenuLine.fit(short) == short)
        #expect(MenuLine.fit(short, maxWidth: MenuLine.width(of: short)) == short)

        let grapheme = "e\u{301}"
        let longestFit = "Prefix \(grapheme)…"
        let longer = "Prefix \(grapheme)X…"
        let room = MenuLine.width(of: longestFit)
        #expect(MenuLine.width(of: longer) > room)
        let composed = MenuLine.fit("Prefix \(grapheme)XXXXXX", maxWidth: room)
        #expect(Array(composed.unicodeScalars) == Array(longestFit.unicodeScalars))
    }

    /// Each kind of line loses the part its kind gives up.
    @Test func aLineInAMenu_losesThePartItsKindGivesUp() {
        let branch = "feature/" + String(repeating: "long-", count: 40) + "chatbot"
        let cut = MenuLine.fit(branch, as: .branch)
        #expect(cut.hasPrefix("feature/") && cut.hasSuffix("chatbot") && cut.contains("…"))
        #expect(MenuLine.fit(branch, as: .pathTitle).hasPrefix("…"))
        let spaced = "Fix the " + String(repeating: "x", count: 200)
        let room = MenuLine.width(of: "Fix the …")
        #expect(MenuLine.fit(spaced, maxWidth: room) == "Fix the…", "no space before the ellipsis")
    }

    /// A conversation's menu name cuts its title before its number, so two
    /// of one long title still read apart; the whole name is kept for the
    /// tooltip and VoiceOver.
    @Test func aConversationsMenuName_cutsItsTitle_andKeepsItsNumber() {
        let title = "Review every libghostty patch on the fork and list the ones upstream took"
        let english = Locale(identifier: "en")
        let choices = [
            ConversationChoice(conversation: TurnSummaryFixture.conversation("a"), title: title, ordinal: 1, unviewedCount: 0),
            ConversationChoice(conversation: TurnSummaryFixture.conversation("b"), title: title, ordinal: 2, unviewedCount: 0)
        ]
        let suffixes = [" #1", " #2"]
        let menuNames = choices.map { ConversationText.menuName($0, locale: english) }
        #expect(menuNames[0] != menuNames[1])
        for (menuName, suffix) in zip(menuNames, suffixes) {
            #expect(menuName.hasPrefix("Review every") && menuName.hasSuffix("…" + suffix))
            #expect(MenuLine.width(of: menuName) <= MenuLine.maxWidth)
        }
        #expect(choices.map { ConversationText.name($0, locale: english) } == suffixes.map { title + $0 })
        #expect(choices.map { ConversationText.spokenName($0, locale: english) } == suffixes.map { "Claude, " + title + $0 })
        let short = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("c"),
            title: "Fix tests",
            ordinal: nil,
            unviewedCount: 0
        )
        #expect(ConversationText.menuName(short, locale: english) == "Fix tests")
    }

    @Test(arguments: [
        ("…/sample-reviews/demo-repos/alpha", .pathTitle),
        (".../repos/beta", .pathTitle),
        ("/usr/local", .pathTitle),
        ("/Users/me/weir src", .pathTitle),
        ("~", .pathTitle),
        ("~/notes", .pathTitle),
        (" ~/padded", .pathTitle),
        ("me@mac: ~/weir", .pathTitle),
        ("me@mac: /Users/me/weir", .pathTitle),
        ("zsh", .name),
        ("Claude Code", .name),
        ("vim ~/notes", .name),
        ("npm run build", .name),
        ("alpha/beta", .name),
        ("…weir", .name),
        ("~notes", .name),
        ("/init", .name),
        ("/review-pr 123 fix", .name),
        ("Question: which one?", .name),
        ("", .name)
    ] as [(String, SupervisionTruncation)])
    func aTitleKeepsItsEndOnlyWhenItReadsAsAPath(_ title: String, expected: SupervisionTruncation) {
        #expect(SupervisionTruncation.isPathTitle(title) == (expected == .pathTitle))
        #expect(SupervisionTruncation.title(title) == expected)
    }

    @Test func aRowsFact_namingAFileOrACommand_keepsBothEnds_andProseItsStart() {
        let subjects: [SessionRowFact.Fact] = [
            .approval("npm test"),
            .running("Write: /Users/me/weir/notes.txt"),
            .prompt(PromptWait(detail: "Write: /Users/me/weir/notes.txt")),
            .prompt(.unclassified(detail: "Overwrite notes.txt?"))
        ]
        #expect(subjects.allSatisfy { SupervisionTruncation.fact($0) == .subject })
        let prose: [SessionRowFact.Fact] = [
            .question("Which color should the button be?"),
            .approval(nil),
            .running(nil),
            .prompt(.question(detail: "Which file?")),
            .prompt(.unclassified(detail: nil)),
            .compacting,
            .idle,
            .commits(3)
        ]
        #expect(prose.allSatisfy { SupervisionTruncation.fact($0) == .sentence })
    }

    // MARK: - The models that name their lines' kinds

    private struct WaitLine {
        let wait: PromptWait
        let words: String
        let truncation: SupervisionTruncation
    }

    @Test func attentionRows_cutNamedWaitSubjectsAndKeepTheStartOfOtherFacts() {
        var queue = AttentionQueue()
        let waits: [WaitLine] = [
            .init(
                wait: PromptWait(detail: "Edit: /repo/Sources/App.swift"),
                words: "Waiting for approval: App.swift",
                truncation: .subject
            ),
            .init(wait: PromptWait(detail: nil), words: "Needs response", truncation: .sentence),
            .init(wait: .question(detail: "Which branch?"), words: "Question: Which branch?", truncation: .sentence)
        ]
        var expected: [AttentionItemID: (words: String, edge: SupervisionTruncation)] = [:]
        for (offset, line) in waits.enumerated() {
            let runtime = "r\(offset)"
            let id = AttentionItemID.prompt(EpisodeKey(origin: .runtime(runtime), episodeToken: "1"))
            queue.insert(
                id: id,
                kind: .prompt(line.wait),
                subject: .runtime(id: runtime, provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
            expected[id] = (line.words, line.truncation)
        }
        let held = ApprovalFact.test()
        let missing = ApprovalFact.test()
        for (offset, approval) in [held, missing].enumerated() {
            queue.insert(
                id: .approval(approval.key),
                kind: .approval(approval),
                subject: .unplaced(provider: .claude),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(waits.count + offset))
            )
        }
        expected[.approval(held.key)] = ("Waiting for approval: swift test", .subject)
        expected[.approval(missing.key)] = ("Needs approval", .sentence)

        let model = NeedsAttentionListModel(
            items: queue.items,
            names: { _ in .init(title: "alpha", place: "alpha") },
            request: { key in key == held.key ? .init(summary: "swift test", question: nil, toolName: "Bash") : nil },
            windowProjectID: nil,
            locale: Locale(identifier: "en")
        )
        #expect(Set(model.rows.map(\.id)) == Set(expected.map(\.0)))
        #expect(model.rows.count == expected.count)
        for (id, line) in expected {
            let row = model.rows.first { $0.id == id }
            #expect(row?.fact == line.words)
            #expect(row?.factTruncation == line.edge)
        }
    }

    @MainActor
    @Test func anAllProjectsCard_isCutAsItsRowsFactIs() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let id = AttentionItemID.prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1"))
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let cases: [WaitLine] = [
            .init(
                wait: PromptWait(detail: "Write: /Users/me/weir/notes.txt"),
                words: "Waiting for approval: notes.txt",
                truncation: .subject
            ),
            .init(wait: .question(detail: "Which branch?"), words: "Question: Which branch?", truncation: .sentence)
        ]
        for line in cases {
            var queue = AttentionQueue()
            queue.insert(
                id: id,
                kind: .prompt(line.wait),
                subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
                arrivedAt: Date(timeIntervalSince1970: 0)
            )
            let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
                session: session, window: session.primaryWindowID, registry: registry, queue: queue,
                runtimes: [], approvals: ApprovalLedger(), pullRequest: { _ in nil }, gitFacts: { _ in nil },
                locale: Locale(identifier: "en")
            ))
            #expect(cards.map(\.id) == [.project(project.id)])
            let card = try #require(cards.first)
            #expect(card.leadItemID == id)
            #expect(card.factText == line.words)
            #expect(card.factTruncation == line.truncation)
        }
    }
}

/// A name set into a sentence is cut in its middle, by count, before the
/// line is laid out (`SupervisionTruncation.middle`).
struct SupervisionTruncationMiddleTests {
    @Test func cuttingAName_preservesWholeGraphemesAndBothEnds() {
        let atLimit = String(repeating: "a", count: 40)
        let name = "nek0der/feature/" + String(repeating: "x", count: 60) + "/1021-1"
        let cases = [
            ("feature/login", 40, "feature/login"),
            (atLimit, 40, atLimit),
            (name, 40, "nek0der/feature/xxx…xxxxxxxxxxxxx/1021-1"),
            ("Ae\u{301}BCDEF", 6, "Ae\u{301}…DEF"),
            ("feature/login", 1, "feature/login"),
            ("", 0, "")
        ]
        for (input, limit, expected) in cases {
            let cut = SupervisionTruncation.middle(input, limit: limit)
            #expect(Array(cut.unicodeScalars) == Array(expected.unicodeScalars))
        }
    }
}
