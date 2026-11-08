// KeyboardShortcutTests.swift
// Weir — a shortcut as it is stored, shown, and checked before it is bound.

// The recorder's `NSEvent` capture cannot be driven headlessly, so its path
// is exercised through what it writes: `StoredShortcut` round-trips through
// Codable and the Ghostty trigger string. The lines that reach libghostty
// are `GhosttyConfigBridgeTests`'.

import Foundation
import Testing
@testable import Weir

@Suite("KeyboardShortcut")
@MainActor
struct KeyboardShortcutTests {

    @Test("Command symbols distinguish unrelated actions")
    func iconNames_areUniqueOutsideTheReviewScopeVariants() {
        // We treat the Review command's two scope variants as one command.
        // Focusing and toggling the sidebar remain different commands.
        let sharedFamilies: [Set<WeirShortcutAction>] = [
            [.review, .reviewLatestTurn]
        ]
        let grouped = Dictionary(grouping: WeirShortcutAction.allCases, by: \.iconName)
        for (symbol, actions) in grouped where actions.count > 1 {
            #expect(sharedFamilies.contains(Set(actions)), "Unexpected shared symbol \(symbol): \(actions)")
        }
    }

    @Test("Command symbols identify their destinations and navigation directions", arguments: [
        (WeirShortcutAction.showNeedsAttention, "tray"),
        (.planUsage, "hourglass"),
        (.toggleSidebar, "sidebar.left"),
        (.focusSidebar, "sidebar.squares.left"),
        (.toggleChangesPanel, "plus.forwardslash.minus"),
        (.showScratch, "note.text"),
        (.previousTab, "arrow.backward.square"),
        (.nextTab, "arrow.forward.square"),
        (.previousSession, "backward.end"),
        (.nextSession, "forward.end"),
        (.showProjectMenu, "book.closed"),
        (.showWorktreeMenu, "list.bullet"),
        (.newWorktree, "arrow.triangle.branch"),
        (.openFolder, "folder"),
        (.splitRight, "rectangle.split.2x1")
    ])
    func iconName_identifiesTheCommand(action: WeirShortcutAction, symbol: String) {
        #expect(action.iconName == symbol)
    }

    // MARK: - Modifiers

    @Test("Ghostty token order is super, ctrl, alt, shift")
    func ghosttyTokens_canonicalOrder() {
        let mods: ShortcutModifiers = [.shift, .command, .control, .option]
        #expect(mods.ghosttyTokens == ["super", "ctrl", "alt", "shift"])
    }

    @Test("Display symbols follow HIG order ⌃⌥⇧⌘")
    func displaySymbols_higOrder() {
        let mods: ShortcutModifiers = [.command, .shift, .control, .option]
        #expect(mods.displaySymbols == "⌃⌥⇧⌘")
    }

    // MARK: - StoredShortcut

    /// Modifiers then the key; Return under Ghostty's Enter name; and `+`
    /// under Ghostty's `plus` alias, since a literal `+` between the `+`
    /// separators (`super++`) is ambiguous.
    @Test("The trigger string is the modifiers and the key, in Ghostty's names", arguments: [
        (StoredShortcut(key: "t", modifiers: [.command, .shift]), "super+shift+t"),
        (StoredShortcut(key: "return", modifiers: [.command, .shift]), "super+shift+enter"),
        (StoredShortcut(key: "+", modifiers: [.command]), "super+plus")
    ])
    func ghosttyTrigger_namesTheModifiersAndTheKey(shortcut: StoredShortcut, trigger: String) {
        #expect(shortcut.ghosttyTrigger == trigger)
    }

    @Test("Display string maps stored keys to inline glyphs", arguments: [
        (StoredShortcut(key: "left", modifiers: [.command]), "⌘←"),
        (StoredShortcut(key: "return", modifiers: [.command, .shift]), "⇧⌘⏎"),
        (StoredShortcut(key: "t", modifiers: [.command]), "⌘T")
    ])
    func displayString_mapsKeysToInlineGlyphs(shortcut: StoredShortcut, expected: String) {
        #expect(shortcut.displayString == expected)
    }

