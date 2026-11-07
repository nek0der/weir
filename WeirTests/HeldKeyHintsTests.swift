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

    @Test("An action during a hold suppresses hints until Command is released", arguments: [false, true])
    func actionDuringHold_spendsTheChord(isShown: Bool) throws {
        var machine = holdingCommand(isShown: isShown)
        try #require(machine.phase == (isShown ? .shown([.command]) : .waiting([.command])))

        machine.actionTaken()
        machine.delayElapsed(chord: [.command], isAllowed: true)
        expectSpentUntilRelease(&machine)
    }

    @Test func actionWithNothingHeld_doesNotSpendTheNextHold() {
        var machine = HeldKeyHintMachine()
        machine.actionTaken()
        #expect(machine.phase == .idle)

        machine.modifiersChanged(to: [.command])
        #expect(machine.phase == .waiting([.command]))
    }

    @Test func keyUpLostToAnotherApp_doesNotShow() {
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: [.command])
        machine.delayElapsed(chord: [], isAllowed: true)
        #expect(machine.phase == .idle)
    }

    @Test func notAllowed_staysDownUntilLetGo() throws {
        var machine = holdingCommand(isShown: false)
        try #require(machine.phase == .waiting([.command]))
        machine.delayElapsed(chord: [.command], isAllowed: false)
        expectSpentUntilRelease(&machine)
    }

    @Test(
        "Releasing Command or resigning the window clears pending and shown hints",
        arguments: [false, true],
        [false, true]
    )
    func endingHold_clearsHints(isShown: Bool, resignsWindow: Bool) throws {
        var machine = holdingCommand(isShown: isShown)
        try #require(machine.phase == (isShown ? .shown([.command]) : .waiting([.command])))
        if resignsWindow {
            machine.windowResigned()
        } else {
            machine.modifiersChanged(to: [])
        }
        #expect(machine.phase == .idle)
        #expect(machine.shownChord == nil)

        machine.delayElapsed(chord: [.command], isAllowed: true)
        #expect(machine.phase == .idle)
        #expect(machine.shownChord == nil)
    }

    private func holdingCommand(isShown: Bool) -> HeldKeyHintMachine {
        if isShown {
            return shown()
        }
        var machine = HeldKeyHintMachine()
        machine.modifiersChanged(to: [.command])
        return machine
    }

    private func expectSpentUntilRelease(_ machine: inout HeldKeyHintMachine) {
        #expect(machine.phase == .spent)
        #expect(machine.shownChord == nil)
        machine.modifiersChanged(to: [.command, .shift])
        machine.delayElapsed(chord: [.command, .shift], isAllowed: true)
        #expect(machine.phase == .spent)
        #expect(machine.shownChord == nil)

        machine.modifiersChanged(to: [])
        #expect(machine.phase == .idle)
        machine.modifiersChanged(to: [.command])
        #expect(machine.phase == .waiting([.command]))
    }

    @Test func capKey_onlyForTheExactEffectiveChord() {
        let shortcut = StoredShortcut(key: "o", modifiers: [.command, .option])
        #expect(HeldKeyCapRule.key(of: shortcut, held: [.command]) == nil)
        #expect(HeldKeyCapRule.key(of: shortcut, held: [.command, .option, .shift]) == nil)
        #expect(HeldKeyCapRule.key(of: shortcut, held: [.command, .option]) == "O")

        var keyboard = KeyboardSettings()
        keyboard.setOverride(StoredShortcut(key: "e", modifiers: [.command]), for: .toggleSidebar)
        #expect(HeldKeyCapRule.key(of: keyboard.shortcut(for: .toggleSidebar), held: [.command]) == "E")

        keyboard.unassign(.toggleSidebar)
        #expect(HeldKeyCapRule.key(of: keyboard.shortcut(for: .toggleSidebar), held: [.command]) == nil)
    }

    @Test func number_coversTheNineTheKeysReach() {
        #expect(HeldKeyCapRule.number(at: 0) == "1")
        #expect(HeldKeyCapRule.number(at: 8) == "9")
        #expect(HeldKeyCapRule.number(at: 9) == nil)
        #expect(HeldKeyCapRule.number(at: nil) == nil)
    }

    @Test func setting_defaultsOnAndRoundTrips() throws {
        #expect(KeyboardSettings().showsHeldKeyHints)
        var keyboard = try JSONDecoder().decode(KeyboardSettings.self, from: Data("{}".utf8))
        #expect(keyboard.showsHeldKeyHints)
        keyboard.showsHeldKeyHints = false
        let data = try JSONEncoder().encode(keyboard)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["showsHeldKeyHints"] as? Bool == false)
        #expect(try !JSONDecoder().decode(KeyboardSettings.self, from: data).showsHeldKeyHints)
        let disabled = Data(#"{"showsHeldKeyHints":false}"#.utf8)
        #expect(try !JSONDecoder().decode(KeyboardSettings.self, from: disabled).showsHeldKeyHints)
    }
}

@MainActor
struct HeldKeyHintsStoreTests {
    @Test(.timeLimit(.minutes(1)))
    func turnedOff_takesTheKeysDown() async throws {
        let hints = HeldKeyHints()
        hints.modifiersChanged(to: [.command]) { ([.command], true) }
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(50)) { hints.shownChord != nil }
        try #require(hints.shownChord == [.command])

        hints.turnedOff()
        #expect(hints.shownChord == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func turnedOff_discardsThePendingHold() async {
        let hints = HeldKeyHints()
        var staleChecks = 0
        hints.modifiersChanged(to: [.command]) {
            staleChecks += 1
            return ([.command], true)
        }

        hints.turnedOff()
        #expect(hints.shownChord == nil)

        hints.modifiersChanged(to: [.command, .option]) { ([.command, .option], true) }
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(50)) { hints.shownChord != nil }
        #expect(hints.shownChord == [.command, .option])
        #expect(staleChecks == 0)
    }
}
