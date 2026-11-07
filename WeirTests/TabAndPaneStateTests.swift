// TabAndPaneStateTests.swift
// Weir — pure-data tests for Tab and its agent, PaneState, and ContainerID extraction.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Tab")
struct TabTests {

    private static let projectID = UUID()
    private static let worktreeID = UUID()

    struct NewTabCase: Sendable {
        let container: ContainerID
        let title: String
        let directory: String?
        let expectedProject: UUID?
        let expectedWorktree: UUID?
        let hasParent: Bool
    }

    @Test("a new tab retains its container and opens one focused pane", arguments: [
        NewTabCase(container: .loose, title: "scratch", directory: nil, expectedProject: nil, expectedWorktree: nil, hasParent: false),
        NewTabCase(
            container: .project(projectID),
            title: "build",
            directory: "/project",
            expectedProject: projectID,
            expectedWorktree: nil,
            hasParent: true
        ),
        NewTabCase(
            container: .worktree(projectID: projectID, worktreeID: worktreeID),
            title: "feat-x",
            directory: "/worktree",
            expectedProject: projectID,
            expectedWorktree: worktreeID,
            hasParent: true
        )
    ])
    func newWithSinglePane_retainsItsContainerAndDirectory(_ input: NewTabCase) {
        let (tab, paneID) = Tab.newWithSinglePane(title: input.title, workingDirectory: input.directory, container: input.container)
        #expect(tab.container == input.container)
        #expect(tab.title == input.title)
        #expect(tab.workingDirectory == input.directory)
        #expect(tab.splitTree.allLeafIDs() == [paneID])
        #expect(tab.splitTree.focusedLeafID == paneID)
        #expect(tab.projectID == input.expectedProject)
        #expect(tab.worktreeID == input.expectedWorktree)
        #expect(tab.container.hasParent == input.hasParent)
    }

    @Test(
        "displayTitle prefers a non-empty override and falls back to the auto title otherwise",
        arguments: [
            // (override, expected)
            ("manual" as String?, "manual"),
            (nil as String?, "auto"),
            ("" as String?, "auto"),
        ]
    )
    func displayTitle_overrideRules(override: String?, expected: String) {
        var tab = Tab.newWithSinglePane(title: "auto", container: .loose).tab
        tab.titleOverride = override
        #expect(tab.displayTitle == expected)
    }

    @Test(arguments: [(nil as String?, "ssh"), ("deploy", "deploy")])
    func namePrefix_staysUntilRenamed(override: String?, initialName: String) {
        var tab = Tab.newWithSinglePane(title: "ssh", container: .loose).tab
        tab.titleOverride = override
        tab.namePrefix = "prod"
        #expect(tab.displayTitle == "prod · \(initialName)")
        #expect(tab.name == initialName)

        tab.title = "~/servers"
        #expect(tab.displayTitle == "prod · \(override ?? "~/servers")")
        tab.rename("web")
        #expect(tab.displayTitle == "web")
        #expect(tab.name == "web")
        #expect(tab.namePrefix == nil)
        tab.rename("")
        #expect(tab.displayTitle == "~/servers")
        #expect(tab.name == "~/servers")
        #expect(tab.namePrefix == nil)
    }

    @Test("a new pane starts in the tab's own default, else where the tab opened")
    func newPaneWorkingDirectory_followsTheTabsDefault() {
        var tab = Tab.newWithSinglePane(title: "t", workingDirectory: "/opened", container: .loose).tab
        tab.pwd = "/now"
        #expect(tab.newPaneWorkingDirectory == "/opened")

        tab.cwdMode = .inheritPrevious
        #expect(tab.newPaneWorkingDirectory == "/now")
        tab.pwd = nil
        #expect(tab.newPaneWorkingDirectory == "/opened")
        tab.workingDirectory = nil
        #expect(tab.newPaneWorkingDirectory == nil)
        tab.workingDirectory = "/opened"
        tab.cwdMode = .home
        #expect(tab.newPaneWorkingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
        tab.cwdMode = .fixed
        #expect(tab.newPaneWorkingDirectory == "/opened", "no fixed folder chosen")
        tab.cwdPath = URL(fileURLWithPath: "/fixed")
        #expect(tab.newPaneWorkingDirectory == "/fixed")
    }

