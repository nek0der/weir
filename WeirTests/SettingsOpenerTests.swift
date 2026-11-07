// SettingsOpenerTests.swift
// Weir — the Settings opener calls openWindow once, after the section; ⌘, and ⌘Q, the names, and the symbol each have one owner.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct SettingsOpenerTests {

    // MARK: - The opener

    @Test func open_withNoSection_callsOpenWindowOnce_withoutRememberingASection() {
        let recorder = SettingsOpenerRecorder()

        recorder.opener.open()

        #expect(recorder.events == [.openWindow(WeirApp.settingsWindowID)])
    }

    @Test func open_onASection_remembersTheSectionBeforeCallingOpenWindow() {
        let recorder = SettingsOpenerRecorder()

        recorder.opener.open(.keyboard)

        #expect(recorder.events == [.rememberSection(.keyboard), .openWindow(WeirApp.settingsWindowID)])
    }

    // MARK: - The palette's rows

    @Test func paletteOpenSettingsRow_callsTheOpenerWithNoSection() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let recorder = SettingsOpenerRecorder()

        try CommandPaletteActions.runRowForTest(
            .openSettings,
            session: session,
            window: session.primaryWindowID,
            settingsOpener: recorder.opener
        )

        #expect(recorder.events == [.openWindow(WeirApp.settingsWindowID)])
    }

    @Test(arguments: SettingsSection.allCases)
    func paletteSectionRow_callsTheOpenerWithItsSection(section: SettingsSection) throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let recorder = SettingsOpenerRecorder()

        try CommandPaletteActions.runRowForTest(
            .openSettingsSection(section),
            session: session,
            window: session.primaryWindowID,
            settingsOpener: recorder.opener
        )

        #expect(recorder.events == [.rememberSection(section), .openWindow(WeirApp.settingsWindowID)])
    }

    // MARK: - ⌘, ⌘Q, the names, and the symbol

    @Test func settingsKey_isCommandComma() {
        #expect(StandardMenuShortcut.settings == StoredShortcut(key: ",", modifiers: [.command]))
    }

    @Test func standardMenuTriggers_keepTheSettingsKeyFromRebinding() {
        #expect(ReservedShortcuts.standardMenuTriggers.contains(StandardMenuShortcut.settings.ghosttyTrigger))
    }

    @Test func quitKey_isCommandQ_andNoBindingTakesIt() {
        #expect(StandardMenuShortcut.quit == StoredShortcut(key: "q", modifiers: [.command]))
        #expect(ReservedShortcuts.triggers.contains(StandardMenuShortcut.quit.ghosttyTrigger))
    }

    /// A terminal answers ⌘Q itself, since libghostty would take it before
    /// the menu, so it answers ⌘Q alone, the key the app menu's Quit Weir
    /// shows.
    @Test func quitKey_matchesCommandQAlone_withOrWithoutCapsLock() throws {
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 12
            ))
        }
        #expect(try StandardMenuShortcut.quit.isPressed(in: press("q", [.command])))
        #expect(try StandardMenuShortcut.quit.isPressed(in: press("Q", [.command, .capsLock])))
        #expect(try !StandardMenuShortcut.quit.isPressed(in: press("q", [.command, .option])))
        #expect(try !StandardMenuShortcut.quit.isPressed(in: press("q", [])))
        #expect(try !StandardMenuShortcut.quit.isPressed(in: press("x", [.command])))
        #expect(try !StandardMenuShortcut.quit.isPressed(in: press("q", [.command], type: .keyUp)))
    }

    @Test func menuBarKeyPress_matchesQuitAndSettings_withOrWithoutCapsLock() {
        for shortcut in [StandardMenuShortcut.quit, StandardMenuShortcut.settings] {
            let key = KeyEquivalent(Character(shortcut.key))
            #expect(shortcut.isPressed(key: key, modifiers: .command))
            #expect(shortcut.isPressed(key: key, modifiers: [.command, .capsLock]))
            let shifted = KeyEquivalent(Character(shortcut.key.uppercased()))
            #expect(shortcut.isPressed(key: shifted, modifiers: [.command, .capsLock]))
            #expect(!shortcut.isPressed(key: key, modifiers: [.command, .option]))
            #expect(!shortcut.isPressed(key: key, modifiers: []))
            #expect(!shortcut.isPressed(key: KeyEquivalent("x"), modifiers: .command))
        }
    }

    @Test func menuBarMoreMenu_keysSettingsAndQuitFromTheStandardMenuKeys() {
        var calls: [String] = []
        let entries = MenuBarMoreMenu.entries(
            onOpenWeir: { calls.append("open") },
            onOpenSettings: { calls.append("settings") },
            onQuit: { calls.append("quit") }
        )

        let items: [PopUpMenuItem] = entries.compactMap { entry in
            if case let .item(item) = entry {
                item
            } else {
                nil
            }
        }

        #expect(items.map(\.shortcut) == [nil, StandardMenuShortcut.settings, StandardMenuShortcut.quit])
        for item in items {
            item.perform()
        }
        #expect(calls == ["open", "settings", "quit"])
    }

    /// A stored ⌫ is SwiftUI's `.delete`, U+0008, and a press of ⌫ carries
    /// U+007F; the two are one key.
    @Test func storedBackspace_matchesAPressOfBackspace() {
        let shortcut = StoredShortcut(key: NamedKey.backspace.rawValue, modifiers: [.command])
        #expect(shortcut.isPressed(key: .backspacePress, modifiers: .command))
        #expect(shortcut.isPressed(key: .backspacePress, modifiers: [.command, .capsLock]))
        #expect(!shortcut.isPressed(key: .deleteForward, modifiers: .command))
    }

    /// The AppKit match reads ⌫ by the same rule: the event carries U+007F,
    /// and the menu's key for a stored ⌫ is U+0008.
    @Test func storedBackspace_matchesABackspaceKeyEvent() throws {
        let shortcut = StoredShortcut(key: NamedKey.backspace.rawValue, modifiers: [.command])
        let press = try NSEvent.testKeyDown(keyCode: 51, modifiers: .command, characters: "\u{7F}")
        let withCapsLock = try NSEvent.testKeyDown(keyCode: 51, modifiers: [.command, .capsLock], characters: "\u{7F}")
        let forwardDelete = try NSEvent.testKeyDown(keyCode: 117, modifiers: .command, characters: "\u{F728}")
        #expect(shortcut.isPressed(in: press))
        #expect(shortcut.isPressed(in: withCapsLock))
        #expect(!shortcut.isPressed(in: forwardDelete))
    }

    @Test func menuBarKeyHandler_hearsQuitWithCapsLockOn() {
        #expect(SupervisionMenuBarContent.appMenuKeys.contains(KeyEquivalent("Q")))
        #expect(SupervisionMenuBarContent.appMenuKeys == [",", "q", "Q"])
    }

    @Test(arguments: ["en", "ja"])
    func shortcutList_namesAndKeysSettingsAsTheMenuDoes(language: String) throws {
        let locale = Locale(identifier: language)
        let sections = KeyboardShortcutCatalog.sections(keyboard: KeyboardSettings(), quickTerminalHotKey: nil, locale: locale)

        let entry = try #require(sections.flatMap(\.entries).first { $0.id == "fixed.settings" })

        #expect(entry.tokens == StandardMenuShortcut.settings.displayTokens)
        #expect(entry.title == SettingsCommand.menuLabel.title.resolved(in: locale))
    }

    @Test func settingsSymbol_isGearshape_andTheMenuLabelUsesIt() {
        #expect(SettingsCommand.symbol == "gearshape")
        #expect(SettingsCommand.menuLabel.symbol == SettingsCommand.symbol)
    }

    @Test func paletteOpenSettingsRow_takesItsNameAndSymbolFromTheCommand() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        let locale = Locale(identifier: "en")

        let row = try withTempDir { dir in
            CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: dir),
                attention: AttentionState(),
                supervision: .empty,
                window: session.primaryWindowID,
                locale: locale
            ).first { $0.action == .openSettings }
        }

        let settingsRow = try #require(row)
        #expect(settingsRow.icon == SettingsCommand.symbol)
        #expect(settingsRow.title == SettingsCommand.openTitle.resolved(in: locale))
    }
}
