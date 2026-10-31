// NeedsAttentionCountModel.swift
// Weir — what the attention count says, and how loudly.

import Foundation
import WeirDomain

/// The attention count across every project: on the title bar's tray, where it
/// goes at zero, and in the menu bar's label.
struct NeedsAttentionCountModel: Equatable {
    enum Style: Equatable {
        /// Something blocks on the person (an approval, a question, a wait
        /// at the agent's prompt, a stop): amber.
        case blocking
        /// Only finished turns nobody has read: blue, so amber
        /// keeps meaning "stopped until you act".
        case unreadOnly
        /// Nothing.
        case empty
    }

    let count: Int
    let style: Style
    let counts: AttentionCounts

    init(_ counts: AttentionCounts) {
        self.counts = counts
        count = counts.total
        style = counts.hasBlockingItems ? .blocking : counts.total > 0 ? .unreadOnly : .empty
    }

    var label: LocalizedStringResource {
        Self.label(count)
    }

    /// "Needs Attention · 3", wherever the count is named: the tray, the
    /// project menu's rows, and the banner after the Mac wakes.
    static func label(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "Needs Attention · \(count)",
            comment: "The attention count: the title bar tray, the project menu, and the notification after the Mac wakes"
        )
    }

    /// "Needs Attention list (⌃⌘J; Next Action: ⌘J) · 1 Approval · 2 Unread".
    /// A shortcut the person has unbound is left out rather than shown
    /// empty; the breakdown lists only the kinds that have items.
    func hint(listShortcut: String?, nextShortcut: String?, locale: Locale) -> String {
        let head = switch (listShortcut, nextShortcut) {
        case let (list?, next?):
            LocalizedStringResource(
                "Needs Attention list (\(list); Next Action: \(next))",
                comment: "Title bar tray, VoiceOver hint; the shortcut that opens the list, the shortcut for the next item"
            )
        case let (list?, nil):
            LocalizedStringResource(
                "Needs Attention list (\(list))",
                comment: "Title bar tray, VoiceOver hint; the shortcut that opens the list"
            )
        case let (nil, next?):
            LocalizedStringResource(
                "Needs Attention list (Next Action: \(next))",
                comment: "Title bar tray, VoiceOver hint; the shortcut for the next item"
            )
        case (nil, nil):
            LocalizedStringResource("Needs Attention list", comment: "Title bar tray, VoiceOver hint with no shortcuts bound")
        }
        let parts = [head.resolved(in: locale)] + AttentionSummaryText.breakdown(counts, locale: locale)
        return AgentStatusText.joined(parts, locale: locale)
    }
}
