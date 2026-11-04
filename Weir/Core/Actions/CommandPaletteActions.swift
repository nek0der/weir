// CommandPaletteActions.swift
// Weir — command-palette verbs (open / close / execute). The
// `.shortcutAction` case reaches into `TabActions.dispatchShortcutAction`
// so the palette re-uses the same dispatch chain the menu bar runs.

import Foundation
import WeirDomain

extension Notification.Name {
    /// Posted when the command palette opens so the overlay grabs focus. A
    /// broadcast: one palette is open at a time, in one window.
    static let weirCommandPaletteFocus = Notification.Name("com.nekoder.weir.commandPaletteFocus")
}

/// What the window did with a palette row before the shared dispatch.
enum PaletteRowHandling: Equatable {
    /// Not the window's: the shared dispatch runs it.
    case notHandled
    /// Run, and the window placed the keyboard itself.
    case handled
    /// Run, or nothing to do, and the keyboard goes back to the terminal
    /// as after any row.
    case handledReturningKeyboard
}

/// A committed palette row and the window whose palette it came from.
///
/// Every main window's chrome receives the notification, so without the
/// window each one would run the row once. Only the window the palette
/// opened in runs it.
struct CommandPaletteExecution: Equatable {
    let action: CommandPaletteAction
    let windowID: WindowID
    /// Committed with ⌘ (⌘Return, ⌘-click): another project's row opens in
    /// a new window rather than switching this one. Only the
    /// supervision window reads it; any other row runs as it would without.
    var opensInNewWindow = false
}

@MainActor
enum CommandPaletteActions {
    /// ⌘P / ⌘⇧P — surface the palette in `windowID`. Idempotent: if it
    /// is already open there, focus it (the overlay observes
    /// `session.commandPaletteState` and grabs focus on the next render).
    /// Open in another window, it moves here, since the window that asks
    /// is the one the person is looking at.
    static func openCommandPalette( // swiftlint:disable:this function_parameter_count
        _ session: WorkspaceSession,
        in windowID: WindowID,
        settings: SettingsStore,
        frecencyStore: FrecencyStore,
        attention: AttentionState,
        registry: (any PaneSurfaceProviding)? = nil,
        initialQuery: String = ">",
        // The window it opens in, as far as its rows' enabled states need it.
        supervision: SupervisionPaletteFacts
    ) {
        if session.commandPaletteState?.windowID == windowID {
            NotificationCenter.default.post(name: .weirCommandPaletteFocus, object: nil)
            return
        }
        let state = CommandPaletteState(locale: settings.appLocale, windowID: windowID)
        state.allItems = CommandPaletteCatalog.buildItems(
            session: session,
            settings: settings,
            attention: attention,
            registry: registry,
            supervision: supervision,
            window: windowID,
            locale: state.locale
        )
        state.initialQuery = initialQuery.isEmpty ? nil : initialQuery
        state.applyFilter(query: "", frecencyStore: frecencyStore)
        session.commandPaletteState = state
    }

    /// Dismiss the palette overlay and leave the keyboard to the caller. Esc
    /// and a click outside it go through `KeyboardHandoff.closePalette`,
    /// which also gives the keyboard back to the pane.
    static func closeCommandPalette(_ session: WorkspaceSession) {
        session.commandPaletteState = nil
    }

    /// Hands a committed row to the chrome of the window the palette is in,
    /// with whether ⌘ committed it (`CommandPaletteExecution.opensInNewWindow`).
    static func postExecution(
        of action: CommandPaletteAction,
        from state: CommandPaletteState,
        opensInNewWindow: Bool = false,
        commands: any WindowCommandPerforming
    ) {
        let execution = CommandPaletteExecution(action: action, windowID: state.windowID, opensInNewWindow: opensInNewWindow)
        commands.perform(.runPaletteRow(execution), in: state.windowID)
    }

