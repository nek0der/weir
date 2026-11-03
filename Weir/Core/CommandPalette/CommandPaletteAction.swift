// CommandPaletteAction.swift
// Weir — actions the command palette can dispatch.

import Foundation
import WeirDomain

enum CommandPaletteAction: Equatable {
    case shortcutAction(WeirShortcutAction)
    case jumpToTab(UUID)
    case activateProject(UUID)
    case activateWorktree(projectID: UUID, worktreeID: UUID)
    case reopenClosedTab(UUID)
    case openRecentProject(URL)
    case openSettings
    /// The settings of the window's project.
    case openProjectSettings
    /// Close the window's project, after the confirmation.
    case closeProject
    /// "Restore Code to Before This Turn…": the restore strip in
    /// the decision bar of the turn's pane, with the keyboard on it.
    case restoreTurn
    /// A tab running `agent` in the window's session, in the session's
    /// folder, as the pane strip's "+" adds one (`AddTabMenu`).
    case newAgentTab(AgentKind)
    /// Settings, opened on `section`.
    case openSettingsSection(SettingsSection)
    /// The focused pane of the window's tab moved to a tab of its own, as
    /// the pane's ⋯ and its context menu move it.
    case movePaneToNewTab
    /// The window's icon bars hidden, or shown again (View ▸ Hide Icon Bars).
    case toggleIconBars
    /// The window's toast taken back, as its Undo does: the toast `UUID`
    /// names, and nothing once another has replaced it.
    case undoToast(UUID)
    case insertPrefix(PalettePrefix)

    var frecencyKey: String {
        switch self {
        case let .shortcutAction(action): "shortcut.\(action.rawValue)"
        case let .jumpToTab(id): "tab.\(id.uuidString)"
        case let .activateProject(id): "project.\(id.uuidString)"
        case let .activateWorktree(pid, wid): "worktree.\(pid.uuidString).\(wid.uuidString)"
        case let .reopenClosedTab(id): "reopen.\(id.uuidString)"
        case let .openRecentProject(url): "recent.\(url.path)"
        case .openSettings: "settings.open"
        case .openProjectSettings: "settings.project"
        case .closeProject: "project.close"
        case .restoreTurn: "restore.turn"
        case let .newAgentTab(agent): "newTab.\(agent.rawValue)"
        case let .openSettingsSection(section): "settings.section.\(section.rawValue)"
        case .movePaneToNewTab: "pane.moveToNewTab"
        case .toggleIconBars: "view.toggleIconBars"
        // One key for every toast, so the row ranks as the one it always is.
        case .undoToast: "toast.undo"
        case let .insertPrefix(mode): "prefix.\(mode.character)"
        }
    }
}
