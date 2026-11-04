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

    /// One window of the table: its session and what it shows.
    private struct WindowCase {
        let name: String
        let session: WorkspaceSession
        let facts: SupervisionPaletteFacts

        init(_ name: String, _ session: WorkspaceSession, _ facts: SupervisionPaletteFacts) {
            self.name = name
            self.session = session
            self.facts = facts
        }
    }

    /// The windows the table walks: each sets a different fact the actions
    /// read, so every case of the answer is met on some row.
    private static func windows() throws -> [WindowCase] {
        var rows: [WindowCase] = []

        let empty = WorkspaceSession()
        rows.append(WindowCase("no tab", empty, SupervisionPaletteFacts(window: window(empty), session: empty)))

        let (split, project) = WorkspaceSessionFixture.withProject(name: "weir")
        split.openTab(container: .project(project.id))
        PaneActions.split(split, direction: .horizontal, in: split.primaryWindowID)
        rows.append(WindowCase("a split tab", split, SupervisionPaletteFacts(window: window(split), session: split)))

        let (reviewed, _) = WorkspaceSessionFixture.withProject(name: "weir")
        let reviewWindow = window(reviewed)
        reviewWindow.review = review()
        rows.append(WindowCase("a review and no tab", reviewed, SupervisionPaletteFacts(window: reviewWindow, session: reviewed)))

        let (gone, goneProject) = WorkspaceSessionFixture.withProject(name: "gone")
        gone.openTab(container: .project(goneProject.id))
        let goneIndex = try #require(gone.projects.firstIndex { $0.id == goneProject.id })
        gone.projects[goneIndex].trouble = .folderMissing
        rows.append(WindowCase("a folder gone", gone, SupervisionPaletteFacts(window: window(gone), session: gone)))

        let fixture = ProjectWindowsFixture()
        var facts = SupervisionPaletteFacts(window: fixture.primary, session: fixture.session)
        facts.isChoosingProject = true
        facts.areRailsHidden = true
        facts.hasDecisionBarMenu = true
        facts.isCreatingWorktreeAtOnce = true
        rows.append(WindowCase("choosing, rails hidden, a worktree in flight", fixture.session, facts))
        return rows
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
            let items = try Self.paletteRows(row.session, facts: row.facts)
            for action in WeirShortcutAction.allCases {
                let item = try #require(items.first { $0.action == .shortcutAction(action) }, "\(action)")
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
        for row in try Self.windows().prefix(4) {
            let window = Self.window(row.session)
            if row.name == "a review and no tab" {
                window.review = Self.review()
            }
            let live = ShortcutAvailability(window: window, session: row.session, registry: nil, attention: AttentionState())
            let read = Self.availability(row.session, facts: SupervisionPaletteFacts(window: window, session: row.session))
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
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, isMissing: true)
        session.setActiveContainer(.worktree(projectID: project.id, worktreeID: worktree.id), in: session.primaryWindowID)
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 2, hasReviewTab: false)
        #expect(!Self.availability(session, facts: facts).isEnabled(.newTab, on: .menu))
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
    @Test func aWorktreeInFlight_turnsCreateWorktreeNowOffOnly() {
        let (session, project) = WorkspaceSessionFixture.withRepository(name: "weir")
        session.setActiveContainer(.project(project.id), in: session.primaryWindowID)
        let window = Self.window(session)
        window.isCreatingWorktreeAtOnce = true
        let availability = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        #expect(availability.facts.isCreatingWorktreeAtOnce())
        #expect(!availability.isEnabled(.newWorktreeNow, on: .palette))
        #expect(availability.isEnabled(.newWorktree, on: .palette))
        window.isCreatingWorktreeAtOnce = false
        let after = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        #expect(after.isEnabled(.newWorktreeNow, on: .palette))
    }

    /// With only the review tab in front, Close and Close Tab are on, in the
    /// palette as in the menu, and ⌘W closes the review.
    @Test func aReviewTabAlone_keepsCloseOn() {
        let (session, _) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = Self.window(session)
        #expect(session.activeTab(in: window.id) == nil)
        let closed = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        #expect(!closed.isEnabled(.closeSurface, on: .palette))
        #expect(!closed.isEnabled(.closeTab, on: .palette))

        window.review = Self.review()
        let open = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        for action: WeirShortcutAction in [.closeSurface, .closeTab] {
            #expect(open.isEnabled(action, on: .palette), "\(action)")
            #expect(open.isEnabled(action, on: .menu), "\(action)")
        }
        let key = CloseKeyCommand.decide(isQuickTerminalKey: false, target: window, canClose: open.isEnabled(.closeSurface, on: .menu))
        #expect(key == .closeReview)
        // Behind a terminal tab there is none to close here.
        window.review?.isShown = false
        let behind = ShortcutAvailability(window: window, session: session, registry: nil, attention: AttentionState())
        #expect(!behind.isEnabled(.closeSurface, on: .palette))
    }

    /// The rule ⌘W and ⌥⌘W share: a terminal tab, or the review in front.
    @Test func closeCommands_areLiveForATabOrAReviewInFront() {
        #expect(ShortcutAvailability.closeCommandsAreLive(hasActiveTab: false, isReviewShown: true))
        #expect(ShortcutAvailability.closeCommandsAreLive(hasActiveTab: true, isReviewShown: false))
        #expect(!ShortcutAvailability.closeCommandsAreLive(hasActiveTab: false, isReviewShown: false))
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
    @Test func theProjectAtEitherEnd_cannotMoveOffIt() {
        let fixture = ProjectWindowsFixture()
        func facts(_ projectID: UUID) -> SupervisionPaletteFacts {
            SupervisionPaletteFacts(projectID: projectID, sessionRowCount: 1, hasReviewTab: false)
        }
        let first = Self.availability(fixture.session, facts: facts(fixture.a.id))
        let last = Self.availability(fixture.session, facts: facts(fixture.c.id))
        #expect(!first.isEnabled(.moveProjectUp, on: .palette))
        #expect(first.isEnabled(.moveProjectDown, on: .palette))
        #expect(last.isEnabled(.moveProjectUp, on: .palette))
        #expect(!last.isEnabled(.moveProjectDown, on: .palette))
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
