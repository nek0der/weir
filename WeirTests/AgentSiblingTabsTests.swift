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
        pane: UUID = pane,
        tmux: TmuxPaneLocation? = nil
    ) -> AgentRuntimePresentation {
        var runtime = AgentRuntimePresentation.test(
            kind: kind,
            runID: id,
            badge: AgentBadge(state: state, updatedAt: updatedAt),
            paneIDs: [pane],
            tmuxLocations: tmux.map { [pane: $0] } ?? [:],
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
        let visible = UUID()
        var partiallyHidden = AgentRuntimePresentation.test(kind: .opencode, runID: "both", paneIDs: [Self.pane, visible])
        partiallyHidden.panesBehindShownTab = [Self.pane]
        partiallyHidden.panesNotInFront = [Self.pane]
        #expect(partiallyHidden.activeAttachmentPaneIDs == [visible])
        #expect(Self.tab("a", isBehind: true).activeAttachmentPaneIDs.isEmpty)
        #expect(Self.tab("b", isBehind: false).activeAttachmentPaneIDs == [Self.pane])
    }

    /// The pane is in sight, and the turn behind stays unread.
    @Test func aTurnBehindTheShownTabIsNotReadByItsPaneBeingInSight() throws {
        var front = Self.tab("front", isBehind: false)
        var behind = Self.tab("behind", isBehind: true)
        front.conversation = TurnSummaryFixture.conversation("ses_front", provider: .opencode)
        behind.conversation = TurnSummaryFixture.conversation("ses_behind", provider: .opencode)
        func turn(of run: AgentRuntimePresentation) throws -> TurnSummary {
            let session = try #require(run.sessionID)
            return try JSONDecoder().decode(TurnSummary.self, from: Data(
                """
                {"turnId":"\(run.runID)-T1","conversation":{"provider":"opencode","conversationId":"\(session)","isFallback":false},
                 "runId":"\(run.runID)","paneId":"\(Self.pane.uuidString)","displayNumber":1,"startedAt":"2026-11-02T00:00:00Z",
                 "phase":"finished","changes":{"kind":"unchanged"},"hasPrompt":true}
                """.utf8
            ))
        }
        let frontTurn = try turn(of: front)
        let behindTurn = try turn(of: behind)
        #expect(frontTurn.conversation == front.conversation)
        #expect(behindTurn.conversation == behind.conversation)
        let history = [frontTurn.conversation: [frontTurn], behindTurn.conversation: [behindTurn]]
        let read = TurnReadRules.turnsRead(inSight: [Self.pane], runtimes: [front, behind].map(TurnReadRuntime.init), history: history)
        #expect(read == [frontTurn.turnID])
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
        let home = UUID()
        let front = UUID()
        let channel = UUID()
        let data = Data(
            """
            {"id":"opencode:A","provider":"opencode","runId":"A","badge":{"state":"running","updatedAt":"2026-11-02T00:00:00Z"},
             "panes":["\(Self.pane.uuidString)","\(home.uuidString)","\(front.uuidString)"],"attachment":"attached",
             "eventToken":"1","episodeToken":"1","pid":"4242","sessionId":"ses_A",
             "panesBehindShownTab":["\(Self.pane.uuidString)"],"panesNotInFront":["\(Self.pane.uuidString)","\(home.uuidString)"],
             "tabChannel":"\(channel.uuidString)"}
            """.utf8
        )
        let projected = try JSONDecoder().decode(AgentProjectedRuntime.self, from: data)
        let runtime = try #require(AgentRuntimePresentation(projected: projected, tmuxLocationsByEndpoint: [:]))
        #expect(runtime.panesBehindShownTab == [Self.pane])
        #expect(runtime.panesNotInFront == [Self.pane, home])
        #expect(runtime.activeAttachmentPaneIDs == [front])
        #expect(runtime.tabChannel == channel)
        #expect(runtime.kind == .opencode)
        #expect(runtime.runID == "A")
        #expect(runtime.processID == 4242)
        #expect(runtime.sessionID == "ses_A")
    }

    // MARK: Conversations

    @Test func openSiblingConversationsKeepTheirPlacesAndTheFrontTitle() {
        let fixture = WorkspaceSessionFixture.withLooseTab()
        let shown = Self.tab("shown", isBehind: false, pane: fixture.paneID)
        let behind = Self.tab("behind", isBehind: true, pane: fixture.paneID)
        let closed = Self.tab("closed", state: .unknown, isBehind: true, pane: fixture.paneID)
        let tabs = ConversationTabs(tabs: [fixture.tab], runtimes: [shown, behind, closed])
        let shownKey = TurnSummaryFixture.conversation("shown", provider: .opencode)
        let behindKey = TurnSummaryFixture.conversation("behind", provider: .opencode)
        let closedKey = TurnSummaryFixture.conversation("closed", provider: .opencode)
        let place = ConversationTabs.Place(tabID: fixture.tab.id, position: 1, paneID: fixture.paneID)
        #expect(tabs.place(of: shownKey) == place)
        #expect(tabs.place(of: behindKey) == place)
        #expect(tabs.place(of: closedKey) == nil)
        #expect(tabs.running == [shownKey, behindKey])
        #expect(tabs.conversations(of: fixture.tab.id) == .init(titled: shownKey, all: [shownKey, behindKey]))
    }

    // MARK: Focus

    private struct FocusRequest {
        let fields: Set<String>
        let sessionID: String?
        let nonce: String?
        let at: Int

        init(at url: URL) throws {
            let body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            fields = Set(body.keys)
            sessionID = body["sessionId"] as? String
            nonce = body["nonce"] as? String
            at = try #require(body["at"] as? Int)
        }

        func check(session: String?, expectsNonce: Bool, since earliest: Int) {
            var expectedFields: Set = ["at"]
            if session != nil {
                expectedFields.insert("sessionId")
            }
            if expectsNonce {
                expectedFields.insert("nonce")
            }
            #expect(fields == expectedFields)
            #expect(sessionID == session)
            #expect(at >= earliest)
            #expect(at <= Self.timestamp())
        }

        static func timestamp() -> Int {
            Int(Date().timeIntervalSince1970 * 1000)
        }
    }

    private struct Screen {
        var session: String?
        var root: String?
    }

    /// Reads and takes the real request, then publishes the plugin's
    /// correlated response. The responder's deadlines precede the
    /// confirmation timeout, so a rejected answer cannot pass by timing out.
    private static func respond(
        channel: UUID,
        under root: URL,
        target: String?,
        screen: Screen,
        confirm: @escaping @MainActor (Duration) async -> Bool
    ) async throws -> Bool {
        let url = AgentTabFocus.requestURL(channel: channel, under: root)
        let earliest = FocusRequest.timestamp()
        let result = Recorded<Bool?>(nil)
        let task = Task { result.value = await confirm(.seconds(6)) }
        let files = FileManager.default
        do {
            await pollUntil(timeout: .seconds(2), interval: .milliseconds(5)) {
                files.fileExists(atPath: url.path)
            }
            try #require(files.fileExists(atPath: url.path), "no request at the process channel")
            let request = try FocusRequest(at: url)
            request.check(session: target, expectsNonce: true, since: earliest)
            let nonce = try #require(request.nonce)
            try #require(UUID(uuidString: nonce) != nil)
            #expect(result.value == nil, "confirmation returned before its answer")
            try files.removeItem(at: url)
            let answer = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(nonce).answer")
            let fields: [String: Any] = [
                "nonce": nonce,
                "sessionId": screen.session.map { $0 as Any } ?? NSNull(),
                "rootSessionId": screen.root.map { $0 as Any } ?? NSNull()
            ]
            try JSONSerialization.data(withJSONObject: fields).write(to: answer, options: .atomic)

            await pollUntil(timeout: .seconds(2), interval: .milliseconds(5)) { result.value != nil }
            let confirmed = try #require(result.value as Bool?, "confirmation did not consume its answer")
            await task.value
            #expect(!files.fileExists(atPath: answer.path))
            return confirmed
        } catch {
            task.cancel()
            await task.value
            throw error
        }
    }

    /// Writing a request takes away what nobody took: requests and answers older than
    /// half a minute, an earlier build's pane-named files among them. Fresh ones stay.
    @Test func writingARequestSweepsStaleFilesAndKeepsFreshOnes() throws {
        try withTempDir { root in
            let directory = root.appendingPathComponent("tab-focus", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let old = Date().addingTimeInterval(-60)
            func file(_ name: String, at date: Date) throws -> URL {
                let url = directory.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
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
            let earliest = FocusRequest.timestamp()

            AgentTabFocus.request(run, under: root)

            for url in stale {
                #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
            }
            let request = AgentTabFocus.requestURL(channel: channel, under: root)
            for url in fresh + [unrelated] {
                #expect(try Data(contentsOf: url) == Data(url.lastPathComponent.utf8))
            }
            let kept = fresh + [unrelated, request]
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(kept.map(\.lastPathComponent)))
            try FocusRequest(at: request).check(session: "ses_abc", expectsNonce: false, since: earliest)
        }
    }

    /// The file belongs to the process launch channel even when tmux attaches it to another pane.
    @Test func aFocusRequestNamesOnlyTheSessionAndIsPrivate() throws {
        let launched = UUID()
        let attached = UUID()
        try withTempDir { directory in
            var run = Self.tab("abc", isBehind: true, pane: attached)
            run.tabChannel = launched
            let earliest = FocusRequest.timestamp()

            AgentTabFocus.request(run, under: directory)

            let url = AgentTabFocus.requestURL(channel: launched, under: directory)
            try FocusRequest(at: url).check(session: "ses_abc", expectsNonce: false, since: earliest)
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
            #expect(url.lastPathComponent == "\(launched.uuidString.uppercased()).json")
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [url.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: AgentTabFocus.requestURL(channel: attached, under: directory).path))
        }
    }

    /// Demo mode has nowhere to write a request: nothing is asked, and nothing confirmed.
    @Test func withNowhereToWrite_nothingIsAskedOrConfirmed() async {
        AgentTabFocus.request(Self.tab("abc", isBehind: true), under: nil)
        let confirmed = await AgentTabFocus.confirm(sessionID: "ses_abc", channel: UUID(), limit: .seconds(1), under: nil)
        #expect(!confirmed)
    }

    // MARK: Review

    private static func destination(_ pane: UUID, agent: AgentKind? = .opencode) -> ReviewDestination {
        ReviewDestination(paneID: pane, title: "", agent: agent)
    }

    /// A Claude destination needs no tab confirmation even when OpenCode
    /// also reports an attachment to that pane.
    @Test(arguments: [false, true])
    func aReviewForClaudeSkipsTabFocus(openCodeIsAlsoAttached: Bool) async throws {
        let pane = UUID()
        try await withTempDir { root in
            let opencode = Self.tab("o", isBehind: false, pane: pane)
            let claude = Self.tab("c", kind: .claude, isBehind: false, pane: pane)
            let runtimes = openCodeIsAlsoAttached ? [opencode, claude] : [claude]
            let shown = await ReviewSessionFocus.show(
                conversation: nil,
                destination: Self.destination(pane, agent: .claude),
                runtimes: { runtimes },
                limit: .zero,
                under: root
            )
            #expect(shown)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(files.isEmpty)
        }
    }

    @Test func aDeadProcessesRecordMakesNoReviewWait() async throws {
        let pane = UUID()
        try await withTempDir { root in
            var dead = Self.tab("o", isBehind: false, pane: pane)
            dead.processID = 4242
            var checked: [pid_t] = []
            let shown = await ReviewSessionFocus.show(
                conversation: nil,
                destination: Self.destination(pane),
                runtimes: { [dead] },
                limit: .zero,
                isAlive: {
                    checked.append($0)
                    return false
                },
                under: root
            )
            #expect(shown)
            #expect(checked == [4242])
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(files.isEmpty)
        }
    }

    /// An inactive tmux pane may still be attached and have a newer run.
    @Test func theActiveTmuxPanesProcessReceivesTheFocusRequest() async throws {
        let pane = UUID()
        let frontChannel = UUID()
        let rearChannel = UUID()
        let frontTmux = TmuxPaneLocation(
            socketPath: "/tmp/s", serverPID: "1", serverStartedAt: "1", sessionID: "$1",
            windowID: "@1", paneID: "%1", isActive: true
        )
        let rearTmux = TmuxPaneLocation(
            socketPath: "/tmp/s", serverPID: "1", serverStartedAt: "1", sessionID: "$1",
            windowID: "@1", paneID: "%2", isActive: false
        )
        var front = Self.tab("front", isBehind: false, updatedAt: Date(timeIntervalSince1970: 1), pane: pane, tmux: frontTmux)
        var rear = Self.tab("rear", isBehind: false, updatedAt: Date(timeIntervalSince1970: 2), pane: pane, tmux: rearTmux)
        front.tabChannel = frontChannel
        rear.tabChannel = rearChannel

        try await withTempDir { root in
            let shown = try await Self.respond(
                channel: frontChannel,
                under: root,
                target: nil,
                screen: Screen(session: "ses_front", root: "ses_front")
            ) { limit in
                await ReviewSessionFocus.show(
                    conversation: nil,
                    destination: Self.destination(pane),
                    runtimes: { [rear, front] },
                    limit: limit,
                    under: root
                )
            }
            #expect(shown)
            let directory = AgentTabFocus.requestURL(channel: rearChannel, under: root).deletingLastPathComponent()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            let withoutActivePane = await ReviewSessionFocus.show(
                conversation: nil,
                destination: Self.destination(pane),
                runtimes: { [rear] },
                limit: .zero,
                under: root
            )
            #expect(withoutActivePane)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    enum RootView: CaseIterable {
        case session
        case subagent
    }

    @Test(arguments: RootView.allCases)
    func anUnnamedConfirmationRequiresTheRootSession(_ view: RootView) async throws {
        let channel = UUID()
        try await withTempDir { root in
            let session = view == .session ? "ses_a" : "ses_child"
            let shown = try await Self.respond(
                channel: channel, under: root, target: nil, screen: Screen(session: session, root: "ses_a")
            ) { limit in
                await AgentTabFocus.confirm(sessionID: nil, channel: channel, limit: limit, under: root)
            }
            #expect(shown == (view == .session))
        }
    }

    /// Answer cleanup is scoped to the confirmation's own nonce.
    @Test func aConfirmationsCleanupLeavesAnothersAnswer() async throws {
        let channel = UUID()
        try await withTempDir { root in
            let url = AgentTabFocus.requestURL(channel: channel, under: root)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let otherNonce = UUID().uuidString
            let other = directory.appendingPathComponent("\(url.lastPathComponent).\(otherNonce).answer")
            let otherBytes = Data(#"{"nonce":"\#(otherNonce)","sessionId":"ses_child","rootSessionId":"ses_other"}"#.utf8)
            try otherBytes.write(to: other)

            let shown = try await Self.respond(
                channel: channel, under: root, target: nil, screen: Screen(session: "ses_a", root: "ses_a")
            ) { limit in
                await AgentTabFocus.confirm(sessionID: nil, channel: channel, limit: limit, under: root)
            }

            #expect(shown)
            #expect(try Data(contentsOf: other) == otherBytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [other.lastPathComponent])
        }
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

    enum ReviewAnswer: CaseIterable {
        case reopenedReviewedSession
        case differentSession
        case namedOnHomeScreen
        case unnamedWithSession
        case unnamedOnHomeScreen
    }

    /// Confirmation gates insertion before any text is pasted.
    @Test(arguments: ReviewAnswer.allCases)
    func aReviewRequiresThePluginsConfirmation(_ answer: ReviewAnswer) async throws {
        let pane = UUID()
        let channel = UUID()
        var closed = Self.tab("a", state: .unknown, isBehind: false, pane: pane)
        var other = Self.tab("b", isBehind: true, pane: pane)
        closed.tabChannel = channel
        other.tabChannel = channel
        let reviewed = try #require(closed.conversation)
        let target: ConversationKey?
        let visibleSession: String?
        let expected: Bool
        switch answer {
        case .reopenedReviewedSession: (target, visibleSession, expected) = (reviewed, "ses_a", true)
        case .differentSession: (target, visibleSession, expected) = (reviewed, "ses_b", false)
        case .namedOnHomeScreen: (target, visibleSession, expected) = (reviewed, nil, false)
        case .unnamedWithSession: (target, visibleSession, expected) = (nil, "ses_b", true)
        case .unnamedOnHomeScreen: (target, visibleSession, expected) = (nil, nil, false)
        }

        try await withTempDir { root in
            let confirmed = try await Self.respond(
                channel: channel,
                under: root,
                target: target == nil ? nil : "ses_a",
                screen: Screen(session: visibleSession, root: visibleSession)
            ) { limit in
                await ReviewSessionFocus.show(
                    conversation: target,
                    destination: Self.destination(pane),
                    runtimes: { [closed, other] },
                    limit: limit,
                    under: root
                )
            }
            #expect(confirmed == expected)
            let attached = AgentTabFocus.requestURL(channel: pane, under: root)
            #expect(!FileManager.default.fileExists(atPath: attached.path))
        }
    }

    @Test func aReviewWithNoAnswerIsRefusedInTime() async throws {
        let pane = UUID()
        let channel = UUID()
        try await withTempDir { root in
            var run = Self.tab("a", isBehind: false, pane: pane)
            run.tabChannel = channel
            let earliest = FocusRequest.timestamp()
            let clock = ContinuousClock()
            let start = clock.now
            let limit = Duration.milliseconds(100)
            let shown = await ReviewSessionFocus.show(
                conversation: nil,
                destination: Self.destination(pane),
                runtimes: { [run] },
                limit: limit,
                under: root
            )

            #expect(!shown)
            #expect(clock.now - start >= limit)
            #expect(clock.now - start < .seconds(3))
            // An untaken request stays for the plugin or the stale-file sweep.
            let url = AgentTabFocus.requestURL(channel: channel, under: root)
            let request = try FocusRequest(at: url)
            request.check(session: nil, expectsNonce: true, since: earliest)
            let nonce = try #require(request.nonce)
            #expect(UUID(uuidString: nonce) != nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [url.lastPathComponent])
        }
    }

    enum ReviewedReceiver: CaseIterable {
        case deadInThisPane
        case liveInThisPane
        case inAnotherPane
        case withoutChannel
        case unnamed
    }

    @Test(arguments: ReviewedReceiver.allCases)
    func reviewedSessionFocusPreservesTheNamedDestination(_ receiver: ReviewedReceiver) async throws {
        let pane = UUID()
        let reviewedChannel = UUID()
        let otherChannel = UUID()
        let reviewedPane = receiver == .inAnotherPane ? UUID() : pane
        var reviewed = Self.tab("a", isBehind: true, updatedAt: Date(timeIntervalSince1970: 1), pane: reviewedPane)
        reviewed.tabChannel = receiver == .withoutChannel ? nil : reviewedChannel
        reviewed.processID = 4242
        var other = Self.tab("b", isBehind: false, updatedAt: Date(timeIntervalSince1970: 2), pane: pane)
        other.tabChannel = otherChannel
        other.processID = 4243
        let runs = [reviewed, other]
        let reviewedConversation = try #require(reviewed.conversation)
        let requested = receiver == .unnamed ? nil : reviewedConversation
        let namesReviewed = receiver == .deadInThisPane || receiver == .liveInThisPane
        #expect(ReviewSessionFocus.conversation(reviewed: requested, inPane: pane, runtimes: runs) == (namesReviewed ? requested : nil))

        try await withTempDir { root in
            @MainActor @Sendable func show(limit: Duration) async -> Bool {
                await ReviewSessionFocus.show(
                    conversation: requested,
                    destination: Self.destination(pane),
                    runtimes: { runs },
                    limit: limit,
                    isAlive: { $0 == 4243 || receiver == .liveInThisPane },
                    under: root
                )
            }

            if receiver == .deadInThisPane {
                let confirmed = await show(limit: .zero)
                #expect(!confirmed)
                let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
                #expect(entries.isEmpty, "refusal must leave both process channels untouched")
            } else {
                let channel = namesReviewed ? reviewedChannel : otherChannel
                let shown = namesReviewed ? "ses_a" : "ses_b"
                let confirmed = try await Self.respond(
                    channel: channel,
                    under: root,
                    target: namesReviewed ? "ses_a" : nil,
                    screen: Screen(session: shown, root: shown),
                    confirm: show
                )
                #expect(confirmed)
                let directory = AgentTabFocus.requestURL(channel: channel, under: root).deletingLastPathComponent()
                let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                #expect(entries.isEmpty)
            }
        }
    }
}
