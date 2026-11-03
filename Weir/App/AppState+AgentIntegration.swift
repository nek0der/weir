// AppState+AgentIntegration.swift
// Weir — coordinates approval routing with service reconciliation readiness.

import AppKit

extension AppState {
    func startAgentIntegration() {
        // Requests are placed through the run they came from, wherever it is
        // attached now (a tmux run included).
        approvalPresentation.runtimes = { [attention] in attention.allRuntimes }
        // Each window keeps its own approval card; the requests it shows are
        // shared, and every window's card follows them as they settle.
        approvalPresentation.onRequestsChanged = { [weak windowRegistry, weak approvalPresentation] in
            guard let windowRegistry, let approvalPresentation else { return }
            windowRegistry.settleApprovalCards(against: approvalPresentation)
        }
        // The time left on a held request is read against the service clock,
        // and read again after the Mac wakes rather than assumed to have
        // survived the sleep.
        approvalPresentation.refreshServiceClock(
            onEvery: NSWorkspace.didWakeNotification,
            in: NSWorkspace.shared.notificationCenter
        )
        agentIntegrationServiceRegistrar.start { [weak approvalPresentation] isReady in
            if isReady {
                approvalPresentation?.start()
            } else {
                approvalPresentation?.stop()
            }
        }
        // Before the attention queue starts: what the list holds by then was
        // waiting at launch, so this request posts no real notification.
        if DemoFixture.openLayer?.stagesApproval == true {
            DemoFixture.stageApproval(in: approvalPresentation)
        }
        connectWindowOverlays()
        connectProgramStatus()
        connectTabReopening()
        startApprovalHandOver()
        startAttentionQueue()
        startNotificationRouting()
        // Before the first reading of the journals, so none goes unheard.
        connectRestoreMoves()
        recoverRestores()
    }

    /// Gives a reopened tab's panes their runs back before it is shown.
    func connectTabReopening() {
        session.onTabReopening = { [weak agentProjection] closed, paneIDs in
            agentProjection?.reviveRuns(of: closed, paneIDs: paneIDs)
        }
    }

    /// Hands the agents' OSC 7501 reports to the projection: which program
    /// names are agents', what each pane last reported, and a pass whenever
    /// an agent's report changes.
    func connectProgramStatus() {
        programStatus.agentApps = Set(AgentProviderRegistry.descriptors.values.compactMap(\.programStatusApp))
        programStatus.onChange = { [weak agentProjection] in
            agentProjection?.requestPass()
        }
        agentProjection.programStatus = { [programStatus] in
            programStatus.projectionInput
        }
        agentProjection.panesBackAtShell = { [programStatus] in
            programStatus.panesBackAtShell
        }
    }

    /// Tells the toast center which window a toast with no window of its
    /// own is drawn in, as each window owns its overlays. Connected before
    /// any toast can be shown.
    func connectWindowOverlays() {
        // A toast whose caller knows no window shows in the one commands
        // act on, as a command's own result would.
        toastCenter.frontWindow = { [weak self] in
            self?.windowRegistry.backgroundCommandTarget.id
        }
        // Read as each toast is shown, so turning VoiceOver on or off
        // counts from the next toast.
        toastCenter.lifetimeScale = {
            NSWorkspace.shared.isVoiceOverEnabled ? ToastItem.voiceOverLifetimeScale : 1
        }
    }

    /// With the hidden setting that holds requests off, hands every held
    /// request to the TUI as it arrives, and those already held once the
    /// setting turns off. Here rather than in the store because the setting
    /// lives in the settings store, which the approvals store does not read.
    private func startApprovalHandOver() {
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = approvalPresentation.pending
            _ = approvalPresentation.ledger.entries
            _ = settingsStore.settings.advanced.holdsApprovals
        } onChange: { [weak self] in
            self?.handOverApprovalsIfNotHeld()
        }
        handOverApprovalsIfNotHeld()
    }

    private func handOverApprovalsIfNotHeld() {
        guard !settingsStore.settings.advanced.holdsApprovals else { return }
        approvalPresentation.handOverHeldRequests()
    }
}
