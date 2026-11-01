// HeldKeyHintsTests.swift
// Weir — when the held-key hints come up and go, and which key a control shows.

import Foundation
import Testing
import WeirDomain
@testable import Weir

struct HeldKeyHintsTests {
    private func shown(_ chord: ShortcutModifiers = [.command]) -> HeldKeyHintMachine {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: chord)
        machine.delayElapsed(chord: chord, isAllowed: true)
        return machine
    }

    @Test func commandHeld_showsOnlyAfterTheWait() {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: [.command])
        #expect(machine.isWaiting)
        #expect(machine.shownChord == nil)
        machine.delayElapsed(chord: [.command], isAllowed: true)
        #expect(machine.shownChord == [.command])
    }

    @Test(arguments: [ShortcutModifiers.option, .shift, .control, [.option, .shift]])
    func withoutCommand_neverWaits(chord: ShortcutModifiers) {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: chord)
        #expect(machine.phase == .idle)
    }

    @Test func addingAModifier_followsTheChord() {
        var machine = shown()
        machine.modifiersChanged(to: [.command, .option])
        #expect(machine.shownChord == [.command, .option])
    }

    @Test func letGo_hides() {
        var machine = shown()
        machine.modifiersChanged(to: [])
        #expect(machine.phase == .idle)
    }

    @Test func keyDuringTheWait_cancelsUntilCommandIsLetGo() {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: [.command])
        machine.actionTaken()
        machine.delayElapsed(chord: [.command], isAllowed: true)
        #expect(machine.shownChord == nil)
        machine.modifiersChanged(to: [.command, .shift])
        #expect(machine.phase == .spent)
        machine.modifiersChanged(to: [])
        machine.modifiersChanged(to: [.command])
        #expect(machine.isWaiting)
    }

    @Test func actionWhileShown_hides() {
        var machine = shown()
        machine.actionTaken()
        #expect(machine.shownChord == nil)
    }

    @Test func actionWithNothingHeld_staysIdle() {
        var machine = HeldKeyHintMachine()
        machine.actionTaken()
        #expect(machine.phase == .idle)
    }

    @Test func keyUpLostToAnotherApp_doesNotShow() {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: [.command])
        machine.delayElapsed(chord: [], isAllowed: true)
        #expect(machine.phase == .idle)
    }

    @Test func notAllowed_staysDownUntilLetGo() {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: [.command])
        machine.delayElapsed(chord: [.command], isAllowed: false)
        #expect(machine.phase == .spent)
    }

    @Test func windowResigned_clears() {
        var machine = shown()
        machine.windowResigned()
        #expect(machine.phase == .idle)
    }

    @Test func capKey_onlyForTheExactChord() {
        let shortcut = StoredShortcut(key: "o", modifiers: [.command, .option])
        #expect(HeldKeyCapRule.key(of: shortcut, held: [.command]) == nil)
        #expect(HeldKeyCapRule.key(of: shortcut, held: [.command, .option]) == shortcut.displayTokens.last)
        #expect(HeldKeyCapRule.key(of: nil, held: [.command]) == nil)
    }

    @Test func capKey_followsARebinding() {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(StoredShortcut(key: "e", modifiers: [.command]), for: .toggleSidebar)
        let key = HeldKeyCapRule.key(of: keyboard.shortcut(for: .toggleSidebar), held: [.command])
        #expect(key == StoredShortcut(key: "e", modifiers: [.command]).displayTokens.last)
    }

    @Test func number_coversTheNineTheKeysReach() {
        #expect(HeldKeyCapRule.number(at: 0) == "1")
        #expect(HeldKeyCapRule.number(at: 8) == "9")
        #expect(HeldKeyCapRule.number(at: 9) == nil)
        #expect(HeldKeyCapRule.number(at: nil) == nil)
    }

    @Test func setting_defaultsOnAndRoundTrips() throws {
        var keyboard = try JSONDecoder().decode(KeyboardSettings.self, from: Data("{}".utf8))
        #expect(keyboard.showsHeldKeyHints)
        keyboard.showsHeldKeyHints = false
        let data = try JSONEncoder().encode(keyboard)
        #expect(try !JSONDecoder().decode(KeyboardSettings.self, from: data).showsHeldKeyHints)
    }
}

@MainActor
struct HeldKeyHintsStoreTests {
    /// The setting turned off from outside, with ⌘ held all the while, takes
    /// the keys down though no modifier key changed.
    @Test(.timeLimit(.minutes(1)))
    func turnedOff_takesTheKeysDown() async {
        let hints = HeldKeyHints()
        hints.modifiersChanged(to: [.command]) { ([.command], true) }
        var waited = 0
        while hints.shownChord == nil, waited < 100 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(hints.shownChord == [.command])
        hints.turnedOff()
        #expect(hints.shownChord == nil)
    }
}
