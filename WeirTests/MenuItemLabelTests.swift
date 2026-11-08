// MenuItemLabelTests.swift
// Weir — that each menu item takes its name and symbol from the one definition of its command, as the palette does.

import AppKit
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
        supervision: SupervisionPaletteFacts = .empty,
        locale: Locale = english
    ) throws -> [CommandPaletteItem] {
        try withTempDir { dir in
            CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: dir),
                attention: AttentionState(),
                supervision: supervision,
                window: session.primaryWindowID,
                locale: locale
            )
        }
    }

    // MARK: - Shortcut actions

    @Test("The palette lists each shortcut action once with its menu label", arguments: [
        ("en", "New Tab"),
        ("ja", "新規タブ")
    ])
    func paletteShortcutRows_readTheMenuLabelModel(localeID: String, newTabTitle: String) throws {
        let locale = Locale(identifier: localeID)
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let items = try Self.paletteItems(session, locale: locale)
        for action in WeirShortcutAction.allCases {
            let label = action.menuLabel
            #expect(label.title.key == action.localizedTitle.key, "\(action)")
            #expect(label.symbol == action.iconName, "\(action)")
            let rows = items.filter { $0.action == .shortcutAction(action) }
            #expect(rows.count == 1, "\(action)")
            let row = try #require(rows.first, "\(action)")
            #expect(row.title == label.title.resolved(in: locale), "\(action)")
            #expect(row.icon == label.symbol, "\(action)")
        }
        let newTab = try #require(items.first { $0.action == .shortcutAction(.newTab) })
        #expect(newTab.title == newTabTitle)
        #expect(newTab.icon == "plus")
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
        #expect(WeirShortcutAction.nextSession.menuLabel.symbol == "forward.end")
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
            #expect(zoom.shortcut == StoredShortcut(key: "return", modifiers: [.command, .shift]))

            store.settings.keyboard.unassign(.newTab)
            #expect(newTab.label.title.key == "New Tab")
            #expect(newTab.shortcut == nil)
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

    @Test("The palette has one row per window action with its menu label", arguments: [
        (false, "Hide Icon Bars"),
        (true, "Show Icon Bars")
    ])
    func paletteWindowRows_matchTheMenuItems(areHidden: Bool, barsTitle: String) throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        facts.areRailsHidden = areHidden
        let items = try Self.paletteItems(session, supervision: facts)
        let windowRows = items.filter { $0.action == .movePaneToNewTab || $0.action == .toggleIconBars }
        #expect(windowRows.map(\.id) == ["pane.moveToNewTab", "view.toggleIconBars"])

        let bars = try #require(windowRows.first { $0.action == .toggleIconBars })
        let barsLabel = MenuItemLabel.iconBars(areHidden: areHidden)
        #expect(bars.title == barsTitle)
        #expect(bars.icon == "sidebar.left")
        #expect(bars.title == barsLabel.title.resolved(in: Self.english))
        #expect(bars.icon == barsLabel.symbol)
        #expect(bars.isEnabled)

        let move = try #require(windowRows.first { $0.action == .movePaneToNewTab })
        #expect(move.title == "Move Pane to New Tab")
        #expect(move.icon == "rectangle.portrait.and.arrow.forward")
        #expect(move.title == MenuItemLabel.movePaneToNewTab.title.resolved(in: Self.english))
        #expect(move.icon == MenuItemLabel.movePaneToNewTab.symbol)
    }

    @Test func paletteMovePane_requiresAnotherVisiblePane() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let single = try #require(Self.paletteItems(session).first { $0.action == .movePaneToNewTab })
        #expect(!single.isEnabled)

        PaneActions.split(session, direction: .horizontal)
        let split = try #require(session.tab(tab.id))
        try #require(split.splitTree.allLeafIDs().count == 2)
        let visible = try #require(Self.paletteItems(session).first { $0.action == .movePaneToNewTab })
        #expect(visible.isEnabled)

        var facts = SupervisionPaletteFacts.empty
        facts.arePanesHidden = true
        let hidden = try #require(Self.paletteItems(session, supervision: facts).first { $0.action == .movePaneToNewTab })
        #expect(!hidden.isEnabled)
    }

    // MARK: - Move Pane to New Tab

    @Test("The terminal menu draws moving a pane differently from splitting it")
    func terminalContextMenu_drawsTheCommandSymbols() throws {
        let menu = SurfaceContextMenu.make(SurfaceContextMenuState(
            hasSelection: false,
            isInPane: true,
            canRenamePane: false,
            zoomAction: .zoom,
            canMoveToNewTab: true,
            shortcut: { _ in nil }
        ), locale: Self.english)
        let expected: [(Selector, String)] = [
            (#selector(SurfaceView.splitRight(_:)), "rectangle.split.2x1"),
            (#selector(SurfaceView.splitDown(_:)), "rectangle.split.1x2"),
            (#selector(SurfaceView.movePaneToNewTab(_:)), "rectangle.portrait.and.arrow.forward")
        ]
        for (action, symbol) in expected {
            let item = try #require(menu.items.first { $0.action == action })
            let actual = try #require(item.image?.tiffRepresentation)
            let expectedImage = try #require(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
            #expect(actual == expectedImage.tiffRepresentation, "\(item.title): \(symbol)")
        }
    }

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

    @Test("The project palette rows match the project menu and name the project")
    func paletteProjectRows_followTheProjectItems() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 0, hasReviewTab: false)
        let items = try Self.paletteItems(session, supervision: facts)
        let menuItems = ProjectMenuModel.projectItems(for: project.id, in: session.projects)
        #expect(menuItems == [.settings, .revealInFinder, .close])

        let projectRows = items.filter { $0.action == .openProjectSettings || $0.action == .closeProject }
        #expect(projectRows.map(\.id) == ["settings.project", "project.close"])
        #expect(projectRows.map(\.subtitle) == ["weir", "weir"])

        let settings = try #require(projectRows.first { $0.action == .openProjectSettings })
        let settingsLabel = ProjectMenuModel.ProjectItem.settings.label
        #expect(settingsLabel.title.key == "Project Settings…")
        #expect(settingsLabel.symbol == "gearshape")
        #expect(settings.title == settingsLabel.title.resolved(in: Self.english))
        #expect(settings.icon == settingsLabel.symbol)

        let close = try #require(projectRows.first { $0.action == .closeProject })
        let closeLabel = ProjectMenuModel.ProjectItem.close.label
        #expect(closeLabel.title.key == "Close Project…")
        #expect(closeLabel.symbol == "xmark")
        #expect(close.title == closeLabel.title.resolved(in: Self.english))
        #expect(close.icon == closeLabel.symbol)

        #expect(ProjectMenuModel.ProjectItem.revealInFinder.label.title.key == "Show in Finder")
        #expect(!items.contains { $0.title == "Show in Finder" })
    }

    @Test("The project menu and palette omit project actions without a current project", arguments: [false, true])
    func paletteProjectRows_requireAnExistingProject(hasStaleID: Bool) throws {
        let (session, _) = WorkspaceSessionFixture.withProject(name: "weir")
        let facts = SupervisionPaletteFacts(projectID: hasStaleID ? UUID() : nil, sessionRowCount: 0, hasReviewTab: false)
        #expect(ProjectMenuModel.projectItems(for: facts.projectID, in: session.projects).isEmpty)
        let items = try Self.paletteItems(session, supervision: facts)
        #expect(!items.contains { $0.action == .openProjectSettings || $0.action == .closeProject })
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
            .togglePaneZoom: ("Toggle Split Zoom", "arrow.up.left.and.arrow.down.right"),
            .closePane: ("Close Pane", "xmark.square"),
            .close: ("Close", "xmark"),
            .renameTab: ("Rename…", "pencil"),
            .closeTab: ("Close Tab", "xmark"),
            .newWorktree: ("New Worktree…", "arrow.triangle.branch"),
            .keyboardShortcuts: ("Keyboard Shortcuts", "keyboard"),
            .reviewChanges: ("Review Unviewed", nil)
        ]
        #expect(Set(expected.keys) == Set(MenuCommand.allCases))
        for command in MenuCommand.allCases {
            #expect(command.title.key == expected[command]?.title, "\(command)")
            #expect(command.icon == expected[command]?.icon, "\(command)")
        }

        #expect(MenuCommand.closeTab.title.key == WeirShortcutAction.closeTab.localizedTitle.key)
        #expect(MenuCommand.closeTab.shortcutSource == .action(.closeTab))
        #expect(MenuCommand.close.title.key == WeirShortcutAction.closeSurface.localizedTitle.key)
        #expect(MenuCommand.close.shortcutSource == .action(.closeSurface))
    }

    // MARK: - Hints and keys

    @Test func emptyAreaHint_namesTheActionAndShowsItsEffectiveKey() {
        var keyboard = KeyboardSettings()
        let defaultHint = EmptySessionHints.Hint(.reopenClosedTab, keyboard: keyboard, isEnabled: true) {}
        #expect(defaultHint.title.key == "Reopen Closed Tab")
        #expect(defaultHint.title.key == WeirShortcutAction.reopenClosedTab.localizedTitle.key)
        #expect(defaultHint.keys == "⇧⌘T")
        #expect(defaultHint.isEnabled)

        keyboard.setOverride(StoredShortcut(key: "e", modifiers: [.control, .option]), for: .reopenClosedTab)
        let rebound = EmptySessionHints.Hint(.reopenClosedTab, keyboard: keyboard, isEnabled: true) {}
        #expect(rebound.title.key == "Reopen Closed Tab")
        #expect(rebound.keys == "⌃⌥E")

        keyboard.unassign(.reopenClosedTab)
        let unbound = EmptySessionHints.Hint(.reopenClosedTab, keyboard: keyboard, isEnabled: false) {}
        #expect(unbound.title.key == "Reopen Closed Tab")
        #expect(unbound.keys == nil)
        #expect(!unbound.isEnabled)
    }

    @Test func primaryActionKey_isWrittenAndReservedFromOnePlace() {
        #expect(StoredShortcut.primaryAction.displayString == "⌘⏎")
        #expect(ReservedShortcuts.triggers.contains(StoredShortcut.primaryAction.ghosttyTrigger))
    }
}
