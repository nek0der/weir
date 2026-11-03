// AddTabMenu.swift
// Weir — the pane strip's "+" menu: a tab running an agent found on this Mac, or a shell, in this session.

import SwiftUI
import WeirDomain

/// What the strip's "+" adds to the session it heads: a tab running one
/// of the agents found on this Mac (`AddTabOffer`), or a shell. An agent
/// added here works in the same folder as the session's own, which one
/// line under the items says while an agent already works there; a new
/// folder is a new session. It takes the keyboard as it opens: ↑↓ move
/// through the items from the first, and Return adds the selected one
/// (`DropdownListKeys`).
struct AddTabMenu: View {
    /// One of the menu's items, as the keys move through them.
    enum Item: Hashable {
        case agent(AgentKind)
        case shell

        /// The agent the tab runs; `nil` for a shell.
        var agent: AgentKind? {
            if case let .agent(kind) = self {
                return kind
            }
            return nil
        }
    }

    let container: ContainerID
    let dismiss: () -> Void
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(InstalledAgentsStore.self) private var installedAgents
    /// The window the menu is in, whose selection the new tab is shown in.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @State private var selection = ListKeyboardSelection<Item>(ids: [])

    var body: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.popoverRowSpacing) {
            // A branch or folder in code type, as the title bar names a
            // branch; "Scratch" is our word, and stays in the sentence's.
            Text("Add Tab to \(Text(verbatim: placeName).font(placeFont))")
                .font(.supervision(.meta))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
                // The sentence ends in the place, a branch after its
                // project, whose end stays.
                .supervisionTruncation(.subject)
                .padding(WeirLayout.Supervision.dropdownHeadingInsets)
                .accessibilityAddTraits(.isHeader)
            let offer = offer
            let items = Self.items(of: offer)
            ForEach(items, id: \.self) { item in
                AddTabMenuItem(
                    title: title(of: item),
                    agent: item.agent,
                    shortcut: item == .shell ? settings.settings.keyboard.shortcut(for: .newTab)?.displayString : nil,
                    isSelected: item == selection.id,
                    // The pointer selects, so one item is lit: the one
                    // Return adds.
                    onHover: { selection.select(item) },
                    action: { add(running: item.agent) }
                )
            }
            if let note = offer.note {
                AddTabMenuNote(note: note)
            }
        }
        .padding(WeirLayout.Supervision.dropdownPadding)
        .dropdownListKeys(Self.items(of: offer), selection: $selection) { item in
            add(running: item.agent)
        }
        // A "+" pressed from the keyboard or VoiceOver never had the pointer
        // on it (`AddTabButton`), so the menu looks again as it opens; an
        // agent installed or removed since then joins or leaves the list.
        .task {
            await installedAgents.refresh(projectID: container.projectID)
        }
    }

    /// The agents found for the place's project, with the note they need.
    private var offer: AddTabOffer {
        AddTabOffer(
            catalog: AgentCatalog.entries.map(\.kind),
            installed: installedAgents.installedAgents(for: container.projectID),
            isAgentWorkingInFolder: session.tabs(in: container).contains { !$0.agentKinds.isEmpty }
        )
    }

    /// The items in order: the agents offered, then the shell, always there.
    static func items(of offer: AddTabOffer) -> [Item] {
        offer.agents.map(Item.agent) + [.shell]
    }

    /// An agent by its product name, the catalog's, the same in every
    /// language; "Shell" is our word, so it is translated.
    private func title(of item: Item) -> Text {
        guard let agent = item.agent else { return Text("Shell") }
        return Text(verbatim: AgentCatalog.entry(for: agent).displayName)
    }

    /// The branch or folder the tab opens in, or "Scratch".
    private var placeName: String {
        Self.placeName(of: container, in: session, locale: locale)
    }

    private var placeFont: Font {
        Self.isNamedPlace(container, in: session) ? .supervisionCode(beside: .meta) : .supervision(.meta)
    }

    /// Whether the place is a branch or a folder, named by the repository
    /// or the disk, rather than "Scratch".
    @MainActor
    static func isNamedPlace(_ container: ContainerID, in session: WorkspaceSession) -> Bool {
        if case .named? = CheckoutName.place(of: container, in: session) {
            return true
        }
        return false
    }

    /// The branch or folder a tab added to `container` opens in, or
    /// "Scratch": the menu's heading and the "+"'s tooltip name it.
    @MainActor
    static func placeName(of container: ContainerID, in session: WorkspaceSession, locale: Locale) -> String {
        // A project the session no longer has has no name of its own, so
        // the heading falls back to the one name a tab's place always has.
        guard case let .named(name)? = CheckoutName.place(of: container, in: session) else {
            return LocalizedStringResource("Scratch").resolved(in: locale)
        }
        return name
    }

    private func add(running agent: AgentKind?) {
        dismiss()
        TabActions.newTab(session, in: container, running: agent, window: window.id, intent: .person, selects: true)
    }
}

/// The line under the items: said once for all of them, where each item
/// saying it made the menu four times as tall as what it offers.
private struct AddTabMenuNote: View {
    let note: AddTabOffer.Note
    @Environment(\.locale) private var locale

    var body: some View {
        text
            .font(.supervision(.caption))
            .foregroundStyle(SupervisionTokens.muted.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(WeirLayout.Supervision.addTabMenuItemInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: Text {
        switch note {
        case .agentAlreadyWorking:
            Text("An agent is already working in this folder. Editing at the same time may cause conflicts.")
        case .noAgentFound:
            // Named from the catalog, so an agent added to it is named
            // here too.
            Text("No agents found. Weir lists \(agentNames) found on your PATH.")
        }
    }

    /// Every agent the catalog has, by its product name, as a list in the
    /// window's language.
    private var agentNames: String {
        AgentCatalog.entries.map(\.displayName).formatted(.list(type: .and).locale(locale))
    }
}

/// One item: the badge the new tab will wear, its name, and the key that
/// adds it from anywhere.
private struct AddTabMenuItem: View {
    let title: Text
    /// The agent the tab runs, whose badge the item shows; `nil` for a
    /// shell.
    let agent: AgentKind?
    /// "⌘T", as the person has it assigned.
    var shortcut: String?
    /// The arrow keys' item, or the one under the pointer.
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
                PaneStripTabBadge(agent: agent)
                    .alignmentGuide(.firstTextBaseline) {
                        $0[VerticalAlignment.center] + WeirLayout.Supervision.addTabMenuBadgeRaise
                    }
                title
                    .font(.supervision(.body))
                    .foregroundStyle(SupervisionTokens.text.color)
                Spacer(minLength: WeirLayout.Supervision.spaceS)
                if let shortcut {
                    KeyComboText(shortcut, size: .meta, weight: .regular)
                        .foregroundStyle(SupervisionTokens.muted.color)
                }
            }
            .padding(WeirLayout.Supervision.addTabMenuItemInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The pointer selects the item it is over (`onHover`), so the
            // selection's fill is the only one the item draws.
            .dropdownRowBackground(
                isSelected: isSelected,
                isHovering: false,
                cornerRadius: WeirLayout.Supervision.addTabMenuItemCornerRadius
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                onHover()
            }
        }
    }
}
