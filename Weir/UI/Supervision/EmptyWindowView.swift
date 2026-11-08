// EmptyWindowView.swift
// Weir — what a window that shows nothing draws where the session would be: the projects to open, and what else to do.

import SwiftUI

/// The body of a window that shows nothing
/// (`WindowSelection.isChoosingProject`): every project in the sidebar's
/// order, then Open Folder… and All Projects. It is the empty session
/// area's kind of list (`EmptySessionHints`), with its width, its rows'
/// fill, and its keys, so a window with no project and a row with no tab
/// read as the same thing: what to do next.
///
/// Choosing a project no window shows shows it in this window, or with ⌘
/// in a new one; choosing one another window shows brings that window
/// forward, as the sidebar does. The keyboard reaches all of it: the first
/// line is selected as the window opens, ↑ ↓ move, Return opens, and
/// ⌘Return opens a project in a new window. The left rail's Scratch shows
/// the scratch tabs instead. Nothing here is a terminal, so no pane is
/// drawn or reported until the person chooses.
struct EmptyWindowView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var registry
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(\.frecencyStore) private var frecencyStore
    @Environment(\.supervisionWindowHandler) private var actions
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var messageSize = WeirFont.Supervision.Size.label.rawValue
    /// The line the keyboard is on; `nil` until the list has lines.
    @State private var selected: Line?
    @FocusState private var isFocused: Bool

    private typealias Layout = WeirLayout.Supervision

    /// A line of the list: a project, or one of the commands under them.
    enum Line: Hashable {
        case project(UUID)
        case openFolder
        case allProjects
    }

    var body: some View {
        let model = EmptyWindowModel(
            session: session,
            window: window.selection,
            attentionQueue: attentionQueue.queue,
            running: { attention.runningAgentCount(inProject: $0, session: session) }
        )
        let lines = model.rows.map { Line.project($0.id) } + [.openFolder, .allProjects]
        ScrollViewReader { proxy in
            // The commands under the projects stay in sight: the projects
            // scroll past a height of their own, and in a window too short
            // for even that, the whole column scrolls instead of being cut
            // off at the window's edge.
            ViewThatFits(in: .vertical) {
                column(model, listMaxHeight: Layout.emptyWindowListMaxHeight)
                ScrollView {
                    column(model, listMaxHeight: nil)
                }
            }
            .onChange(of: selected) { _, line in
                if let line {
                    proxy.scrollTo(line)
                }
            }
        }
        .frame(maxWidth: Layout.emptySessionHintsWidth)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.downArrow) {
            move(by: 1, in: lines)
            return .handled
        }
        .onKeyPress(.upArrow) {
            move(by: -1, in: lines)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard let selected else { return .ignored }
            run(selected, in: model, opensInNewWindow: press.modifiers.chord == .command)
            return .handled
        }
        .onAppear {
            selected = lines.first
            isFocused = true
        }
        // A panel or menu closing hands the keyboard to a terminal, which
        // this window does not have: the list takes it back, or the keys
        // would reach nothing while the selection still shows.
        .onChange(of: window.openLayers(session: session).isEmpty) { _, isEmpty in
            if isEmpty {
                isFocused = true
            }
        }
        // A project removed or added: the keyboard stays on a line that is
        // there.
        .onChange(of: lines) { _, lines in
            if let current = selected, lines.contains(current) {
                return
            }
            selected = lines.first
        }
        .padding(Layout.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The message, the projects, and the commands under them. With
    /// `listMaxHeight`, the projects scroll past it; without, they are laid
    /// out whole, for a column that scrolls as one.
    private func column(_ model: EmptyWindowModel, listMaxHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // What the area asks, quiet as the hints are: the list below is
            // the answer, and a heading over it outweighed it.
            Text("Open a Project", comment: "A window that shows nothing: the heading over the projects it can open")
                .font(.system(size: messageSize))
                .foregroundStyle(SupervisionTokens.muted.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Layout.spaceS)
                .padding(.bottom, Layout.spaceXS)
            if !model.rows.isEmpty {
                if let listMaxHeight {
                    ScrollView {
                        projectRows(model)
                    }
                    .frame(maxHeight: listMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    projectRows(model)
                }
                DropdownSeparator()
            }
            EmptyHintRow(hint: openFolderHint, isSelected: selected == .openFolder)
                .id(Line.openFolder)
            EmptyHintRow(hint: allProjectsHint, isSelected: selected == .allProjects)
                .id(Line.allProjects)
            if !model.rows.isEmpty {
                keyHints
                    .padding(.horizontal, Layout.spaceS)
                    .padding(.top, Layout.spaceS)
            }
        }
    }

    private func projectRows(_ model: EmptyWindowModel) -> some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                EmptyWindowProjectRow(row: row, isSelected: selected == .project(row.id)) {
                    open(row, opensInNewWindow: $0)
                }
                .id(Line.project(row.id))
            }
        }
    }

    private var openFolderHint: EmptySessionHints.Hint {
        EmptySessionHints.Hint(.openFolder, keyboard: settings.settings.keyboard, isEnabled: true) {
            actions?.openFolder()
        }
    }

    private var allProjectsHint: EmptySessionHints.Hint {
        EmptySessionHints.Hint(.allProjects, keyboard: settings.settings.keyboard, isEnabled: true) {
            window.commands.send(.toggleAllProjects)
        }
    }

    /// Return and ⌘Return, as the hints write keys: the two the list takes
    /// that no row shows.
    private var keyHints: some View {
        HStack(spacing: Layout.spaceM) {
            keyHint("⏎", Text("Open"))
            keyHint("⌘⏎", Text(NewWindowText.actionName))
        }
        .accessibilityElement(children: .combine)
    }

    private func keyHint(_ keys: String, _ label: Text) -> some View {
        HStack(spacing: Layout.spaceXS) {
            SupervisionKeycap(keys: keys, size: .meta, color: hintColor, style: .quiet, scalesWithText: true)
            label
                .font(.supervision(.meta))
                .foregroundStyle(hintColor.color)
        }
    }

    /// The hints' ink: muted, the text color under Increase Contrast.
    private var hintColor: ThemedColor {
        contrast == .increased ? SupervisionTokens.text : SupervisionTokens.muted
    }

    private func move(by offset: Int, in lines: [Line]) {
        guard !lines.isEmpty else { return }
        let index = selected.flatMap { lines.firstIndex(of: $0) } ?? (offset > 0 ? -1 : lines.count)
        selected = lines[min(max(index + offset, 0), lines.count - 1)]
    }

    private func run(_ line: Line, in model: EmptyWindowModel, opensInNewWindow: Bool) {
        switch line {
        case let .project(id):
            guard let row = model.rows.first(where: { $0.id == id }) else { return }
            open(row, opensInNewWindow: opensInNewWindow)
        case .openFolder:
            openFolderHint.run()
        case .allProjects:
            allProjectsHint.run()
        }
    }

    /// Shows the project in this window, or brings forward the window that
    /// shows it, as project ▾ does from a window that shows one
    /// (`WindowRegistry.show(project:in:from:intent:)`). With ⌘
    /// (`opensInNewWindow`), a project no window shows opens in a new
    /// window instead (`WindowRegistry.openInNewWindow`).
    private func open(_ row: EmptyWindowModel.Row, opensInNewWindow: Bool) {
        frecencyStore?.record(ProjectMenuModel.frecencyKey(row.id))
        if opensInNewWindow, row.opensInNewWindow {
            registry.openInNewWindow(project: row.id, in: session, from: window)
        } else {
            registry.show(project: row.id, in: session, from: window, intent: .person)
        }
    }
}

