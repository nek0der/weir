// AgentSiblingTabsTests.swift
// Weir — several sessions of one process in a pane: what a run in a tab behind counts as.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct AgentSiblingTabsTests {
    private static let pane = UUID()

    private static func tab(
        _ id: String,
        kind: AgentKind = .opencode,
        state: AgentState = .finished,
        isBehind: Bool,
        updatedAt: Date = Date(),
        pane: UUID = pane
    ) -> AgentRuntimePresentation {
        var runtime = AgentRuntimePresentation.test(
            kind: kind,
            runID: id,
            badge: AgentBadge(state: state, updatedAt: updatedAt),
            paneIDs: [pane],
            sessionID: "ses_\(id)",
            conversation: TurnSummaryFixture.conversation(id, provider: kind)
        )
        runtime.panesBehindShownTab = isBehind ? [pane] : []
        runtime.panesNotInFront = isBehind ? [pane] : []
        runtime.tabChannel = kind == .opencode ? pane : nil
        return runtime
    }

    // MARK: In sight

    @Test func theHomeScreenKeepsTheHeaderButNothingIsInSight() {
        var run = Self.tab("a", isBehind: false)
        run.panesNotInFront = [Self.pane]
        #expect(run.activeAttachmentPaneIDs.isEmpty)
        #expect(AttentionState.headerRuntime(inPane: Self.pane, among: [run])?.runID == "a")
    }

    @Test func aRunBehindTheShownTabIsNotAttachedForSight() {
        #expect(Self.tab("a", isBehind: true).activeAttachmentPaneIDs.isEmpty)
        #expect(Self.tab("b", isBehind: false).activeAttachmentPaneIDs == [Self.pane])
    }

    /// The pane is in sight, and the turn behind stays unread.
    @Test func aTurnBehindTheShownTabIsNotReadByItsPaneBeingInSight() throws {
        let turn = try TurnSummaryFixture.turn("t1")
        let history = [TurnSummaryFixture.conversation: [turn]]
        func runtime(isBehind: Bool) -> TurnReadRuntime {
            var run = Self.tab("R", kind: .claude, isBehind: isBehind)
            run.conversation = TurnSummaryFixture.conversation
            return TurnReadRuntime(run)
        }
        let behind = TurnReadRules.turnsRead(inSight: [Self.pane], runtimes: [runtime(isBehind: true)], history: history)
        #expect(!behind.contains(turn.turnID))
        let shown = TurnReadRules.turnsRead(inSight: [Self.pane], runtimes: [runtime(isBehind: false)], history: history)
        #expect(shown.contains(turn.turnID))
    }

    @Test func theHeaderIgnoresActivityBehindTheShownTab() {
        let shown = Self.tab("shown", isBehind: false, updatedAt: Date(timeIntervalSince1970: 1))
        let busy = Self.tab("busy", state: .running, isBehind: true, updatedAt: Date(timeIntervalSince1970: 99))
        let runtime = AttentionState.headerRuntime(inPane: Self.pane, among: [shown, busy])
        #expect(runtime?.runID == "shown")
    }

    @Test func runsWithNoTabsReadAsBefore() {
        let older = Self.tab("older", kind: .claude, isBehind: false, updatedAt: Date(timeIntervalSince1970: 1))
        let newer = Self.tab("newer", kind: .claude, isBehind: false, updatedAt: Date(timeIntervalSince1970: 2))
        #expect(AttentionState.headerRuntime(inPane: Self.pane, among: [older, newer])?.runID == "newer")
        #expect(older.activeAttachmentPaneIDs == [Self.pane])
    }

    @Test func theRulesSayWhatIsBehindOverTheBridge() throws {
        let data = Data(
            """
            {"id":"opencode:A","provider":"opencode","runId":"A","badge":{"state":"running","updatedAt":"2026-11-02T00:00:00Z"},
             "panes":["\(Self.pane.uuidString)"],"attachment":"attached","eventToken":"1","episodeToken":"1",
             "panesBehindShownTab":["\(Self.pane.uuidString)"],"panesNotInFront":["\(Self.pane.uuidString)"],
             "tabChannel":"\(Self.pane.uuidString)"}
            """.utf8
        )
        let projected = try JSONDecoder().decode(AgentProjectedRuntime.self, from: data)
        let runtime = try #require(AgentRuntimePresentation(projected: projected, tmuxLocationsByEndpoint: [:]))
        #expect(runtime.panesBehindShownTab == [Self.pane])
        #expect(runtime.panesNotInFront == [Self.pane])
        #expect(runtime.tabChannel == Self.pane)
    }

    // MARK: Conversations

    @Test func aConversationBehindStillHasItsPlace() {
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let shown = Self.tab("shown", isBehind: false, pane: fixture.paneID)
        let behind = Self.tab("behind", isBehind: true, pane: fixture.paneID)
        let tabs = ConversationTabs(tabs: [fixture.tab], runtimes: [shown, behind])
        let key = TurnSummaryFixture.conversation("behind", provider: .opencode)
        #expect(tabs.place(of: key)?.paneID == fixture.paneID)
        #expect(tabs.running.contains(key))
    }

    // MARK: Conversations, closed

    @Test func aClosedTabsConversationHasNoPlace() {
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let closed = Self.tab("closed", state: .unknown, isBehind: true, pane: fixture.paneID)
        let tabs = ConversationTabs(tabs: [fixture.tab], runtimes: [closed])
        let key = TurnSummaryFixture.conversation("closed", provider: .opencode)
        #expect(tabs.place(of: key) == nil)
        #expect(!tabs.running.contains(key))
    }

    // MARK: Focus

    private static func scratch() -> URL {
        WeirPaths.applicationSupportDirectory().appendingPathComponent(UUID().uuidString)
    }

    private struct Seen: Sendable {
        var sessionID: String?
        var nonce: String?
    }

    /// The plugin's half: reads the request, answers with `shows`.
    private static func answering(channel: UUID, root: URL, shows: String?) -> Task<Seen, Never> {
        Task.detached {
            let url = AgentTabFocus.requestURL(channel: channel, under: root)
            for _ in 0..<400 {
                if let data = try? Data(contentsOf: url),
                   let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    try? FileManager.default.removeItem(at: url)
                    let answer: [String: Any] = [
                        "nonce": request["nonce"] ?? "",
                        "sessionId": shows ?? NSNull(),
                        "rootSessionId": shows ?? NSNull()
                    ]
                    if let body = try? JSONSerialization.data(withJSONObject: answer) {
                        let done = url.deletingLastPathComponent()
                            .appendingPathComponent("\(url.lastPathComponent).\(request["nonce"] ?? "").answer")
                        try? body.write(to: done, options: .atomic)
                    }
                    return Seen(sessionID: request["sessionId"] as? String, nonce: request["nonce"] as? String)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return Seen()
        }
    }

    /// Writing a request takes away what nobody took: requests and answers older than
    /// half a minute, an earlier build's pane-named files among them. Fresh ones stay.
    @Test func writingARequestSweepsStaleFilesAndKeepsFreshOnes() throws {
        let root = Self.scratch()
        let directory = root.appendingPathComponent("tab-focus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-60)
        func file(_ name: String, at date: Date) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let stale = try [
            file("\(UUID().uuidString).json", at: old),
            file("\(UUID().uuidString).json.N.answer", at: old),
            file("\(UUID().uuidString.uppercased()).json", at: old)
        ]
        let fresh = try [
            file("\(UUID().uuidString).json", at: Date()),
            file("\(UUID().uuidString).json.N.answer", at: Date())
        ]
        let unrelated = try file("notes.txt", at: old)
        let channel = UUID()
        var run = Self.tab("abc", isBehind: true)
        run.tabChannel = channel
        AgentTabFocus.request(run, under: root)
        for url in stale {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        for url in fresh + [unrelated, AgentTabFocus.requestURL(channel: channel, under: root)] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aFocusRequestNamesOnlyTheSessionAndIsPrivate() throws {
        let pane = UUID()
        let directory = Self.scratch()
        AgentTabFocus.request(Self.tab("abc", isBehind: true, pane: pane), under: directory)
        let url = AgentTabFocus.requestURL(channel: pane, under: directory)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(body.keys) == ["sessionId", "at"])
        #expect(body["sessionId"] as? String == "ses_abc")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(url.lastPathComponent == "\(pane.uuidString.uppercased()).json")
        try? FileManager.default.removeItem(at: directory)
    }

    /// tmux shows the process in another pane; its plugin reads what the launching pane names.
    @Test func aRequestGoesToThePaneTheProcessWasLaunchedFromNotTheOneShowingIt() {
        let (launched, attached) = (UUID(), UUID())
        let directory = Self.scratch()
        var run = Self.tab("abc", isBehind: true, pane: attached)
        run.tabChannel = launched
        AgentTabFocus.request(run, under: directory)
        #expect(FileManager.default.fileExists(atPath: AgentTabFocus.requestURL(channel: launched, under: directory).path))
        #expect(!FileManager.default.fileExists(atPath: AgentTabFocus.requestURL(channel: attached, under: directory).path))
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Review

    private static func destination(_ pane: UUID, agent: AgentKind? = .opencode) -> ReviewDestination {
        ReviewDestination(paneID: pane, title: "", agent: agent)
    }

    /// tmux can hold OpenCode and Claude in one pane's session. What the pane hosts
    /// decides; the other's channel is not asked, and no wait is spent on it.
    @Test func aReviewForAnotherAgentInThePaneAsksNothing() async {
        let pane = UUID()
        let root = Self.scratch()
        let opencode = Self.tab("o", isBehind: false, pane: pane)
        let claude = Self.tab("c", kind: .claude, isBehind: false, pane: pane)
        let began = ContinuousClock.now
        let shown = await ReviewSessionFocus.show(
            conversation: nil,
            destination: Self.destination(pane, agent: .claude),
            runtimes: { [opencode, claude] },
            under: root
        )
        #expect(shown)
        #expect(began.duration(to: .now) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: AgentTabFocus.requestURL(channel: pane, under: root).path))
    }

    @Test func aDeadProcessesRecordMakesNoReviewWait() async {
        let pane = UUID()
        let root = Self.scratch()
        var dead = Self.tab("o", isBehind: false, pane: pane)
        dead.processID = 4242
        let began = ContinuousClock.now
        let shown = await ReviewSessionFocus.show(
            conversation: nil,
            destination: Self.destination(pane),
            runtimes: { [dead] },
            isAlive: { _ in false },
            under: root
        )
        #expect(shown)
        #expect(began.duration(to: .now) < .seconds(1))
    }

    /// Two tmux panes attached to one Weir pane: the one in front has the say.
    @Test func aRunBehindAnotherTmuxPaneIsNotWhatTakesTheText() async {
        let pane = UUID()
        let root = Self.scratch()
        var behindTmux = AgentRuntimePresentation.test(
            kind: .opencode,
            runID: "o",
            paneIDs: [pane],
            tmuxLocations: [pane: TmuxPaneLocation(
                socketPath: "/tmp/s", serverPID: "1", serverStartedAt: "1", sessionID: "$1",
                windowID: "@1", paneID: "%1", isActive: false
            )],
            sessionID: "ses_o"
        )
        behindTmux.tabChannel = pane
        let shown = await ReviewSessionFocus.show(
            conversation: nil,
            destination: Self.destination(pane),
            runtimes: { [behindTmux] },
            limit: .zero,
            under: root
        )
        #expect(shown)
    }

    /// A subagent's view is on screen, with no session named: it is no session to paste to.
    @Test func aSubagentsViewIsNotAnySession() async {
        let pane = UUID()
        let root = Self.scratch()
        let url = AgentTabFocus.requestURL(channel: pane, under: root)
        let plugin = Task.detached {
            for _ in 0..<400 {
                if let data = try? Data(contentsOf: url),
                   let nonce = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["nonce"] as? String
                {
                    let body = Data(#"{"nonce":"\#(nonce)","sessionId":"ses_child","rootSessionId":"ses_a"}"#.utf8)
                    try? body.write(to: url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(nonce).answer"))
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let shown = await AgentTabFocus.confirm(sessionID: nil, channel: pane, limit: .seconds(3), under: root)
        await plugin.value
        #expect(!shown)
    }

    /// Two confirmations at once keep their own answers.
    @Test func aConfirmationsCleanupLeavesAnothersAnswer() async throws {
        let pane = UUID()
        let root = Self.scratch()
        let directory = AgentTabFocus.requestURL(channel: pane, under: root).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("\(pane.uuidString.uppercased()).json.other.answer")
        try Data("{}".utf8).write(to: other)
        _ = await AgentTabFocus.confirm(sessionID: nil, channel: pane, limit: .milliseconds(30), under: root)
        #expect(FileManager.default.fileExists(atPath: other.path))
        try? FileManager.default.removeItem(at: root)
    }

    /// The destination names the conversation the paste will go to: the reviewed one,
    /// when the pane holds it in a tab, even behind or closed; otherwise what is on screen.
    @Test func theDestinationNamesTheReviewedSessionOfThePane() {
        let pane = UUID()
        let shown = Self.tab("shown", isBehind: false, pane: pane)
        let behind = Self.tab("behind", isBehind: true, pane: pane)
        let closed = Self.tab("closed", state: .unknown, isBehind: true, pane: pane)
        let runs = [shown, behind, closed]
        let key = { TurnSummaryFixture.conversation($0, provider: .opencode) }
        #expect(ReviewSessionFocus.conversation(reviewed: key("behind"), inPane: pane, runtimes: runs) == key("behind"))
        #expect(ReviewSessionFocus.conversation(reviewed: key("closed"), inPane: pane, runtimes: runs) == key("closed"))
        #expect(ReviewSessionFocus.conversation(reviewed: key("elsewhere"), inPane: pane, runtimes: runs) == nil)
        #expect(ReviewSessionFocus.conversation(reviewed: nil, inPane: pane, runtimes: runs) == nil)
        #expect(ReviewSessionFocus.conversation(reviewed: key("behind"), inPane: UUID(), runtimes: runs) == nil)
        // An agent with no tabs names what its pane shows, as before.
        let claude = Self.tab("c", kind: .claude, isBehind: false, pane: pane)
        #expect(ReviewSessionFocus.conversation(
            reviewed: TurnSummaryFixture.conversation("c"),
            inPane: pane,
            runtimes: [claude]
        ) == nil)
    }

    @Test func aPaneWithNoTabsHasNothingToAsk() async {
        let run = Self.tab("a", kind: .claude, isBehind: false)
        let shown = await ReviewSessionFocus.show(
            conversation: nil,
            destination: Self.destination(Self.pane, agent: .claude),
            runtimes: { [run] },
            limit: .zero
        )
        #expect(shown)
    }

    /// One tab left, from the home screen, or the wanted one closed: the check is not
    /// skipped, and only the plugin's answer lets the paste go.
    @Test func aReviewPastesOnlyOnThePluginsAnswer() async {
        let key = TurnSummaryFixture.conversation("a", provider: .opencode)
        let pane = UUID()
        let root = Self.scratch()
        let closed = Self.tab("a", state: .unknown, isBehind: false, pane: pane)
        let other = Self.tab("b", isBehind: true, pane: pane)
        func show(answer: String?, conversation: ConversationKey?) async -> (Bool, Seen) {
            let plugin = Self.answering(channel: pane, root: root, shows: answer)
            let shown = await ReviewSessionFocus.show(
                conversation: conversation,
                destination: Self.destination(pane),
                runtimes: { [closed, other] },
                limit: .seconds(3),
                under: root
            )
            return await (shown, plugin.value)
        }
        let (confirmed, request) = await show(answer: "ses_a", conversation: key)
        #expect(confirmed, "A reopened and in front")
        #expect(request.sessionID == "ses_a")
        #expect(request.nonce != nil)
        let (stillB, _) = await show(answer: "ses_b", conversation: key)
        #expect(!stillB, "another session in front")
        let (home, _) = await show(answer: nil, conversation: key)
        #expect(!home, "the home screen")
        let (anyShown, named) = await show(answer: "ses_b", conversation: nil)
        #expect(anyShown, "no conversation of its own goes to what is on screen")
        #expect(named.sessionID == nil)
        let (noneShown, _) = await show(answer: nil, conversation: nil)
        #expect(!noneShown, "but not to the home screen")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aReviewWithNoAnswerIsRefusedInTime() async {
        let pane = UUID()
        let root = Self.scratch()
        let run = Self.tab("a", isBehind: false, pane: pane)
        let shown = await ReviewSessionFocus.show(
            conversation: nil,
            destination: Self.destination(pane),
            runtimes: { [run] },
            limit: .milliseconds(100),
            under: root
        )
        #expect(!shown)
        try? FileManager.default.removeItem(at: root)
    }
}
