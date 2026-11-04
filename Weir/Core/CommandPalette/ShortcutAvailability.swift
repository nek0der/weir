// ShortcutAvailability.swift
// Weir — whether each shortcut action can run now in a window, for its menu item, its palette row, and the channel.

import Foundation
import WeirDomain

/// Where an action's enabled state is asked. The two answer alike for every
/// action except the ones `ShortcutAvailability.isEnabled(_:on:)` names.
enum ShortcutSurface: CaseIterable {
    /// The menu bar's item, and the controls that stand for it in the
    /// window (an empty session's hints).
    case menu
    /// The command palette's row, which the automation channel's `command`
    /// and `open` run too.
    case palette
}

/// Whether each `WeirShortcutAction` can run now in one window. The menu
/// bar, the palette, the empty session's hints, and the automation channel
/// all ask this, so an item and its row disagree only where
/// `isEnabled(_:on:)` splits them on purpose. Each case is written out: an
/// action added to the list has to say when it is on.
///
/// It reads what it needs of the session (the window's tab, its history,
/// its closed tabs) and of the window (`ShortcutWindowFacts`) as each action
/// is asked, so a menu item observes only what its own answer reads.
@MainActor
struct ShortcutAvailability {
    let session: WorkspaceSession
    /// The window the actions run in.
    let window: WindowID
    /// What only the window's own state can say, read as an action asks.
    let facts: ShortcutWindowFacts
    /// The window's pane views, which say where a pane has a neighbor on
    /// screen; without them, the split tree's own layout says
    /// (`PaneActions.adjacentLeaf`).
    let registry: (any PaneSurfaceProviding)?
    /// The app's attention list, which ⌘J walks.
    let attention: AttentionState

    init(
        session: WorkspaceSession,
        window: WindowID,
        facts: ShortcutWindowFacts,
        registry: (any PaneSurfaceProviding)?,
        attention: AttentionState
    ) {
        self.session = session
        self.window = window
        self.facts = facts
        self.registry = registry
        self.attention = attention
    }

    /// The answer for the palette, from the facts it read as it opened.
    init(
        session: WorkspaceSession,
        window: WindowID,
        facts: SupervisionPaletteFacts,
        registry: (any PaneSurfaceProviding)?,
        attention: AttentionState
    ) {
        self.init(session: session, window: window, facts: ShortcutWindowFacts(facts), registry: registry, attention: attention)
    }

