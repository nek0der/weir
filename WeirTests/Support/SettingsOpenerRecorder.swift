// SettingsOpenerRecorder.swift
// Weir — a Settings opener that records what opening did, in order, with no window and no defaults.

import Foundation
@testable import Weir

/// What a `SettingsOpener` did, in the order it did it.
enum SettingsOpenerEvent: Equatable {
    case rememberSection(SettingsSection)
    case openWindow(String)
}

/// Hands out a `SettingsOpener` whose effects land in `events`: the
/// section it would write to `UserDefaults` and the window it would open,
/// so a test writes nothing under `~/Library`.
@MainActor
final class SettingsOpenerRecorder {
    private(set) var events: [SettingsOpenerEvent] = []

    var opener: SettingsOpener {
        SettingsOpener(
            openWindow: { self.events.append(.openWindow($0)) },
            rememberSection: { self.events.append(.rememberSection($0)) }
        )
    }
}
