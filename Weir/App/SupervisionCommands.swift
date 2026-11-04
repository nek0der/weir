// SupervisionCommands.swift
// Weir — the supervision window's own menu items: new window, open folder, close window, and the rest.

import SwiftUI

/// The menu items the supervision window adds. Each runs in the window that
/// has the keyboard; the items that act on a window are off while another
/// one (Settings, a sheet's own window) has it, rather than reaching a
/// window behind it (`WindowRegistry.commandTarget`).
struct SupervisionCommands: Commands {
    let state: AppState

    /// The key main window; `nil` while none is.
    private var window: ProjectWindowState? {
        state.windowRegistry.commandTarget
    }

    /// Whether the window's project offers its own items, as the project
    /// ▾ and the palette decide it (`ProjectMenuModel.projectItems`).
    private var hasProjectItems: Bool {
        guard let window else { return false }
        return !ProjectMenuModel.projectItems(for: window.selection.shownProjectID, in: state.session.projects).isEmpty
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            MainWindowCommandItems(state.quickTerminal) {
                // With no main window key too: with every window closed,
                // it still opens a new one.
                ShortcutMenuButton(.newWindow, in: state.settingsStore) {
                    SupervisionWindowActions.newWindow(from: window, session: state.session, registry: state.windowRegistry)
                }
                // Opens a project rather than acting in a window's contents,
                // so it stays live with Settings in front, from the window
                // the person was last in (as New Window does).
                ShortcutMenuButton(.openFolder, in: state.settingsStore) {
                    SupervisionWindowActions.openFolder(
                        from: window ?? state.windowRegistry.backgroundCommandTarget,
                        session: state.session,
                        registry: state.windowRegistry,
                        frecency: state.frecencyStore
                    )
                }
                // The project ▾'s and the palette's own, for whoever
                // looks in the menu first: the same commands, so the
                // sheet and the confirmation are the ones those open.
                Divider()
                Button {
                    guard let window else { return }
                    window.commands.send(.openProjectSettings(nil))
                } label: {
                    Label(ProjectMenuModel.ProjectItem.settings.label)
                }
                .disabled(!hasProjectItems)
                Button {
                    guard let window else { return }
                    window.commands.send(.closeProject(nil))
                } label: {
                    Label(ProjectMenuModel.ProjectItem.close.label)
                }
                .disabled(!hasProjectItems)
                Divider()
                ShortcutMenuButton(.closeWindow, in: state.settingsStore) {
                    guard let window else { return }
                    SupervisionWindowActions.closeWindow(window, registry: state.windowRegistry, session: state.session)
                }
                .disabled(window == nil)
            }
        }
        CommandGroup(after: .sidebar) {
            MainWindowCommandItems(state.quickTerminal) {
                ShortcutMenuButton(
                    .toggleChangesPanel,
                    label: .changesPanel(isShown: window?.selection.showsChangesPanel == true),
                    in: state.settingsStore
                ) {
                    guard let window else { return }
                    ChangesPanelActions.toggle(window, session: state.session)
                }
                // A window that shows nothing has no panel to show.
                .disabled(window == nil || window?.selection.isChoosingProject == true)
                ShortcutMenuButton(.allProjects, in: state.settingsStore) {
                    guard let window else { return }
                    window.commands.send(.toggleAllProjects)
                }
                .disabled(window == nil)
                ShortcutMenuButton(.showScratch, in: state.settingsStore) {
                    window?.commands.send(.showScratch)
                }
                .disabled(window == nil)
                ShortcutMenuButton(.planUsage, in: state.settingsStore) {
                    window?.commands.send(.togglePlanUsage)
                }
                .disabled(window == nil || window?.areRailsHidden == true)
                Button {
                    if let window {
                        SupervisionWindowActions.toggleIconBars(in: window)
                    }
                } label: {
                    Label(MenuItemLabel.iconBars(areHidden: window?.areRailsHidden == true))
                }
                .disabled(window == nil)
            }
        }
        CommandGroup(after: .windowList) {
            MainWindowCommandItems(state.quickTerminal) {
                Divider()
                ShortcutMenuButton(.showNeedsAttention, in: state.settingsStore) {
                    guard let window else { return }
                    SupervisionWindowActions.showNeedsAttention(in: window)
                }
                .disabled(window == nil)
                ShortcutMenuButton(.showOpenTabs, in: state.settingsStore) {
                    guard let window else { return }
                    SupervisionWindowActions.showOpenTabs(in: window)
                }
                .disabled(window == nil || window?.selection.isChoosingProject == true)
                ShortcutMenuButton(.showProjectMenu, in: state.settingsStore) {
                    window?.commands.send(.showProjectMenu)
                }
                .disabled(window == nil)
                ShortcutMenuButton(.showWorktreeMenu, in: state.settingsStore) {
                    window?.commands.send(.showWorktreeMenu)
                }
                .disabled(!hasWorktreeMenu(window))
                // On whenever there is a window: whether the focused pane's
                // bar shows a ⋯ is not something the menu can watch, and
                // the key does nothing where there is none.
                ShortcutMenuButton(.showDecisionBarMenu, in: state.settingsStore) {
                    window?.commands.send(.showDecisionBarMenu)
                }
                .disabled(window == nil)
                ShortcutMenuButton(.focusSidebar, in: state.settingsStore) {
                    guard let window else { return }
                    SupervisionWindowActions.focusSidebar(in: state.session, window: window)
                }
                .disabled(window == nil)
                // Each window walks its own history.
                ShortcutMenuButton(.goBack, in: state.settingsStore) {
                    guard let window else { return }
                    SupervisionWindowActions.goBack(in: window, session: state.session)
                }
                .disabled(window.map { !state.session.canNavigateBack(in: $0.id) } ?? true)
                ShortcutMenuButton(.goForward, in: state.settingsStore) {
                    guard let window else { return }
                    SupervisionWindowActions.goForward(in: window, session: state.session)
                }
                .disabled(window.map { !state.session.canNavigateForward(in: $0.id) } ?? true)
            }
        }
    }

    /// Whether `window`'s title bar shows the worktree ▾ its item opens.
    private func hasWorktreeMenu(_ window: ProjectWindowState?) -> Bool {
        window?.selection.shownProjectID.flatMap { state.session.project($0) }.map(CheckoutName.hasWorktreeMenu) ?? false
    }
}
