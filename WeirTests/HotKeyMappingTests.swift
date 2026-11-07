// HotKeyMappingTests.swift
// Weir — the quick terminal hotkey as Carbon registers it, and the system shortcuts it must not take.

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Weir

@Suite("HotKeyMapping")
@MainActor
struct HotKeyMappingTests {

    // MARK: - Hotkey mapping

    @Test("Named keys are layout independent and Return uses the main keyboard", arguments: [
        ("escape", UInt16(53)),
        ("f1", 122),
        ("up", 126),
        ("return", 36),
        ("enter", 36)
    ])
    func keyCode_namedKey_usesCaptureTable(key: String, expectedCode: UInt16) {
        #expect(HotKeyMapping.keyCode(for: key, translate: { _ in nil }) == expectedCode)
    }

    @Test func keyCode_letterResolvedThroughLayoutScan() {
        let translate = QuickTerminalKeyLayout.translate(QuickTerminalKeyLayout.us)
        #expect(HotKeyMapping.keyCode(for: "t", translate: translate) == 17)
        #expect(HotKeyMapping.keyCode(for: "]", translate: translate) == 30)
    }

    @Test func keyCode_digitOnTopRowAndKeypad_takesLowestKeyCode() {
        #expect(HotKeyMapping.keyCode(for: "1", translate: QuickTerminalKeyLayout.translate(QuickTerminalKeyLayout.us)) == 18)
    }

    @Test func keyCode_letterFollowsTheLayout() {
        // A layout that moves `t` elsewhere (as switching input sources
        // can) must move the registered keyCode with it.
        let moved: [UInt16: String] = [5: "t"]
        #expect(HotKeyMapping.keyCode(for: "t", translate: QuickTerminalKeyLayout.translate(moved)) == 5)
    }

    @Test func keyCode_characterMissingFromLayout_returnsNil() {
        #expect(HotKeyMapping.keyCode(for: "ß", translate: QuickTerminalKeyLayout.translate(QuickTerminalKeyLayout.us)) == nil)
    }

    @Test func keyCode_layoutScanSkipsNamedKeys() {
        // Named keys never stand for a layout character, even if a
        // translator returns one for them.
        let layout: [UInt16: String] = [36: "x", 40: "x"]
        #expect(HotKeyMapping.keyCode(for: "x", translate: QuickTerminalKeyLayout.translate(layout)) == 40)
    }

