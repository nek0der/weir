// ProjectOpening.swift
// Weir — where choosing a row of a project lands: here, in the window that shows it, or in a new window.

/// Where choosing a row of a project lands, from values alone. One project
/// is shown in one window at a time, so the answer turns on which window
/// shows the row's project, and on whether the person held ⌘ (or chose
/// "Open in New Window"), which asks for a new window. Every row that
/// opens a project (the sidebar, project ▾, the palette, the all
/// projects sheet, the Needs Attention list, the menu bar, a window that
/// shows nothing) reads it here, so no entry point offers a new window
/// that another would not.
package enum ProjectOpening: Equatable, Sendable {
    /// The row is of the project this window shows: it opens here, with ⌘
    /// or without, since the project cannot be shown twice.
    case here
    /// Another window shows the project, hidden or not: that window comes
    /// forward, with ⌘ or without.
    case otherWindow
    /// No window shows the project: this window switches to it in place.
    case switchHere
    /// No window shows the project and the person asked for a new window.
    case newWindow

    /// `isShownHere`: this window shows the row's project.
    /// `isShownElsewhere`: another window does, hidden ones included.
    /// `asksForNewWindow`: ⌘-click, ⌘Return, or "Open in New Window".
    package init(isShownHere: Bool, isShownElsewhere: Bool, asksForNewWindow: Bool) {
        if isShownHere {
            self = .here
        } else if isShownElsewhere {
            self = .otherWindow
        } else {
            self = asksForNewWindow ? .newWindow : .switchHere
        }
    }

    /// Whether ⌘ opens the row in a new window: what the row's tooltip and
    /// its "Open in New Window" entry offer. A row that would only open
    /// here, or bring another window forward, offers neither.
    package static func offersNewWindow(isShownHere: Bool, isShownElsewhere: Bool) -> Bool {
        ProjectOpening(isShownHere: isShownHere, isShownElsewhere: isShownElsewhere, asksForNewWindow: true) == .newWindow
    }
}