    @Test("the new fields round-trip, and a mode a later build added reads as none")
    func groupFields_roundTrip_andToleratesAnUnknownMode() throws {
        var tab = Tab.newWithSinglePane(title: "t", workingDirectory: "/opened", container: .loose).tab
        tab.namePrefix = "prod"
        tab.paletteIndex = 4
        tab.cwdMode = .fixed
        tab.cwdPath = URL(fileURLWithPath: "/fixed")

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded == tab)

        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["cwdMode"] = "nearestRepo"
        let later = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(later.cwdMode == nil)
        #expect(later.newPaneWorkingDirectory == "/opened")
        tab.cwdMode = nil
        #expect(later == tab)
    }

    @Test("per-pane tmux bindings persist and older tabs load without them", .tags(.persistence))
    func tmuxBindings_preserveEachPane_andDefaultToEmptyForOlderTabs() throws {
        let first = UUID()
        let second = UUID()
        let tree = SplitTree(leafID: first).insert(at: first, direction: .horizontal, newID: second).tree
        var tab = Tab(title: "t", splitTree: tree, container: .loose)
        tab.tmuxBindings = [
            first: TmuxBinding(
                socketPath: "/private/tmp/weir-first.sock", sessionID: "$3", sessionName: "first",
                serverPID: "123", serverStartedAt: "1700000000", isProvisional: true
            ),
            second: TmuxBinding(
                socketPath: "/private/tmp/weir-second.sock", sessionID: "$8", sessionName: "second",
                serverPID: "456", serverStartedAt: "1700000010", isProvisional: false
            )
        ]
        let encoded = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: encoded)
        #expect(decoded.tmuxBindings == tab.tmuxBindings)
        #expect(decoded.splitTree == tree)

        var older = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        try #require(older.removeValue(forKey: "tmuxBindings") != nil)
        let legacy = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(legacy.tmuxBindings.isEmpty)
        #expect(legacy.splitTree == tree)
    }

    @Test func aTabSavedAndRead_keepsItsStagedInstruction_andAnOlderFileReadsWithoutOne() throws {
        let made = Tab.newWithSinglePane(title: "t", container: .loose)
        var tab = made.tab
        let pane = made.paneID
        tab.initialPromptFiles[pane] = "/tmp/weir-prompts/p"
        tab.initialAgentExecutables[pane] = AgentInstallation(kind: .codex, executable: "/opt/tools/bin/codex")
        let encoded = try JSONEncoder().encode(tab)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let prompts = try #require(object["initialPromptFiles"])
        let persistedPrompts = try JSONDecoder().decode(
            [UUID: String].self,
            from: JSONSerialization.data(withJSONObject: prompts)
        )
        #expect(persistedPrompts == [pane: "/tmp/weir-prompts/p"])
        #expect(object["initialAgentExecutables"] == nil)
        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!text.contains("/opt/tools/bin/codex"))
        let decoded = try JSONDecoder().decode(Tab.self, from: encoded)
        #expect(decoded.initialPromptFiles == [pane: "/tmp/weir-prompts/p"])
        // The executable the sheet found is never saved: a restored pane
        // searches afresh.
        #expect(decoded.initialAgentExecutables.isEmpty)

        var older = object
        try #require(older.removeValue(forKey: "initialPromptFiles") != nil)
        let fromOlder = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(fromOlder.initialPromptFiles.isEmpty)
    }

    // MARK: - The tab's agent

    @Test func aTabWithTwoAgents_namesBoth_inAgentKindsOrder() {
        let claudePane = UUID()
        let codexPane = UUID()
        let anotherCodexPane = UUID()
        let tree = SplitTree(leafID: codexPane).insert(at: codexPane, direction: .horizontal, newID: claudePane).tree
            .insert(at: claudePane, direction: .vertical, newID: anotherCodexPane).tree
        var tab = Tab(
            title: "t",
            splitTree: tree,
            container: .loose
        )
        tab.agentBadges[.codex] = [codexPane: AgentBadge(state: .running, updatedAt: Date())]
        #expect(tab.agentKinds == [.codex])
        tab.agentBadges[.claude] = [claudePane: AgentBadge(state: .idle, updatedAt: Date())]
        tab.agentBadges[.codex]?[anotherCodexPane] = AgentBadge(state: .idle, updatedAt: Date())
        #expect(tab.agentKinds == [.claude, .codex], "distinct providers in AgentKind's order, independent of pane order")
    }

    @Test func aTabIsAnAgentTab_whileAnAgentHasASessionInIt_andRunsInTmuxByEitherSource() {
        let pane = UUID()
        var tab = Tab(title: "t", splitTree: SplitTree(leafID: pane), container: .loose)
        #expect(tab.agentKinds.isEmpty)
        tab.agentBadges[.codex] = [pane: AgentBadge(state: .unknown, updatedAt: Date())]
        #expect(tab.agentKinds == [.codex], "a run restored at launch has not reported yet, and is still the tab's agent")
        tab.agentBadges[.codex] = [pane: AgentBadge(state: .idle, updatedAt: Date())]
        #expect(tab.agentKinds == [.codex], "the tab wears its agent's badge")

        #expect(!tab.isHostedInTmux(mountedTmuxPaneIDs: []))
        #expect(!tab.isHostedInTmux(mountedTmuxPaneIDs: [UUID()]))
        #expect(tab.isHostedInTmux(mountedTmuxPaneIDs: [pane]))
        tab.agentBadges[.codex]?[pane]?.isTmuxHosted = true
        #expect(tab.isHostedInTmux(mountedTmuxPaneIDs: []))

        tab.agentBadges[.codex] = [:]
        #expect(tab.agentKinds.isEmpty, "a retired run leaves the tab a plain terminal")
        #expect(!tab.isHostedInTmux(mountedTmuxPaneIDs: []))
    }

    /// A tab's first title is its folder: the tab keeps the folder's
    /// characters, and its name shows the newline.
    @Test("a tab's first title keeps the newline, and its name shows it")
    func pwdStyleTitle_keepsTheNewline_andTheTabsNameShowsIt() {
        let title = TitleFormatting.pwdStyle(for: URL(fileURLWithPath: "/tmp/feat\nline"))
        #expect(title == "/tmp/feat\nline")
        let tab = Tab(title: title, splitTree: SplitTree(leafID: UUID()), container: .loose)
        #expect(tab.name == "/tmp/feat\u{240A}line")
        #expect(tab.displayTitle == "/tmp/feat\u{240A}line")
    }
}