    // swiftlint:disable function_parameter_count
    /// Run the palette row the user committed. Records the frecency
    /// hit so the next session sorts smarter, then routes to the
    /// matching domain action and pulls focus back to the terminal
    /// surface, except after a row the window ran placing the keyboard
    /// itself (`PaletteRowHandling.handled`).
    static func executeCommandPaletteAction(
        _ action: CommandPaletteAction,
        session: WorkspaceSession,
        attention: AttentionState,
        registry: any PaneSurfaceProviding,
        commands: any WindowCommandPerforming,
        frecencyStore: FrecencyStore,
        toastCenter: ToastCenter,
        minPaneSize: PaneMinimumSize,
        agentProjection: AgentProjectionAdapter? = nil,
        window: WindowID,
        // The Settings rows open Settings through the window's own opener,
        // once, whichever window's palette ran them.
        settingsOpener: SettingsOpener,
        // The rows the window runs itself: the supervision window's session
        // rows, review tab, and close keys, as its menu runs them, and the
        // rows that go to another project.
        runsInWindow: (CommandPaletteAction) -> PaletteRowHandling = { _ in .notHandled }
    ) {
        // The window's palette closes whatever the row does: left open it
        // would stand over the next place the window shows. A palette open
        // in another window is that window's, and keeps its query: a row the
        // channel runs here is no answer to it.
        if session.commandPaletteState?.windowID == window {
            closeCommandPalette(session)
        }
        // A window the session does not know runs nothing: what was asked
        // of a window that is gone is not done in another.
        guard session.selection(window) != nil else { return }
        frecencyStore.record(action.frecencyKey)

        let handling = runsInWindow(action)
        // The window placed the keyboard itself: it moved it (a review tab
        // put in front, behind, or closed; another window brought to the
        // front), or the tab it switched to takes it as its surface mounts.
        // Pulling it back to the terminal here would undo the first.
        guard handling != .handled else { return }
        if handling == .notHandled {
            dispatch(
                action,
                session: session,
                attention: attention,
                registry: registry,
                commands: commands,
                window: window,
                toastCenter: toastCenter,
                minPaneSize: minPaneSize,
                agentProjection: agentProjection,
                settingsOpener: settingsOpener
            )
        }

        // Restore focus to the terminal surface so the next keystroke
        // lands on the pane the user was working in before the palette
        // intercepted the keyboard.
        if let tab = session.activeTab(in: window),
           let leafID = tab.splitTree.effectiveFocusedLeafID,
           let view = registry.paneSurface(for: leafID)
        {
            view.takeKeyboardFocus()
        }
    }

    /// The shared dispatch of a committed row, in `window`.
    private static func dispatch(
        _ action: CommandPaletteAction,
        session: WorkspaceSession,
        attention: AttentionState,
        registry: any PaneSurfaceProviding,
        commands: any WindowCommandPerforming,
        window: WindowID,
        toastCenter: ToastCenter,
        minPaneSize: PaneMinimumSize,
        agentProjection: AgentProjectionAdapter?,
        settingsOpener: SettingsOpener
    ) {
        switch action {
        case let .shortcutAction(shortcut):
            TabActions.dispatchShortcutAction(
                shortcut,
                session: session,
                attention: attention,
                registry: registry,
                commands: commands,
                trackers: TabActions.SessionTrackers(
                    projection: agentProjection
                ),
                toastCenter: toastCenter,
                minPaneSize: minPaneSize,
                window: window
            )
        case let .jumpToTab(tabID):
            if let tab = session.tab(tabID) {
                session.setActiveContainer(tab.container, in: window, intent: .person)
                session.setActiveTab(tabID, in: window, intent: .person)
            }
        case let .activateProject(projectID):
            session.setActiveContainer(.project(projectID), in: window, intent: .person)
        case let .activateWorktree(pid, wid):
            session.setActiveContainer(.worktree(projectID: pid, worktreeID: wid), in: window, intent: .person)
        case let .reopenClosedTab(tabID):
            TabActions.reopenClosedTab(session, specificID: tabID, in: window, intent: .person)
        case let .openRecentProject(url):
            // Same flow as the sidebar's `+` menu. It finishes after the
            // focus restore below, and the new tab's surface takes focus
            // itself when it mounts.
            Task { @MainActor in
                await session.openProject(at: url, in: window, intent: .person)
            }
        case .openSettings, .openSettingsSection:
            openSettings(for: action, with: settingsOpener)
        case .openProjectSettings:
            commands.perform(.openProjectSettings(nil), in: window)
        case .closeProject:
            commands.perform(.closeProject(nil), in: window)
        case .newAgentTab, .movePaneToNewTab:
            dispatchControlRow(action, session: session, window: window)
        case .restoreTurn, .toggleIconBars, .undoToast:
            break // Run by the supervision window (`SupervisionWindowActions.runPaletteAction`).
        case .insertPrefix:
            break // Handled in ToolbarPaletteField, never reaches here.
        }
    }

    // swiftlint:enable function_parameter_count

    /// Runs the palette's Open Settings row, which opens on the section
    /// Settings showed last, and its Settings: section rows, which open on
    /// their section.
    private static func openSettings(for action: CommandPaletteAction, with opener: SettingsOpener) {
        if case let .openSettingsSection(section) = action {
            opener.open(section)
        } else {
            opener.open()
        }
    }

    /// The rows for controls with no keyboard shortcut of their own, each as
    /// its control runs it.
    private static func dispatchControlRow(_ action: CommandPaletteAction, session: WorkspaceSession, window: WindowID) {
        switch action {
        case let .newAgentTab(agent):
            // The session the strip's "+" adds to: the window's.
            guard let container = session.selection(window)?.activeContainerID,
                  ShortcutAvailability.canOpenTab(in: container, session: session)
            else { return }
            TabActions.newTab(session, in: container, running: agent, window: window, intent: .person, selects: true)
        case .movePaneToNewTab:
            guard let paneID = session.activeTab(in: window)?.splitTree.effectiveFocusedLeafID else { return }
            TabActions.movePaneToNewTab(session, paneID: paneID, in: window, intent: .person)
        default:
            break
        }
    }
}