    @Test func keyCode_currentLayout_resolvesLettersWhenAvailable() throws {
        // Runs against the machine's real input source. A layout without
        // Unicode data has no translator; there is nothing to check then.
        guard let translate = StoredShortcut.currentLayoutTranslator() else {
            try Test.cancel("the current input source has no Unicode layout data")
        }
        let code = try #require(HotKeyMapping.keyCodeRange.first { code in
            NamedKey(keyCode: code) == nil && translate(code)?.isEmpty == false
        })
        let character = try #require(translate(code))
        let resolved = try #require(HotKeyMapping.keyCode(for: character, translate: translate))
        #expect(translate(resolved)?.lowercased() == character.lowercased())
    }

    @Test func carbonModifiers_mapEachModifier() {
        #expect(HotKeyMapping.carbonModifiers(for: [.command]) == UInt32(cmdKey))
        #expect(HotKeyMapping.carbonModifiers(for: [.shift]) == UInt32(shiftKey))
        #expect(HotKeyMapping.carbonModifiers(for: [.option]) == UInt32(optionKey))
        #expect(HotKeyMapping.carbonModifiers(for: [.control]) == UInt32(controlKey))
        #expect(
            HotKeyMapping.carbonModifiers(for: [.command, .shift, .option, .control])
                == UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        #expect(HotKeyMapping.carbonModifiers(for: []) == 0)
    }

    @Test func combination_joinsKeyCodeAndModifiers() {
        let shortcut = StoredShortcut(key: "t", modifiers: [.control, .option])
        let combination = HotKeyMapping.combination(for: shortcut, translate: QuickTerminalKeyLayout.translate(QuickTerminalKeyLayout.us))
        #expect(combination == HotKeyCombination(keyCode: 17, carbonModifiers: UInt32(controlKey | optionKey)))
    }

    // MARK: - System hotkeys

    private static func symbolicEntry(code: Int, modifiers: Int, isEnabled: Bool = true) -> [String: Any] {
        [
            kHISymbolicHotKeyCode as String: NSNumber(value: code),
            kHISymbolicHotKeyModifiers as String: NSNumber(value: modifiers),
            kHISymbolicHotKeyEnabled as String: isEnabled
        ]
    }

    /// The entry mask is Carbon's, so a system entry and the combination
    /// we would register for the same keys compare equal. Values are the
    /// ones macOS 27 reports for Spotlight (⌘Space) and the ⌘⇧3 screenshot.
    @Test func systemHotKeys_modifiersMatchRegisteredCarbonFormat() {
        let parsed = SystemHotKeys.combinations(from: [
            Self.symbolicEntry(code: 49, modifiers: 0x100),
            Self.symbolicEntry(code: 20, modifiers: 0x300)
        ])
        let spotlight = HotKeyMapping.combination(
            for: .init(key: "space", modifiers: [.command]),
            translate: { _ in nil }
        )
        let screenshot = HotKeyMapping.combination(
            for: .init(key: "3", modifiers: [.command, .shift]),
            translate: QuickTerminalKeyLayout.translate([20: "3"])
        )
        let expectedSpotlight = HotKeyCombination(keyCode: 49, carbonModifiers: UInt32(cmdKey))
        let expectedScreenshot = HotKeyCombination(keyCode: 20, carbonModifiers: UInt32(cmdKey | shiftKey))
        #expect(spotlight == expectedSpotlight)
        #expect(screenshot == expectedScreenshot)
        #expect(parsed == [expectedSpotlight, expectedScreenshot])
    }

    @Test func systemHotKeys_disabledAndUnassignedEntries_areSkipped() {
        let invalid = [
            Self.symbolicEntry(code: 49, modifiers: 0x100, isEnabled: false),
            Self.symbolicEntry(code: 0xFFFF, modifiers: 0x100),
            ["unexpected": 1]
        ]
        #expect(SystemHotKeys.combinations(from: invalid).isEmpty)
        let parsed = SystemHotKeys.combinations(from: invalid + [Self.symbolicEntry(code: 20, modifiers: 0x300)])
        #expect(parsed == [HotKeyCombination(keyCode: 20, carbonModifiers: UInt32(cmdKey | shiftKey))])
    }

    /// Arrows and F-keys always carry the fn bit, so ⌃↑ (Mission Control,
    /// reported as 0x21000) must still match our ⌃↑.
    @Test func systemHotKeys_fnBitOnFunctionKey_isDropped() {
        let parsed = SystemHotKeys.combinations(from: [Self.symbolicEntry(code: 126, modifiers: 0x21000)])
        #expect(parsed == [HotKeyCombination(keyCode: 126, carbonModifiers: UInt32(controlKey))])
        #expect(SystemHotKeys.contains(.init(key: "up", modifiers: [.control]), in: parsed, translate: { _ in nil }))
    }

    /// On a letter the fn bit means Globe is part of the shortcut (Globe⌃F
    /// fills the window), which our hotkey can never be.
    @Test func systemHotKeys_fnBitOnLetter_isSkipped() {
        let parsed = SystemHotKeys.combinations(from: [Self.symbolicEntry(code: 3, modifiers: 0x21000)])
        #expect(parsed.isEmpty)
    }

    @Test func systemHotKeys_contains_resolvesThroughTheLayout() {
        let system: Set = [HotKeyCombination(keyCode: 40, carbonModifiers: UInt32(controlKey | cmdKey))]
        let translate = QuickTerminalKeyLayout.translate(QuickTerminalKeyLayout.us)
        #expect(SystemHotKeys.contains(.init(key: "k", modifiers: [.command, .control]), in: system, translate: translate))
        #expect(!SystemHotKeys.contains(.init(key: "k", modifiers: [.command]), in: system, translate: translate))
        #expect(!SystemHotKeys.contains(.init(key: "ß", modifiers: [.command, .control]), in: system, translate: translate))
    }
}