    // swiftlint:disable:next cyclomatic_complexity
    func isEnabled(_ action: WeirShortcutAction, on surface: ShortcutSurface) -> Bool {
        // A pane command is off while the review hides the panes: it would
        // change panes nobody sees.
        if SupervisionPaletteFacts.isOffPaneCommand(action, arePanesHidden: facts.arePanesHidden()) {
            return false
        }
        switch action {
        // New Tab opens in the window's active row, which needs its folder.
        case .newTab:
            return activeContainer.map { Self.canOpenTab(in: $0, session: session) } ?? false
        case .newWorktree:
            return canMakeWorktree
        // ⌥⌘N makes one at a time.
        case .newWorktreeNow:
            return canMakeWorktree && !facts.isCreatingWorktreeAtOnce()
        // The font size commands change the focused pane's terminal, which
        // only a drawn tab has (`TabActions.dispatchGhosttyAction`).
        case .renameTab, .nextPrompt, .previousPrompt, .splitRight, .splitDown, .increaseFontSize, .decreaseFontSize,
             .resetFontSize:
            return hasActiveTab
        case .reopenClosedTab:
            return !session.closedTabStack.isEmpty
        case .closeSurface, .closeTab:
            return Self.closeCommandsAreLive(hasActiveTab: hasActiveTab, isReviewShown: facts.arePanesHidden())
        case .openFolder, .closeWindow, .newWindow, .toggleSidebar, .notificationHistory, .allProjects, .showScratch,
             .showNeedsAttention, .showProjectMenu, .focusSidebar, .keyboardShortcuts:
            return true
        // The review tab opens from any tab, and says why when there is
        // nothing to read; Review Latest Turn opens the same tab. While the
        // review is in front the window may have no tab left: Review then
        // closes it (`ReviewTabActions.toggle`), and Review Latest Turn
        // reads the review's own agent pane.
        case .review, .reviewLatestTurn:
            return hasActiveTab || facts.arePanesHidden()
        // A window choosing a project shows no session: no Changes panel to
        // show, and no pane strip for Open Tabs to hang from.
        case .toggleChangesPanel, .showOpenTabs:
            return !facts.isChoosingProject()
        // The plan usage panel hangs from its rail button alone.
        case .planUsage:
            return !facts.areRailsHidden()
        case .nextSession, .previousSession:
            return facts.sessionRowCount() > 1
        case .nextTab, .previousTab:
            return SupervisionPaletteFacts.canCycleTab(tabCount: tabCount, hasReviewTab: facts.hasReviewTab())
        case .showWorktreeMenu:
            return facts.hasWorktreeMenu()
        // The menu keeps it on whenever there is a window: whether the
        // focused pane's bar shows a ⋯ is not something the menu can watch,
        // and the key beeps where there is none. The palette is built as it
        // opens, so its row can say.
        case .showDecisionBarMenu:
            return surface == .menu || facts.hasDecisionBarMenu()
        case .moveProjectUp:
            return canMoveProject(by: -1)
        case .moveProjectDown:
            return canMoveProject(by: 1)
        case .goBack:
            return session.canNavigateBack(in: window)
        case .goForward:
            return session.canNavigateForward(in: window)
        case .nextAttention, .previousAttention:
            return attention.hasAttentionItems()
        case .equalizeSplits, .toggleSplitZoom:
            return drawnTab?.splitTree.isSplit == true
        case .focusPaneLeft:
            return isReachable(.left)
        case .focusPaneRight:
            return isReachable(.right)
        case .focusPaneUp:
            return isReachable(.up)
        case .focusPaneDown:
            return isReachable(.down)
        // While the review is in front, Find goes to its own search, though
        // the window may have no tab left.
        case .find:
            return hasActiveTab || facts.arePanesHidden()
        case .findNext, .findPrevious:
            return facts.arePanesHidden() || hasPaneSearch
        // The menu items open the palette; the palette's own rows would
        // only open what is open already.
        case .commandPalette, .quickOpen:
            return surface == .menu
        }
    }

    /// Whether a tab can open in `container`: not while its folder is gone,
    /// where the shell would start somewhere else. New Tab, the pane
    /// strip's "+", and the palette's agent rows ask the same.
    static func canOpenTab(in container: ContainerID, session: WorkspaceSession) -> Bool {
        !session.isFolderMissing(container)
    }

    /// Whether a worktree can be made in `project`: it is a Git repository
    /// (`CheckoutName.isRepository`), since `git worktree add` fails in a
    /// folder that is not one, and its folder is there with git to run
    /// (`Project.canMakeWorktree`). New Worktree… and Create Worktree Now,
    /// the sidebar header's + and "New Worktree in…", and the worktree ▾'s
    /// New Worktree… ask the same.
    static func canMakeWorktree(in project: Project) -> Bool {
        CheckoutName.isRepository(project) && project.canMakeWorktree
    }

    /// Whether ⌘W and ⌥⌘W have something to close in the window: a
    /// terminal tab, or the review tab in front, which they close first
    /// (`ReviewTabActions.closeIfInFront`). A review stays open with every
    /// terminal tab closed, so the tab alone cannot say.
    static func closeCommandsAreLive(hasActiveTab: Bool, isReviewShown: Bool) -> Bool {
        hasActiveTab || isReviewShown
    }

    // MARK: - What the actions read

    /// The row the window shows; `nil` for a window the session does not
    /// know, where nothing runs.
    private var activeContainer: ContainerID? {
        session.selection(window)?.activeContainerID
    }

    /// The tab the window draws (`WorkspaceSession.drawnTab(in:)`): none
    /// while another window draws the scratch tabs this one has selected,
    /// where this one shows a notice in their place. A command on the
    /// window's tab would then act on panes another window shows.
    private var drawnTab: Tab? {
        session.drawnTab(in: window)
    }

    private var hasActiveTab: Bool {
        drawnTab != nil
    }

    /// How many terminal tabs ⇧⌘[ ⇧⌘] step through, with the review tab.
    private var tabCount: Int {
        activeContainer.map { session.tabs(in: $0).count } ?? 0
    }

    /// Whether the project the window shows can have a worktree made in it
    /// (`canMakeWorktree(in:)`).
    private var canMakeWorktree: Bool {
        facts.projectID().flatMap { session.project($0) }.map(Self.canMakeWorktree(in:)) ?? false
    }

