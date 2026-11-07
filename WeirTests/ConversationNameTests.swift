// ConversationNameTests.swift
// Weir — which conversation names a tab's row, how the name follows it while it runs, and that it is kept.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct ConversationNameTests {
    private static let claudePane = UUID()
    private static let codexPane = UUID()

    private static func badge(
        conversationID: String? = nil,
        sessionTitle: String? = nil,
        generatedTitle: String? = nil,
        firstPrompt: String? = nil,
        startedAt seconds: TimeInterval? = 0
    ) -> AgentBadge {
        AgentBadge(
            state: .running,
            updatedAt: Date(),
            firstPrompt: firstPrompt,
            conversationID: conversationID,
            providerSessionTitle: sessionTitle,
            providerGeneratedTitle: generatedTitle,
            sessionStartedAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func remembered(
        _ current: ConversationName?,
        _ badges: [AgentKind: [UUID: AgentBadge]]
    ) -> ConversationName? {
        // Through the tab, which binds the rule to the pane header's title.
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.conversationName = current
        tab.agentBadges = badges
        tab.rememberConversationName()
        return tab.conversationName
    }

    @Test func aConversation_isNamedByItsCLITitle_elseItsFirstPrompt() {
        let prompt = Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(conversationID: "c", firstPrompt: "Add tests")]])
        #expect(prompt?.name == "Add tests")

        let titled = Self.remembered(prompt, [.claude: [Self.claudePane: Self.badge(
            conversationID: "c",
            generatedTitle: "Testing the store",
            firstPrompt: "Add tests"
        )]])
        // The title the CLI gave it later follows, as the pane header does.
        #expect(titled?.name == "Testing the store")
        #expect(titled?.conversationID == "c")

        let renamed = Self.remembered(titled, [.claude: [Self.claudePane: Self.badge(
            conversationID: "c",
            sessionTitle: "Review the store",
            generatedTitle: "Testing the store",
            firstPrompt: "Add tests"
        )]])
        #expect(renamed?.name == "Review the store")
    }

    @Test func aRunBeforeItsSessionIsKnown_namesNothingYet() {
        #expect(Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(firstPrompt: "Add tests")]]) == nil)
        #expect(Self.remembered(nil, [.codex: [Self.codexPane: Self.badge(
            sessionTitle: "Left over",
            firstPrompt: "Fix the build"
        )]]) == nil)
    }

    /// A Codex conversation an earlier build named, when Codex badges
    /// carried no id: what a tab restored after an update holds.
    private static func savedWithoutID(_ name: String, startedAt seconds: TimeInterval? = 0) -> ConversationName {
        ConversationName(
            name: name,
            provider: .codex,
            paneID: codexPane,
            conversationID: nil,
            startedAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test func aNameSavedWithoutAnID_followsItsSession_andTakesItsID() {
        // The same session in the same pane reports its id now: it is the
        // same conversation, so its title follows and its id is kept.
        let known = Self.remembered(Self.savedWithoutID("Fix the build"), [.codex: [Self.codexPane: Self.badge(
            conversationID: "thread",
            sessionTitle: "Fix the CI build",
            firstPrompt: "Fix the build"
        )]])
        #expect(known?.name == "Fix the CI build")
        #expect(known?.conversationID == "thread")
    }

    @Test func theName_isKept_whenTheConversationEnds() {
        let named = Self.remembered(nil, [.codex: [Self.codexPane: Self.badge(conversationID: "t", firstPrompt: "Fix the build")]])
        #expect(named?.name == "Fix the build")
        #expect(Self.remembered(named, [:]) == named)
    }

    @Test func aLaterConversation_doesNotRenameTheTab() throws {
        let first = try #require(Self.remembered(
            nil,
            [.claude: [Self.claudePane: Self.badge(conversationID: "a", firstPrompt: "First task")]]
        ))
        #expect(first.name == "First task")
        // A new conversation in the same pane, after the first ended.
        let next = Self.remembered(first, [.claude: [Self.claudePane: Self.badge(
            conversationID: "b",
            firstPrompt: "Second task",
            startedAt: 60
        )]])
        #expect(next == first)

        // A name saved without an id is told from the next session in its
        // pane by the start.
        let legacy = Self.savedWithoutID("Codex task")
        let again = Self.remembered(legacy, [.codex: [Self.codexPane: Self.badge(
            conversationID: "n",
            firstPrompt: "Another",
            startedAt: 60
        )]])
        #expect(again == legacy)
    }

    @Test func aNameSavedWithNeitherIDNorStart_isNeverTakenForTheNext() {
        let first = Self.savedWithoutID("First", startedAt: nil)
        let next = Self.remembered(first, [.codex: [Self.codexPane: Self.badge(
            conversationID: "n",
            firstPrompt: "Second",
            startedAt: nil
        )]])
        #expect(next == first)
    }

    @Test func onlyTheRememberedConversation_isAskedForATitle_inOrder() {
        let current = ConversationName(
            name: "First task",
            provider: .claude,
            paneID: Self.claudePane,
            conversationID: "a",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let later = UUID()
        let observed = [
            ConversationName.Observed(provider: .claude, paneID: later, conversationID: "a", startedAt: Date(timeIntervalSince1970: 20)),
            ConversationName.Observed(
                provider: .codex,
                paneID: Self.codexPane,
                conversationID: nil,
                startedAt: Date(timeIntervalSince1970: 5)
            ),
            ConversationName.Observed(
                provider: .claude,
                paneID: Self.claudePane,
                conversationID: "a",
                startedAt: Date(timeIntervalSince1970: 10)
            )
        ]
        var asked: [UUID] = []

        let next = ConversationName.remembered(current, observed: observed) { session in
            asked.append(session.paneID)
            return "Title in \(session.paneID == later ? "later" : "earlier")"
        }

        // The Codex session is another conversation, so it is never asked;
        // of the two panes holding this one, the earlier answers, every time.
        #expect(asked == [Self.claudePane])
        #expect(next?.name == "Title in earlier")
        #expect(next?.paneID == Self.claudePane)
        #expect(ConversationName.remembered(current, observed: observed.reversed()) { _ in "x" }?.paneID == Self.claudePane)
    }

    @Test func anEarliestSessionWithoutATitle_leavesTheNameToTheNext() {
        let untitled = UUID()
        let observed = [
            ConversationName.Observed(provider: .claude, paneID: untitled, conversationID: nil, startedAt: Date(timeIntervalSince1970: 0)),
            ConversationName.Observed(
                provider: .codex,
                paneID: Self.codexPane,
                conversationID: nil,
                startedAt: Date(timeIntervalSince1970: 10)
            )
        ]

        let named = ConversationName.remembered(nil, observed: observed) { session in
            session.paneID == untitled ? nil : "Codex task"
        }

        #expect(named?.name == "Codex task")
        #expect(named?.paneID == Self.codexPane)
        #expect(named?.startedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func theRememberedConversation_answersFromALaterPane_whenTheEarlierHasNoTitle() {
        let current = ConversationName(
            name: "First task",
            provider: .claude,
            paneID: Self.claudePane,
            conversationID: "a",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let later = UUID()
        let observed = [
            ConversationName.Observed(
                provider: .claude,
                paneID: Self.claudePane,
                conversationID: "a",
                startedAt: Date(timeIntervalSince1970: 10)
            ),
            ConversationName.Observed(provider: .claude, paneID: later, conversationID: "a", startedAt: Date(timeIntervalSince1970: 20))
        ]

        let next = ConversationName.remembered(current, observed: observed) { session in
            session.paneID == later ? "Renamed" : nil
        }

        #expect(next?.name == "Renamed")
        #expect(next?.paneID == later)
        // Still ordered by when the conversation first started.
        #expect(next?.startedAt == current.startedAt)
    }

    @Test func aResumedConversation_keepsFollowingItsTitle() {
        let first = Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(conversationID: "a", firstPrompt: "First task")]])
        // `claude --continue` starts a new session of the same conversation.
        let resumedPane = UUID()
        let resumed = Self.remembered(first, [.claude: [resumedPane: Self.badge(
            conversationID: "a",
            sessionTitle: "Renamed by /rename",
            firstPrompt: "First task",
            startedAt: 90
        )]])
        #expect(resumed?.name == "Renamed by /rename")
        #expect(resumed?.provider == .claude)
        #expect(resumed?.paneID == resumedPane)
        #expect(resumed?.conversationID == "a")
        // Still ordered by when the conversation first started.
        #expect(resumed?.startedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func twoConversationsAtOnce_nameTheTabByTheEarlier() {
        let named = Self.remembered(nil, [
            .claude: [Self.claudePane: Self.badge(conversationID: "c", firstPrompt: "Later", startedAt: 20)],
            .codex: [Self.codexPane: Self.badge(conversationID: "x", firstPrompt: "Earlier", startedAt: 10)]
        ])
        #expect(named?.name == "Earlier")
    }

    @Test(arguments: [nil as String?, "thread"])
    func aTab_keepsItsName_throughTheSnapshot(conversationID: String?) throws {
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.conversationName = ConversationName(
            name: "Add tests",
            provider: .codex,
            paneID: Self.codexPane,
            conversationID: conversationID,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder().encode(tab)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let name = try #require(object["conversationName"] as? [String: Any])
        #expect(name["name"] as? String == "Add tests")
        #expect(name["provider"] as? String == "codex")
        #expect(name["paneID"] as? String == Self.codexPane.uuidString)
        #expect(name["conversationID"] as? String == conversationID)

        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded.id == tab.id)
        #expect(decoded.conversationName == tab.conversationName)
    }

    /// Forward compatibility: the tab's decoder passes over a key it does
    /// not know and keeps the rest. This is what lets a file with a key
    /// from a later build open here; whether a build from before the name
    /// does the same depends on that build's decoder, which this test
    /// cannot run. Such a build would write the session back without the
    /// name.
    @Test func aTab_withAKeyItDoesNotKnow_stillDecodes_andKeepsItsName() throws {
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.conversationName = ConversationName(
            name: "Add tests",
            provider: .claude,
            paneID: Self.claudePane,
            conversationID: "c",
            startedAt: nil
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["aLaterField"] = ["name": "from a newer build"]

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.id == tab.id)
        #expect(decoded.conversationName == tab.conversationName)
    }

    @Test func aTabFromBeforeTheName_orWithAProviderThisBuildDoesNotKnow_stillDecodes() throws {
        let tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        #expect(object["conversationName"] == nil)
        #expect(try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object)).conversationName == nil)

        object["conversationName"] = ["name": "Add tests", "provider": "gemini", "paneID": UUID().uuidString]
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.conversationName == nil)
        #expect(decoded.id == tab.id)
    }
}