    @Test("Display tokens split modifiers and key into chips", arguments: [
        (StoredShortcut(key: "t", modifiers: [.command, .shift, .control, .option]), ["⌃", "⌥", "⇧", "⌘", "T"]),
        (StoredShortcut(key: "left", modifiers: [.command]), ["⌘", "←"]),
        (StoredShortcut(key: "k", modifiers: []), ["K"])
    ])
    func displayTokens_splitsChips(shortcut: StoredShortcut, expected: [String]) {
        #expect(shortcut.displayTokens == expected)
    }

    @Test("Stored shortcuts read and write the numeric modifier mask")
    func codable_preservesTheStoredShortcutShape() throws {
        let stored = Data(#"{"key":"d","modifiers":3}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredShortcut.self, from: stored)
        #expect(decoded == StoredShortcut(key: "d", modifiers: [.command, .shift]))

        let data = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        #expect(object == ["key": "d", "modifiers": 3])
    }

    // MARK: - KeyboardSettings

    @Test("Effective shortcut falls back to the action's default")
    func shortcut_defaultFallback() {
        let kb = KeyboardSettings()
        #expect(kb.shortcut(for: .newTab) == StoredShortcut(key: "t", modifiers: [.command]))
    }

    @Test("Review Latest Turn is a View action on option-command-L")
    func reviewLatestTurn_isAViewActionOnOptionCommandL() {
        #expect(WeirShortcutAction.reviewLatestTurn.category == .view)
        #expect(WeirShortcutAction.reviewLatestTurn.localizedTitle.resolved(in: Locale(identifier: "en")) == "Review Latest Turn")
        #expect(WeirShortcutAction.reviewLatestTurn.iconName == ReviewPresentation.symbol)
        #expect(
            WeirShortcutAction.reviewLatestTurn.defaultShortcut
                == StoredShortcut(key: "l", modifiers: [.command, .option])
        )
    }

    @Test func showDecisionBarMenu_isANavigationAction_onOptionCommandPeriod_thatNoOtherDefaultHolds() {
        let key = StoredShortcut(key: ".", modifiers: [.command, .option])
        #expect(WeirShortcutAction.showDecisionBarMenu.category == .navigation)
        #expect(WeirShortcutAction.showDecisionBarMenu.ghosttyAction == nil)
        #expect(WeirShortcutAction.showDecisionBarMenu.defaultShortcut == key)
        #expect(WeirShortcutAction.allCases.filter { $0.defaultShortcut == key } == [.showDecisionBarMenu])
        #expect(!ReservedShortcuts.standardMenuTriggers.contains(key.ghosttyTrigger))
        #expect(KeyboardSettings().validate(key, for: .showDecisionBarMenu) == .ok)
    }

    @Test("Override wins over the default")
    func shortcut_overrideWins() {
        var kb = KeyboardSettings()
        let custom = StoredShortcut(key: "k", modifiers: [.command, .control])
        kb.setOverride(custom, for: .newTab)
        #expect(kb.shortcut(for: .newTab) == custom)
    }

    @Test("Reset restores the default")
    func shortcut_resetRestoresDefault() {
        var kb = KeyboardSettings()
        let override = StoredShortcut(key: "k", modifiers: [.command])
        kb.setOverride(override, for: .newTab)
        #expect(kb.shortcut(for: .newTab) == override)

        kb.resetOverride(for: .newTab)

        #expect(kb.overrides[WeirShortcutAction.newTab.rawValue] == nil)
        #expect(kb.shortcut(for: .newTab) == StoredShortcut(key: "t", modifiers: [.command]))
    }

    // MARK: - Validation

    @Test("Validate rejects a trigger already used by another action")
    func validate_conflictDetected() {
        let kb = KeyboardSettings()
        let occupied = StoredShortcut(key: "t", modifiers: [.command])
        let unused = StoredShortcut(key: "k", modifiers: [.command, .control, .shift])
        #expect(kb.validate(occupied, for: .closeSurface) == .conflict(.newTab))
        #expect(kb.validate(unused, for: .closeSurface) == .ok)
    }

