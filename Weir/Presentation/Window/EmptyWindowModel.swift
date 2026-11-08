// EmptyWindowModel.swift
// Weir — what a window that shows nothing offers: every project, in its sidebar's order, with its state or its window.

import Foundation
import WeirDomain

/// The projects a window that shows nothing lists: every project, in the
/// order the window's sidebar lists them (`SidebarArrangement`), so the
/// list and the sidebar beside it agree on project order. Each row shows
/// its window marker, attention count, and running count independently.
struct EmptyWindowModel: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let paletteIndex: Int?
        /// The project's folder, with the home folder as "~": the row's
        /// tooltip, not a line of its own, as a long path cut short told
        /// projects apart less than their names do.
        let folder: String
        /// Another window shows the project, hidden or not.
        let isInOtherWindow: Bool
        let attention: NeedsAttentionCountModel
        /// Agents running or compacting in the project.
        let running: Int

        /// ⌘-click or ⌘Return opens the project in a new window, which the
        /// row's tooltip and its VoiceOver action say. A row of a project
        /// another window shows only brings that window forward.
        var opensInNewWindow: Bool {
            ProjectOpening.offersNewWindow(isShownHere: false, isShownElsewhere: isInOtherWindow)
        }

        /// Returns the folder, activity, and opening action for the tooltip and VoiceOver.
        func help(locale: Locale) -> String {
            var parts = [folder, ProjectMenuModel.activityDescription(
                attention: attention, running: running, isInOtherWindow: isInOtherWindow, locale: locale
            )]
            if opensInNewWindow {
                parts.append(NewWindowText.clickHelp(locale: locale))
            }
            return parts.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    let rows: [Row]

    /// `projects` in the order they are offered; `shownElsewhere`, those
    /// another window shows; `attentionQueue` and `running`, each
    /// project's counts, as project ▾ reads them (`ProjectMenuModel.Facts`).
    init(
        projects: [Project],
        shownElsewhere: Set<UUID> = [],
        attentionQueue: AttentionQueue = AttentionQueue(),
        running: (UUID) -> Int = { _ in 0 }
    ) {
        rows = projects.map { project in
            Row(
                id: project.id,
                name: project.name,
                paletteIndex: project.paletteIndex,
                folder: PathFormatting.abbreviateHome(project.rootURL.path),
                isInOtherWindow: shownElsewhere.contains(project.id),
                attention: NeedsAttentionCountModel(attentionQueue.counts(inProject: project.id)),
                running: running(project.id)
            )
        }
    }
}

extension EmptyWindowModel {
    /// The list of `window` as the session's windows stand, with the
    /// counts `attentionQueue` and `running` give.
    @MainActor
    init(
        session: WorkspaceSession,
        window: WindowSelection,
        attentionQueue: AttentionQueue = AttentionQueue(),
        running: (UUID) -> Int = { _ in 0 }
    ) {
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        let order = window.sidebarArrangement.ordered(session.projects.map(\.id))
        self.init(
            projects: order.compactMap { byID[$0] },
            shownElsewhere: Set(session.otherWindowsByProject(than: window.windowID).keys),
            attentionQueue: attentionQueue,
            running: running
        )
    }
}
