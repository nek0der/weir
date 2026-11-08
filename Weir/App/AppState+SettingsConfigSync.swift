// AppState+SettingsConfigSync.swift
// Weir — bridge `SettingsStore.settings` into libghostty's live
// reload path. Lives outside `WeirApp.swift` so the host file stays
// under the SwiftLint file-length warning band; the call site is
// `AppState.init`'s `startSettingsConfigSync()`.

import AppKit
import Foundation

extension AppState {
    /// Bridge `SettingsStore.settings` → libghostty live reload.
    /// Observation tracking re-runs on every settings mutation; we
    /// diff against `lastAppliedSettings` so dragging a slider that
    /// settles back to the original value doesn't churn libghostty.
    func startSettingsConfigSync() {
        // The terminal started from these settings, so a later change that
        // returns to them is already in effect and needs no reload.
        if ghosttyApp != nil, lastAppliedConfigKey == nil {
            lastAppliedConfigKey = ghosttyConfigKey(for: lastAppliedSettings)
        }
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = self.settingsStore.settings
        } onChange: { [weak self] in
            guard let self else { return }
            let current = self.settingsStore.settings
            guard current != self.lastAppliedSettings else { return }
            // Apply UI-only updates (transparency resolver, color
            // scheme) immediately — they're cheap and the Liquid Glass
            // surfaces should track the user's intent without the debounce
            // window. Defer the libghostty reload through the debounce
            // so a slider drag collapses into one apply.
            self.reduceTransparencyResolver.apply(
                userEnabled: current.appearance.transparency.isOn
            )
            Self.applyColorScheme(current.appearance.colorScheme)
            self.syncGhosttyColorScheme()
            self.scheduleSettingsReload()
        }
    }

    /// Re-arm a debounced libghostty reload that fires after a short
    /// idle window. Reads the latest settings value at fire time so a
    /// slider drag collapses into one apply.
    func scheduleSettingsReload() {
        settingsReloadDebounceTask?.cancel()
        settingsReloadDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: PersistenceTiming.interactive)
            guard !Task.isCancelled, let self else { return }
            let latest = self.settingsStore.settings
            guard latest != self.lastAppliedSettings else { return }
            self.lastAppliedSettings = latest
            self.applyGhosttyConfig(latest)
        }
    }

    /// Reads the person's Ghostty config again after an edit to that file,
    /// or retries a failed reload even when the settings have not changed.
    func reloadGhosttyUserConfig() {
        applyGhosttyConfig(settingsStore.settings, isForced: true)
    }

    private func applyGhosttyConfig(_ settings: WeirSettings, isForced: Bool = false) {
        guard let ghosttyApp else { return }
        let resourcesDir = GhosttyApp.resolveResourcesDir()
        let includeUserConfig = settings.advanced.ghosttyConfig.isOn
        let key = ghosttyConfigKey(for: settings)
        if !isForced, key == lastAppliedConfigKey {
            // The terminal already runs what the settings ask for, so a
            // warning left by a reload that a later change undid is stale.
            settingsStore.ghosttyConfigReloadError = nil
            lastFailedConfigKey = nil
            return
        }

        do {
            settingsStore.ghosttyConfigDiagnostics = try GhosttyConfigBridge.reloadConfig(
                settings: settings,
                resourcesDir: resourcesDir,
                includeUserConfig: includeUserConfig,
                install: { ghosttyApp.replaceConfig(with: $0, surfaces: allSurfaceViews) }
            )
            lastAppliedConfigKey = key
            lastFailedConfigKey = nil
            settingsStore.ghosttyConfigReloadError = nil
            syncSecureInputPreference(from: ghosttyApp)
        } catch {
            settingsStore.ghosttyConfigReloadError = error
            // An unrelated settings save tries the failed key again; the
            // person has been told once, and Retry tells them again.
            let isRepeat = !isForced && key == lastFailedConfigKey
            lastFailedConfigKey = key
            if !isRepeat, !NSApp.windows.contains(where: { $0.isVisible && $0.isWeirSettingsWindow }) {
                toastCenter.showInFrontWindow(ToastItem(message: error.message, undo: nil))
            }
        }
    }

    /// What libghostty receives for `settings`, compared so edits to
    /// Weir-only settings do not rebuild the terminal configuration.
    private func ghosttyConfigKey(for settings: WeirSettings) -> String {
        GhosttyConfigBridge.makeConfigString(
            settings: settings,
            resourcesDir: GhosttyApp.resolveResourcesDir()
        ) + "\n# includeUserConfig=\(settings.advanced.ghosttyConfig.isOn)"
    }

    func makeGhosttyEventCoordinator() -> GhosttyEventCoordinator {
        GhosttyEventCoordinator(
            ghosttyApp: ghosttyApp,
            session: session,
            registry: registry,
            notificationManager: notificationManager,
            bellFeaturesProvider: { [settingsStore] in
                BellFeatures.forAction(settingsStore.settings.terminal.bellAction)
            },
            secureInputManager: registry.secureInputManager,
            attention: attention,
            claimsSurfaceExit: { [weak quickTerminal] view in
                quickTerminal?.handleSurfaceExit(view) == true
            },
            commandWindow: { [windowRegistry] in
                windowRegistry.backgroundCommandTarget.id
            },
            linkOpener: TerminalLinkOpener(
                notify: { [toastCenter] message in
                    toastCenter.showInFrontWindow(ToastItem(message: message, undo: nil))
                },
                fileApplication: { [settingsStore] in
                    FileOpener.chosenApplication(in: settingsStore)
                },
                locale: { [settingsStore] in
                    settingsStore.appLocale
                },
                presentAlert: { alert, window, completion in
                    WindowAlert.begin(alert, on: window, completion: completion)
                }
            ),
            // What a pane runs in front changes as a command starts, which
            // its title marks, and as it ends.
            onTitleChanged: { [weak self] paneID in
                self?.paneAgentsInFront.titleChanged(inPane: paneID)
            },
            onCommandFinished: { [weak self] paneID, exitCode, durationNs in
                self?.paneAgentsInFront.commandFinished(inPane: paneID)
                // A resume whose command came back to the shell failed: the
                // bar says so at once, not at the deadline. One typed at
                // launch becomes a stop the list did not have.
                guard let self,
                      stopLedger.resumeCommandFinished(inPane: paneID, exitCode: exitCode, durationNs: durationNs) != nil
                else { return }
                refreshAttentionQueue()
                refreshStopResumeOffers()
            },
            programStatus: programStatus,
            agentProjection: agentProjection
        )
    }

    func syncSecureInputPreference(from app: GhosttyApp?) {
        registry.secureInputManager.setAutomaticEnabled(
            app?.isAutomaticSecureInputEnabled ?? true
        )
    }

    func syncGhosttyColorScheme() {
        guard let ghosttyApp else { return }
        let colorScheme = GhosttyApp.currentColorScheme(
            preference: settingsStore.settings.appearance.colorScheme
        )
        ghosttyApp.setColorScheme(colorScheme, surfaces: allSurfaceViews)
    }
}
