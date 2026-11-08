// NeedsAttentionButton.swift
// Weir — the title bar's tray and its count, which opens the Needs Attention list.

import SwiftUI

/// The attention count across every project, always in sight, on a tray: amber
/// while something blocks on the person, blue for unread turns only, and none at
/// zero. It opens the Needs Attention list; ⌘J moves to the next item without it.
struct NeedsAttentionButton: View {
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale

    var body: some View {
        let model = NeedsAttentionCountModel(attentionQueue.queue.counts())
        TitleBarMenuButton(menu: .needsAttention) { isHighlighted in
            // Lit while its list is open, as Changes is while its panel is.
            NeedsAttentionMark(
                model: model,
                isControl: true,
                isLit: window.titleBarMenu?.menu == .needsAttention,
                isHovering: isHighlighted
            )
        }
        // ⌘J and ⇧⌘J walk the list this opens.
        .heldKeyCap(.showNeedsAttention, .nextAttention, .previousAttention)
        // The name alone: the badge on the tray says the count.
        .hoverChip(
            "Needs Attention",
            shortcut: settings.settings.keyboard.shortcut(for: .showNeedsAttention)?.displayString,
            placement: .below
        )
        .accessibilityLabel(Text(model.label))
        .accessibilityHint(Text(verbatim: model.hint(
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

/// The attention tray and count, on a control's corner or inline in a project row.
struct NeedsAttentionMark: View {
    let model: NeedsAttentionCountModel
    var isControl = false
    var isLit = false
    var isHovering = false

    private let symbol = "tray"

    var body: some View {
        let tone: IconBadge.CountTone = model.style == .blocking ? .blocking : .unread
        if isControl {
            IconControlFace(
                systemImage: symbol,
                isLit: isLit,
                isHovering: isHovering,
                badge: .counting(model.count, tone: tone),
                standsOnCorner: true
            )
        } else {
            HStack(spacing: WeirLayout.Supervision.spaceSnug) {
                Image(systemName: symbol)
                Text(verbatim: String(model.count))
                    .monospacedDigit()
            }
            .foregroundStyle(IconBadgeMark.countColor(for: tone))
        }
    }
}
