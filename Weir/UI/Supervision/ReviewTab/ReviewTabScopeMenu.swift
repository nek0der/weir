// ReviewTabScopeMenu.swift
// Weir — "Review Scope": the one menu that chooses what the review tab reads, and whose turns.

import SwiftUI
import WeirDomain

/// "Review Scope": the menu that chooses what the tab reads, the
/// conversation with it. It lists the worktree's unviewed turns, then a row
/// per conversation with its badge, name, and state, opening its turns, then
/// the uncommitted changes and the branch (`ReviewScopeMenu`), and holds no
/// turn rows, line, or receipts: the changes panel has those. An AppKit
/// menu (`PopUpMenuButton`), whose items carry a second line and the badge.
struct ReviewTabScopeMenu: View {
    let tab: ReviewTabState
    let handler: ReviewTabHandler
    var isEnabled = true
    @Environment(\.locale) private var locale

    var body: some View {
        let context = handler.context(tab)
        let menu = ReviewScopeMenu.make(tab, context)
        let selection = ReviewTabModel.shown(tab.selection, context)
        ReviewTabScopePicker(
            current: ReviewTabText.option(selection, counts: menu.counts(of: selection), locale: locale),
            spoken: ReviewTabText.scope(
                selection, conversation: menu.labelConversation, counts: menu.counts(of: selection), locale: locale
            ),
            conversation: menu.labelConversation,
            isEnabled: isEnabled
        ) {
            entries(menu)
        }
    }

    /// The worktree's unviewed turns; each conversation as one row opening
    /// its choices; the viewed ones the same under a heading; then what no
    /// conversation owns. A worktree of one conversation lists its choices
    /// as they are. What the worktree's range reads through is its tooltip,
    /// and the top edge says it once it is chosen (`ReviewTabScopeNotes`).
    private func entries(_ menu: ReviewScopeMenu) -> [PopUpMenuEntry] {
        var entries: [PopUpMenuEntry] = []
        if let worktree = menu.worktree {
            let viewed = ReviewTabText.includesViewedTurns(menu.worktreeCounts?.viewedTurns ?? 0, locale: locale)
            entries.append(.item(item(worktree, counts: menu.worktreeCounts, note: viewed)))
            entries.append(.separator)
        }
        for section in menu.sections {
            if section.conversation == nil {
                let digits = Self.numberDigits(section.choices)
                entries += section.choices.map { .item(item($0, numberDigits: digits)) }
            } else if let row = row(section) {
                entries.append(row)
            }
        }
        if !menu.folded.isEmpty {
            entries.append(.header(ConversationText.section(.viewed, locale: locale)))
            entries += menu.folded.compactMap(row)
        }
        if let last = entries.last, case .separator = last {
            entries.removeLast()
        }
        if !entries.isEmpty, !menu.tail.isEmpty {
            entries.append(.separator)
        }
        entries += menu.tail.map { .item(item($0)) }
        return entries
    }

    /// A conversation's row: its badge, name, and line, checked while the
    /// tab reads one of its choices, opening its unviewed turns and then
    /// its single turns, newest first. `nil` without a conversation; off
    /// with nothing to choose, as an empty submenu would open on nothing.
    private func row(_ section: ReviewScopeMenu.Section) -> PopUpMenuEntry? {
        guard let agent = section.conversation else { return nil }
        var opener = ConversationMenuItem.make(
            choice: agent,
            isChecked: section.choices.contains(where: \.isChecked),
            locale: locale,
            perform: {}
        )
        // A row's tooltip lands on the first entry of the submenu it opens,
        // the one most often chosen, so it shows only for what the row cut.
        if ConversationText.menuName(agent, locale: locale) == ConversationText.name(agent, locale: locale) {
            opener.help = nil
        }
        guard !section.choices.isEmpty else {
            opener.isEnabled = false
            return .item(opener)
        }
        var choices: [PopUpMenuEntry] = section.lead.map { [.item(item($0, of: agent))] } ?? []
        if !choices.isEmpty, !section.turns.isEmpty {
            choices.append(.separator)
        }
        let digits = Self.numberDigits(section.turns)
        choices += section.turns.map { .item(item($0, of: agent, numberDigits: digits)) }
        return .submenu(opener, choices)
    }

