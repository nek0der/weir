// MenuBarStores.swift
// Weir — what the menu bar extra's actions read and change, handed over by the app.

import Foundation
import WeirDomain

/// The stores and the ways out the menu bar extra's actions use
/// (`MenuBarActions`), and nothing else of the app. The app builds it
/// (`AppState.menuBarStores`).
@MainActor
struct MenuBarStores {
    let session: WorkspaceSession
    let windows: WindowRegistry
    let attentionQueue: AttentionQueueStore
    let approvals: ApprovalPresentationStore
    let stopLedger: StopLedgerStore
    /// What a usage limit stop offers while its limit holds, read once per
    /// call: the sync that knows is set up after launch.
    let resetNotice: (AttentionItem, Date) -> UsageLimitResetNotice?
    /// "Notify When It Resets" (`SupervisionWindowActions.requestResetNotice`).
    let requestResetNotice: (AttentionItemID) -> Void
    /// "Resume Same Conversation", kept against a window
    /// (`SupervisionWindowActions.perform`).
    let resume: (AttentionItemID, _ paneID: UUID, ProjectWindowState) -> Void
}
