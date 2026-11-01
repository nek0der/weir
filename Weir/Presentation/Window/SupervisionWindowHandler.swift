// SupervisionWindowHandler.swift
// Weir — the supervision window's own actions, as its views are handed them.

import Foundation
import WeirDomain

/// The window's way to its own actions, handed to its views: what they run,
/// bound to the window, and no more of the app. App builds it
/// (`SupervisionWindowActions.handler`), so a view passes a press on without
/// naming the code that carries it out. Equal by window, as
/// `PrimaryActionHandler` is.
struct SupervisionWindowHandler: Equatable, Sendable {
    let windowID: WindowID
    /// Carries out a command that is the whole window's, and says whether
    /// it was one.
    let takeCommand: @MainActor @Sendable (WindowCommand) -> Bool
    /// A palette row the window runs itself; the flag is a commit with ⌘.
    let runPaletteAction: @MainActor @Sendable (CommandPaletteAction, Bool) -> PaletteRowHandling
    /// The window is back in front: ⌘⏎ waits before it acts.
    let cameToFront: @MainActor @Sendable () -> Void
    let goBack: @MainActor @Sendable () -> Void
    let goForward: @MainActor @Sendable () -> Void
    let showScratch: @MainActor @Sendable () -> Void
    let openFolder: @MainActor @Sendable () -> Void
    /// A sidebar header's ＋: the new worktree sheet for that project.
    let newWorktree: @MainActor @Sendable (UUID) -> Void
    /// Answer… on a row, by the request and the row's project.
    let answer: @MainActor @Sendable (ApprovalPresentation, UUID?) -> Void
    /// A row's Open Changes Panel.
    let openChangesPanel: @MainActor @Sendable (ContainerID) -> Void
    /// Whether ⌥⌘N's first use after an update took the key.
    let introduceInstantWorktree: @MainActor @Sendable () -> Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
