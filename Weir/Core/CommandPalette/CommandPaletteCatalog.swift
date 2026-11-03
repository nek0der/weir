// CommandPaletteCatalog.swift
// Weir — builds the palette item list from live `WorkspaceSession` and `SettingsStore`.

import Foundation
import WeirDomain

@MainActor
enum CommandPaletteCatalog {

    /// Lightweight context bundle for `isActionEnabled` — keeps the
    /// per-action dispatch fed by one value instead of six loose flags.
    private struct ActionEnabledContext {
        let hasActiveTab: Bool
        /// ⇧⌘[ ⇧⌘] have a tab to step to: another terminal tab, or the
        /// window's review tab.
        let canCycleTab: Bool
        /// ⌘[ ⌘] have somewhere to go: another session row.
        let canCycleSession: Bool
        let isSplit: Bool
        let reachable: (SpatialDirection) -> Bool
        let isProjectActive: Bool
        /// The window shows a project (not its project chooser): the one
        /// Move Project Up and Down move.
        let hasShownProject: Bool
        let hasClosedTabs: Bool
        /// Find has a search to open: the active tab's, or the review's
        /// while it is in front, though the window may have no tab left.
        let canFind: Bool
        let hasActiveSearch: Bool
        let hasWaitingAttention: Bool
        let canReview: Bool
        let canGoBack: Bool
        let canGoForward: Bool
        /// The window shows a session, whose strip Open Tabs hangs from.
        let hasPaneStrip: Bool
        /// The rail shows the button Plan Usage hangs from.
        let hasRails: Bool
        /// The title bar shows the worktree ▾.
        let hasWorktreeMenu: Bool
        /// The focused pane's decision bar shows its ⋯.
        let hasDecisionBarMenu: Bool
    }

    private struct ShortcutDependencies {
        let settings: SettingsStore
        let attention: AttentionState
        let registry: (any PaneSurfaceProviding)?
        let supervision: SupervisionPaletteFacts
        /// The window the palette opened in, whose tab the actions act on.
        let window: WindowID
        let locale: Locale
    }

    /// Item titles are `String`s, because fuzzy matching and its highlight
    /// work on characters, so they are resolved here in `locale`: the app
    /// locale, which the palette's window is drawn in. The list is rebuilt
    /// every time the palette opens, so a language switch shows up on the
    /// next open.
    static func buildItems( // swiftlint:disable:this function_parameter_count
        session: WorkspaceSession,
        settings: SettingsStore,
        attention: AttentionState,
        registry: (any PaneSurfaceProviding)? = nil,
        // The window it opens in, as far as its rows' enabled states need it.
        supervision: SupervisionPaletteFacts,
        window: WindowID,
        locale: Locale
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        items.reserveCapacity(80)
        appendShortcutActions(
            to: &items,
            session: session,
            dependencies: ShortcutDependencies(
                settings: settings,
                attention: attention,
                registry: registry,
                supervision: supervision,
                window: window,
                locale: locale
            )
        )
        appendNewAgentTabs(to: &items, session: session, window: window, supervision: supervision, locale: locale)
        appendWindowRows(to: &items, session: session, window: window, supervision: supervision, locale: locale)
        appendTabs(to: &items, session: session)
        appendProjects(to: &items, session: session, window: window, supervision: supervision, locale: locale)
        appendClosedTabs(to: &items, session: session)
        appendRecentProjects(to: &items, session: session)
        appendRestore(to: &items, facts: supervision, locale: locale)
        appendToastUndo(to: &items, facts: supervision, locale: locale)
        appendSettings(to: &items, locale: locale)
        appendSettingsSections(to: &items, locale: locale)
        // A project ID the window still holds after its project went is no
        // project to set up or close, like the project ▾'s items.
        if let projectID = supervision.projectID, let project = session.project(projectID) {
            appendProjectSettings(to: &items, projectName: project.name, locale: locale)
            appendCloseProject(to: &items, projectName: project.name, locale: locale)
        }
        return items
    }

    // MARK: - Shortcut actions

