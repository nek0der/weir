// PaneNavigation.swift
// Weir — jump-to-pane and flash helpers shared across views

import Foundation
import WeirDomain

@MainActor
func jumpToPane(
    _ paneID: UUID,
    session: WorkspaceSession,
    registry: any SurfaceViewProviding,
    in window: WindowID,
    intent: SelectionIntent
) {
    guard let tab = session.tab(containing: paneID) else { return }
    // The same jump ⌘J makes, so a tab zoomed on another pane unzooms
    // instead of focusing a pane the person cannot see.
    PaneActions.activateAndFocus(
        session,
        registry: registry,
        tabID: tab.id,
        paneID: paneID,
        in: window,
        intent: intent
    )
    flashPane(paneID, session: session)
}

/// Per-pane debounce so a rapid second flash on the same pane cancels
/// the first task's "ringing = false" instead of letting it land
/// midway through the second flash and cut it short.
@MainActor
private var flashTasks: [UUID: Task<Void, Never>] = [:]

@MainActor
func flashPane(_ paneID: UUID, session: WorkspaceSession) {
    flashTasks[paneID]?.cancel()
    session.setBell(paneID: paneID, ringing: true)
    flashTasks[paneID] = Task { @MainActor [weak session] in
        try? await Task.sleep(nanoseconds: BellFeatures.paneFlashNanoseconds)
        if Task.isCancelled {
            return
        }
        session?.setBell(paneID: paneID, ringing: false)
        flashTasks[paneID] = nil
    }
}
