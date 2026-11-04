// AutomationController+PaletteRows.swift
// Weir — which palette row the channel's `open` and `command` run, and why it refuses one.

#if DEBUG && WEIR_AUTOMATION

    import Foundation

    extension AutomationController {
        /// What `open` does for a layer that `action`'s palette row opens.
        enum OpenStep: Equatable {
            /// The layer is up: each of these rows toggles it, so running one
            /// would close it.
            case alreadyOpen
            /// The row is not in the window, or the palette shows it off.
            case refused(String)
            /// The row to run in the window, as the palette runs it.
            case run(CommandPaletteItem)
        }

        /// Decides `open` for a layer `action`'s row opens: `items` are the
        /// window's palette rows, read only when the layer is not up yet.
        static func openStep(_ action: WeirShortcutAction, isOpen: Bool, items: () -> [CommandPaletteItem]) -> OpenStep {
            guard !isOpen else { return .alreadyOpen }
            switch row(CommandPaletteAction.shortcutAction(action).frecencyKey, among: items()) {
            case let .runnable(item): return .run(item)
            case let .refused(reason): return .refused(reason)
            }
        }

        /// The shortcut action whose palette row opens `layer`; `nil` for the
        /// review, which opens for a named pane rather than through a palette
        /// row.
        static func action(opening layer: AutomationLayer) -> WeirShortcutAction? {
            switch layer {
            case .needsAttention: .showNeedsAttention
            case .allProjects: .allProjects
            case .notificationHistory: .notificationHistory
            case .keyboardShortcuts: .keyboardShortcuts
            case .planUsage: .planUsage
            case .review: nil
            }
        }

        /// A palette row the channel was asked to run, or why it cannot.
        enum RowLookup: Equatable {
            case runnable(CommandPaletteItem)
            case refused(String)
        }

        /// The palette row `id` of `items`, refused when the window has no
        /// such row or the palette shows it disabled (`ShortcutAvailability`,
        /// `.palette`).
        static func row(_ id: String, among items: [CommandPaletteItem]) -> RowLookup {
            guard let item = items.first(where: { $0.id == id }) else {
                return .refused("no command \(id) in this window; commands lists them")
            }
            return item.isEnabled ? .runnable(item) : .refused("\(id) is disabled now")
        }
    }

#endif