    private static func appendShortcutActions(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession,
        dependencies: ShortcutDependencies
    ) {
        let window = dependencies.window
        let activeTab = session.activeTab(in: window)
        let hasActiveTab = activeTab != nil
        let supervision = dependencies.supervision
        // A window the session does not know has no tabs, and nothing to
        // act on.
        let selection = session.selection(window)
        let tabCount = selection.map { session.tabs(in: $0.activeContainerID).count } ?? 0
        // As the menu decides (`PaneCommands`, `NavigationCommands`): the
        // window's review tab is one of the tabs stepped through, and ⌘[ ⌘]
        // walk its session rows.
        let canCycleTab = SupervisionPaletteFacts.canCycleTab(tabCount: tabCount, facts: supervision)
        let canCycleSession = supervision.sessionRowCount > 1
        let isSplit = activeTab?.splitTree.isSplit == true
        // Per-direction reachability — same source of truth the Pane menu
        // uses, so a Focus/Move action grays out in exactly the directions
        // it can't reach (also covers zoom + single-pane via `adjacentLeaf`).
        let reachable: (SpatialDirection) -> Bool = {
            PaneActions.adjacentLeaf(session, registry: dependencies.registry, direction: $0, in: window) != nil
        }
        // The window's project, kept while a scratch tab is selected, so the
        // palette offers what the title bar does.
        let isProjectActive = (supervision.projectID ?? selection?.activeContainerID.projectID) != nil
        let hasClosedTabs = !session.closedTabStack.isEmpty
        let focusedPaneID = activeTab?.splitTree.effectiveFocusedLeafID
        // As the menu decides (`SettingsAwareFindCommands`): while the review
        // is in front, Find, Find Next, and Find Previous go to its own search.
        let hasActiveSearch = supervision.arePanesHidden
            || focusedPaneID.map { session.paneSearchStates[$0] != nil } ?? false
        let hasWaitingAttention = dependencies.attention.hasAttentionItems()

        let context = ActionEnabledContext(
            hasActiveTab: hasActiveTab,
            canCycleTab: canCycleTab,
            canCycleSession: canCycleSession,
            isSplit: isSplit,
            reachable: reachable,
            isProjectActive: isProjectActive,
            hasShownProject: supervision.projectID != nil,
            hasClosedTabs: hasClosedTabs,
            canFind: hasActiveTab || supervision.arePanesHidden,
            hasActiveSearch: hasActiveSearch,
            hasWaitingAttention: hasWaitingAttention,
            // The review tab opens from any tab, and says why when there is
            // nothing to read.
            canReview: hasActiveTab,
            canGoBack: session.canNavigateBack(in: window),
            canGoForward: session.canNavigateForward(in: window),
            hasPaneStrip: !supervision.isChoosingProject,
            hasRails: !supervision.areRailsHidden,
            hasWorktreeMenu: supervision.hasWorktreeMenu,
            hasDecisionBarMenu: supervision.hasDecisionBarMenu
        )

        for action in WeirShortcutAction.allCases {
            let shortcut = dependencies.settings.settings.keyboard.shortcut(for: action)
            // A pane command is off while the review hides the panes.
            let enabled = isActionEnabled(action, context: context)
                && !SupervisionPaletteFacts.isOffPaneCommand(action, arePanesHidden: supervision.arePanesHidden)
            items.append(row(
                action.localizedTitle,
                icon: action.iconName,
                shortcutDisplay: shortcut?.displayString,
                action: .shortcutAction(action),
                isEnabled: enabled,
                locale: dependencies.locale
            ))
        }
    }

    // MARK: - New agent tabs

