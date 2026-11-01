// LeftRailView.swift
// Weir — the left tool window bar: sessions, scratch, all projects, history; update, plan usage, shortcuts, and Settings below.

import Sparkle
import SwiftUI
import WeirDomain

/// The left rail: the entries to what does not depend on the current
/// session. Its top holds what the work uses (the sessions sidebar, the
/// scratch tabs, all projects, the notification history); its bottom, help and app-wide
/// entries (an update when there is one, the agents' plan usage, the
/// keyboard shortcuts, Settings), with space between the two. Icons only,
/// each named by its hover chip and VoiceOver label.
struct LeftRailView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationHistoryStore.self) private var historyStore
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(ProjectWindowState.self) private var window
    @Environment(UpdateStateModel.self) private var updateState
    @Environment(\.sparkleUpdater) private var updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    /// The history control's frame, in global coordinates: its panel opens
    /// beside it, level with the rail's top.
    @State private var historyButtonFrame: CGRect = .zero
    /// The plan usage control's frame, in the same coordinates: its panel
    /// opens beside it.
    @State private var usageButtonFrame: CGRect = .zero
    /// The rail's own frame: it runs the body's height, so its top and
    /// bottom are the columns'.
    @State private var railFrame: CGRect = .zero
    /// Whether the update popover is open, which the rail's one lit button
    /// reads.
    @State private var isUpdateOpen = false

    private var highlight: RailHighlight {
        let selection = window.selection
        return RailHighlight.of(
            isSidebarPresented: window.isSidebarPresented,
            isOnScratch: selection.activeContainerID == .loose && !selection.isChoosingProject,
            isAllProjectsPresented: window.isAllProjectsPresented,
            isHistoryPresented: historyPresentation.isPresented,
            isPlanUsagePresented: window.planUsage.isPresented,
            // With no update left to show, its button and popover are gone.
            isUpdatePresented: isUpdateOpen && updateState.showsBadge
        )
    }

    var body: some View {
        RailColumn {
            let highlight = highlight
            // A list, as the sidebar is, rather than the menu's sidebar
            // symbol, which says where a panel goes, not what it holds.
            IconControlButton(
                systemImage: "list.bullet.rectangle",
                name: WorktreeText.railEntry,
                shortcut: shortcut(.toggleSidebar),
                isSelected: window.isSidebarPresented,
                isLit: highlight == .sidebar
            ) {
                window.commands.send(.toggleSidebar)
            }
            .heldKeyCap(.toggleSidebar)
            RailScratchButton(isHighlighted: highlight == .scratch)
            IconControlButton(
                systemImage: WeirShortcutAction.allProjects.iconName,
                name: "All Projects",
                shortcut: shortcut(.allProjects),
                isSelected: window.isAllProjectsPresented,
                isLit: highlight == .allProjects
            ) {
                window.commands.send(.toggleAllProjects)
            }
            .heldKeyCap(.allProjects)
            // A dot says there is something unread, and no more: a number
            // here reads as a second Needs Attention count. The count is in
            // the VoiceOver value.
            let unread = historyStore.unreadCount
            IconControlButton(
                systemImage: "bell",
                name: "Notification History",
                shortcut: shortcut(.notificationHistory),
                isSelected: historyPresentation.isPresented,
                isLit: highlight == .history,
                badge: NotificationHistoryRailText.badge(unread: unread),
                value: NotificationHistoryRailText.unreadCount(unread, locale: locale)
            ) {
                toggleNotificationHistory(historyPresentation, session: session)
            }
            .heldKeyCap(.notificationHistory)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                historyButtonFrame = frame
                anchorPanels()
            }
        } bottom: {
            // Only while there is something to say about an update, so
            // the shortcuts below stay in place the rest of the time.
            if updateState.showsBadge, let updater {
                RailUpdateButton(updater: updater, isOpen: $isUpdateOpen, isLit: highlight == .update)
            }
            RailPlanUsageButton(isLit: highlight == .planUsage)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    usageButtonFrame = frame
                    anchorPanels()
                }
            IconControlButton(systemImage: "keyboard", name: "Keyboard Shortcuts", shortcut: shortcut(.keyboardShortcuts)) {
                window.commands.send(.toggleKeyboardShortcuts)
            }
            .heldKeyCap(.keyboardShortcuts)
            // The same scene ⌘, opens (`OpenSettingsCommand`), so a person
            // who never learned the key still finds Settings here.
            IconControlButton(systemImage: "gearshape", name: "Settings", shortcut: OpenSettingsCommand.shortcutDisplay) {
                openWindow(id: WeirApp.settingsWindowID)
            }
            .heldKeyCap(chord: .command) { "," }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            railFrame = frame
            anchorPanels()
        }
    }

    /// The rail runs the body's height, so its top and bottom are the
    /// columns'.
    private func anchorPanels() {
        window.historyAnchor = RailPanelAnchor(
            frame: historyButtonFrame,
            columnTop: railFrame.minY,
            columnBottom: railFrame.maxY
        )
        window.planUsage.anchor = RailPanelAnchor(
            frame: usageButtonFrame,
            columnTop: railFrame.minY,
            columnBottom: railFrame.maxY
        )
    }

    private func shortcut(_ action: WeirShortcutAction) -> String? {
        settings.settings.keyboard.shortcut(for: action)?.displayString
    }
}

/// A rail's column: its icons from the top, a gap, and its icons at
/// the bottom, running the body's height as the surfaces beside it do. The
/// first icon is centered on the surfaces' heading line and the last on
/// the foot bars' line (`railTopInset`, `railBottomInset`).
struct RailColumn<Top: View, Bottom: View>: View {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        VStack(spacing: Layout.railButtonSpacing) {
            top()
            Spacer(minLength: Layout.railGroupMinimumGap)
            bottom()
        }
        .padding(.top, Layout.railTopInset)
        .padding(.bottom, Layout.railBottomInset)
        .frame(width: Layout.railWidth)
        .frame(maxHeight: .infinity)
    }
}

/// The rail's update icon, drawn in the accent color, opening the
/// update popover beside the rail.
private struct RailUpdateButton: View {
    let updater: SPUUpdater
    @Binding var isOpen: Bool
    /// Whether this is the one button the rail lights (`RailHighlight`).
    let isLit: Bool
    @Environment(UpdateStateModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.weirAccent) private var accent
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            UpdateStatusGlyph(
                state: model.state,
                color: SupervisionTokens.accentIcon(settings.settings.appearance.accentColor)
            )
            .iconControlFrame(isLit: isLit, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .hoverChip(model.state.helpText, shortcut: nil, placement: .beside)
        // When the update is done with, the button goes and leaves the state.
        .onDisappear { isOpen = false }
        .accessibilityLabel(Text(model.state.helpText))
        .accessibilityValue(Text(verbatim: model.state.progressValueText(locale: locale)))
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            UpdatePopover(updater: updater) {
                isOpen = false
            }
            .environment(\.locale, locale)
            .weirAccentPropagated(accent)
        }
    }
}
