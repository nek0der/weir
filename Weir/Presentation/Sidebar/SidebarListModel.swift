// SidebarListModel.swift
// Weir — every project under its own header in the sidebar: the header's model, and every line of the list the sidebar draws.

import Foundation
import WeirDomain

/// A project's header in the sidebar: `[mark] name ─── count ▽`.
struct SidebarProjectHeader: Identifiable, Equatable {
    let id: UUID
    let name: String
    let paletteIndex: Int?
    /// The project the window shows.
    let isCurrent: Bool
    let isCollapsed: Bool
    /// Another window shows the project, hidden or not: the
    /// header says so in place of its count, and the project's work goes on
    /// in that window.
    let isInOtherWindow: Bool
    /// The working rows, which the header counts.
    let workingCount: Int
    /// The rows of the folded sections: a folded header's count adds
    /// them to `workingCount`, and VoiceOver reads them apart
    /// (`SidebarHeaderText`).
    let moreCount: Int
    /// What waits or runs inside a folded header (`marks(counts:running:)`);
    /// none on an open one, whose rows show it. The header draws only the
    /// first (`displayedMark`); VoiceOver and the tooltip read them all.
    let marks: [SessionRowFact.Glyph]
    /// The requests waiting inside a folded header: the approval card
    /// opened for one stands beside the header, as its row is not drawn.
    let requestKeys: [ApprovalKey]
    /// What kept the last sync from reading the project's folder
    /// (`Project.trouble`): the header says so in place of its count,
    /// open or folded, as it is about every row under it.
    var trouble: Trouble?

    /// A project's trouble, with the folder its sentence names
    /// (`ProjectTroubleText.explanation`).
    struct Trouble: Equatable {
        let kind: ProjectTrouble
        let folder: URL
    }

    /// The contents of the count slot, shared by open and folded headers.
    enum TrailingMark: Equatable {
        case count
        case otherWindow
        case trouble(Trouble)
    }

    /// The count slot's content, with trouble taking priority in either window.
    var trailingMark: TrailingMark {
        // Trouble needs attention first. The other window remains reachable
        // through the header's menu and VoiceOver actions.
        if let trouble {
            return .trouble(trouble)
        }
        return isInOtherWindow ? .otherWindow : .count
    }

    /// The one mark the header draws: the most urgent of `marks`. One at
    /// most keeps the mark the same width on every header, so the marks and
    /// counts of the projects line up down the sidebar.
    var displayedMark: SessionRowFact.Glyph? {
        marks.first
    }

    /// The marks a folded header holds, one of each kind, in this order:
    /// a wait on the person, a stop, then a turn running. Unread turns get
    /// none: they ask for nothing, and the count of the attention button
    /// already says they are there.
    static func marks(counts: AttentionCounts, running: Int) -> [SessionRowFact.Glyph] {
        let wait: SessionRowFact.Glyph? = if counts.approvals > 0 {
            .needsApproval
        } else if counts.questions > 0 {
            .needsAnswer
        } else if counts.prompts > 0 {
            .needsResponse
        } else if counts.signIns > 0 {
            .needsSignIn
        } else {
            nil
        }
        return [wait, counts.stops > 0 ? .stopped : nil, running > 0 ? .running : nil].compactMap(\.self)
    }
}

/// Whether a project's header is open when the window has not met it yet
/// (`SidebarArrangement`): the window's own project, and one with two or
/// more working rows, open; any other, and one another window shows,
/// folded. Read once, as the sidebar meets the project, so a header never
/// opens or folds later by itself as its rows change.
enum SidebarFoldDefault {
    static func isOpen(isCurrent: Bool, isInOtherWindow: Bool, workingCount: Int) -> Bool {
        if isCurrent {
            return true
        }
        return !isInOtherWindow && workingCount >= 2
    }
}

/// The sidebar's list: each project's header, in the window's order,
/// with its rows under it while it is open. `items` lays every line out flat for the keys and
/// lookups; the view draws `groups`, a section per project.
struct SidebarListModel: Equatable {
    /// One line of the list, in the order the sidebar draws them.
    enum Item: Identifiable, Equatable {
        case header(SidebarProjectHeader)
        case fold(SessionSidebarModel.Fold)
        case row(SessionSidebarModel.Row)

        var id: SidebarItemID {
            switch self {
            case let .header(header): .header(header.id)
            case let .fold(fold): fold.id
            case let .row(row): .row(row.id)
            }
        }
    }

    /// One project: its header, and its rows while it is open.
    struct Group: Identifiable, Equatable {
        let header: SidebarProjectHeader
        /// `nil` while the header is folded: its rows are counted, not built.
        let rows: SessionSidebarModel?

        var id: UUID {
            header.id
        }
    }

    let groups: [Group]
    let items: [Item]

    init(groups: [Group]) {
        self.groups = groups
        items = groups.flatMap { group in
            [Item.header(group.header)] + (group.rows?.items ?? []).map { item in
                switch item {
                case let .row(row): Item.row(row)
                case let .fold(fold): Item.fold(fold)
                }
            }
        }
    }

    /// The rows built for `projectID`, in the order they are listed; none
    /// while its header is folded.
    func rows(ofProject projectID: UUID) -> [SessionSidebarModel.Row] {
        groups.first { $0.id == projectID }?.rows?.rows ?? []
    }

    /// Every row built, in the order they are listed.
    var rows: [SessionSidebarModel.Row] {
        groups.flatMap { $0.rows?.rows ?? [] }
    }

    /// What the list says in place of its headers: with no project there
    /// is none to list, which the sidebar says rather than leave a blank.
    var emptyState: EmptyState? {
        groups.isEmpty ? .noProjects : nil
    }

    /// The headers, in the window's order.
    var headers: [SidebarProjectHeader] {
        groups.map(\.header)
    }
}

/// The project a dragged tab or pane is over in this window's sidebar, and its last
/// line, where the project's mark ends.
struct CarriedOverProject {
    let projectID: UUID
    let lastLine: SidebarItemID?

    init?(projectID: UUID?, in model: SidebarListModel) {
        guard let projectID else { return nil }
        self.projectID = projectID
        lastLine = model.items.last { $0.id.projectID == projectID }?.id
    }
}
