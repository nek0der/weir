// SidebarHeaderText.swift
// Weir — what a project's header in the sidebar says, and what VoiceOver reads for it.

import Foundation

/// The words of a project's header, read by the header and by the tests,
/// so a test pins the words on screen.
enum SidebarHeaderText {
    /// The count after the rule, on a folded header only: every row it
    /// hides, its folded sections' too. An open header shows none, since
    /// its rows are in view and each folded section's own heading counts
    /// what it holds. Counting them again in the header ("3 · 55 more")
    /// repeated those numbers, and "more" did not say more of what.
    static func count(_ header: SidebarProjectHeader, locale: Locale) -> String? {
        guard header.isCollapsed else { return nil }
        return (header.workingCount + header.moreCount).formatted(.number.locale(locale))
    }

    /// What VoiceOver reads for the header, including trouble whose icon
    /// is hidden by the header's single accessibility element.
    static func accessibilityLabel(_ header: SidebarProjectHeader, locale: Locale) -> String {
        let project = projectLabel(header, locale: locale)
        guard let trouble = header.trouble else { return project }
        return [project, ProjectTroubleText.label(trouble.kind).resolved(in: locale)]
            .formatted(.list(type: .and).locale(locale))
    }

    private static func projectLabel(_ header: SidebarProjectHeader, locale: Locale) -> String {
        if header.isInOtherWindow {
            return LocalizedStringResource(
                "\(header.name), project, shown in another window",
                comment: "Sidebar project header, VoiceOver: a project another window shows"
            ).resolved(in: locale)
        }
        // Both counts whether the header is open or folded: on screen an
        // open header leaves them to its rows and a folded one sums them,
        // and VoiceOver has neither the rows nor a sum to go by.
        guard header.moreCount > 0 else {
            return LocalizedStringResource(
                "\(header.name), project, \(header.workingCount) worktrees",
                comment: "Sidebar project header, VoiceOver: the project's name and its working rows"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "\(header.name), project, \(header.workingCount) worktrees, \(header.moreCount) more",
            comment: "Sidebar project header, VoiceOver: the project's name, its working rows, and the rows of its folded sections"
        ).resolved(in: locale)
    }

    /// What VoiceOver and the tooltip say of a folded header's marks: what
    /// waits or runs inside, in words, since the marks are glyphs. `names`
    /// are the marks' state names, as the glyphs read them
    /// (`StateGlyph.Kind.name`). `nil` with none.
    static func contents(_ names: [String], locale: Locale) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.formatted(.list(type: .and).locale(locale))
        return LocalizedStringResource(
            "Contains: \(list)",
            comment: "Sidebar folded project header, VoiceOver and tooltip: the states waiting or running inside it"
        ).resolved(in: locale)
    }

    /// The header's ＋: a new worktree in this project, whichever project
    /// the window shows.
    static func newWorktree(in name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "New Worktree in \(name)…",
            comment: "Sidebar project header's + button and menu item: the new worktree sheet for this project"
        )
    }

    /// The tooltip of the "Other Window" mark, which brings that window
    /// forward.
    static func otherWindowHelp(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "Brings forward the window that shows \(name)",
            comment: "Sidebar project header, tooltip of the Other Window mark"
        )
    }
}

/// The symbol and words for a project's trouble (`ProjectTrouble`): the
/// icon's accessible label, and the explanation in its tooltip and the
/// header's VoiceOver hint.
enum ProjectTroubleText {
    /// Returns a distinct shape for each kind, so color is not the only cue.
    static func symbol(_ trouble: ProjectTrouble) -> String {
        switch trouble {
        case .folderMissing: "folder.badge.questionmark"
        case .gitUnavailable: "exclamationmark.triangle"
        case .listingFailed: "list.bullet.rectangle"
        }
    }

    static func label(_ trouble: ProjectTrouble) -> LocalizedStringResource {
        switch trouble {
        case .folderMissing:
            LocalizedStringResource(
                "Folder Missing",
                comment: "Sidebar project header, in place of its count: the project's folder is gone from disk"
            )
        case .gitUnavailable:
            LocalizedStringResource(
                "Git Unavailable",
                comment: "Sidebar project header, in place of its count: no git could be run"
            )
        case .listingFailed:
            LocalizedStringResource(
                "Git Error",
                comment: "Sidebar project header, in place of its count: git refused to list the project's worktrees"
            )
        }
    }

    /// What happened and what to do. `folder` is the project's folder, which
    /// a person looks for after a rename.
    static func explanation(_ trouble: ProjectTrouble, folder: URL) -> LocalizedStringResource {
        switch trouble {
        case .folderMissing:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "The project’s folder is gone: \(PathFormatting.showingControlCharacters(folder.path)). Move it back, or close the project.",
                comment: "Sidebar project header, tooltip and VoiceOver: the project's folder was deleted or moved; the path follows"
            )
        case .gitUnavailable:
            LocalizedStringResource(
                "Git couldn’t run. Install the Command Line Tools with xcode-select --install in Terminal.",
                comment: "Project header tooltip and VoiceOver: no git could be run; xcode-select --install is a command"
            )
        case let .listingFailed(detail?):
            LocalizedStringResource(
                "Git couldn’t list the worktrees: \(detail)",
                comment: "Project header tooltip and VoiceOver: git refused to list the worktrees; git's English message follows"
            )
        case .listingFailed(nil):
            LocalizedStringResource(
                "Git couldn’t list the worktrees.",
                comment: "Sidebar project header, tooltip and VoiceOver: git did not list the worktrees and said nothing"
            )
        }
    }
}
