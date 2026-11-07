// ShortcutAvailabilityTests.swift
// Weir — that a menu item and its palette row are on together, from the one answer both read.

import Foundation
import Observation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Shortcut availability")
@MainActor
struct ShortcutAvailabilityTests {
    /// The actions whose menu item and palette row answer differently, on
    /// purpose (`ShortcutAvailability.isEnabled(_:on:)`): the menu cannot
    /// watch the decision bar's ⋯, and the palette's own rows would open
    /// what is open already.
    private static let surfaceSplit: Set<WeirShortcutAction> = [.showDecisionBarMenu, .commandPalette, .quickOpen]

    private static func availability(
        _ session: WorkspaceSession,
        facts: SupervisionPaletteFacts,
        window: WindowID? = nil
    ) -> ShortcutAvailability {
        ShortcutAvailability(
            session: session,
            window: window ?? session.primaryWindowID,
            facts: facts,
            registry: nil,
            attention: AttentionState()
        )
    }

    /// The palette's rows for the same window, facts, and attention list.
    private static func paletteRows(
        _ session: WorkspaceSession,
        facts: SupervisionPaletteFacts,
        window: WindowID? = nil
    ) throws -> [CommandPaletteItem] {
        try withTempDir { dir in
            CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: dir),
                attention: AttentionState(),
                supervision: facts,
                window: window ?? session.primaryWindowID,
                locale: Locale(identifier: "en")
            )
        }
    }

    private static func review() -> ReviewTabState {
        ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
    }

    /// A window state over the session's primary selection.
    private static func window(_ session: WorkspaceSession) -> ProjectWindowState {
        ProjectWindowState(selection: session.primarySelection)
    }

    @MainActor
    private struct WindowCase {
        let name: String
        let session: WorkspaceSession
        let window: ProjectWindowState

        init(_ name: String, _ session: WorkspaceSession, _ window: ProjectWindowState) {
            self.name = name
            self.session = session
            self.window = window
        }

        var facts: SupervisionPaletteFacts {
            SupervisionPaletteFacts(window: window, session: session)
        }
    }

    /// Real window states shared by the catalog and live/snapshot comparisons.
    private static func windows() throws -> [WindowCase] {
        let empty = WorkspaceSession()
        let (split, project) = WorkspaceSessionFixture.withProject(name: "split")
        split.openTab(container: .project(project.id))
        PaneActions.split(split, direction: .horizontal, in: split.primaryWindowID)

        let (reviewed, _) = WorkspaceSessionFixture.withProject(name: "review")
        let reviewWindow = window(reviewed)
        reviewWindow.review = review()

        let (gone, goneProject) = WorkspaceSessionFixture.withProject(name: "gone")
        gone.openTab(container: .project(goneProject.id))
        let goneIndex = try #require(gone.projects.firstIndex { $0.id == goneProject.id })
        gone.projects[goneIndex].trouble = .folderMissing

        let (working, repository) = WorkspaceSessionFixture.withRepository(name: "worktrees")
        working.openTab(container: .project(repository.id))
        let focused = try #require(working.focusedPaneID(in: working.primaryWindowID))
        let busy = window(working)
        busy.areRailsHidden = true
        busy.isCreatingWorktreeAtOnce = true
        busy.decisionBarMenus.set(.init(owner: UUID(), isShown: { true }, open: {}), inPane: focused)

        let choosing = WorkspaceSession()
        choosing.primarySelection.isChoosingProject = true
        return [
            WindowCase("no tab", empty, window(empty)),
            WindowCase("a split tab", split, window(split)),
            WindowCase("a review and no tab", reviewed, reviewWindow),
            WindowCase("a folder gone", gone, window(gone)),
            WindowCase("rails hidden, a bar menu and a worktree in flight", working, busy),
            WindowCase("choosing a project", choosing, window(choosing))
        ]
    }

    // MARK: - One answer

    /// Every palette row is on exactly when the shared answer says, and the
    /// answer's menu surface agrees with its palette surface, except where
    /// they split on purpose. What a menu item adds around the answer (the
    /// quick terminal stepping it aside, Find in Settings, ⌘J from a window
    /// behind) is the item's own and not covered here.
    @Test func thePalettesRows_andTheMenuSurface_giveTheSameAnswer() throws {
        for row in try Self.windows() {
            let availability = Self.availability(row.session, facts: row.facts)
            let items = try Self.paletteRows(row.session, facts: row.facts).filter {
                if case .shortcutAction = $0.action {
                    return true
                }
                return false
            }
            let actions = WeirShortcutAction.allCases
            #expect(items.count == actions.count, "\(row.name)")
            #expect(Set(items.map(\.id)) == Set(actions.map { "shortcut.\($0.rawValue)" }), "\(row.name)")
            for action in actions {
                let item = try #require(items.first { $0.id == "shortcut.\(action.rawValue)" }, "\(action)")
                #expect(item.action == .shortcutAction(action), "\(row.name): \(item.id)")
                let palette = availability.isEnabled(action, on: .palette)
                #expect(item.isEnabled == palette, "\(row.name): \(action)")
                if !Self.surfaceSplit.contains(action) {
                    #expect(availability.isEnabled(action, on: .menu) == palette, "\(row.name): \(action)")
                }
            }
        }
    }

    /// `MenuAvailability` answers off with no key window, and otherwise
    /// the window's menu surface. The items that stay live with no key
    /// window (⌘W, Find in Settings, ⌘J, New Window, Open Folder, Help) do
    /// not ask it for that case, so this says nothing of them.
    @Test func menuAvailability_isOffWithNoWindow_andOtherwiseTheMenuSurface() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        session.openTab(container: .project(project.id))
        let window = Self.window(session)
        let availability = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        let none = MenuAvailability(availability: nil)
        let key = MenuAvailability(availability: availability)
        for action in WeirShortcutAction.allCases {
            #expect(!none.isEnabled(action), "\(action)")
            #expect(key.isEnabled(action) == availability.isEnabled(action, on: .menu), "\(action)")
        }
    }

    /// The facts the menu reads from the window one by one are the ones the
    /// palette reads from it all at once, for every action and surface.
    @Test func theWindowsFactsReadOneByOne_matchThoseReadAtOnce() throws {
        let windows = try Self.windows()
        #expect(windows.contains { $0.facts.isChoosingProject })
        #expect(windows.contains { $0.facts.hasDecisionBarMenu })
        #expect(windows.contains { $0.facts.areRailsHidden })
        #expect(windows.contains { $0.facts.isCreatingWorktreeAtOnce })
        for row in windows {
            let live = ShortcutAvailability(window: row.window, session: row.session, registry: nil, attention: AttentionState())
            let read = Self.availability(row.session, facts: row.facts)
            for action in WeirShortcutAction.allCases {
                for surface in ShortcutSurface.allCases {
                    #expect(live.isEnabled(action, on: surface) == read.isEnabled(action, on: surface), "\(row.name): \(action)")
                }
            }
        }
    }

    /// A menu item observes only what its own answer reads: Command
    /// Palette's does not change when the rails hide or a worktree is being
    /// made, while Plan Usage's, which reads the rails, does.
    @Test func aMenuItem_observesOnlyWhatItsAnswerReads() {
        let (session, project) = WorkspaceSessionFixture.withRepository(name: "weir")
        session.setActiveContainer(.project(project.id), in: session.primaryWindowID)
        let window = Self.window(session)
        let availability = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        func changes(_ action: WeirShortcutAction, when change: () -> Void) -> Bool {
            let hasChanged = Recorded(false)
            withObservationTracking {
                _ = availability.isEnabled(action, on: .menu)
            } onChange: {
                hasChanged.value = true
            }
            change()
            return hasChanged.value
        }

        #expect(!changes(.commandPalette) { window.areRailsHidden.toggle() })
        #expect(!changes(.commandPalette) { window.isCreatingWorktreeAtOnce.toggle() })
        #expect(changes(.planUsage) { window.areRailsHidden.toggle() })
        #expect(changes(.newWorktreeNow) { window.isCreatingWorktreeAtOnce.toggle() })
    }

    // MARK: - The surfaces that split

    /// The menu keeps Show Decision Bar Menu on whenever there is a window;
    /// the palette's row needs the bar's ⋯. The menu opens the palette; the
    /// palette lists itself off.
    @Test func theDocumentedSplit_menuOn_paletteFollowsTheWindow() {
        let session = WorkspaceSession()
        var facts = SupervisionPaletteFacts.empty
        let without = Self.availability(session, facts: facts)
        #expect(without.isEnabled(.showDecisionBarMenu, on: .menu))
        #expect(!without.isEnabled(.showDecisionBarMenu, on: .palette))
        facts.hasDecisionBarMenu = true
        #expect(Self.availability(session, facts: facts).isEnabled(.showDecisionBarMenu, on: .palette))
        for action: WeirShortcutAction in [.commandPalette, .quickOpen] {
            #expect(without.isEnabled(action, on: .menu), "\(action)")
            #expect(!without.isEnabled(action, on: .palette), "\(action)")
        }
    }

    // MARK: - The facts the palette lacked

    /// New Tab, the agent rows, and the pane strip's "+" are off while the
    /// row's folder is gone, as the File menu's New Tab was: the shell would
    /// start somewhere else.
    @Test func aMissingFolder_turnsNewTabOff() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        session.setActiveContainer(.project(project.id), in: session.primaryWindowID)
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        #expect(Self.availability(session, facts: facts).isEnabled(.newTab, on: .palette))

        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].trouble = .folderMissing
        let availability = Self.availability(session, facts: facts)
        for surface in ShortcutSurface.allCases {
            #expect(!availability.isEnabled(.newTab, on: surface), "\(surface)")
        }
        #expect(!ShortcutAvailability.canOpenTab(in: .project(project.id), session: session))
        let agentRows = try Self.paletteRows(session, facts: facts).filter {
            if case .newAgentTab = $0.action {
                return true
            }
            return false
        }
        #expect(!agentRows.isEmpty)
        #expect(agentRows.allSatisfy { !$0.isEnabled })
    }

    /// A worktree whose folder is gone is no place for a tab either.
    @Test func aMissingWorktreeFolder_turnsNewTabOff() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session)
        let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        session.setActiveContainer(container, in: session.primaryWindowID)
        let window = Self.window(session)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let worktreeIndex = try #require(session.projects[index].worktrees.firstIndex { $0.id == worktree.id })

        for missing in [false, true] {
            session.projects[index].worktrees[worktreeIndex].missingSince = missing ? Date(timeIntervalSince1970: 0) : nil
            #expect(session.selection(window.id)?.activeContainerID == container)
            #expect(ShortcutAvailability.canOpenTab(in: container, session: session) == !missing)
            try Self.expect([.newTab], are: !missing, in: window, session: session, "missing: \(missing)")
            let agentRows = try Self.paletteRows(session, facts: SupervisionPaletteFacts(window: window, session: session))
                .filter {
                    if case .newAgentTab = $0.action {
                        return true
                    }
                    return false
                }
            #expect(!agentRows.isEmpty)
            #expect(agentRows.allSatisfy { $0.isEnabled == !missing })
        }
    }

    /// New Worktree… and Create Worktree Now are off for a project whose
    /// folder is gone or where git cannot run, as the File menu's were.
    @Test func aProjectThatCannotMakeWorktrees_turnsNewWorktreeOff() throws {
        let (session, project) = WorkspaceSessionFixture.withRepository(name: "weir")
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        for action: WeirShortcutAction in [.newWorktree, .newWorktreeNow] {
            #expect(Self.availability(session, facts: facts).isEnabled(action, on: .palette), "\(action)")
        }
        for trouble: ProjectTrouble in [.gitUnavailable, .folderMissing] {
            session.projects[index].trouble = trouble
            let availability = Self.availability(session, facts: facts)
            for action: WeirShortcutAction in [.newWorktree, .newWorktreeNow] {
                #expect(!availability.isEnabled(action, on: .palette), "\(trouble): \(action)")
                #expect(!availability.isEnabled(action, on: .menu), "\(trouble): \(action)")
            }
        }
    }

    /// While ⌥⌘N is making a worktree, Create Worktree Now is off, and New
    /// Worktree…, whose sheet asks first, stays on.
    @Test func aWorktreeInFlight_turnsCreateWorktreeNowOffOnly() throws {
        let (session, project) = WorkspaceSessionFixture.withRepository(name: "weir")
        session.setActiveContainer(.project(project.id), in: session.primaryWindowID)
        let window = Self.window(session)
        let live = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        for creating in [false, true, false] {
            window.isCreatingWorktreeAtOnce = creating
            for surface in ShortcutSurface.allCases {
                #expect(live.isEnabled(.newWorktreeNow, on: surface) == !creating)
                #expect(live.isEnabled(.newWorktree, on: surface))
            }
            try Self.expect([.newWorktreeNow], are: !creating, in: window, session: session, "creating: \(creating)")
            try Self.expect([.newWorktree], are: true, in: window, session: session, "creating: \(creating)")
        }
    }

    @Test func closeCommands_areLiveForATabOrAReviewInFront() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = Self.window(session)
        let commands: [WeirShortcutAction] = [.closeSurface, .closeTab]
        #expect(session.activeTab(in: window.id) == nil)
        try Self.expect(commands, are: false, in: window, session: session, "neither tab nor review")

        window.review = Self.review()
        try Self.expect(commands, are: true, in: window, session: session, "review alone in front")
        let live = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        let key = CloseKeyCommand.decide(isQuickTerminalKey: false, target: window, canClose: live.isEnabled(.closeSurface, on: .menu))
        #expect(key == .closeReview)

        window.review?.isShown = false
        try Self.expect(commands, are: false, in: window, session: session, "hidden review without a tab")

        let tab = session.openTab(container: .project(project.id))
        #expect(session.activeTab(in: window.id)?.id == tab.id)
        try Self.expect(commands, are: true, in: window, session: session, "terminal tab with a hidden review")
        window.review?.isShown = true
        try Self.expect(commands, are: true, in: window, session: session, "terminal tab and review in front")
    }

    /// A window choosing a project shows no session, so Show Changes is off
    /// in the palette as in the menu.
    @Test func choosingAProject_turnsToggleChangesOff() {
        let session = WorkspaceSession()
        var facts = SupervisionPaletteFacts.empty
        #expect(Self.availability(session, facts: facts).isEnabled(.toggleChangesPanel, on: .palette))
        facts.isChoosingProject = true
        let choosing = Self.availability(session, facts: facts)
        for surface in ShortcutSurface.allCases {
            #expect(!choosing.isEnabled(.toggleChangesPanel, on: surface), "\(surface)")
        }
    }

    /// The window's first and last projects have no place to move off
    /// their end, in the window's own order.
    @Test func theProjectAtEitherEnd_cannotMoveOffIt() throws {
        let fixture = ProjectWindowsFixture()
        let other = try fixture.window(showing: fixture.c)
        #expect(fixture.session.projects.map(\.id) == [fixture.a.id, fixture.b.id, fixture.c.id])
        #expect(fixture.primary.selection.shownProjectID == fixture.a.id)
        #expect(other.selection.shownProjectID == fixture.c.id)
        fixture.primary.selection.sidebarArrangement.projectOrder = [fixture.b.id, fixture.c.id, fixture.a.id]
        other.selection.sidebarArrangement.projectOrder = [fixture.c.id, fixture.a.id, fixture.b.id]

        try Self.expect([.moveProjectUp], are: true, in: fixture.primary, session: fixture.session, "a is last")
        try Self.expect([.moveProjectDown], are: false, in: fixture.primary, session: fixture.session, "a is last")
        try Self.expect([.moveProjectUp], are: false, in: other, session: fixture.session, "c is first")
        try Self.expect([.moveProjectDown], are: true, in: other, session: fixture.session, "c is first")
    }

    // MARK: - The rules each surface shares

    /// The answer for `actions` in `window` agrees on both surfaces and in
    /// the palette's rows, and is `expected`.
    private static func expect(
        _ actions: [WeirShortcutAction],
        are expected: Bool,
        in window: ProjectWindowState,
        session: WorkspaceSession,
        _ comment: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let availability = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        let facts = SupervisionPaletteFacts(window: window, session: session)
        let rows = try paletteRows(session, facts: facts, window: window.id)
        for action in actions {
            for surface in ShortcutSurface.allCases {
                #expect(
                    availability.isEnabled(action, on: surface) == expected,
                    "\(comment): \(action) \(surface)",
                    sourceLocation: sourceLocation
                )
            }
            let row = rows.first { $0.action == .shortcutAction(action) }
            #expect(row?.isEnabled == expected, "\(comment): \(action) row", sourceLocation: sourceLocation)
        }
    }

    private static let fontSizes: [WeirShortcutAction] = [.increaseFontSize, .decreaseFontSize, .resetFontSize]

    /// The font size commands change the focused pane's terminal: off with
    /// no tab, and off while the review hides the panes, where they would
    /// change a pane nobody sees.
    @Test func theFontSizeCommands_needADrawnPane() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = Self.window(session)
        try Self.expect(Self.fontSizes, are: false, in: window, session: session, "no tab")

        session.openTab(container: .project(project.id))
        try Self.expect(Self.fontSizes, are: true, in: window, session: session, "a tab")

        window.review = Self.review()
        try Self.expect(Self.fontSizes, are: false, in: window, session: session, "the review in front")
        for action in Self.fontSizes {
            #expect(SupervisionPaletteFacts.isOffPaneCommand(action, arePanesHidden: true), "\(action)")
        }
    }

    /// A window that has the scratch tabs selected while another window
    /// draws them shows a notice, not their panes: the commands on the
    /// window's tab are off there, rather than act on the other window's
    /// panes.
    @Test func aWindowWhoseScratchTabsAnotherDraws_offersNoTabCommands() throws {
        let session = WorkspaceSession()
        let tab = session.openTab(container: .loose)
        PaneActions.split(session, direction: .horizontal, in: session.primaryWindowID)
        let other = session.addWindow(showing: nil, layoutFrom: session.primaryWindowID)
        session.setActiveTab(tab.id, in: other.windowID)
        // The primary chose them last, so it draws them.
        session.setActiveTab(tab.id)
        #expect(session.isScratchElsewhere(in: other.windowID))
        #expect(session.activeTab(in: other.windowID)?.id == tab.id)

        let tabCommands: [WeirShortcutAction] = [
            .renameTab, .splitRight, .splitDown, .closeSurface, .closeTab, .find, .review, .reviewLatestTurn,
            .nextPrompt, .previousPrompt, .equalizeSplits, .toggleSplitZoom
        ] + Self.fontSizes
        try Self.expect(tabCommands, are: false, in: ProjectWindowState(selection: other), session: session, "scratch elsewhere")
        try Self.expect(tabCommands, are: true, in: Self.window(session), session: session, "the drawing window")
    }

    /// While the review is in front with every terminal tab closed, Review
    /// closes it and Review Latest Turn reads the review's own agent pane,
    /// so both stay on.
    @Test func aReviewTabAlone_keepsReviewOn() throws {
        let (session, _) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = Self.window(session)
        #expect(session.activeTab(in: window.id) == nil)
        try Self.expect([.review, .reviewLatestTurn], are: false, in: window, session: session, "no tab")

        window.review = Self.review()
        try Self.expect([.review, .reviewLatestTurn], are: true, in: window, session: session, "the review alone")
    }

    /// A folder that is not a Git repository can have no worktree made in
    /// it (`git worktree add` fails there): New Worktree… and Create
    /// Worktree Now are off, as the worktree ▾ and the sidebar header ask.
    @Test func aFolderThatIsNotARepository_turnsNewWorktreeOff() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "folder")
        session.setActiveContainer(.project(project.id), in: session.primaryWindowID)
        let window = Self.window(session)
        #expect(!CheckoutName.isRepository(project))
        #expect(project.canMakeWorktree)
        #expect(!ShortcutAvailability.canMakeWorktree(in: project))
        try Self.expect([.newWorktree, .newWorktreeNow], are: false, in: window, session: session, "a plain folder")

        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].mainBranchName = "main"
        #expect(ShortcutAvailability.canMakeWorktree(in: session.projects[index]))
        try Self.expect([.newWorktree, .newWorktreeNow], are: true, in: window, session: session, "a repository")
    }
}
