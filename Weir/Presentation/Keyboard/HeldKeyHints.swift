// HeldKeyHints.swift
// Weir — which keys a window shows on its controls while ⌘ is held.

import Foundation
import Observation
import WeirDomain

/// When the keys come up and go. ⌘ held on its own for a moment asks what can
/// be pressed; a key or a click with it is the person already doing something,
/// and the keys stay down until ⌘ is let go, so they do not come back between
/// two shortcuts pressed under one held ⌘.
struct HeldKeyHintMachine: Equatable {
    enum Phase: Equatable {
        case idle
        case waiting(ShortcutModifiers)
        case shown(ShortcutModifiers)
        /// ⌘ is still down from something it was used for.
        case spent
    }

    private(set) var phase = Phase.idle

    /// The modifier keys the keys are shown for; `nil` while none are.
    var shownChord: ShortcutModifiers? {
        if case let .shown(chord) = phase {
            return chord
        }
        return nil
    }

    var isWaiting: Bool {
        if case .waiting = phase {
            return true
        }
        return false
    }

    /// Every hint needs ⌘ in the chord: ⌥ or ⇧ alone are the terminal's and
    /// the input method's, and held all the time.
    mutating func modifiersChanged(to chord: ShortcutModifiers) {
        guard chord.contains(.command) else {
            phase = .idle
            return
        }
        switch phase {
        case .idle, .waiting:
            phase = .waiting(chord)
        case .shown:
            phase = .shown(chord)
        case .spent:
            break
        }
    }

    /// A key, a click, or a scroll.
    mutating func actionTaken() {
        if phase != .idle {
            phase = .spent
        }
    }

    /// The wait is over. `chord` is read afresh: a key-up lost to another app
    /// must not bring the keys up with nothing held.
    mutating func delayElapsed(chord: ShortcutModifiers, isAllowed: Bool) {
        guard isWaiting else { return }
        guard chord.contains(.command) else {
            phase = .idle
            return
        }
        phase = isAllowed ? .shown(chord) : .spent
    }

    /// The window stopped being the one the keyboard goes to.
    mutating func windowResigned() {
        phase = .idle
    }
}

/// The key a control shows for `shortcut` while `held` is down: the last key
/// alone, and only if `held` is exactly what the shortcut needs, so what is on
/// screen is what pressing that key does now.
enum HeldKeyCapRule {
    static func key(of shortcut: StoredShortcut?, held: ShortcutModifiers) -> String? {
        guard let shortcut, shortcut.modifiers == held else { return nil }
        return shortcut.displayTokens.last
    }

    /// The number ⌘n or ⌃⌘n goes to `index` by, for the nine it reaches.
    static func number(at index: Int?) -> String? {
        guard let index, (0..<9).contains(index) else { return nil }
        return String(index + 1)
    }
}

/// One window's keys on show (`HeldKeyHintMonitor` feeds it). Per window, since
/// only the window with the keyboard hears the modifier keys.
@MainActor
@Observable
final class HeldKeyHints {
    /// How long ⌘ rests before the keys come up: past a shortcut pressed at
    /// an ordinary pace, so ⌘C in a terminal does not flash them.
    static let delay: Duration = .milliseconds(300)

    private(set) var shownChord: ShortcutModifiers?
    @ObservationIgnored private var machine = HeldKeyHintMachine()
    /// The running wait; `nil` outside one.
    @ObservationIgnored private var delayTask: Task<Void, Never>?

    /// `check` is asked when the wait ends: what is held by then, and whether
    /// the window has room for the keys.
    func modifiersChanged(to chord: ShortcutModifiers, check: @escaping @MainActor () -> (chord: ShortcutModifiers, isAllowed: Bool)) {
        machine.modifiersChanged(to: chord)
        settle()
        guard machine.isWaiting, delayTask == nil else { return }
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            delayTask = nil
            let reading = check()
            machine.delayElapsed(chord: reading.chord, isAllowed: reading.isAllowed)
            settle()
        }
    }

    func actionTaken() {
        machine.actionTaken()
        settle()
    }

    func windowResigned() {
        machine.windowResigned()
        settle()
    }

    /// The setting went off, or a file reload turned it off, with keys up.
    func turnedOff() {
        machine.windowResigned()
        settle()
    }

    /// Written only on a change: every control on the window reads it.
    private func settle() {
        if !machine.isWaiting {
            delayTask?.cancel()
            delayTask = nil
        }
        if shownChord != machine.shownChord {
            shownChord = machine.shownChord
        }
    }
}
