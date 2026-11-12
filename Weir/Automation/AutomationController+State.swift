// AutomationController+State.swift
// Weir — what `state` reports of a window beyond its panes (its layers, dropdown, review, and keyboard), of Settings, and of posted keys.

#if DEBUG && WEIR_AUTOMATION

    import AppKit
    import Foundation

    extension AutomationController {
        func openLayers(of window: ProjectWindowState, in state: AppState) -> [AutomationLayer] {
            let layers = window.openLayers(session: state.session)
            var open: [AutomationLayer] = []
            if window.titleBarMenu?.menu == .needsAttention {
                open.append(.needsAttention)
            }
            if layers.contains(.allProjects) {
                open.append(.allProjects)
            }
            if layers.contains(.notificationHistory) {
                open.append(.notificationHistory)
            }
            if layers.contains(.keyboardShortcuts) {
                open.append(.keyboardShortcuts)
            }
            if layers.contains(.planUsage) {
                open.append(.planUsage)
            }
            if window.review?.isShown == true {
                open.append(.review)
            }
            return open
        }

        /// The Settings window and the section it shows, which it keeps in
        /// `UserDefaults` (`SettingsSection.lastSectionDefaultsKey`).
        func settingsSnapshot() -> AutomationSnapshot.Settings? {
            guard Self.settingsWindow() != nil else { return nil }
            let section = UserDefaults.standard.string(forKey: SettingsSection.lastSectionDefaultsKey) ?? SettingsSection.general.rawValue
            return AutomationSnapshot.Settings(section: section)
        }

        /// What holds the window's keyboard: a sheet attached to it, or else
        /// its first responder, told apart as a terminal pane or one of
        /// Weir's own controls. `nil` when the window holds it itself, or is
        /// not shown.
        func keyboard(of window: ProjectWindowState, in state: AppState) -> AutomationSnapshot.Keyboard? {
            guard let nsWindow = state.windowRegistry.nsWindow(for: window.id) else { return nil }
            if let sheet = nsWindow.attachedSheet {
                let holder: AnyObject = sheet.firstResponder ?? sheet
                return AutomationSnapshot.Keyboard(kind: .sheet, pane: nil, view: String(describing: type(of: holder)))
            }
            guard let responder = nsWindow.firstResponder, !(responder is NSWindow) else { return nil }
            let view = String(describing: type(of: responder))
            if let surface = responder as? SurfaceView {
                return AutomationSnapshot.Keyboard(kind: .pane, pane: surface.paneID, view: view)
            }
            return AutomationSnapshot.Keyboard(kind: .control, pane: nil, view: view)
        }

        /// Where a key posted now would land, by the rule the gate applies
        /// as it arrives (`AutomationPostedKeys`), with the gate's counts.
        func postedKeys(in state: AppState) -> AutomationSnapshot.PostedKeys {
            let registry = state.windowRegistry
            let shown = registry.windows.filter { registry.presenter?.isOnScreen($0.id) ?? false }
            let refusal = AutomationPostedKeys.refusal(
                isSettingsShown: Self.settingsWindow() != nil,
                isQuickTerminalShown: state.quickTerminal.isVisible,
                shownWindows: shown.map { registry.nsWindow(for: $0.id) }
            )
            return AutomationSnapshot.PostedKeys(
                window: shown.count == 1 ? shown.first?.id.rawValue : nil,
                refusal: refusal,
                seen: AutomationPostedKeys.seen,
                dropped: AutomationPostedKeys.dropped
            )
        }

        /// The Settings window, while it is open (`WeirWindowRole.settings`).
        static func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0.isWeirSettingsWindow && $0.isVisible }
        }

        static func name(of menu: TitleBarMenuRequest.Menu) -> String {
            switch menu {
            case .project: "project"
            case .worktree: "worktree"
            case .needsAttention: "needsAttention"
            case .addTab: "addTab"
            case .openTabs: "openTabs"
            }
        }

        static func name(of scope: ReviewScopeOption) -> String {
            switch scope {
            case .unviewedTurns: "unviewedTurns"
            case .worktreeUnviewedTurns: "worktreeUnviewedTurns"
            case .turn: "turn"
            case .incompleteTurn: "incompleteTurn"
            case .uncommitted: "uncommitted"
            case .branch: "branch"
            }
        }
    }

#endif