    /// One choice, with the menu's checkmark on the one the tab reads.
    /// In a conversation's submenu VoiceOver hears the conversation with it
    /// ("Claude #4: T6 · …"), as its row is not read with each item. The
    /// base is cut alone, so a long one keeps the words around it. A turn's
    /// number takes `numberDigits` places, so its words line up with the
    /// other turns'.
    private func item(
        _ choice: ReviewScopeMenu.Choice,
        of conversation: ConversationChoice? = nil,
        counts: ReviewScopeCatalog.RangeCounts? = nil,
        note: String? = nil,
        numberDigits: Int = 0
    ) -> PopUpMenuItem {
        let whole = ReviewTabText.option(choice.option, counts: counts, locale: locale)
        var text = whole
        if case let .branch(base) = choice.option {
            let cut = MenuLine.fit(base, as: .branch, maxWidth: MenuLine.nameBeforeWordsWidth)
            text = ReviewTabText.option(.branch(base: cut), locale: locale)
        }
        var isTurn = false
        if case let .turn(range, _) = choice.option {
            isTurn = true
            text = ReviewTabText.alignedTurn(whole, numbers: range.numbers, digits: numberDigits)
        }
        var item = PopUpMenuItem(
            verbatim: text,
            isChecked: choice.isChecked,
            help: note ?? (isTurn || text == whole ? nil : whole),
            accessibilityLabel: conversation.map { ReviewTabText.scope(choice.option, conversation: $0, locale: locale) }
                ?? (text == whole ? nil : whole),
            accessibilityValue: note
        ) { [handler] in
            handler.select(choice.option, choice.conversation)
        }
        item.hasTabularDigits = isTurn
        return item
    }

    /// How many places the widest single turn's number among `choices` takes.
    private static func numberDigits(_ choices: [ReviewScopeMenu.Choice]) -> Int {
        choices.reduce(0) { widest, choice in
            guard case let .turn(range, _) = choice.option, range.numbers.count == 1 else { return widest }
            return max(widest, String(range.numbers.lowerBound).count)
        }
    }
}

/// "Review Scope" and its menu, apart from what the menu lists. The label
/// names the choice, and, for a choice of one conversation's turns in a
/// worktree of two or more, the conversation's badge and name before it.
/// Whole while the line has room; in a narrow column the label gives way
/// first, its choice cut at its end, so the line's trailing controls (the
/// comment preview, Refresh) stay inside the column. "Review Scope" itself
/// stays whole.
struct ReviewTabScopePicker: View {
    /// The scope shown, as the menu names it.
    let current: String
    /// The scope with its conversation, as VoiceOver and the tooltip say it.
    var spoken: String?
    /// The conversation the label names, `nil` for none.
    var conversation: ConversationChoice?
    var isEnabled = true
    let entries: () -> [PopUpMenuEntry]
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    init(
        current: String,
        spoken: String? = nil,
        conversation: ConversationChoice? = nil,
        isEnabled: Bool = true,
        entries: @escaping () -> [PopUpMenuEntry]
    ) {
        self.current = current
        self.spoken = spoken
        self.conversation = conversation
        self.isEnabled = isEnabled
        self.entries = entries
    }

    /// Whole, then the choice cut at its end, then, narrower still, the
    /// conversation by its badge alone, its name kept in the tooltip and
    /// in what VoiceOver reads.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            line { menu(showsName: true).fixedSize() }
                .fixedSize()
            line { menu(showsName: true) }
            line { menu(showsName: false) }
        }
    }

    private func line(@ViewBuilder menu: () -> some View) -> some View {
        HStack(spacing: Layout.reviewTabScopeLabelSpacing) {
            // The menu's name on screen as well as for VoiceOver, which
            // reads it from the menu's own trigger.
            Text("Review Scope")
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize()
                .accessibilityHidden(true)
            menu()
        }
    }

    private func menu(showsName: Bool) -> some View {
        let said = spoken ?? current
        return PopUpMenuButton(
            verbatim: LocalizedStringResource("Review Scope").resolved(in: locale),
            help: said,
            value: said
        ) {
            entries()
        } label: {
            BorderedMenuTriggerLabel {
                if let conversation {
                    let badge = SessionRowFact.Badge.agent(conversation.conversation.provider)
                    ConversationIdentityLead(identity: conversation.identity) {
                        SessionAgentBadge(badge: badge, text: SessionRowFactText.badge(badge, locale: locale), size: .regular)
                    }
                    if showsName {
                        Text(verbatim: ConversationText.name(conversation, locale: locale))
                            .font(.supervision(.row, weight: .semibold))
                            .foregroundStyle(SupervisionTokens.text.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(verbatim: current)
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .disabled(!isEnabled)
    }
}
