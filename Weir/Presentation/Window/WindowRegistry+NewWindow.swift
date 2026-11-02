// WindowRegistry+NewWindow.swift
// Weir — the windows the person asks for: a project or a row in a new window, and New Window.

import Foundation
import OSLog

private let log = Logger.weir("window.registry")

extension WindowRegistry {
    /// Opens `projectID` in a new window for the person: ⌘-click, ⌘Return,
    /// or Open in New Window on a row of a project no window shows
    /// (`ProjectOpening.newWindow`), wherever the row is (the sidebar,
    /// project ▾, the palette's "#" and "@", the all projects sheet, the
    /// Needs Attention list, a window that shows nothing), and a folder
    /// from outside the app. `from` `nil` is the window commands act on.
    ///
    /// The window that shows the project already, hidden or not, comes
    /// forward instead, as choosing the project anywhere brings it
    /// (`raise`): one project, one window. `from`'s own project is left as
    /// it is, and `from` returned with nothing done: there is nothing to
    /// open. Otherwise a new window opens on what the project showed last
    /// (`WorkspaceSession.addWindow(showing:layoutFrom:)`), laid out like
    /// `from` and on its screen, and takes the review tab and the scroll
    /// positions the project kept, as a window switching to it does. A
    /// `from` that is hidden (every window closed, the last one hidden)
    /// keeps its project: the new window opens all the same, and the hidden
    /// one then closes for real (`openWindow(showing:from:in:)`), as New
    /// Window does. Returns the window that shows the project;
    /// `nil` for a `from` that closed or a project the session does not
    /// have, where nothing changes.
    @discardableResult
    func openInNewWindow(project projectID: UUID, in session: WorkspaceSession, from: ProjectWindowState?) -> ProjectWindowState? {
        let from = from ?? backgroundCommandTarget
        guard window(from.id) === from, session.project(projectID) != nil else { return nil }
        if from.selection.shownProjectID == projectID {
            return from
        }
        if let shown = window(showingProject: projectID, in: session) {
            raise(shown.id, in: session)
            session.noteProjectUsed(projectID)
            return shown
        }
        return openWindow(showing: projectID, from: from, in: session)
    }

    /// Opens `container`, a row of a project, in a new window: the project
    /// as `openInNewWindow(project:in:from:)` opens it, then the row chosen
    /// there, as a click on it would choose it. The sidebar's rows, the
    /// palette's worktrees, and a card of the all projects sheet open so
    /// with ⌘. A project another window has come to show since the row
    /// offered a new window brings that window forward, on the row, as a
    /// plain click on the row would. Returns the window that shows the row;
    /// `nil` for a row of no project, or when nothing could open.
    @discardableResult
    func openInNewWindow(row container: ContainerID, in session: WorkspaceSession, from: ProjectWindowState?) -> ProjectWindowState? {
        guard let projectID = container.projectID,
              let target = openInNewWindow(project: projectID, in: session, from: from)
        else { return nil }
        session.setActiveContainer(container, in: target.id, intent: .person)
        return target
    }

    /// New Window, from the File menu, the palette, or the Dock
    /// menu: always a new window, one that shows nothing yet
    /// (`WindowSelection.isChoosingProject`) and offers every project,
    /// laid out like `from` (the window commands act on when `nil`, or when
    /// `from` closed) and on its screen. A Dock click brings back the
    /// window hidden as the last one closed (`showLastWindow`); New Window
    /// never does, so the command does what its name says however many
    /// windows are shown. Each time a new window, even beside one that
    /// shows nothing already, as a new document window is. Returns the
    /// window opened.
    @discardableResult
    func openEmptyWindow(in session: WorkspaceSession, from: ProjectWindowState?) -> ProjectWindowState {
        let asked = from.flatMap { window($0.id) === $0 ? $0 : nil } ?? backgroundCommandTarget
        return openWindow(showing: nil, from: asked, in: session)
    }

    /// Makes a window on `projectID` (`nil`: one that shows nothing), laid
    /// out like `from` and placed beside it, the one way every new window
    /// is made. The window hidden as the last one closed closes for real
    /// once the new one is shown, as it would had it not been the last
    /// (`close`): a hidden window never stands beside a shown one, and its
    /// project keeps what it showed for the next window that shows it. Its
    /// frame and full screen go with it, as a closed window's do.
    private func openWindow(showing projectID: UUID?, from: ProjectWindowState, in session: WorkspaceSession) -> ProjectWindowState {
        let opened = listed(session.addWindow(showing: projectID, layoutFrom: from.id))
        let shows = projectID == nil ? "showing nothing" : "on a project"
        log.notice("window \(opened.id.rawValue.uuidString, privacy: .public) opened \(shows, privacy: .public)")
        presenter?.show(opened, openedFrom: from.id)
        for hidden in windows where hidden !== opened && hidden.isHidden {
            close(hidden.id, in: session)
        }
        return opened
    }

    /// The window of a selection the session has just added: listed as the
    /// session told of it (`connectProjectSwitching`), or here when the
    /// session switches no window and so tells nothing (tests, with no app
    /// layer connected).
    private func listed(_ selection: WindowSelection) -> ProjectWindowState {
        window(selection.windowID) ?? addWindow(selection)
    }
}