    /// Whether the project the window shows has a place to move to in the
    /// window's sidebar order, as the sidebar's Move Up and Move Down decide
    /// (`ProjectOrder.canMove`).
    private func canMoveProject(by offset: Int) -> Bool {
        guard let projectID = facts.projectID(), let selection = session.selection(window) else { return false }
        let order = selection.sidebarArrangement.ordered(session.projects.map(\.id))
        return ProjectOrder.canMove(projectID, by: offset, in: order)
    }

    /// Whether the focused pane has a neighbor that way
    /// (`PaneActions.adjacentLeaf`), which is none while zoomed or with one
    /// pane. It asks only for a tab the window draws, since `adjacentLeaf`
    /// reads the selected one whether drawn here or not.
    private func isReachable(_ direction: SpatialDirection) -> Bool {
        hasActiveTab && PaneActions.adjacentLeaf(session, registry: registry, direction: direction, in: window) != nil
    }

    /// Whether the focused pane has a search open for Find Next and Find
    /// Previous to step through.
    private var hasPaneSearch: Bool {
        drawnTab?.splitTree.effectiveFocusedLeafID.map { session.paneSearchStates[$0] != nil } ?? false
    }
}

/// The window's own state that the actions' answers read, each fact read
/// when an action asks for it. The menu bar reads them from the window as
/// it draws an item (`ShortcutWindowFacts(window:session:sections:)`), so
/// an item observes only the facts its own answer reads; the palette reads
/// them from what it gathered as it opened.
@MainActor
struct ShortcutWindowFacts {
    /// The window's project, kept while a scratch tab is selected.
    let projectID: () -> UUID?
    /// How many session rows ⌘[ ⌘] walk.
    let sessionRowCount: () -> Int
    /// Whether the window's strip shows a review tab.
    let hasReviewTab: () -> Bool
    /// Whether the review tab is in front, standing where the panes were.
    let arePanesHidden: () -> Bool
    /// Whether the window offers the projects to open instead of a session.
    let isChoosingProject: () -> Bool
    /// Whether the rail, and the plan usage button on it, is hidden.
    let areRailsHidden: () -> Bool
    /// Whether the title bar shows the worktree ▾.
    let hasWorktreeMenu: () -> Bool
    /// Whether the focused pane's decision bar shows a ⋯.
    let hasDecisionBarMenu: () -> Bool
    /// Whether ⌥⌘N is making a worktree in the window now.
    let isCreatingWorktreeAtOnce: () -> Bool

    init(
        projectID: @escaping () -> UUID?,
        sessionRowCount: @escaping () -> Int,
        hasReviewTab: @escaping () -> Bool,
        arePanesHidden: @escaping () -> Bool,
        isChoosingProject: @escaping () -> Bool,
        areRailsHidden: @escaping () -> Bool,
        hasWorktreeMenu: @escaping () -> Bool,
        hasDecisionBarMenu: @escaping () -> Bool,
        isCreatingWorktreeAtOnce: @escaping () -> Bool
    ) {
        self.projectID = projectID
        self.sessionRowCount = sessionRowCount
        self.hasReviewTab = hasReviewTab
        self.arePanesHidden = arePanesHidden
        self.isChoosingProject = isChoosingProject
        self.areRailsHidden = areRailsHidden
        self.hasWorktreeMenu = hasWorktreeMenu
        self.hasDecisionBarMenu = hasDecisionBarMenu
        self.isCreatingWorktreeAtOnce = isCreatingWorktreeAtOnce
    }

    /// The facts the palette gathered as it opened.
    init(_ facts: SupervisionPaletteFacts) {
        self.init(
            projectID: { facts.projectID },
            sessionRowCount: { facts.sessionRowCount },
            hasReviewTab: { facts.hasReviewTab },
            arePanesHidden: { facts.arePanesHidden },
            isChoosingProject: { facts.isChoosingProject },
            areRailsHidden: { facts.areRailsHidden },
            hasWorktreeMenu: { facts.hasWorktreeMenu },
            hasDecisionBarMenu: { facts.hasDecisionBarMenu },
            isCreatingWorktreeAtOnce: { facts.isCreatingWorktreeAtOnce }
        )
    }
}