    /// One row per agent the pane strip's "+" offers, in the catalog's
    /// order: the agents found on this Mac (`InstalledAgentRule`), so an
    /// agent the "+" lists has its row and one it leaves out has none. Off
    /// where "+" is: no session in the window, or its folder gone.
    private static func appendNewAgentTabs(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession,
        window: WindowID,
        supervision: SupervisionPaletteFacts,
        locale: Locale
    ) {
        let container = session.selection(window)?.activeContainerID
        let isEnabled = !supervision.isChoosingProject && container.map { !session.isFolderMissing($0) } ?? false
        let agents = InstalledAgentRule.shown(catalog: AgentCatalog.entries.map(\.kind), installed: supervision.installedAgents)
        for agent in agents {
            items.append(row(
                "New \(AgentCatalog.entry(for: agent).displayName) Tab",
                icon: "plus",
                action: .newAgentTab(agent),
                isEnabled: isEnabled,
                locale: locale
            ))
        }
    }

    // MARK: - Window rows

    /// Rows for what the window's controls do with no keyboard shortcut of
    /// their own: Move Pane to New Tab, from the pane's ⋯ and its context
    /// menu, and View ▸ Hide Icon Bars.
    private static func appendWindowRows(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession,
        window: WindowID,
        supervision: SupervisionPaletteFacts,
        locale: Locale
    ) {
        // A pane alone in its tab has nowhere to move from, and a pane
        // command is off while the review hides the panes.
        let canMovePane = session.activeTab(in: window)?.splitTree.isSplit == true && !supervision.arePanesHidden
        items.append(row(
            "Move Pane to New Tab",
            icon: "rectangle.split.2x1",
            action: .movePaneToNewTab,
            isEnabled: canMovePane,
            locale: locale
        ))
        items.append(row(
            supervision.areRailsHidden ? "Show Icon Bars" : "Hide Icon Bars",
            icon: "rectangle.lefthalf.inset.filled",
            action: .toggleIconBars,
            locale: locale
        ))
    }

    /// A row titled `title` in `locale`, found by its English title too, and
    /// named by its action's key (`CommandPaletteAction.frecencyKey`), which
    /// `commands` and `command` list and run it by.
    private static func row(
        _ title: LocalizedStringResource,
        category: CommandPaletteCategory = .actions,
        subtitle: String? = nil,
        icon: String,
        shortcutDisplay: String? = nil,
        action: CommandPaletteAction,
        isEnabled: Bool = true,
        locale: Locale
    ) -> CommandPaletteItem {
        let localizedTitle = title.resolved(in: locale)
        let englishTitle = title.resolved(in: .english)
        return CommandPaletteItem(
            id: action.frecencyKey,
            category: category,
            title: localizedTitle,
            searchAlias: localizedTitle != englishTitle ? englishTitle : nil,
            subtitle: subtitle,
            icon: icon,
            shortcutDisplay: shortcutDisplay,
            action: action,
            isEnabled: isEnabled
        )
    }

    // MARK: - Tabs

    private static func appendTabs(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession
    ) {
        for tab in session.tabs {
            let subtitle = tab.workingDirectory ?? tab.pwd
            items.append(CommandPaletteItem(
                id: "tab.\(tab.id.uuidString)",
                category: .navigate,
                title: tab.shownTitle,
                subtitle: subtitle.map { PathFormatting.abbreviateHome($0) },
                icon: "macwindow",
                shortcutDisplay: nil,
                action: .jumpToTab(tab.id)
            ))
        }
    }

    // MARK: - Projects + worktrees

