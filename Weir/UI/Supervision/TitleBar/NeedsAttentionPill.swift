// NeedsAttentionPill.swift
// Weir — the title bar's tray and its count, which opens the Needs Attention list.

import SwiftUI

/// The attention count across every project, always in sight, on a tray: amber
/// while something blocks on the person, blue for unread turns only, and none at
/// zero. It opens the Needs Attention list; ⌘J moves to the next item without it.
struct NeedsAttentionPill: View {
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale

    var body: some View {
        let model = NeedsAttentionPillModel(attentionQueue.queue.counts())
        TitleBarMenuButton(menu: .needsAttention) { isHighlighted in
            // Lit while its list is open, as Changes is while its panel is.
            RailIconFace(
                systemImage: "tray",
                isLit: window.titleBarMenu?.menu == .needsAttention,
                isHovering: isHighlighted,
                badge: .counting(model.count, tone: model.style == .blocking ? .blocking : .unread),
                standsOnCorner: true
            )
        }
        // The name alone: the badge on the tray says the count.
        .hoverChip(
            "Needs Attention",
            shortcut: settings.settings.keyboard.shortcut(for: .showNeedsAttention)?.displayString,
            placement: .below
        )
        .accessibilityLabel(Text(model.label))
        .accessibilityHint(Text(verbatim: model.tooltip(
            listShortcut: settings.settings.keyboard.shortcut(for: .showNeedsAttention)?.displayString,
            nextShortcut: settings.settings.keyboard.shortcut(for: .nextAttention)?.displayString,
            locale: locale
        )))
        .accessibilityValue(Text(verbatim: AgentStatusText.spokenList(
            AttentionSummaryText.breakdown(model.counts, locale: locale),
            locale: locale
        )))
    }
}
