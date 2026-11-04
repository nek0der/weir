// SurfaceView+ContextMenu.swift
// Weir — right-click context menu for terminal panes; modeled on
// Ghostty's macOS app and wired to libghostty actions + TabActions
// via the callbacks `PaneHostView` installs.

import AppKit
import GhosttyKit

extension SurfaceView {
    /// Right-click only. We deliberately don't surface a menu on
    /// ⌃-left-click — libghostty's mouse pipeline already routes that
    /// to the running TUI, and intercepting it would break programs that
    /// bind ⌃-click themselves.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }

        // AppKit calls menu(for:) BEFORE rightMouseDown and skips
        // rightMouseDown entirely when we return non-nil. Two
        // consequences we have to handle manually:
        //   1. Promote this pane to focused in both the AppKit
        //      responder chain AND the SwiftUI model — otherwise
        //      Split / Close / Find target the previously-focused
        //      pane (focusedLeafID is only written by .onTapGesture).
        //   2. Re-emit the right-mouse press to libghostty so TUIs
        //      with mouse reporting still see the click, and the release
        //      when the menu closes: the menu's tracking takes the
        //      physical release too, and without ours libghostty keeps
        //      the button held, reporting every later move as a
        //      right-button drag.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        onRequestFocus?()

        // Forward the right-press to libghostty only when there is no
        // selection to protect. On a mouse-reporting surface (a TUI like
        // vim / htop / Claude) libghostty reports the press to the program
        // and, as a side effect, clears any shift-selection — which would
        // strip the Copy item exactly when the user reached for it. So when
        // a selection already exists we leave it untouched and just show
        // the menu; with no selection we let libghostty handle the press
        // (word-select under the cursor for the default context-menu
        // action; click-forwarding in a TUI), then re-read the selection
        // for the Copy gate below.
        let isPressSent: Bool
        if let surface, !ghostty_surface_has_selection(surface) {
            sendRightMousePressForMenu(with: event)
            isPressSent = true
        } else {
            isPressSent = false
        }

        let menu = SurfaceContextMenu.make(
            SurfaceContextMenuState(
                hasSelection: surface.map { ghostty_surface_has_selection($0) } ?? false,
                isInPane: paneID != nil,
                canRenamePane: canRenamePane?() == true,
                zoomAction: paneZoomAction?(),
                canMoveToNewTab: canMoveToNewTab?() == true,
                shortcut: { [keyboardSettings] command in
                    command.shortcut { keyboardSettings?().shortcut(for: $0) }
                }
            ),
            locale: resolvedAppLocale
        )
        // Only a menu that followed a press closes with a release, so a
        // program never sees a release it had no press for.
        if isPressSent {
            menu.delegate = self
        }
        return menu
    }

    /// The app locale the host installed, for the text this view puts
    /// outside SwiftUI. A surface no host has wired never reaches the
    /// screen, so its fallback is never read.
    var resolvedAppLocale: Locale {
        appLocale?() ?? .current
    }

    // MARK: - Action handlers

    @objc override func selectAll(_ sender: Any?) {
        runSurfaceBinding("select_all")
    }

    @objc func clearScreen(_ sender: Any?) {
        runSurfaceBinding("clear_screen")
    }

    @objc func scrollToTop(_ sender: Any?) {
        runSurfaceBinding("scroll_to_top")
    }

    @objc func scrollToBottom(_ sender: Any?) {
        runSurfaceBinding("scroll_to_bottom")
    }

    @objc func findInSurface(_ sender: Any?) {
        onRequestBeginSearch?()
    }

    @objc func splitRight(_ sender: Any?) {
        onRequestSplit?(.horizontal)
    }

    @objc func splitDown(_ sender: Any?) {
        onRequestSplit?(.vertical)
    }

    @objc func closePaneFromMenu(_ sender: Any?) {
        onRequestCloseActivePane?()
    }

    @objc func movePaneToNewTab(_ sender: Any?) {
        onRequestMoveToNewTab?()
    }

    @objc func renamePaneFromMenu(_ sender: Any?) {
        onRequestRenamePane?()
    }

    @objc func zoomPaneFromMenu(_ sender: Any?) {
        onRequestZoomAction?()
    }

    private func runSurfaceBinding(_ action: String) {
        guard let surface else { return }
        GhosttyFFI.performBindingAction(action, on: surface)
    }
}

extension SurfaceView: NSMenuDelegate {
    /// The right-button release `menu(for:)` owes libghostty for the press
    /// it sent. The surface is the delegate only of such a menu.
    func menuDidClose(_ menu: NSMenu) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_RIGHT,
            Self.translateMods(NSEvent.modifierFlags)
        )
    }
}

