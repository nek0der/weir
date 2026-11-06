// SavingSuspendedAlert.swift
// Weir — the alert that settings are not being saved, or that a save failed.

import SwiftUI

/// Tells, once and in one window (`AppState.savingNoticeWindowID`), that
/// this launch cannot save the settings or some of Weir's own files, or
/// that a save of the sessions or the settings failed
/// (`SavingSuspendedNotice.alert`). The same notice
/// stays at the top of Settings → General, which Open Settings goes to.
private struct SavingSuspendedAlertModifier: ViewModifier {
    let state: AppState
    /// Whether this window tells it: one window, not every one.
    let isShown: Bool
    @Environment(\.openWindow) private var openWindow

    private var notice: SavingSuspendedNotice? {
        SavingSuspendedNotice.alert(
            launchSettings: state.launchSavingSuspension,
            launchStores: state.launchSuspendedStores,
            failedSessionFile: state.isSaveFailureAlertPending ? state.savingStatus.failedSessionFile : nil,
            isSettingsSaveFailing: state.isSaveFailureAlertPending && state.settingsStore.hasFailedToSave,
            settingsFile: state.settingsStore.settingsFileURL,
            locale: state.settingsStore.appLocale
        )
    }

    /// The settings first, as the alert has always named them; then the
    /// smaller stores the launch found; then a failing save.
    private func title(locale: Locale) -> String {
        if state.launchSavingSuspension != nil {
            SavingSuspendedText.launchTitle(locale: locale)
        } else if !state.launchSuspendedStores.isEmpty {
            SavingSuspendedText.storesTitle(locale: locale)
        } else {
            SavingSuspendedText.saveFailedTitle(locale: locale)
        }
    }

    func body(content: Content) -> some View {
        let locale = state.settingsStore.appLocale
        content.alert(
            Text(verbatim: title(locale: locale)),
            isPresented: Binding(
                get: { isShown && notice != nil },
                set: {
                    // Only this window's own dismissal: one the alert left
                    // for another window is not an answer.
                    if !$0, isShown {
                        state.dismissSavingNotice()
                    }
                }
            ),
            presenting: notice
        ) { _ in
            Button(SavingSuspendedText.openSettings(locale: locale)) {
                state.dismissSavingNotice()
                SettingsOpener(openWindow).open(.general)
            }
            Button("OK", role: .cancel) {
                state.dismissSavingNotice()
            }
        } message: { notice in
            Text(verbatim: notice.sentences.joined(separator: "\n\n"))
        }
    }
}

extension View {
    /// The alert that settings are not being saved, or that a save failed
    /// (`SavingSuspendedAlertModifier`).
    func savingSuspendedAlert(state: AppState, isShown: Bool) -> some View {
        modifier(SavingSuspendedAlertModifier(state: state, isShown: isShown))
    }
}
