// CommandPaletteTests.swift
// Weir — the palette's catalog, which rows it offers and enables in a window, and its state opening and closing.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("CommandPalette")
@MainActor
struct CommandPaletteTests {
    /// The rows the palette offers in `window` (the primary by default),
    /// with settings read from a folder of their own.
    private static func items(
        _ session: WorkspaceSession,
        supervision: SupervisionPaletteFacts = .empty,
        window: WindowID? = nil,
        locale: String = "en"
    ) throws -> [CommandPaletteItem] {
        try withTempDir { dir in
            CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: dir),
                attention: AttentionState(),
                supervision: supervision,
                window: window ?? session.primaryWindowID,
                locale: Locale(identifier: locale)
            )
        }
    }

    private static func isEnabled(_ action: WeirShortcutAction, in items: [CommandPaletteItem]) -> Bool? {
        items.first { $0.action == .shortcutAction(action) }?.isEnabled
    }

    // MARK: - Catalog

    @Test("Recent projects use the recent-history symbol")
    func catalog_recentProjects_haveTheirOwnHistorySymbol() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let recent = URL(fileURLWithPath: "/tmp/weir-recent-project")
        session.recentProjectPaths = [recent]
        let item = try #require(Self.items(session).first { $0.action == .openRecentProject(recent) })
        #expect(item.icon == "clock.arrow.trianglehead.counterclockwise.rotate.90")
    }

    /// The palette moves the project the window shows; with none shown
    /// (the project chooser, or a scratch tab only), the moves are off; at
    /// either end of the window's order, the move off that end is off too,
    /// as the sidebar's Move Up and Move Down are (`ProjectOrder.canMove`).
    @Test func theProjectMoves_needAShownProject_withSomewhereToGo() throws {
        let fixture = ProjectWindowsFixture()
        func rows(_ projectID: UUID?) throws -> [CommandPaletteItem] {
            try Self.items(
                fixture.session,
                supervision: SupervisionPaletteFacts(projectID: projectID, sessionRowCount: 1, hasReviewTab: false)
            )
        }
        let none = try rows(nil)
        #expect(Self.isEnabled(.moveProjectUp, in: none) == false)
        #expect(Self.isEnabled(.moveProjectDown, in: none) == false)

        let first = try rows(fixture.a.id)
        #expect(Self.isEnabled(.moveProjectUp, in: first) == false)
        #expect(Self.isEnabled(.moveProjectDown, in: first) == true)
        let middle = try rows(fixture.b.id)
        #expect(Self.isEnabled(.moveProjectUp, in: middle) == true)
        #expect(Self.isEnabled(.moveProjectDown, in: middle) == true)
        let last = try rows(fixture.c.id)
        #expect(Self.isEnabled(.moveProjectUp, in: last) == true)
        #expect(Self.isEnabled(.moveProjectDown, in: last) == false)

        // The window's own order, not the session's.
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.c.id, fixture.b.id, fixture.a.id])
        #expect(try Self.isEnabled(.moveProjectUp, in: rows(fixture.c.id)) == false)
        #expect(try Self.isEnabled(.moveProjectDown, in: rows(fixture.a.id)) == false)
    }

    /// While the review stands where the terminal was, the pane commands
    /// (split right, split down, equalize, and zoom) are off: they would act
    /// on panes nobody sees. Find stays on, and Split Right is back once the
    /// review is hidden again.
    @Test func thePaneCommands_areOffWhileTheReviewHidesThePanes_andBackAfter() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        session.openTab(container: .project(project.id))
        PaneActions.split(session, direction: .horizontal, in: session.primaryWindowID)
        let window = ProjectWindowState(selection: session.primarySelection)
        let paneCommands: [WeirShortcutAction] = [.splitRight, .splitDown, .equalizeSplits, .toggleSplitZoom]

        let terminal = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        for action in paneCommands {
            #expect(Self.isEnabled(action, in: terminal) == true, "\(action)")
        }

        window.review = ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(window.arePanesHidden)
        let review = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        for action in paneCommands {
            #expect(Self.isEnabled(action, in: review) == false, "\(action)")
        }
        #expect(Self.isEnabled(.find, in: review) == true)
        // As in the menu, Find Next and Find Previous go to the review's own
        // search, though no pane has one open.
        #expect(Self.isEnabled(.findNext, in: terminal) == false)
        #expect(Self.isEnabled(.findNext, in: review) == true)
        #expect(Self.isEnabled(.findPrevious, in: review) == true)

        window.review?.isShown = false
        #expect(!window.arePanesHidden)
        let back = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        #expect(Self.isEnabled(.splitRight, in: back) == true)
    }

    /// Show Current Diff opens the review in a window with no terminal tab,
    /// and the menu's Find goes to the review there, so the palette's does.
    @Test func find_isOnForTheReview_inAWindowWithNoTab() throws {
        let (session, _) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = ProjectWindowState(selection: session.primarySelection)
        let empty = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        #expect(Self.isEnabled(.find, in: empty) == false)

        window.review = ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        let review = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        for action: WeirShortcutAction in [.find, .findNext, .findPrevious] {
            #expect(Self.isEnabled(action, in: review) == true, "\(action)")
        }
    }

    /// "#" opens on the projects in the window's sidebar order, and each
    /// one's worktrees in the order its sidebar lists them, before use
    /// re-ranks them.
    @Test func theProjectRows_comeInTheSidebarsOrder() throws {
        let fixture = ProjectWindowsFixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.b.id, fixture.c.id])
        let index = try #require(fixture.session.projects.firstIndex { $0.id == fixture.a.id })
        let first = Worktree(label: "first", workingDirectory: URL(fileURLWithPath: "/tmp/a-first"), origin: .gitWorktree)
        let second = Worktree(label: "second", workingDirectory: URL(fileURLWithPath: "/tmp/a-second"), origin: .gitWorktree)
        fixture.session.projects[index].worktrees = [first, second]
        // The sidebar lists `second` before `first` (the other worktrees
        // come after the working ones).
        let order: [ContainerID] = [
            .worktree(projectID: fixture.a.id, worktreeID: second.id),
            .project(fixture.a.id),
            .worktree(projectID: fixture.a.id, worktreeID: first.id)
        ]
        var facts = SupervisionPaletteFacts(projectID: fixture.a.id, sessionRowCount: 3, hasReviewTab: false)
        facts.rowOrder = order

        let state = CommandPaletteState(locale: Locale(identifier: "en"), windowID: fixture.primary.id)
        state.allItems = try Self.items(fixture.session, supervision: facts)
        state.applyFilter(query: "#", frecencyStore: nil)

        #expect(state.results.map(\.id) == [
            "project.\(fixture.b.id.uuidString)",
            "project.\(fixture.c.id.uuidString)",
            "project.\(fixture.a.id.uuidString)",
            "worktree.\(fixture.a.id.uuidString).\(second.id.uuidString)",
            "worktree.\(fixture.a.id.uuidString).\(first.id.uuidString)"
        ])
    }

    @Test("the window's own actions are offered")
    func catalog_offersTheWindowsOwnActions() throws {
        let (session, project) = WorkspaceSessionFixture.withRepository(name: "weir")
        session.openTab(container: .project(project.id))

        let supervision = try Self.items(
            session,
            supervision: SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        )

        for action in [
            WeirShortcutAction.openFolder,
            .closeWindow,
            .showNeedsAttention,
            .showOpenTabs,
            .focusSidebar,
            .toggleChangesPanel,
            .newWorktree,
            .allProjects,
            .newWindow
        ] {
            #expect(Self.isEnabled(action, in: supervision) == true, "\(action)")
        }
        #expect(Self.isEnabled(.goBack, in: supervision) == session.canNavigateBack(in: session.primaryWindowID))
        #expect(supervision.first { $0.id == "settings.project" }?.action == .openProjectSettings)
        // The detail names whose settings they are.
        #expect(supervision.first { $0.id == "settings.project" }?.subtitle == "weir")
        // Close Project… is the project ▾'s, and names what it closes.
        #expect(supervision.first { $0.id == "project.close" }?.action == .closeProject)
        #expect(supervision.first { $0.id == "project.close" }?.subtitle == "weir")
    }

    @Test("a window that shows no project offers no New Worktree, which would have nowhere to go")
    func catalog_newWorktree_needsAShownProject() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()

        let items = try Self.items(session)

        #expect(Self.isEnabled(.newWorktree, in: items) == false)
        #expect(Self.isEnabled(.newWorktreeNow, in: items) == false)
    }

    @Test("a window choosing a project has no pane strip, so it offers no Open Tabs")
    func catalog_showOpenTabs_needsAPaneStrip() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        let showing = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.showOpenTabs, in: showing) == true)
        facts.isChoosingProject = true
        let choosing = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.showOpenTabs, in: choosing) == false)
    }

    @Test("a row adds a tab running each agent the strip's + offers, on when New Tab is")
    func catalog_newAgentTabs_followNewTab() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let ids = AgentCatalog.entries.map { CommandPaletteAction.newAgentTab($0.kind).frecencyKey }

        let showing = try Self.items(session)
        #expect(Self.isEnabled(.newTab, in: showing) == true)
        for id in ids {
            #expect(showing.first { $0.id == id }?.isEnabled == true, "\(id)")
        }
    }

    /// A window choosing a project opens New Tab on the scratch tabs and
    /// takes them, and an agent row opens its tab the same way, so both
    /// rows are on there.
    @Test func aWindowChoosingAProject_offersTheAgentRows_whichOpenTheirTabThere() throws {
        let session = WorkspaceSession()
        TabActions.newTab(session, in: .loose, running: .codex)
        let oldTab = try #require(session.activeTab(in: session.primaryWindowID))
        let oldPane = try #require(oldTab.splitTree.allLeafIDs().first)
        let oldHint = try #require(oldTab.agentsInFront[oldPane])
        #expect(oldHint.kind == .codex)
        let choosing = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID)
        let window = ProjectWindowState(selection: choosing)
        let facts = SupervisionPaletteFacts(window: window, session: session)
        #expect(facts.isChoosingProject)
        let items = try Self.items(session, supervision: facts, window: choosing.windowID)
        #expect(Self.isEnabled(.newTab, in: items) == true)
        let agent = AgentKind.claude
        let row = try #require(items.first { $0.action == .newAgentTab(agent) })
        #expect(row.isEnabled)

        try CommandPaletteActions.runRowForTest(row.action, session: session, window: choosing.windowID)

        #expect(!choosing.isChoosingProject)
        let opened = try #require(session.drawnTab(in: choosing.windowID))
        #expect(opened.id != oldTab.id)
        #expect(session.tabs.map(\.id) == [oldTab.id, opened.id])
        #expect(opened.container == .loose)
        let paneID = try #require(opened.splitTree.allLeafIDs().first)
        #expect(opened.agentsInFront[paneID]?.kind == agent)
        #expect(session.tab(oldTab.id)?.agentsInFront[oldPane] == oldHint)
    }

    @Test("the agent rows offer the agents found on this Mac, as the strip's + does")
    func catalog_newAgentTabs_offerOnlyTheAgentsFound() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        facts.installedAgents = [.codex]

        let items = try Self.items(session, supervision: facts)

        let offered = items.compactMap { item -> AgentKind? in
            if case let .newAgentTab(agent) = item.action {
                return agent
            }
            return nil
        }
        #expect(offered == [.codex])
    }

    @Test("a row opens Settings on each of its sections")
    func catalog_settingsSections_areOffered() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()

        let items = try Self.items(session)

        for section in SettingsSection.allCases {
            let row = items.first { $0.action == .openSettingsSection(section) }
            #expect(row?.id == "settings.section.\(section.rawValue)")
            #expect(row?.category == .settings)
        }
    }

    @Test("Move Pane to New Tab needs a split tab, and Hide Icon Bars says which way it goes")
    func catalog_windowRows_followTheWindow() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        session.openTab(container: .project(project.id))
        var facts = SupervisionPaletteFacts.empty
        let move = { (items: [CommandPaletteItem]) in items.first { $0.action == .movePaneToNewTab }?.isEnabled }
        let bars = { (items: [CommandPaletteItem]) in items.first { $0.action == .toggleIconBars }?.title }

        let single = try Self.items(session, supervision: facts)
        #expect(move(single) == false)
        #expect(bars(single) == "Hide Icon Bars")

        PaneActions.split(session, direction: .horizontal, in: session.primaryWindowID)
        let split = try Self.items(session, supervision: facts)
        #expect(move(split) == true)
        #expect(bars(split) == "Hide Icon Bars")

        facts.areRailsHidden = true
        let railsHidden = try Self.items(session, supervision: facts)
        #expect(move(railsHidden) == true)
        #expect(bars(railsHidden) == "Show Icon Bars")

        facts.arePanesHidden = true
        let panesHidden = try Self.items(session, supervision: facts)
        #expect(move(panesHidden) == false)
        #expect(bars(panesHidden) == "Show Icon Bars")
    }

    @Test("Plan Usage needs the rail, and Show Worktree Menu needs its button")
    func catalog_controlsWithNoAnchor_areOff() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        let plain = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.planUsage, in: plain) == true)
        #expect(Self.isEnabled(.showWorktreeMenu, in: plain) == false)
        facts.areRailsHidden = true
        let railsHidden = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.planUsage, in: railsHidden) == false)
        #expect(Self.isEnabled(.showWorktreeMenu, in: railsHidden) == false)

        facts.hasWorktreeMenu = true
        let worktreeMenu = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.planUsage, in: worktreeMenu) == false)
        #expect(Self.isEnabled(.showWorktreeMenu, in: worktreeMenu) == true)
    }

    @Test("Show Decision Bar Menu is on only while the focused pane's bar shows its ⋯")
    func catalog_showDecisionBarMenu_needsTheBarsMenu() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        for hasMenu in [false, true] {
            facts.hasDecisionBarMenu = hasMenu
            let rows = try Self.items(session, supervision: facts).filter { $0.id == "shortcut.showDecisionBarMenu" }
            #expect(rows.map(\.action) == [.shortcutAction(.showDecisionBarMenu)])
            #expect(rows.map(\.category) == [.actions])
            #expect(rows.map(\.isEnabled) == [hasMenu])
        }
    }

    /// The toast's Undo is the pointer's alone on screen, so the palette
    /// lists it while the toast offers one, and names that toast.
    @Test func catalog_listsTheToastsUndo_onlyWhileItOffersOne_withItsMessageAndLabel() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let isUndo = { (item: CommandPaletteItem) in
            if case .undoToast = item.action {
                true
            } else {
                false
            }
        }
        var facts = SupervisionPaletteFacts.empty
        #expect(try !Self.items(session, supervision: facts).contains(where: isUndo))

        let toast = ToastItem(.markedViewed(through: 3)) {}
        facts.toastUndo = SupervisionPaletteFacts.ToastUndo(toast)
        let plain = try #require(Self.items(session, supervision: facts).first(where: isUndo))
        #expect(plain.action == .undoToast(toast.id))
        #expect(plain.title == "Undo")
        #expect(plain.subtitle == toast.message.resolved(in: Locale(identifier: "en")))
        #expect(plain.isEnabled)

        let across = ToastItem(.markedViewedInConversations(through: 3, conversation: "main", others: 1)) {}
        facts.toastUndo = SupervisionPaletteFacts.ToastUndo(across)
        let labeled = try #require(Self.items(session, supervision: facts).first(where: isUndo))
        #expect(labeled.title == "Undo in 2 Conversations")

        #expect(SupervisionPaletteFacts.ToastUndo(ToastItem(message: .verbatim("Not enough room"), undo: nil)) == nil)
    }

    @Test("a window with no project, or one whose project is gone, offers no project rows")
    func catalog_projectRows_needTheProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        func items(projectID: UUID?) throws -> [CommandPaletteItem] {
            try Self.items(session, supervision: SupervisionPaletteFacts(projectID: projectID, sessionRowCount: 0, hasReviewTab: false))
        }

        let scratch = try items(projectID: nil)
        #expect(!scratch.contains { $0.id == "settings.project" })
        #expect(!scratch.contains { $0.id == "project.close" })

        let gone = try items(projectID: UUID())
        #expect(!gone.contains { $0.id == "settings.project" })
        #expect(!gone.contains { $0.id == "project.close" })

        #expect(try items(projectID: project.id).contains { $0.id == "project.close" })
    }

    @Test("tab and session navigation follow their own row counts", arguments: [false, true], [1, 2])
    func catalog_theWindowsRows_decideWhetherTheirKeysAreOffered(hasReview: Bool, sessionRowCount: Int) throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let facts = SupervisionPaletteFacts(projectID: nil, sessionRowCount: sessionRowCount, hasReviewTab: hasReview)
        let rows = try Self.items(session, supervision: facts)

        #expect(Self.isEnabled(.nextTab, in: rows) == hasReview)
        #expect(Self.isEnabled(.previousTab, in: rows) == hasReview)
        #expect(Self.isEnabled(.nextSession, in: rows) == (sessionRowCount == 2))
        #expect(Self.isEnabled(.previousSession, in: rows) == (sessionRowCount == 2))
    }

    @Test("a window's actions read that window's tab")
    func catalog_theWindowsActions_readTheWindowsTab() throws {
        let fixture = ProjectWindowsFixture()
        let other = try fixture.window(showing: fixture.b)
        PaneActions.split(fixture.session, direction: .horizontal, in: other.id)
        let primaryTab = try #require(fixture.session.drawnTab(in: fixture.primary.id))
        let otherTab = try #require(fixture.session.drawnTab(in: other.id))
        #expect(primaryTab.id == fixture.aTab.id)
        #expect(primaryTab.splitTree.allLeafIDs().count == 1)
        #expect(otherTab.id == fixture.bTab.id)
        #expect(otherTab.splitTree.allLeafIDs().count == 2)

        #expect(try Self.isEnabled(.equalizeSplits, in: Self.items(fixture.session, window: other.id)) == true)
        #expect(try Self.isEnabled(.equalizeSplits, in: Self.items(fixture.session)) == false)
    }

    @Test("the restore entry names its turn, and is off without one")
    func catalog_restoreEntry_namesItsTurn() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        session.openTab(container: .project(project.id))
        func entry(_ facts: SupervisionPaletteFacts) throws -> CommandPaletteItem? {
            try Self.items(session, supervision: facts, locale: "ja").first { $0.id == "restore.turn" }
        }
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)

        let none = try #require(try entry(facts))
        #expect(!none.isEnabled)
        #expect(none.title == "このターンの前にコードを復元…")
        #expect(none.searchAlias == "Restore Code to Before This Turn…")
        var withTurn = facts
        withTurn.restoreTurnNumber = 5
        let five = try #require(try entry(withTurn))
        #expect(five.isEnabled)
        #expect(five.subtitle == "T5")
        #expect(five.action == .restoreTurn)
        #expect(five.icon == "gobackward")
    }

    @Test("catalog includes all shortcut actions")
    func catalog_includesAllShortcutActions() throws {
        let items = try Self.items(WorkspaceSession())
        // The actions also hold the window's own rows, such as the restore
        // entry, which are no shortcut.
        let shortcutItems = items.filter { $0.id.hasPrefix("shortcut.") }
        #expect(shortcutItems.map(\.id) == WeirShortcutAction.allCases.map { "shortcut.\($0.rawValue)" })
        #expect(shortcutItems.map(\.action) == WeirShortcutAction.allCases.map(CommandPaletteAction.shortcutAction))
        #expect(shortcutItems.allSatisfy { $0.category == .actions })
    }

    @Test("the review entries open from any tab")
    func catalog_reviewEntriesFollowTheActiveTab() throws {
        let empty = try Self.items(WorkspaceSession())
        #expect(empty.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == false)
        #expect(empty.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == false)

        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        // The review tab says why when there is nothing to read,
        // so a tab with no turn still offers both.
        let items = try Self.items(session)
        #expect(items.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == true)
        #expect(items.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == true)
    }

    @Test("catalog includes open tabs with display titles")
    func catalog_includesOpenTabs() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.titleOverride = "build" }
        let tabItems = try Self.items(session).filter {
            if case .jumpToTab = $0.action {
                return true
            }
            return false
        }
        #expect(tabItems.map(\.id) == ["tab.\(tab.id.uuidString)"])
        #expect(tabItems.map(\.category) == [.navigate])
        #expect(tabItems.map(\.title) == ["build"])
        #expect(tabItems.map(\.action) == [.jumpToTab(tab.id)])
    }

    @Test("catalog includes projects")
    func catalog_includesProjects() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let projectItems = try Self.items(session).filter {
            if case .activateProject = $0.action {
                return true
            }
            return false
        }
        #expect(projectItems.map(\.id) == ["project.\(project.id.uuidString)"])
        #expect(projectItems.map(\.category) == [.navigate])
        #expect(projectItems.map(\.title) == [project.name])
        #expect(projectItems.map(\.action) == [.activateProject(project.id)])
    }

    /// A worktree is found by the name its row has, its conversation's here
    /// rather than its label, and one only Git reported says it is among the
    /// other worktrees, in the palette's language.
    @Test("a worktree is offered by its row's name, and one Git only reported says so")
    func catalog_namesWorktreesAsTheirRows() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let named = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let other = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let tab = session.openTab(
            container: .worktree(projectID: project.id, worktreeID: named.id),
            in: session.primaryWindowID,
            intent: .repair,
            selects: false
        )
        session.update(tab.id) {
            $0.conversationName = ConversationName(
                name: "Add tests",
                provider: .claude,
                paneID: UUID(),
                conversationID: "c",
                startedAt: Date(timeIntervalSince1970: 0)
            )
        }
        func item(_ worktree: Worktree, locale: String) throws -> CommandPaletteItem? {
            try Self.items(session, locale: locale).first { $0.action == .activateWorktree(projectID: project.id, worktreeID: worktree.id) }
        }

        #expect(try item(named, locale: "en")?.title == "Add tests")
        #expect(try item(named, locale: "en")?.subtitle?.contains("Other Worktrees") == false)
        #expect(try item(other, locale: "en")?.title == other.workingDirectory.lastPathComponent)
        #expect(try item(other, locale: "en")?.subtitle?.hasPrefix("Other Worktrees · ") == true)
        #expect(try item(other, locale: "ja")?.subtitle?.hasPrefix("ほかのワークツリー · ") == true)
    }

    /// With the window's sections, the palette says "other" of the rows the
    /// sidebar lists there, and only those: a worktree only Git reported,
    /// which the sidebar keeps among the working rows, is not.
    @Test("a worktree is called other where the sidebar lists it so")
    func catalog_followsTheSidebarsSections_forOtherWorktrees() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let waiting = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let other = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        var facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        facts.rowSections = [.worktree(projectID: project.id, worktreeID: other.id): .other]
        func subtitle(_ worktree: Worktree) throws -> String? {
            try Self.items(session, supervision: facts)
                .first { $0.action == .activateWorktree(projectID: project.id, worktreeID: worktree.id) }?.subtitle
        }

        #expect(try subtitle(waiting)?.contains("Other Worktrees") == false)
        #expect(try subtitle(other)?.hasPrefix("Other Worktrees · ") == true)
    }

    // MARK: - Order

    /// The highlighted row is the one Return runs: `selectedIndex` counts
    /// the rows in the order the dropdown draws them, section by section.
    /// The catalog lists the actions before the tabs, and the dropdown
    /// heads Navigate first, so a list kept in rank order ran New Tab while
    /// the first tab was highlighted.
    @Test("selection follows the rows in display order", arguments: ["", "b", "t", "#", ">"])
    func selection_followsDisplayedRowsAndClampsAtEnds(query: String) throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "bench")
        let tab = session.openTab(container: .project(project.id), title: "build")
        let state = CommandPaletteState(locale: Locale(identifier: "en"), windowID: session.primaryWindowID)
        state.allItems = try Self.items(session)
        #expect(state.allItems.first?.category == .actions)
        state.applyFilter(query: query, frecencyStore: nil)
        try #require(!state.results.isEmpty)

        let drawn = state.sections.flatMap { section in
            section.items.enumerated().map { (index: section.startIndex + $0.offset, row: $0.element.item) }
        }
        #expect(drawn.map(\.index) == Array(state.results.indices))
        #expect(drawn.map(\.row) == state.results.map(\.item))
        #expect(state.sections.map(\.category) == state.sections.map(\.category).sorted())
        #expect(Set(state.sections.map(\.category)).count == state.sections.count)
        if query.isEmpty {
            #expect(drawn.first?.row.title == "build")
            #expect(drawn.first?.row.action == .jumpToTab(tab.id))
        }

        state.moveSelection(up: true)
        #expect(state.selectedIndex == 0)
        for (index, row) in drawn {
            try #require(state.selectedIndex == index)
            #expect(state.results[state.selectedIndex].item.action == row.action)
            state.moveSelection(up: false)
        }
        #expect(state.selectedIndex == drawn.count - 1)
    }

    /// A match far apart scores below zero, and its row still shows the
    /// characters it matched.
    @Test func aMatchFarApart_stillShowsItsCharacters() throws {
        let title = "a" + String(repeating: "x", count: 40) + "b"
        let state = CommandPaletteState(locale: Locale(identifier: "en"), windowID: WindowID())
        state.allItems = [CommandPaletteItem(
            id: "far",
            category: .navigate,
            title: title,
            subtitle: nil,
            icon: "terminal",
            shortcutDisplay: nil,
            action: .insertPrefix(.help)
        )]
        state.applyFilter(query: "ab", frecencyStore: nil)
        let row = try #require(state.results.first)
        #expect(row.score < 0)
        #expect(row.matchedIndices == [0, 41])
    }

    // MARK: - State lifecycle

    @Test("opening the palette records its window and builds a selectable result")
    func state_openBuildsItems_andCloseLetsGo() throws {
        let fixture = ProjectWindowsFixture()
        let window = try fixture.window(showing: fixture.b)
        fixture.session.update(fixture.bTab.id) { $0.titleOverride = "Quasar Build" }
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            CommandPaletteActions.openCommandPalette(
                fixture.session,
                in: window.id,
                settings: SettingsStore(directory: dir),
                frecencyStore: frecency,
                attention: AttentionState(),
                initialQuery: "quasar",
                supervision: .empty
            )
            let state = try #require(fixture.session.commandPaletteState)
            #expect(state.windowID == window.id)
            #expect(state.initialQuery == "quasar")
            state.applyFilter(query: "quasar", frecencyStore: frecency)
            #expect(state.results.map(\.id) == ["tab.\(fixture.bTab.id.uuidString)"])
            #expect(state.results.map(\.item.action) == [.jumpToTab(fixture.bTab.id)])
            #expect(state.selectedIndex == 0)

            CommandPaletteActions.closeCommandPalette(fixture.session)
            #expect(fixture.session.commandPaletteState == nil)
        }
    }
}
