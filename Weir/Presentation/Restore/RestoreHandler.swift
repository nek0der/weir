// RestoreHandler.swift
// Weir — the window's way to the restore strip and record, as its views are handed it.

import Foundation
import WeirDomain

/// The window's way to the restore strip and record, handed to its bars
/// and its changes panel: what they read and what they run, and no
/// more of the app. Equal by window, as `PrimaryActionHandler` is.
struct RestoreHandler: Equatable, Sendable {
    let windowID: WindowID
    /// What the strip asks now, `nil` when its turn is gone.
    let confirmation: @MainActor @Sendable (RestoreStrip, Locale) -> RestoreConfirmation?
    /// "Restore Code" in the strip of a pane.
    let confirm: @MainActor @Sendable (UUID, Locale) -> Void
    let cancel: @MainActor @Sendable (UUID) -> Void
    /// The record a pane's bar shows at rest.
    let record: @MainActor @Sendable (UUID) -> RestoreJournal?
    /// The journal a "Done" line names, as last read.
    let journal: @MainActor @Sendable (RestoreDone) -> RestoreJournal?
    let undo: @MainActor @Sendable (RestoreJournal) -> Void
    /// Whether a restore or an undo of a worktree is under way.
    let isBusy: @MainActor @Sendable (String) -> Bool
    /// How the last "Undo Restore" of a worktree fell short.
    let undoResult: @MainActor @Sendable (String) -> RestoreCoordinator.UndoResult?
    /// Opens the strip for a turn, in its pane's bar (the bar's ⋯).
    let ask: @MainActor @Sendable (TurnID) -> Void
    let canAsk: @MainActor @Sendable (TurnID) -> Bool
    /// The turn the palette's entry restores to, for its subtitle.
    let paletteTurnNumber: @MainActor @Sendable () -> Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
