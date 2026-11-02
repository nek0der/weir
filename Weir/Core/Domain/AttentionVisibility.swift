// AttentionVisibility.swift
// Weir — whether the person can be said to see a pane, for routing notifications and reading turns.

import Foundation

/// The facts that decide whether a pane counts as seen.
///
/// A pane counts as seen only when Weir is the frontmost app and the pane
/// is on screen in a window that shows it: a minimized, hidden, or covered
/// window, a leaf hidden by zoom, and a pane under the review surface do
/// not count, and an unfocused split leaf does. This is separate from which
/// terminals draw (`PaneVisibility`): a window behind another app still
/// draws, but nobody is looking at it.
package struct AttentionVisibility: Equatable, Sendable {
    /// The union of every on-screen window's attended panes.
    package var attendedPanes: Set<UUID> = []
    package var isAppActive = false

    package init(
        attendedPanes: Set<UUID> = [],
        isAppActive: Bool = false
    ) {
        self.attendedPanes = attendedPanes
        self.isAppActive = isAppActive
    }

    /// Every pane `isSeen` holds for: none while another app is in front.
    package var seenPanes: Set<UUID> {
        isAppActive ? attendedPanes : []
    }

    package func isSeen(_ paneID: UUID) -> Bool {
        isAppActive && attendedPanes.contains(paneID)
    }
}
