// PrimaryActionHandler.swift
// Weir — the window's way to ⌘⏎ and the decision bar's buttons, as its views are handed it.

import Foundation
import WeirDomain

/// The window's way to ⌘⏎, handed to each pane's surface, and to
/// the decision bar's buttons. Equal by window, so a redraw of the window
/// does not tell every pane it changed.
struct PrimaryActionHandler: Equatable, Sendable {
    let windowID: WindowID
    let handle: @MainActor @Sendable (PrimaryKeyPress, UUID) -> Bool
    /// The bar's primary button, clicked: the same action, without the
    /// gate, which only keeps a key press from landing on an item it was
    /// not meant for.
    let perform: @MainActor @Sendable (PrimaryAction, UUID) -> Void
    /// The bar's Undo on its "Done" line.
    let undo: @MainActor @Sendable (ViewedLineUndo, UUID) -> Void
    /// The stop's ⋯ "Start New Conversation" and "Show Partial Changes",
    /// by the stop's item and its pane.
    let startNewConversation: @MainActor @Sendable (AttentionItemID, UUID) -> Void
    let showPartialChanges: @MainActor @Sendable (AttentionItemID, UUID) -> Void
    /// The bar's "Review Unviewed": the window's review tab on the pane's
    /// unviewed turns.
    let openReview: @MainActor @Sendable (UUID, ConversationKey?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
