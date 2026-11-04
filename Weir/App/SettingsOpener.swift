// SettingsOpener.swift
// Weir — the one way into the Settings window, from every menu, row, and button.

import SwiftUI

/// Opens the Settings window, on a section or on the one it showed last.
///
/// Every place that offers Settings opens it through this: the app menu's
/// Settings… (⌘,), the rail, the menu bar item, the palette's rows, the
/// keyboard shortcut list's Customize…, the alert that settings are not
/// being saved, and the screen a libghostty failure leaves. The Settings
/// scene is a SwiftUI `Window(id:)`, which only `OpenWindowAction` opens,
/// and only a view can read one; every one of those places is a view, so
/// each hands in its own when it opens Settings. We take it at the call
/// rather than broadcast a request for some mounted view to hear. A
/// broadcast is heard by every main window, so each one asks the scene to
/// open, and nothing hears it while no main window's chrome is mounted.
///
/// Opening does not make Weir active: the verification channel's
/// `settings.*` commands open Settings behind the person's windows. The
/// menu bar item, which leaves another app in front, makes Weir active
/// itself first (`MenuBarActions.openSettings`).
@MainActor
struct SettingsOpener {
    private let openWindow: @MainActor (String) -> Void
    private let rememberSection: @MainActor (SettingsSection) -> Void

    /// The opener a view uses, with the view's `openWindow`.
    init(_ openWindow: OpenWindowAction) {
        self.init(
            openWindow: { openWindow(id: $0) },
            rememberSection: { UserDefaults.standard.set($0.rawValue, forKey: SettingsSection.lastSectionDefaultsKey) }
        )
    }

    /// Each effect as its own closure, so a test sees what opening did.
    init(
        openWindow: @escaping @MainActor (String) -> Void,
        rememberSection: @escaping @MainActor (SettingsSection) -> Void
    ) {
        self.openWindow = openWindow
        self.rememberSection = rememberSection
    }

    /// Opens Settings on `section`, or on the section it showed last for
    /// nil. The Settings scene reads the section it opens on from
    /// `SettingsSection.lastSectionDefaultsKey`, so the section is written
    /// before the window opens.
    func open(_ section: SettingsSection? = nil) {
        if let section {
            rememberSection(section)
        }
        openWindow(WeirApp.settingsWindowID)
    }
}
