// ProjectMenuModel.swift
// Weir — the title bar's project dropdown: which projects, in what order, with what counts.

import Foundation
import WeirDomain

/// The project dropdown's list: the projects in the order the
/// window's sidebar lists them, narrowed by the search text, each with its attention and
/// running counts so another project's work shows without opening it, and
/// a note on those another window shows, which choosing brings forward
/// rather than switching this window.
struct ProjectMenuModel: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let paletteIndex: Int?
        let isCurrent: Bool
        /// Another window shows the project, hidden or not.
        let isInOtherWindow: Bool
        let attention: NeedsAttentionCountModel
        /// Agents running or compacting in the project.
        let running: Int

        /// ⌘-click or ⌘Return opens the project in a new window: a
        /// project neither this window nor another shows. What the row's
        /// tooltip and its VoiceOver action say, so neither offers it on a
        /// row whose window would only come forward.
        var opensInNewWindow: Bool {
            ProjectOpening.offersNewWindow(isShownHere: isCurrent, isShownElsewhere: isInOtherWindow)
        }
    }

    let rows: [Row]

    /// What the dropdown needs from the app, per project.
    struct Facts {
        let attention: (UUID) -> AttentionCounts
        let running: (UUID) -> Int
        /// Whether a window shows the project, hidden or not.
        let isShown: (UUID) -> Bool
    }

    /// `projects` in the order to list them: the sidebar's, so the
    /// dropdown and the sidebar never disagree on where a project is, and
    /// nothing moves up because it was used.
    init(projects: [Project], currentProjectID: UUID?, query: String, facts: Facts) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        rows = projects
            .filter { project in
                needle.isEmpty
                    || project.name.localizedCaseInsensitiveContains(needle)
                    || project.rootURL.path.localizedCaseInsensitiveContains(needle)
            }
            .map { project in
                Row(
                    id: project.id,
                    name: project.name,
                    paletteIndex: project.paletteIndex,
                    isCurrent: project.id == currentProjectID,
                    isInOtherWindow: project.id != currentProjectID && facts.isShown(project.id),
                    attention: NeedsAttentionCountModel(facts.attention(project.id)),
                    running: facts.running(project.id)
                )
            }
    }

    /// What the dropdown offers for the project the window shows,
    /// under Open Folder…: its settings, its folder, and closing it, last
    /// since it is the one that takes something away.
    enum ProjectItem: Equatable {
        case settings
        case revealInFinder
        case close

        /// The item's name and symbol wherever it is offered: the File
        /// menu, the palette, the sidebar's project menu, and the project ▾,
        /// which draws the name alone.
        var label: MenuItemLabel {
            switch self {
            case .settings: MenuItemLabel(title: "Project Settings…", symbol: "gearshape")
            case .revealInFinder: .showInFinder
            case .close: MenuItemLabel(title: "Close Project…", symbol: "xmark")
            }
        }
    }

    /// The window's project's items, or none when the window shows no
    /// project, or one that has just been removed.
    static func projectItems(for projectID: UUID?, in projects: [Project]) -> [ProjectItem] {
        guard let projectID, projects.contains(where: { $0.id == projectID }) else { return [] }
        return [.settings, .revealInFinder, .close]
    }

    /// Whether `item` can be chosen for `project`. A folder that is gone
    /// has nothing to show in Finder. The project ▾ and the sidebar's
    /// project menu both ask it, so the two never disagree on it.
    static func isEnabled(_ item: ProjectItem, for project: Project) -> Bool {
        switch item {
        case .revealInFinder:
            !project.isRootMissing
        case .settings, .close:
            true
        }
    }

    /// The frecency key the palette's project rows record, so choosing a
    /// project in the dropdown counts toward the palette's order.
    static func frecencyKey(_ projectID: UUID) -> String {
        CommandPaletteAction.activateProject(projectID).frecencyKey
    }

    /// The two letters on a project's mark: the first letters of the first
    /// two words of a hyphenated name ("weir-site" is "WS"), else the
    /// first two letters of its one word ("weir" is "WE"). Two letters fit the
    /// mark at any name's length, and two words tell apart the sibling
    /// repositories a hyphen usually names.
    static func initials(of name: String) -> String {
        let words = name.split(separator: "-")
        guard words.count > 1 else {
            return String((words.first ?? "").prefix(2)).uppercased()
        }
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// A row's tooltip and VoiceOver value, including the meanings of its icons.
    static func rowHelp(_ row: Row, locale: Locale) -> String? {
        var parts = [activityDescription(
            attention: row.attention, running: row.running,
            isInOtherWindow: row.isInOtherWindow, locale: locale
        )]
        if row.isCurrent {
            parts.append(LocalizedStringResource("Current Window").resolved(in: locale))
        } else if row.opensInNewWindow {
            parts.append(NewWindowText.clickHelp(locale: locale))
        }
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Describes the window marker and both activity counts for project rows.
    static func activityDescription(
        attention: NeedsAttentionCountModel, running: Int, isInOtherWindow: Bool, locale: Locale
    ) -> String {
        var parts: [String] = []
        if isInOtherWindow {
            parts.append(LocalizedStringResource("Other Window").resolved(in: locale))
        }
        if attention.count > 0 {
            parts.append(attention.label.resolved(in: locale))
            parts.append(contentsOf: AttentionSummaryText.breakdown(attention.counts, locale: locale))
        }
        if running > 0 {
            parts.append(LocalizedStringResource("Running · \(running)").resolved(in: locale))
        }
        return AgentStatusText.joined(parts, locale: locale)
    }

    /// The project control's tooltip: what it is, and how many items wait
    /// in the other projects when any do.
    static func controlHelp(otherProjectsCount: Int, locale: Locale) -> String {
        guard otherProjectsCount > 0 else {
            return LocalizedStringResource("Project").resolved(in: locale)
        }
        return LocalizedStringResource(
            "Project · Other projects need attention: \(otherProjectsCount)",
            comment: "Title bar project control tooltip; how many items need attention in the other projects"
        ).resolved(in: locale)
    }
}

extension ProjectMenuModel {
    /// The dropdown of `window` as the app's session, windows, and
    /// attention list describe it, in the window's order.
    @MainActor
    init(
        session: WorkspaceSession,
        registry: WindowRegistry,
        window: WindowSelection,
        query: String,
        attentionQueue: AttentionQueue,
        attention: AttentionState
    ) {
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        self.init(
            projects: window.sidebarArrangement.ordered(session.projects.map(\.id)).compactMap { byID[$0] },
            currentProjectID: window.shownProjectID,
            query: query,
            facts: Facts(
                attention: { attentionQueue.counts(inProject: $0) },
                running: { attention.runningAgentCount(inProject: $0, session: session) },
                isShown: { registry.window(showingProject: $0, in: session) != nil }
            )
        )
    }
}
