// MenuItemLabelTests.swift
// Weir — that each menu item takes its name and symbol from the one definition of its command, as the palette does.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Menu item labels")
@MainActor
struct MenuItemLabelTests {
    private static let english = Locale(identifier: "en")

    /// The rows the palette offers in the session's primary window.
    private static func paletteItems(
        _ session: WorkspaceSession,
        supervision: SupervisionPaletteFacts = .empty
    ) throws -> [CommandPaletteItem] {
        try withTempDir { dir in
            CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: dir),
                attention: AttentionState(),
                supervision: supervision,
                window: session.primaryWindowID,
                locale: english
            )
        }
    }

    // MARK: - Shortcut actions

    @Test("an action's menu label model holds its shortcut list title and icon", arguments: WeirShortcutAction.allCases)
    func menuLabelModel_holdsTheActionsTitleAndIcon(action: WeirShortcutAction) {
        #expect(action.menuLabel.title.key == action.localizedTitle.key)
        #expect(action.menuLabel.symbol == action.iconName)
    }

    /// The palette's shortcut rows and `menuLabel` read the same model
    /// values. The menu's stateful items (Zoom Pane, Show Changes) pass a
    /// label of their own instead, so this does not say the menu and every
    /// row agree word for word.
    @Test("each palette shortcut row reads the action's menu label model")
    func paletteShortcutRows_readTheMenuLabelModel() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let items = try Self.paletteItems(session)
        for action in WeirShortcutAction.allCases {
            let row = try #require(items.first { $0.action == .shortcutAction(action) }, "\(action)")
            #expect(row.title == action.menuLabel.title.resolved(in: Self.english), "\(action)")
            #expect(row.icon == action.menuLabel.symbol, "\(action)")
        }
    }

    /// The menu items that drew a symbol of their own now draw the action's,
    /// which three of them shared with another item.
    @Test func menuIcons_areTheActionsIcons() {
        #expect(WeirShortcutAction.newTab.menuLabel.symbol == "plus")
        #expect(WeirShortcutAction.reopenClosedTab.menuLabel.symbol == "arrow.uturn.backward")
        #expect(WeirShortcutAction.closeSurface.menuLabel.symbol == "xmark.square")
        #expect(WeirShortcutAction.closeTab.menuLabel.symbol == "xmark")
        #expect(WeirShortcutAction.closeTab.menuLabel.symbol != WeirShortcutAction.closeWindow.menuLabel.symbol)
        #expect(WeirShortcutAction.equalizeSplits.menuLabel.symbol == "equal.square")
        #expect(WeirShortcutAction.nextTab.menuLabel.symbol != WeirShortcutAction.focusPaneRight.menuLabel.symbol)
        #expect(WeirShortcutAction.previousTab.menuLabel.symbol != WeirShortcutAction.focusPaneLeft.menuLabel.symbol)
        #expect(WeirShortcutAction.nextSession.menuLabel.symbol == "chevron.left.chevron.right")
        #expect(WeirShortcutAction.quickOpen.menuLabel.symbol != WeirShortcutAction.find.menuLabel.symbol)
    }

    @Test("a menu bar item built for an action shows its name, symbol, and the person's key")
    func shortcutMenuButton_resolvesItsLabelAndKey() throws {
        try withTempDir { dir in
            let store = SettingsStore(directory: dir)
            let rebound = StoredShortcut(key: "f5", modifiers: [.control])
            store.settings.keyboard.setOverride(rebound, for: .newTab)

            let newTab = ShortcutMenuButton(.newTab, in: store) {}
            #expect(newTab.label.title.key == "New Tab")
            #expect(newTab.label.symbol == "plus")
            #expect(newTab.shortcut == rebound)

            // PaneCommands' zoom item while the tab is zoomed.
            let zoom = ShortcutMenuButton(
                .toggleSplitZoom,
                label: PaneHeaderRules.zoomAction(isZoomed: true).menuLabel,
                in: store
            ) {}
            #expect(zoom.label.title.key == "Unzoom Pane")
            #expect(zoom.label.symbol == "arrow.down.right.and.arrow.up.left")
            #expect(zoom.shortcut == WeirShortcutAction.toggleSplitZoom.defaultShortcut)
        }
    }

    // MARK: - Stateful items

    @Test func paneZoom_namesWhatPressingItDoes() {
        #expect(PaneZoomAction.zoom.title.key == "Zoom Pane")
        #expect(PaneZoomAction.zoom.symbol == WeirShortcutAction.toggleSplitZoom.iconName)
        #expect(PaneZoomAction.unzoom.title.key == "Unzoom Pane")
        #expect(PaneZoomAction.unzoom.symbol == "arrow.down.right.and.arrow.up.left")
        for zoom in [PaneZoomAction.zoom, .unzoom] {
            #expect(zoom.menuLabel.title.key == zoom.title.key)
            #expect(zoom.menuLabel.symbol == zoom.symbol)
        }
    }

    @Test func changesPanel_andIconBars_sayWhichWayTheyGo() {
        #expect(MenuItemLabel.changesPanel(isShown: true).title.key == "Hide Changes")
        #expect(MenuItemLabel.changesPanel(isShown: false).title.key == "Show Changes")
        #expect(MenuItemLabel.changesPanel(isShown: false).symbol == WeirShortcutAction.toggleChangesPanel.iconName)
        #expect(MenuItemLabel.iconBars(areHidden: true).title.key == "Show Icon Bars")
        #expect(MenuItemLabel.iconBars(areHidden: false).title.key == "Hide Icon Bars")
    }

    @Test("the palette's Hide Icon Bars and Move Pane to New Tab rows are the menus' items")
    func paletteWindowRows_matchTheMenuItems() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        for areHidden in [false, true] {
            facts.areRailsHidden = areHidden
            let items = try Self.paletteItems(session, supervision: facts)
            let bars = try #require(items.first { $0.action == .toggleIconBars })
            let label = MenuItemLabel.iconBars(areHidden: areHidden)
            #expect(bars.title == label.title.resolved(in: Self.english))
            #expect(bars.icon == label.symbol)
            let move = try #require(items.first { $0.action == .movePaneToNewTab })
            #expect(move.title == MenuItemLabel.movePaneToNewTab.title.resolved(in: Self.english))
            #expect(move.icon == MenuItemLabel.movePaneToNewTab.symbol)
        }
    }

    // MARK: - Move Pane to New Tab

    @Test("a pane moves to a tab of its own only from a tab that holds another, zoomed or not")
    func canMovePaneToNewTab_needsAnotherPane() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let single = try #require(session.tab(tab.id))
        #expect(!single.canMovePaneToNewTab)
        let lone = try #require(single.splitTree.allLeafIDs().first)
        #expect(TabActions.splitPaneOff(session, paneID: lone) == nil)

        PaneActions.split(session, direction: .horizontal)
        let split = try #require(session.tab(tab.id))
        #expect(split.canMovePaneToNewTab)

        let zoomed = try #require(split.splitTree.allLeafIDs().first)
        session.update(tab.id) { $0.zoomedLeafID = zoomed }
        #expect(try #require(session.tab(tab.id)).canMovePaneToNewTab)
        #expect(TabActions.splitPaneOff(session, paneID: zoomed) != nil)
    }

    // MARK: - Project items

    @Test func projectItems_haveOneNameAndSymbolEach() {
        #expect(ProjectMenuModel.ProjectItem.settings.label.title.key == "Project Settings…")
        #expect(ProjectMenuModel.ProjectItem.settings.label.symbol == "gearshape")
        #expect(ProjectMenuModel.ProjectItem.revealInFinder.label.title.key == "Show in Finder")
        #expect(ProjectMenuModel.ProjectItem.close.label.title.key == "Close Project…")
        #expect(ProjectMenuModel.ProjectItem.close.label.symbol == "xmark")
    }

    /// The project's item, the shell command's row, the notice that saving
    /// is suspended, and a reviewed file's path menu all take "Show in
    /// Finder" from the one definition.
    @Test func showInFinder_isReadFromOneDefinitionByEveryMenu() throws {
        let shared = MenuItemLabel.showInFinder
        #expect(shared.title.key == "Show in Finder")
        #expect(shared.symbol == "folder")

        let project = ProjectMenuModel.ProjectItem.revealInFinder.label
        #expect(project.title.key == shared.title.key)
        #expect(project.symbol == shared.symbol)

        #expect(ShellCommandRow.Action.showInFinder.title.key == shared.title.key)

        for identifier in ["en", "ja"] {
            let locale = Locale(identifier: identifier)
            #expect(SavingSuspendedText.showFiles(locale: locale) == shared.title.resolved(in: locale))
        }
        #expect(SavingSuspendedText.showFiles(locale: Locale(identifier: "ja")) == "Finder で表示")

        try withTempDir { root in
            let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
            let items = ReviewFileMenuModel.items(for: file, in: root, application: .macOSDefault) { _ in true }
            let reveal = try #require(items.first { $0.action == .reveal("a.swift", root: root) })
            #expect(reveal.title.key == shared.title.key)
        }
    }

    @Test("the palette offers the project's items where the project ▾ does, named as it names them")
    func paletteProjectRows_followTheProjectItems() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 0, hasReviewTab: false)
        let items = try Self.paletteItems(session, supervision: facts)
        #expect(!ProjectMenuModel.projectItems(for: project.id, in: session.projects).isEmpty)
        let settings = try #require(items.first { $0.action == .openProjectSettings })
        #expect(settings.title == ProjectMenuModel.ProjectItem.settings.label.title.resolved(in: Self.english))
        #expect(settings.icon == ProjectMenuModel.ProjectItem.settings.label.symbol)
        let close = try #require(items.first { $0.action == .closeProject })
        #expect(close.title == ProjectMenuModel.ProjectItem.close.label.title.resolved(in: Self.english))
        #expect(close.icon == ProjectMenuModel.ProjectItem.close.label.symbol)

        let gone = SupervisionPaletteFacts(projectID: UUID(), sessionRowCount: 0, hasReviewTab: false)
        #expect(ProjectMenuModel.projectItems(for: gone.projectID, in: session.projects).isEmpty)
        let none = try Self.paletteItems(session, supervision: gone)
        #expect(!none.contains { $0.action == .openProjectSettings || $0.action == .closeProject })
    }

    // MARK: - Weir's own menus

    @Test("each command of Weir's own menus has one name and symbol")
    func menuCommand_titleAndIcon() {
        let expected: [MenuCommand: (title: String, icon: String?)] = [
            .copy: ("Copy", nil),
            .paste: ("Paste", nil),
            .selectAll: ("Select All", nil),
            .find: ("Find…", nil),
            .splitRight: ("Split Right", "rectangle.split.2x1"),
            .splitDown: ("Split Down", "rectangle.split.1x2"),
            .togglePaneZoom: ("Toggle Split Zoom", WeirShortcutAction.toggleSplitZoom.iconName),
            .closePane: ("Close Pane", "xmark.square"),
            .close: ("Close", "xmark"),
            .renameTab: ("Rename…", "pencil"),
            .closeTab: ("Close Tab", "xmark"),
            .newWorktree: ("New Worktree…", WeirShortcutAction.newWorktree.iconName),
            .keyboardShortcuts: ("Keyboard Shortcuts", "keyboard"),
            .reviewChanges: ("Review Unviewed", nil)
        ]
        #expect(Set(expected.keys) == Set(MenuCommand.allCases))
        for command in MenuCommand.allCases {
            #expect(command.title.key == expected[command]?.title, "\(command)")
            #expect(command.icon == expected[command]?.icon, "\(command)")
        }
    }

    /// A tab's menu names ⌥⌘W as the menu bar does, and the review tab's
    /// names ⌘W as the menu bar does.
    @Test func menuCommand_namesTheKeyItShows() {
        #expect(MenuCommand.closeTab.title.key == WeirShortcutAction.closeTab.localizedTitle.key)
        #expect(MenuCommand.closeTab.shortcutSource == .action(.closeTab))
        #expect(MenuCommand.close.title.key == WeirShortcutAction.closeSurface.localizedTitle.key)
        #expect(MenuCommand.close.shortcutSource == .action(.closeSurface))
    }

    // MARK: - Hints and keys

    @Test func emptyAreaHint_isNamedByItsAction() {
        let keyboard = KeyboardSettings()
        let hint = EmptySessionHints.Hint(.reopenClosedTab, keyboard: keyboard, isEnabled: true) {}
        #expect(hint.title.key == WeirShortcutAction.reopenClosedTab.localizedTitle.key)
        #expect(hint.keys == keyboard.shortcut(for: .reopenClosedTab)?.displayString)
    }

    @Test func primaryActionKey_isWrittenAndReservedFromOnePlace() {
        #expect(StoredShortcut.primaryAction.displayString == "⌘⏎")
        #expect(ReservedShortcuts.triggers.contains(StoredShortcut.primaryAction.ghosttyTrigger))
    }
}