@MainActor
@Suite("Tab agent maps")
struct TabAgentMapDecodingTests {
    private static let pane = "11111111-1111-4111-8111-111111111111"

    /// A tab as a build before the two maps wrote it: one field per provider.
    private func legacyTab() -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": "tab",
            "container": ["kind": "loose"],
            "splitTree": ["root": ["leaf": ["id": Self.pane]]],
            "claudeSessions": [Self.pane, ["sessionId": "claude-S", "cwd": "/repo"]],
            "codexSessions": [Self.pane, ["sessionId": "codex-S", "cwd": "/repo"]],
            "claudeAgentBadges": [
                Self.pane,
                ["state": "running", "updatedAt": 780_000_000.0]
            ],
            "codexAgentBadges": [
                Self.pane,
                ["state": "idle", "updatedAt": 780_000_010.0]
            ]
        ]
    }

    @Test("an older file's per-provider fields are read into the maps")
    func decode_foldsTheLegacyFields() throws {
        let data = try JSONSerialization.data(withJSONObject: legacyTab())
        let tab = try JSONDecoder().decode(Tab.self, from: data)
        let pane = try #require(UUID(uuidString: Self.pane))

        // Upgrading must not blank the hints the interface is about to draw,
        // and must not offer one provider's session to another.
        #expect(tab.agentSessions == [
            .claude: [pane: AgentSessionInfo(sessionId: "claude-S", cwd: "/repo")],
            .codex: [pane: AgentSessionInfo(sessionId: "codex-S", cwd: "/repo")]
        ])
        #expect(tab.agentBadges == [
            .claude: [pane: AgentBadge(state: .running, updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_000))],
            .codex: [pane: AgentBadge(state: .idle, updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_010))]
        ])
    }

    /// A tab as a newer build writes it: the maps are objects keyed by
    /// provider id, and one of the ids is a provider this build does not have.
    private func tabFromANewerBuild() -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": "tab",
            "container": ["kind": "loose"],
            "splitTree": ["root": ["leaf": ["id": Self.pane]]],
            "agentSessions": [
                "claude": [Self.pane, ["sessionId": "claude-S", "cwd": "/repo"]],
                "gemini": [Self.pane, ["sessionId": "gemini-S", "cwd": "/repo"]]
            ],
            "agentBadges": [
                "claude": [Self.pane, ["state": "idle", "updatedAt": 780_000_010.0]],
                "gemini": [Self.pane, ["state": "running", "updatedAt": 780_000_000.0]]
            ]
        ]
    }

    @Test("a provider this build does not know is skipped, not fatal")
    func decode_skipsAnUnknownProvider() throws {
        let data = try JSONSerialization.data(withJSONObject: tabFromANewerBuild())
        let tab = try JSONDecoder().decode(Tab.self, from: data)
        let pane = try #require(UUID(uuidString: Self.pane))

        // The tab restores with what this build can read; the projection
        // fills the rest in from the records on its first pass.
        #expect(tab.agentSessions == [.claude: [pane: AgentSessionInfo(sessionId: "claude-S", cwd: "/repo")]])
        #expect(tab.agentBadges == [
            .claude: [pane: AgentBadge(state: .idle, updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_010))]
        ])
    }

    @Test("both maps use provider keys and omit legacy fields when saved")
    func encode_keysTheMapsByProviderId() throws {
        let tab = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: legacyTab()))
        let data = try JSONEncoder().encode(tab)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(object["agentSessions"] as? [String: Any])
        let badges = try #require(object["agentBadges"] as? [String: Any])
        #expect(Set(sessions.keys) == ["claude", "codex"])
        #expect(Set(badges.keys) == ["claude", "codex"])
        for kind in [AgentKind.claude, .codex] {
            let savedSessions = try #require(sessions[kind.rawValue])
            let savedBadges = try #require(badges[kind.rawValue])
            #expect(try JSONDecoder().decode(
                [UUID: AgentSessionInfo].self,
                from: JSONSerialization.data(withJSONObject: savedSessions)
            ) == tab.agentSessions[kind])
            #expect(try JSONDecoder().decode(
                [UUID: AgentBadge].self,
                from: JSONSerialization.data(withJSONObject: savedBadges)
            ) == tab.agentBadges[kind])
        }
        for key in ["claudeSessions", "codexSessions", "claudeAgentBadges", "codexAgentBadges"] {
            #expect(object[key] == nil, "Legacy key: \(key)")
        }
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded.agentSessions == tab.agentSessions)
        #expect(decoded.agentBadges == tab.agentBadges)
    }

    @Test("the array shape an unreleased build wrote is still read")
    func decode_acceptsTheArrayShape() throws {
        var file = tabFromANewerBuild()
        file["agentSessions"] = ["codex", [Self.pane, ["sessionId": "codex-S", "cwd": "/repo"]]]
        file["agentBadges"] = ["codex", [Self.pane, ["state": "idle", "updatedAt": 780_000_010.0]]]
        let data = try JSONSerialization.data(withJSONObject: file)
        let tab = try JSONDecoder().decode(Tab.self, from: data)
        let pane = try #require(UUID(uuidString: Self.pane))

        #expect(tab.agentSessions == [.codex: [pane: AgentSessionInfo(sessionId: "codex-S", cwd: "/repo")]])
        #expect(tab.agentBadges == [
            .codex: [pane: AgentBadge(state: .idle, updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_010))]
        ])
    }

}