/// A project row with independent window, attention, and running marks.
/// Its tooltip includes the folder and activity.
private struct EmptyWindowProjectRow: View {
    let row: EmptyWindowModel.Row
    let isSelected: Bool
    /// Opens the row; `true` in a new window (⌘-click, or VoiceOver's
    /// "Open in New Window").
    let action: (_ opensInNewWindow: Bool) -> Void
    @Environment(\.locale) private var locale
    @State private var isHovering = false
    /// The name's size, as the hints' names scale (`EmptyHintRow`).
    @ScaledMetric(relativeTo: .body) private var titleSize = WeirFont.Supervision.Size.label.rawValue

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        // A Button, so the keyboard and VoiceOver can press it: only a
        // click reads ⌘ (`NewWindowModifier.isCommandClick`).
        Button { action(NewWindowModifier.isCommandClick) } label: {
            HStack(spacing: Layout.spaceS) {
                ProjectAvatar(name: row.name, paletteIndex: row.paletteIndex, size: .header)
                Text(verbatim: row.name)
                    .font(.system(size: titleSize))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(1)
                    .supervisionTruncation(.name)
                Spacer(minLength: Layout.spaceS)
                mark
                    // The mark stays whole; the name is what a narrow row cuts.
                    .fixedSize()
            }
            .padding(.horizontal, Layout.spaceS)
            .padding(.vertical, Layout.spaceXS)
            .contentShape(Rectangle())
            .dropdownRowBackground(
                isSelected: isSelected,
                isHovering: isHovering,
                cornerRadius: Layout.smallControlCornerRadius
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: row.help(locale: locale)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.name))
        .accessibilityValue(Text(verbatim: row.help(locale: locale)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // VoiceOver's press opens the row as a plain click does; a new
        // window is its own action.
        .accessibilityAction { action(false) }
        .accessibilityActions {
            if row.opensInNewWindow {
                Button { action(true) } label: { Text(NewWindowText.actionName) }
            }
        }
    }

    @ViewBuilder private var mark: some View {
        if row.isInOtherWindow {
            Image(systemName: ContainerSymbol.otherWindow)
                .font(.supervision(.meta))
                .foregroundStyle(SupervisionTokens.muted.color)
                .accessibilityLabel(Text("Other Window"))
                .help(Text("Other Window"))
        }
        ProjectActivityCounts(attention: row.attention, running: row.running)
    }
}
