// ProjectMenuModelTests.swift
// Weir — the title bar's project dropdown.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct ProjectMenuModelTests {
    private static func project(_ name: String, path: String? = nil) -> Project {
        Project(name: name, rootURL: URL(fileURLWithPath: path ?? "/tmp/\(name)"), paletteIndex: 0)
    }

    private static func facts(
        attention: [UUID: AttentionCounts] = [:],
        running: [UUID: Int] = [:],
        shown: Set<UUID> = []
    ) -> ProjectMenuModel.Facts {
        ProjectMenuModel.Facts(
            attention: { attention[$0] ?? AttentionCounts() },
            running: { running[$0] ?? 0 },
            isShown: { shown.contains($0) }
        )
    }

    @MainActor
    @Test func theDropdownKeepsTheWindowsSidebarOrderAndAppendsUnlistedProjects() throws {
        let fixture = ProjectWindowsFixture()
        let d = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("d"), suggestedName: "d")
        let aa = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("aa"), suggestedName: "aa")
        let other = try fixture.window(showing: fixture.c)
        fixture.registry.hide(other.id)
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.c.id, fixture.a.id])
        fixture.session.recentProjectPaths = [aa.rootURL, d.rootURL, fixture.b.rootURL]

        let rows = ProjectMenuModel(
            session: fixture.session,
            registry: fixture.registry,
            window: fixture.primary.selection,
            query: "",
            attentionQueue: AttentionQueue(),
            attention: AttentionState()
        ).rows

        #expect(rows.map(\.id) == [fixture.c.id, fixture.a.id, fixture.b.id, d.id, aa.id])
        #expect(rows.map(\.name) == ["c", "a", "b", "d", "aa"])
        #expect(rows.map(\.isCurrent) == [false, true, false, false, false])
        #expect(other.isHidden)
        #expect(rows.map(\.isInOtherWindow) == [true, false, false, false, false])
    }

    @Test func theSearch_matchesTheNameOrTheFolder_withoutCase() {
        let projects = [Self.project("Weir"), Self.project("notes", path: "/Users/me/work/weir-notes"), Self.project("other")]

        let model = ProjectMenuModel(projects: projects, currentProjectID: nil, query: " WEIR ", facts: Self.facts())

        #expect(model.rows.map(\.name) == ["Weir", "notes"])
        #expect(ProjectMenuModel(projects: projects, currentProjectID: nil, query: "zzz", facts: Self.facts()).rows.isEmpty)
    }

    @Test func eachRow_carriesItsCounts_andMarksTheWindowsProject() {
        let projects = [Self.project("a"), Self.project("b"), Self.project("c")]
        let facts = Self.facts(
            attention: [projects[0].id: AttentionCounts(stops: 1), projects[1].id: AttentionCounts(unread: 2)],
            running: [projects[1].id: 3],
            shown: [projects[0].id, projects[1].id]
        )

        let rows = ProjectMenuModel(projects: projects, currentProjectID: projects[1].id, query: "", facts: facts).rows

        #expect(rows.map(\.id) == projects.map(\.id))
        #expect(rows.map(\.attention.counts) == [AttentionCounts(stops: 1), AttentionCounts(unread: 2), AttentionCounts()])
        #expect(rows.map(\.attention.count) == [1, 2, 0])
        #expect(rows.map(\.attention.style) == [.blocking, .unreadOnly, .empty])
        #expect(rows.map(\.running) == [0, 3, 0])
        #expect(rows.map(\.isCurrent) == [false, true, false])
        #expect(rows.map(\.isInOtherWindow) == [true, false, false])
    }

    @Test func theMenuAndPaletteUseTheSameProjectFrecencyKeys() {
        let first = UUID()
        let second = UUID()
        let expected = ["project.\(first.uuidString)", "project.\(second.uuidString)"]
        #expect([first, second].map(ProjectMenuModel.frecencyKey) == expected)
        #expect([first, second].map { CommandPaletteAction.activateProject($0).frecencyKey } == expected)
    }

    @Test(arguments: [
        ("weir", "WE"),
        ("weir-site", "WS"),
        ("my-side-project", "MS"),
        ("-dotfiles", "DO"),
        ("a", "A"),
        ("", ""),
    ])
    func theMark_takesTwoWordsInitials_elseTheFirstTwoLetters(name: String, initials: String) {
        #expect(ProjectMenuModel.initials(of: name) == initials)
    }

    @Test func theControlsTooltip_countsOtherProjectsItems_onlyWhenThereAreAny() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(ProjectMenuModel.controlHelp(otherProjectsCount: 0, locale: english) == "Project")
        #expect(ProjectMenuModel.controlHelp(otherProjectsCount: 3, locale: english) == "Project · Other projects need attention: 3")
        #expect(ProjectMenuModel.controlHelp(otherProjectsCount: 3, locale: japanese) == "プロジェクト · ほかのプロジェクトに要対応 3 件")
    }

    @Test func theRowsTooltip_namesTheCurrentWindow_orHowToOpenANewOne() {
        func row(isCurrent: Bool, isInOtherWindow: Bool = false) -> ProjectMenuModel.Row {
            ProjectMenuModel.Row(
                id: UUID(),
                name: "weir-site",
                paletteIndex: nil,
                isCurrent: isCurrent,
                isInOtherWindow: isInOtherWindow,
                attention: NeedsAttentionCountModel(AttentionCounts()),
                running: 0
            )
        }
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: true), locale: english) == "Current Window")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: true), locale: japanese) == "現在のウインドウ")
        // Another window comes forward either way, so its tooltip names
        // the window rather than offering a new one.
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: false), locale: english) == "⌘-click to open in a new window")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: false), locale: japanese) == "⌘ クリックで新しいウインドウに開く")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: false, isInOtherWindow: true), locale: english) == "Other Window")
        // What the tooltip and the VoiceOver action both read.
        #expect(row(isCurrent: false).opensInNewWindow)
        #expect(!row(isCurrent: true).opensInNewWindow)
        #expect(!row(isCurrent: false, isInOtherWindow: true).opensInNewWindow)
    }

    @Test(arguments: ["en", "ja"])
    func rowHelpRetainsIconMeaningsAndAttentionBreakdown(language: String) throws {
        let locale = Locale(identifier: language)
        let row = ProjectMenuModel.Row(
            id: UUID(), name: "weir", paletteIndex: nil, isCurrent: false, isInOtherWindow: true,
            attention: NeedsAttentionCountModel(AttentionCounts(approvals: 1, unread: 2)), running: 3
        )
        let help = try #require(ProjectMenuModel.rowHelp(row, locale: locale))
        let expected = language == "en"
            ? ["Other Window", "Needs Attention · 3", "1 Approval", "2 Unread", "Running · 3"]
            : ["別のウインドウ", "要対応 3", "承認 1", "未読 2", "実行中 3"]
        for text in expected {
            #expect(help.contains(text))
        }
    }

    @Test(arguments: ["en", "ja"])
    func emptyWindowHelpRetainsActivityAlongsideTheOtherWindowMark(language: String) {
        let row = EmptyWindowModel.Row(
            id: UUID(), name: "weir", paletteIndex: nil, folder: "/tmp/weir", isInOtherWindow: true,
            attention: NeedsAttentionCountModel(AttentionCounts(unread: 2)), running: 3
        )
        let help = row.help(locale: Locale(identifier: language))
        let expected = language == "en"
            ? ["/tmp/weir", "Other Window", "Needs Attention · 2", "2 Unread", "Running · 3"]
            : ["/tmp/weir", "別のウインドウ", "要対応 2", "未読 2", "実行中 3"]
        #expect(row.isInOtherWindow)
        for text in expected {
            #expect(help.contains(text))
        }
        #expect(!help.contains("⌘"))
    }

    @Test(arguments: [
        (ProjectTrouble?.none, true),
        (.folderMissing, false),
        (.gitUnavailable, true),
        (.listingFailed(detail: "offline"), true)
    ])
    func theWindowsProject_offersCloseProject_afterItsSettingsAndFolder(trouble: ProjectTrouble?, canReveal: Bool) {
        let other = Self.project("other")
        var project = Self.project("weir")
        project.trouble = trouble
        let projects = [other, project]

        #expect(ProjectMenuModel.projectItems(for: project.id, in: projects) == [.settings, .revealInFinder, .close])
        #expect(ProjectMenuModel.projectItems(for: nil, in: projects).isEmpty)
        #expect(ProjectMenuModel.projectItems(for: UUID(), in: projects).isEmpty)
        #expect(ProjectMenuModel.isEnabled(.settings, for: project))
        #expect(ProjectMenuModel.isEnabled(.revealInFinder, for: project) == canReveal)
        #expect(ProjectMenuModel.isEnabled(.close, for: project))
    }

    @MainActor
    @Test func closeProjectBuildsAConfirmationTargetForTheSelectedProject() {
        let fixture = ProjectWindowsFixture()

        let target = TitleBarMenuHost.closeTarget(for: fixture.b.id, in: fixture.session)

        #expect(target?.projectID == fixture.b.id)
        #expect(target?.name == "b")
        fixture.session.removeProject(fixture.b.id)
        #expect(TitleBarMenuHost.closeTarget(for: fixture.b.id, in: fixture.session) == nil)
        #expect(TitleBarMenuHost.closeTarget(for: nil, in: fixture.session) == nil)
    }

    @MainActor
    @Test func closeWarningDetectsLiveAgentsOnlyInTheProjectsOwnTabs() throws {
        let fixture = ProjectWindowsFixture()
        let session = fixture.session
        let projectID = fixture.a.id
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: projectID, in: session)
        let checkout = session.openTab(container: .worktree(projectID: projectID, worktreeID: worktree.id))
        let stamp = Date(timeIntervalSince1970: 100)
        func setBadge(_ state: AgentState, in tab: Tab) throws {
            let pane = try #require(tab.splitTree.allLeafIDs().first)
            session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: state, updatedAt: stamp)] }
        }

        #expect(!session.hasLiveAgent(inProject: projectID))
        try setBadge(.running, in: fixture.scratchTab())
        try setBadge(.running, in: fixture.bTab)
        try setBadge(.unknown, in: fixture.aTab)
        #expect(!session.hasLiveAgent(inProject: projectID))

        try setBadge(.running, in: checkout)
        #expect(session.hasLiveAgent(inProject: projectID))
        session.update(checkout.id) { $0.agentBadges = [:] }
        #expect(!session.hasLiveAgent(inProject: projectID))
        try setBadge(.running, in: fixture.aTab)
        #expect(session.hasLiveAgent(inProject: projectID))
        let rootPane = try #require(fixture.aTab.splitTree.allLeafIDs().first)
        session.update(fixture.aTab.id) {
            $0.agentBadges = [:]
            $0.agentsInFront[rootPane] = PaneAgentInFront(kind: .codex, isStaged: false)
        }
        #expect(session.hasLiveAgent(inProject: projectID))
    }
}