@Suite("PaneState")
struct PaneStateTests {

    @Test("hasUnread tracks the count field")
    func hasUnread_tracksUnreadCount() {
        var state = PaneState()
        #expect(state.hasUnread == false)
        state.unreadCount = 1
        #expect(state.hasUnread)
        state.unreadCount = 0
        #expect(state.hasUnread == false)
    }

    @Test("a pane state saved before panes had names reads with none")
    func decode_withoutAName_readsNone() throws {
        let decoded = try JSONDecoder().decode(PaneState.self, from: Data(#"{"unreadCount":2}"#.utf8))
        #expect(decoded.unreadCount == 2)
        #expect(decoded.name == nil)
    }
}

@Suite("ContainerID extraction")
struct ContainerIDExtractionTests {

    @Test("projectID is set on .project and .worktree, nil on .loose")
    func projectID_extraction() {
        let pid = UUID()
        let wid = UUID()
        #expect(ContainerID.project(pid).projectID == pid)
        #expect(ContainerID.project(pid).worktreeID == nil)
        #expect(ContainerID.worktree(projectID: pid, worktreeID: wid).projectID == pid)
        #expect(ContainerID.worktree(projectID: pid, worktreeID: wid).worktreeID == wid)
        #expect(ContainerID.loose.projectID == nil)
    }
}
