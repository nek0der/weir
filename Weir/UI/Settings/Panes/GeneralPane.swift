// GeneralPane.swift
// Weir — first Settings pane. Hosts the language picker + Sparkle
// auto-update controls.
//
// Form layout follows the macOS 26 System Settings convention:
// `Form` + `.formStyle(.grouped)` puts each `Section` in a rounded
// card; in-row controls (Picker, Toggle) provide their own label via
// the first argument; secondary copy lives in the Section footer.

import AppKit
import Sparkle
import SwiftUI

struct GeneralPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.updaterStack) private var updaterStack

    var body: some View {
        @Bindable var settings = settings
        SettingsForm(title: "General", section: .general) {
            SavingSuspendedSection()

            Section {
                Picker("Display Language", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.localizedTitle).tag(lang)
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.displayLanguage.id)
                // The menu bar only takes a new language at launch, so the
                // change offers the relaunch it waits for.
                if settings.needsRelaunchForLanguage {
                    RelaunchRow(reason: "The menu bar changes language when Weir relaunches.")
                }
            } header: {
                Text("Language")
            } footer: {
                SettingsFootnote("App content updates immediately. The macOS menu bar updates on next launch.")
            }

            Section {
                SettingsToggle("Show in menu bar", isOn: $settings.settings.general.showMenuBarExtra)
                    .settingsSearchTarget(SettingsSearchCatalog.menuBarExtra.id)
            } header: {
                Text("Menu Bar")
            } footer: {
                SettingsFootnote(
                    """
                    Lists what needs your attention. Short commands can be allowed or denied there; \
                    anything else opens in Weir.
                    """
                )
            }

            Section {
                SettingsToggle(
                    "Notify when a usage limit resets",
                    isOn: $settings.settings.general.notifyOnUsageLimitReset
                )
                .settingsSearchTarget(SettingsSearchCatalog.usageLimitReset.id)
            } header: {
                Text("Usage Limits")
            } footer: {
                SettingsFootnote("When an agent stops at its plan’s usage limit, a notification arrives at the time the limit resets.")
            }

            ConfirmationsSection()

            FileApplicationSection()

            if let updaterStack {
                UpdatesSection(updaterStack: updaterStack)
            }

            AboutSection()
        }
    }
}

/// Tells, above everything else in the pane, that this launch has stopped
/// saving one of the app's files or that a save failed
/// (`SavingSuspendedNotice`), with a way to the files the person has to
/// act on. Absent while every one is saved.
private struct SavingSuspendedSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.savingStatus) private var savingStatus
    @Environment(\.locale) private var locale

    var body: some View {
        if let notice = SavingSuspendedNotice.make(
            status: savingStatus,
            settings: settings.savingSuspension,
            isSettingsSaveFailing: settings.hasFailedToSave,
            settingsFile: settings.settingsFileURL,
            locale: locale
        ) {
            Section {
                ForEach(notice.sentences, id: \.self) { sentence in
                    Label {
                        Text(verbatim: sentence)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // The sentence carries the meaning; the symbol only
                        // draws the eye to it.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SupervisionTokens.waiting.color)
                            .accessibilityHidden(true)
                    }
                }
                SettingsButtonRow {
                    Button(SavingSuspendedText.showFiles(locale: locale)) {
                        // The files, or their folder when none of them is
                        // there any more: moved out by hand, as the notice
                        // asks.
                        FinderReveal.select(notice.files)
                    }
                }
            }
        }
    }
}

