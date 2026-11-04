// CommonText.swift
// Weir — the words several surfaces share for the same action or count.

import Foundation

/// Words that mean one thing wherever they appear. Each was once written
/// at every place it showed, under its own key or its own translator
/// comment, and the copies drifted: "Try Again" beside "Retry", "3/10"
/// beside "3 / 10", one key carrying several comments of which the catalog
/// keeps one. One resource each keeps the words and their comment the same.
enum CommonText {
    /// Runs again what just failed: a pane that could not start, the
    /// approval service, an update's check or quit, a new worktree's stage,
    /// the review's load.
    static let retry = LocalizedStringResource(
        "Retry",
        comment: "Button: runs again what just failed: a pane, the approval service, an update, a new worktree's stage, the review"
    )

    /// Closes the popover or strip it sits on once nothing is left to do
    /// there. The × buttons and menus that say "Close" use the same key.
    static let close = LocalizedStringResource(
        "Close",
        comment: "Button: closes the popover, strip, sheet, or pane it belongs to"
    )

    /// Quits the app, as the app menu's Quit does: the menu bar item's ⋯
    /// menu, and the window shown when the terminal could not start. Keyed
    /// apart from the Settings row of the same English, which names the
    /// moment a confirmation is asked rather than the action.
    static let quitApp = LocalizedStringResource(
        "app.quit",
        defaultValue: "Quit Weir",
        comment: "Button or menu item: quits the app, as the app menu's Quit does"
    )

    /// "3 / 10": which one of how many is shown, the decision bar's item or
    /// the find bar's match. VoiceOver hears each surface's own "of" form.
    static func position(_ index: Int, of count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "\(index) / \(count)",
            comment: "Which one of how many is shown: the decision bar's item, the find bar's match"
        )
    }

    /// "- / 10": the find bar's matches while none is current yet, spaced
    /// as `position` is, so the counter keeps its look once one is.
    static func noPosition(of count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "- / \(count)",
            comment: "The find bar's matches while none is current yet; argument: how many"
        )
    }
}
