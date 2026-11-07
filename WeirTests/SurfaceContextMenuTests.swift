// SurfaceContextMenuTests.swift
// Weir — the terminal's right-click menu names, draws, and keys its items as the other pane menus do.

import AppKit
import Testing
@testable import Weir

@Suite("Surface context menu")
@MainActor
struct SurfaceContextMenuTests {
    private static let en = Locale(identifier: "en")
    private static let ja = Locale(identifier: "ja")

    private static func state(
        zoomAction: PaneZoomAction? = .zoom,
        keyboard: KeyboardSettings = KeyboardSettings()
    ) -> SurfaceContextMenuState {
        SurfaceContextMenuState(
            hasSelection: true,
            isInPane: true,
            canRenamePane: true,
            zoomAction: zoomAction,
            canMoveToNewTab: true,
            shortcut: { command in command.shortcut(in: keyboard) }
        )
    }

    private static func item(_ menu: NSMenu, _ action: Selector) throws -> NSMenuItem {
        try #require(menu.items.first { $0.action == action })
    }

    /// Whether `item` draws `symbol`: compared by the pixels AppKit makes
    /// of each, since a symbol image does not say which symbol it is. A
    /// command with no symbol of ours (Copy, Paste, Select All) gets the one
    /// AppKit gives its standard action, which we leave as it is.
    private static func draws(_ item: NSMenuItem, _ symbol: String?) -> Bool {
        guard let symbol else { return true }
        guard let expected = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.tiffRepresentation else { return false }
        return item.image?.tiffRepresentation == expected
    }

    /// The item the menu sends `command`'s action from.
    private static func selector(_ command: MenuCommand) -> Selector? {
        switch command {
        case .copy: #selector(SurfaceView.copy(_:))
        case .paste: #selector(SurfaceView.paste(_:))
        case .selectAll: #selector(SurfaceView.selectAll(_:))
        case .find: #selector(SurfaceView.findInSurface(_:))
        case .splitRight: #selector(SurfaceView.splitRight(_:))
        case .splitDown: #selector(SurfaceView.splitDown(_:))
        case .closePane: #selector(SurfaceView.closePaneFromMenu(_:))
        default: nil
        }
    }

    @Test("each item a shortcut performs takes its name, symbol, and key from its command", arguments: [
        MenuCommand.copy, .paste, .selectAll, .find, .splitRight, .splitDown, .closePane
    ])
    func commandItems_followTheirCommand(command: MenuCommand) throws {
        let action = try #require(Self.selector(command))
        var keyboard = KeyboardSettings()
        // A rebound key shows too, not only the defaults.
        keyboard.setOverride(StoredShortcut(key: "f7", modifiers: [.control]), for: .splitDown)
        for locale in [Self.en, Self.ja] {
            let item = try Self.item(SurfaceContextMenu.make(Self.state(keyboard: keyboard), locale: locale), action)
            #expect(item.title == command.title.resolved(in: locale), "\(command)")
            #expect(Self.draws(item, command.icon), "\(command)")
            let key = command.shortcut(in: keyboard)?.menuKeyEquivalent
            #expect(item.keyEquivalent == (key?.key ?? ""), "\(command)")
            #expect(key == nil || item.keyEquivalentModifierMask == key?.modifiers, "\(command)")
        }
    }

    /// The Pane menu's and the palette's symbols, not the half-filled
    /// rectangles the menu drew before.
    @Test func splitItems_drawThePaneMenusSymbols() throws {
        let menu = SurfaceContextMenu.make(Self.state(), locale: Self.en)
        #expect(try Self.draws(Self.item(menu, #selector(SurfaceView.splitRight(_:))), "rectangle.split.2x1"))
        #expect(try Self.draws(Self.item(menu, #selector(SurfaceView.splitDown(_:))), "rectangle.split.1x2"))
    }

    @Test("the zoom item names what pressing it does, in each language, with the zoom key", arguments: [
        PaneZoomAction.zoom, .unzoom
    ])
    func zoomItem_followsPaneZoomAction(zoom: PaneZoomAction) throws {
        var keyboard = KeyboardSettings()
        let rebound = StoredShortcut(key: "f6", modifiers: [.control])
        keyboard.setOverride(rebound, for: .toggleSplitZoom)
        for locale in [Self.en, Self.ja] {
            let menu = SurfaceContextMenu.make(Self.state(zoomAction: zoom, keyboard: keyboard), locale: locale)
            let item = try Self.item(menu, #selector(SurfaceView.zoomPaneFromMenu(_:)))
            #expect(item.title == zoom.title.resolved(in: locale))
            #expect(Self.draws(item, zoom.symbol))
            #expect(item.keyEquivalent == rebound.menuKeyEquivalent?.key)
            #expect(item.keyEquivalentModifierMask == .control)
        }
        #expect(PaneZoomAction.zoom.title.resolved(in: Self.ja) != PaneZoomAction.unzoom.title.resolved(in: Self.ja))
    }

    @Test func moveItem_isTheOtherPaneMenusItem() throws {
        for locale in [Self.en, Self.ja] {
            let menu = SurfaceContextMenu.make(Self.state(), locale: locale)
            let item = try Self.item(menu, #selector(SurfaceView.movePaneToNewTab(_:)))
            #expect(item.title == MenuItemLabel.movePaneToNewTab.title.resolved(in: locale))
            #expect(Self.draws(item, MenuItemLabel.movePaneToNewTab.symbol))
            #expect(item.keyEquivalent.isEmpty)
        }
    }

    @Test func itemsNoShortcutPerforms_showNoKey() throws {
        let menu = SurfaceContextMenu.make(Self.state(), locale: Self.en)
        for action in [
            #selector(SurfaceView.clearScreen(_:)),
            #selector(SurfaceView.scrollToTop(_:)),
            #selector(SurfaceView.scrollToBottom(_:)),
            #selector(SurfaceView.renamePaneFromMenu(_:))
        ] {
            #expect(try Self.item(menu, action).keyEquivalent.isEmpty)
        }
        #expect(try Self.draws(Self.item(menu, #selector(SurfaceView.renamePaneFromMenu(_:))), "pencil"))
    }
}