/// Four pickers. The keyboard / mouse split for tab close is
/// intentional — the × button is the most mis-clicked affordance in
/// the app, so users tend to want it stricter than the deliberate
/// ⌘W / ⌘⌥W keystroke. ⌘Q is app-wide. Pane close has no mouse
/// path, so it sits as a single knob.
private struct ConfirmationsSection: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            policyPicker(
                "Quit Weir",
                id: SettingsSearchCatalog.confirmationQuit.id,
                binding: $settings.settings.confirmations.quit,
                setting: \.confirmations.quit
            )
            policyPicker(
                "Close Tab (Keyboard)",
                id: SettingsSearchCatalog.confirmationCloseTabKeyboard.id,
                binding: $settings.settings.confirmations.closeTabKeyboard,
                setting: \.confirmations.closeTabKeyboard
            )
            policyPicker(
                "Close Tab (× Button)",
                id: SettingsSearchCatalog.confirmationCloseTabMouse.id,
                binding: $settings.settings.confirmations.closeTabMouse,
                setting: \.confirmations.closeTabMouse
            )
            policyPicker(
                "Close Pane",
                id: SettingsSearchCatalog.confirmationClosePane.id,
                binding: $settings.settings.confirmations.closePane,
                setting: \.confirmations.closePane
            )
        } header: {
            Text("Action Confirmations")
        } footer: {
            SettingsFootnote("“Only while an agent is running” asks only when an agent Weir tracks is running in that pane.")
        }
    }

    private func policyPicker(
        _ title: LocalizedStringKey,
        id: String,
        binding: Binding<ConfirmPolicy>,
        setting: KeyPath<WeirSettings, ConfirmPolicy>
    ) -> some View {
        Picker(title, selection: binding) {
            ForEach(ConfirmPolicy.allCases, id: \.self) { policy in
                SettingsDefaultMark.title(Text(policy.localizedTitle), value: policy, of: setting).tag(policy)
            }
        }
        .settingsSearchTarget(id)
    }
}

/// Footer card that mirrors what the standard About panel shows. Lets
/// users grab the version for bug reports without leaving Settings.
private struct AboutSection: View {
    var body: some View {
        Section {
            HStack(spacing: 12) {
                Text("Weir")
                Spacer(minLength: 12)
                Text(Self.versionString)
                    .foregroundStyle(SettingsFootnote.style.color)
                    .textSelection(.enabled)
                    .monospacedDigit()
            }
            .settingsControlRow(controlHeight: WeirLayout.settingsTextRowControlHeight)
            .settingsSearchTarget(SettingsSearchCatalog.appVersion.id)
        }
    }

    private static let versionString: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? short : "\(short) (\(build))"
    }()
}

/// The Sparkle auto-update controls. They live in their own struct
/// because the auto-check toggle binds through Sparkle's own KVO-backed
/// setter (not the `WeirSettings` JSON path), and "Check Now" starts its
/// check through `UpdaterStack.checkForUpdates()`, as the menu does.
private struct UpdatesSection: View {
    let updaterStack: UpdaterStack
    @State private var isAutoCheckEnabled: Bool
    @Environment(UpdateStateModel.self) private var stateModel

    private var updater: SPUUpdater {
        updaterStack.updater
    }

    init(updaterStack: UpdaterStack) {
        self.updaterStack = updaterStack
        self._isAutoCheckEnabled = State(initialValue: updaterStack.updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Section {
            SettingsToggle("Automatically check for updates", isOn: Binding(
                get: { isAutoCheckEnabled },
                set: { newValue in
                    isAutoCheckEnabled = newValue
                    updater.automaticallyChecksForUpdates = newValue
                }
            ))
            .settingsSearchTarget(SettingsSearchCatalog.automaticUpdates.id)
            HStack(spacing: 12) {
                Text("Updates")
                Spacer(minLength: 12)
                // We don't gate this on Sparkle's `canCheckForUpdates`,
                // which stays false while a session is open, including
                // one that only shows its result. A check asked for then
                // waits for that session to end
                // (`UpdaterStack.checkForUpdates()`), so the button
                // stays on.
                Button("Check Now…") {
                    updaterStack.checkForUpdates()
                }
                .disabled(stateModel.disablesCheckForUpdates)
            }
            .settingsControlRow()
            .settingsSearchTarget(SettingsSearchCatalog.checkForUpdates.id)
            // Inline the same state-driven popover content underneath
            // the button so a user who initiated the check from
            // Settings sees the result here, not just on the update control
            // of the main window. The view is hidden while `.idle` so
            // the section collapses back to its resting size when no
            // check is in flight.
            if case .idle = stateModel.state {
                EmptyView()
            } else {
                UpdatePopover(dismiss: {
                    stateModel.show(.idle)
                }, width: nil)
                    .environment(\.updatePopoverMetrics, .settingsRow)
            }
        } header: {
            Text("Software Update")
        }
    }
}