    /// Each project, then its worktrees by the names their rows have
    /// (`RowName`), so the palette finds a row by the name the sidebar
    /// shows. A worktree only Git reported, folded among the other
    /// worktrees, says so before its folder. Projects come in the window's
    /// sidebar order, and each one's worktrees as its sidebar lists them
    /// (`SupervisionPaletteFacts.rowOrder`). The list "#" opens on therefore
    /// starts from the order the person keeps, and use re-ranks it from
    /// there.
    private static func appendProjects(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession,
        window: WindowID,
        supervision: SupervisionPaletteFacts,
        locale: Locale
    ) {
        let other = LocalizedStringResource(
            "Other Worktrees",
            comment: "Sidebar fold line: the worktrees Git reports that nobody has opened in Weir"
        ).resolved(in: locale)
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        let projectIDs = session.projects.map(\.id)
        let order = session.selection(window)?.sidebarArrangement.ordered(projectIDs) ?? projectIDs
        let rowSections = supervision.rowSections
        let rank = Dictionary(supervision.rowOrder.enumerated().map { ($1, $0) }) { first, _ in first }
        for project in order.compactMap({ byID[$0] }) {
            items.append(CommandPaletteItem(
                id: "project.\(project.id.uuidString)",
                category: .navigate,
                title: project.name,
                subtitle: PathFormatting.abbreviateHome(project.rootURL.path),
                icon: ContainerSymbol.project,
                shortcutDisplay: nil,
                action: .activateProject(project.id)
            ))

            // A row the order does not name keeps the project's order,
            // after the ones it does.
            let worktrees = project.worktrees.enumerated()
                .filter { !$0.element.isHidden }
                .sorted { lhs, rhs in
                    let left = rank[.worktree(projectID: project.id, worktreeID: lhs.element.id)] ?? Int.max
                    let right = rank[.worktree(projectID: project.id, worktreeID: rhs.element.id)] ?? Int.max
                    return left != right ? left < right : lhs.offset < rhs.offset
                }
                .map(\.element)
            for worktree in worktrees {
                let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
                let folder = PathFormatting.abbreviateHome(worktree.workingDirectory.path)
                // Where the sidebar lists it, an item waiting in it
                // included; without the sidebar's sections, by what the row
                // holds: a tab keeps it among the working ones.
                let isOther = rowSections.isEmpty
                    ? SidebarSectionRule.isUnopened(admission: worktree.admission, hasTabs: !session.tabs(in: row).isEmpty)
                    : rowSections[row] == .other
                items.append(CommandPaletteItem(
                    id: "worktree.\(project.id.uuidString).\(worktree.id.uuidString)",
                    category: .navigate,
                    title: session.rowName(of: row)?.text ?? worktree.label,
                    subtitle: isOther ? "\(other) · \(folder)" : folder,
                    icon: ContainerSymbol.worktree,
                    shortcutDisplay: nil,
                    action: .activateWorktree(
                        projectID: project.id,
                        worktreeID: worktree.id
                    )
                ))
            }
        }
    }

    // MARK: - Closed tabs

    private static func appendClosedTabs(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession
    ) {
        for closed in session.closedTabStack {
            items.append(CommandPaletteItem(
                id: "reopen.\(closed.tab.id.uuidString)",
                category: .reopen,
                title: closed.tab.displayTitle,
                subtitle: nil,
                icon: "arrow.uturn.backward",
                shortcutDisplay: nil,
                action: .reopenClosedTab(closed.tab.id)
            ))
        }
    }

    // MARK: - Recent projects

    private static func appendRecentProjects(
        to items: inout [CommandPaletteItem],
        session: WorkspaceSession
    ) {
        for url in session.recentProjectPaths {
            let alreadyOpen = session.projects.contains { $0.rootURL == url }
            if alreadyOpen {
                continue
            }

            items.append(CommandPaletteItem(
                id: "recent.\(url.path)",
                category: .reopen,
                title: url.lastPathComponent,
                subtitle: PathFormatting.abbreviateHome(url.path),
                icon: "clock",
                shortcutDisplay: nil,
                action: .openRecentProject(url)
            ))
        }
    }

    // MARK: - Settings

    private static func appendSettings(to items: inout [CommandPaletteItem], locale: Locale) {
        items.append(row("Open Settings", category: .settings, icon: "gear", action: .openSettings, locale: locale))
    }

    /// Settings opened on each of its sections, in the sidebar's order, as
    /// the keyboard shortcut list's "Customize…" opens it on Keyboard.
    private static func appendSettingsSections(to items: inout [CommandPaletteItem], locale: Locale) {
        for section in SettingsSection.allCases {
            items.append(row(
                "Settings: \(section.title)",
                category: .settings,
                icon: section.icon,
                action: .openSettingsSection(section),
                locale: locale
            ))
        }
    }