/// What the right-click menu offers, read from the surface each time it
/// opens.
struct SurfaceContextMenuState {
    var hasSelection: Bool
    /// Find, split, and close act through callbacks the pane host
    /// installs. A surface outside any pane (the quick terminal) has none
    /// of them, so the menu leaves those items out rather than offer ones
    /// that do nothing.
    var isInPane: Bool
    var canRenamePane: Bool
    var zoomAction: PaneZoomAction?
    var canMoveToNewTab: Bool
    /// The key an item shows; see `MenuCommand`. The menu is built per
    /// right-click and dropped when it closes, so these keys answer only
    /// while it is open, and a keystroke made without it reaches the menu
    /// bar once.
    var shortcut: (MenuCommand) -> StoredShortcut?
}

/// Builds the terminal's right-click menu. Kept apart from the view so the
/// titles can be checked in a given language without a live surface. The
/// items carry no target: they travel the responder chain to the surface,
/// which `menu(for:)` has just made first responder. An item a shortcut
/// performs is named and drawn by its `MenuCommand`, the zoom item by its
/// `PaneZoomAction`, and Move Pane to New Tab by its `MenuItemLabel`, as
/// the header's ⋯ and the Pane menu name and draw them.
@MainActor
enum SurfaceContextMenu {
    /// `locale` is the app locale: an AppKit menu is outside SwiftUI's
    /// environment, and would otherwise answer in the launch language.
    static func make(_ state: SurfaceContextMenuState, locale: Locale) -> NSMenu {
        let menu = NSMenu()
        let add = ItemAdder(menu: menu, state: state, locale: locale)

        if state.hasSelection {
            add(.copy, #selector(SurfaceView.copy(_:)))
        }
        add(.paste, #selector(SurfaceView.paste(_:)))

        menu.addItem(.separator())
        add(.selectAll, #selector(SurfaceView.selectAll(_:)))
        add("Clear", #selector(SurfaceView.clearScreen(_:)))

        menu.addItem(.separator())
        add("Scroll to Top", #selector(SurfaceView.scrollToTop(_:)))
        add("Scroll to Bottom", #selector(SurfaceView.scrollToBottom(_:)))

        guard state.isInPane else { return menu }

        menu.addItem(.separator())
        add(.find, #selector(SurfaceView.findInSurface(_:)))
        if state.canRenamePane {
            add("Rename Pane…", #selector(SurfaceView.renamePaneFromMenu(_:)), symbol: "pencil")
        }

        menu.addItem(.separator())
        add(.splitRight, #selector(SurfaceView.splitRight(_:)))
        add(.splitDown, #selector(SurfaceView.splitDown(_:)))

        if state.zoomAction != nil || state.canMoveToNewTab {
            menu.addItem(.separator())
        }
        if let zoomAction = state.zoomAction {
            add(
                zoomAction.title,
                #selector(SurfaceView.zoomPaneFromMenu(_:)),
                symbol: zoomAction.symbol,
                keyOf: .togglePaneZoom
            )
        }
        if state.canMoveToNewTab {
            let movePane = MenuItemLabel.movePaneToNewTab
            add(movePane.title, #selector(SurfaceView.movePaneToNewTab(_:)), symbol: movePane.symbol)
        }

        menu.addItem(.separator())
        add(.closePane, #selector(SurfaceView.closePaneFromMenu(_:)))
        return menu
    }

    /// Adds one item to the menu being built, its title in the app locale.
    @MainActor
    private struct ItemAdder {
        let menu: NSMenu
        let state: SurfaceContextMenuState
        let locale: Locale

        /// An item a shortcut performs: its command's name, symbol, and key.
        func callAsFunction(_ command: MenuCommand, _ action: Selector) {
            callAsFunction(command.title, action, symbol: command.icon, keyOf: command)
        }

        /// An item named `title`, showing the key of `command` when a
        /// shortcut performs it.
        func callAsFunction(
            _ title: LocalizedStringResource,
            _ action: Selector,
            symbol: String? = nil,
            keyOf command: MenuCommand? = nil
        ) {
            let item = menu.addItem(withTitle: title.resolved(in: locale), action: action, keyEquivalent: "")
            if let command {
                item.showShortcut(state.shortcut(command))
            }
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
        }
    }
}

// MARK: - NSMenuItemValidation

/// Gates the right-click menu **and** any Edit-menu equivalents that
/// dispatch through the responder chain (`copy:` / `paste:` /
/// `selectAll:`). Without this, AppKit would leave every item enabled
/// even when the surface is gone or there's no selection.
extension SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)),
             #selector(selectAll(_:)),
             #selector(clearScreen(_:)),
             #selector(scrollToTop(_:)),
             #selector(scrollToBottom(_:)),
             #selector(findInSurface(_:)),
             #selector(splitRight(_:)),
             #selector(splitDown(_:)),
             #selector(closePaneFromMenu(_:)):
            return surface != nil
        case #selector(movePaneToNewTab(_:)):
            return surface != nil && canMoveToNewTab?() == true
        case #selector(renamePaneFromMenu(_:)):
            return canRenamePane?() == true
        case #selector(zoomPaneFromMenu(_:)):
            return surface != nil && paneZoomAction?() != nil
        default:
            return true
        }
    }
}
