// NotificationHistoryDismissKeyTests.swift
// Weir — which Escape closes the notification history panel before the terminal under it sees the key.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct NotificationHistoryDismissKeyTests {
    private static let escape: UInt16 = 53

    @Test func escape_plainOrShifted_dismisses() throws {
        let plain = try NSEvent.testKeyDown(keyCode: Self.escape, characters: "\u{1B}")
        let shifted = try NSEvent.testKeyDown(keyCode: Self.escape, modifiers: .shift, characters: "\u{1B}")
        #expect(NotificationHistoryView.isDismissKey(plain))
        #expect(NotificationHistoryView.isDismissKey(shifted))
    }

    @Test func escape_withCommandControlOrOption_isLeftToTheWindow() throws {
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            let event = try NSEvent.testKeyDown(keyCode: Self.escape, modifiers: modifier, characters: "\u{1B}")
            #expect(!NotificationHistoryView.isDismissKey(event))
        }
    }

    @Test func commandDelete_isTheDeleteChord_withOrWithoutCapsLock() {
        let delete = NotificationHistoryView.deleteShortcut
        #expect(delete.isPressed(key: .backspacePress, modifiers: .command))
        #expect(delete.isPressed(key: .backspacePress, modifiers: [.command, .capsLock]))
        #expect(!delete.isPressed(key: .backspacePress, modifiers: []))
        #expect(!delete.isPressed(key: .backspacePress, modifiers: .capsLock))
    }

    /// A press of ⌫ carries U+007F, not the U+0008 of SwiftUI's `.delete`,
    /// and the handler hears both.
    @Test func commandDelete_hearsTheCharacterAPressOfBackspaceCarries() {
        let delete = NotificationHistoryView.deleteShortcut
        #expect(NotificationHistoryView.deleteKeys == [.backspacePress, .delete])
        #expect(delete.isPressed(key: .delete, modifiers: .command))
        #expect(!delete.isPressed(key: .deleteForward, modifiers: .command))
        #expect(!delete.isPressed(key: "a", modifiers: .command))
    }

    @Test func commandDelete_withAnotherModifier_isNotTheDeleteChord() {
        for extra: EventModifiers in [.control, .option, .shift] {
            #expect(!NotificationHistoryView.deleteShortcut.isPressed(key: .backspacePress, modifiers: [.command, extra]))
        }
    }

    @Test func otherKey_isLeftToTheWindow() throws {
        let event = try NSEvent.testKeyDown(keyCode: 0, characters: "a")
        #expect(!NotificationHistoryView.isDismissKey(event))
    }
}