    /// "Restore Code to Before This Turn…", with the turn it goes
    /// back to as its subtitle; off when there is no turn to restore to
    /// (`SupervisionPaletteFacts.restoreTurnNumber`). Whether the restore
    /// can run now, the strip it opens says, as every entry's does.
    private static func appendRestore(to items: inout [CommandPaletteItem], facts: SupervisionPaletteFacts, locale: Locale) {
        items.append(row(
            RestoreGate.entryTitle,
            subtitle: facts.restoreTurnNumber.map { "T\($0)" },
            icon: "arrow.uturn.backward",
            action: .restoreTurn,
            isEnabled: facts.restoreTurnNumber != nil,
            locale: locale
        ))
    }

    /// The window's toast's Undo, with the toast's message as its subtitle,
    /// while the toast offers one: its button is the pointer's alone, as ⇥
    /// stays the terminal's and ⌘Z the pane's. The toast stays while the
    /// palette is open (`ToastHost`).
    private static func appendToastUndo(to items: inout [CommandPaletteItem], facts: SupervisionPaletteFacts, locale: Locale) {
        guard let undo = facts.toastUndo else { return }
        items.append(row(
            undo.label ?? LocalizedStringResource(
                "Undo",
                comment: "Takes back the last move: a toast's, the decision bar's after Mark as Viewed, or a restore's"
            ),
            subtitle: undo.message.resolved(in: locale),
            icon: "arrow.uturn.backward.circle",
            action: .undoToast(undo.id),
            locale: locale
        ))
    }

    /// The window's project settings: the palette's way to them in the
    /// supervision window, where the project ▾ also has them. The detail
    /// names the project, since the palette's other settings are the app's.
    private static func appendProjectSettings(to items: inout [CommandPaletteItem], projectName: String, locale: Locale) {
        items.append(row(
            "Project Settings…",
            category: .settings,
            subtitle: projectName,
            icon: "gearshape",
            action: .openProjectSettings,
            locale: locale
        ))
    }

    /// Close Project…, beside the project ▾'s: it asks first, as
    /// that one does. The detail names the project it closes.
    private static func appendCloseProject(to items: inout [CommandPaletteItem], projectName: String, locale: Locale) {
        items.append(row("Close Project…", subtitle: projectName, icon: "xmark", action: .closeProject, locale: locale))
    }

    // MARK: - Action availability

    // swiftlint:disable:next cyclomatic_complexity
    private static func isActionEnabled(
        _ action: WeirShortcutAction,
        context: ActionEnabledContext
    ) -> Bool {
        switch action {
        // A window that shows no project has nowhere to make one.
        case .newWorktree, .newWorktreeNow: context.isProjectActive
        // The palette moves the window's own project, which it must show.
        case .moveProjectUp, .moveProjectDown: context.hasShownProject
        case .renameTab: context.hasActiveTab
        case .reopenClosedTab: context.hasClosedTabs
        case .closeSurface, .closeTab: context.hasActiveTab
        case .nextTab, .previousTab: context.canCycleTab
        case .nextSession, .previousSession: context.canCycleSession
        case .nextAttention, .previousAttention: context.hasWaitingAttention
        case .find: context.canFind
        case .findNext, .findPrevious: context.hasActiveSearch
        case .nextPrompt, .previousPrompt: context.hasActiveTab
        case .splitRight, .splitDown: context.hasActiveTab
        case .equalizeSplits, .toggleSplitZoom: context.isSplit
        case .focusPaneLeft: context.reachable(.left)
        case .focusPaneRight: context.reachable(.right)
        case .focusPaneUp: context.reachable(.up)
        case .focusPaneDown: context.reachable(.down)
        // Review Latest Turn opens the same tab on the pane's latest turn.
        case .review, .reviewLatestTurn: context.canReview
        case .commandPalette, .quickOpen: false
        case .goBack: context.canGoBack
        case .goForward: context.canGoForward
        case .showOpenTabs: context.hasPaneStrip
        case .planUsage: context.hasRails
        case .showWorktreeMenu: context.hasWorktreeMenu
        case .showDecisionBarMenu: context.hasDecisionBarMenu
        default: true
        }
    }
}