    @Test func validate_rejectsTheQuickTerminalHotKey() {
        let hotKey = StoredShortcut(key: "`", modifiers: [.control])
        let keyboard = KeyboardSettings()
        #expect(keyboard.validate(hotKey, for: .newTab, quickTerminalHotKey: hotKey) == .quickTerminalConflict)
        #expect(keyboard.validate(hotKey, for: .newTab, quickTerminalHotKey: nil) == .ok)
        #expect(
            keyboard.validate(.init(key: "`", modifiers: [.command]), for: .newTab, quickTerminalHotKey: hotKey)
                == .ok
        )
    }

    // MARK: - Encoding shape

    /// Keep the stored characters that feed Ghostty's codepoint matching
    /// for layout-dependent keys such as `=` and `]`.
    @Test("Punctuation defaults are stored as literal characters")
    func encoding_punctuationDefaultsAreLiteral() throws {
        let increase = try #require(WeirShortcutAction.increaseFontSize.defaultShortcut)
        #expect(increase.key == "=")
        let decrease = try #require(WeirShortcutAction.decreaseFontSize.defaultShortcut)
        #expect(decrease.key == "-")
        let reset = try #require(WeirShortcutAction.resetFontSize.defaultShortcut)
        #expect(reset.key == "0")
        let nextSection = try #require(WeirShortcutAction.nextSession.defaultShortcut)
        #expect(nextSection.key == "]")
    }

    /// Re-saving an action's own current shortcut must not flag
    /// itself as a conflict. The recorder hits this when a user
    /// records the same key back into the same action — without the
    /// `other != action` filter in `validate` we'd refuse a no-op.
    @Test("Validate ignores self when checking conflicts")
    func validate_ignoresSelf() throws {
        var kb = KeyboardSettings()
        let current = try #require(WeirShortcutAction.newTab.defaultShortcut)
        kb.setOverride(current, for: .newTab)
        #expect(kb.validate(current, for: .newTab) == .ok)
    }

    /// An unused trigger is free. ⌘1 is reserved for the tab jump, and
    /// ⌘Q because Weir routes it through AppKit's terminate path (state
    /// save), which a binding would race. A bare letter would hijack every
    /// plain keypress of that character and break the terminal, so the
    /// recorder rejects it.
    @Test("validation accepts unused triggers and rejects reserved triggers or triggers without modifiers", arguments: [
        (StoredShortcut(key: "k", modifiers: [.command, .control, .shift]), ShortcutValidation.ok),
        (StoredShortcut(key: "1", modifiers: [.command]), .reserved),
        (StoredShortcut(key: "q", modifiers: [.command]), .reserved),
        (StoredShortcut(key: "k", modifiers: []), .missingModifier)
    ])
    func validate_distinguishesUnusedReservedAndBareTriggers(
        shortcut: StoredShortcut,
        result: ShortcutValidation
    ) {
        #expect(KeyboardSettings().validate(shortcut, for: .newTab) == result)
    }

    // MARK: - Persistence

    /// Old `settings.json` files written before the `keyboard`
    /// section existed must still decode — the root container drops
    /// `decode` for `keyboard` and uses `decodeIfPresent` exactly to
    /// keep the user's other (already-tuned) sections.
    @Test("Settings without a keyboard section decode with defaults")
    func decoder_keyboardMissingFallsBack() throws {
        let legacy = #"""
        {"schemaVersion":1,
         "appearance":{"accentColor":"default","backgroundOpacity":0.73,"transparency":"on"},
         "font":{"size":19,"ligatures":true,"lineHeight":0},
         "terminal":{},
         "advanced":{"ghosttyConfig":"on"}}
        """#
        let decoded = try JSONDecoder().decode(WeirSettings.self, from: Data(legacy.utf8))
        #expect(decoded.keyboard.overrides.isEmpty)
        #expect(decoded.keyboard.shortcut(for: .newTab) == StoredShortcut(key: "t", modifiers: [.command]))
        #expect(decoded.appearance.backgroundOpacity == 0.73)
        #expect(decoded.font.size == 19)
        #expect(decoded.font.ligatures)
        #expect(decoded.advanced.ghosttyConfig == .on)
    }

    @Test("ShortcutModifiers preserves unknown bits without displaying them")
    func decoder_modifiersTolerateUnknownBits() throws {
        let stored = Data("255".utf8)
        let decoded = try JSONDecoder().decode(ShortcutModifiers.self, from: stored)
        #expect(decoded.rawValue == 255)
        #expect(decoded.displaySymbols == "⌃⌥⇧⌘")
        #expect(decoded.ghosttyTokens == ["super", "ctrl", "alt", "shift"])

        let data = try JSONEncoder().encode(decoded)
        let mask = try #require(JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? Int)
        #expect(mask == 255)
    }
}
