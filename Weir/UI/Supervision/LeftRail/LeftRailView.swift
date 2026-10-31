// LeftRailView.swift
// Weir — the left tool window bar: sessions, scratch, all projects, history; update, plan usage, shortcuts, and Settings below.

import Sparkle
import SwiftUI

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
            RailButton(
                systemImage: "list.bullet.rectangle",
                name: WorktreeText.railEntry,
                shortcut: shortcut(.toggleSidebar),
                isSelected: window.isSidebarPresented,
                isLit: highlight == .sidebar
            ) {
                window.commands.send(.toggleSidebar)
            }
            RailScratchButton(isHighlighted: highlight == .scratch)
            RailButton(
                systemImage: WeirShortcutAction.allProjects.iconName,
                name: "All Projects",
                shortcut: shortcut(.allProjects),
                isSelected: window.isAllProjectsPresented,
                isLit: highlight == .allProjects
            ) {
                window.commands.send(.toggleAllProjects)
            }
            // A dot says there is something unread, and no more: a number
            // here reads as a second Needs Attention count. The count is in
            // the VoiceOver value.
            let unread = historyStore.unreadCount
            RailButton(
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
            RailButton(systemImage: "keyboard", name: "Keyboard Shortcuts", shortcut: shortcut(.keyboardShortcuts)) {
                window.commands.send(.toggleKeyboardShortcuts)
            }
            // The same scene ⌘, opens (`OpenSettingsCommand`), so a person
            // who never learned the key still finds Settings here.
            RailButton(systemImage: "gearshape", name: "Settings", shortcut: OpenSettingsCommand.shortcutDisplay) {
                openWindow(id: WeirApp.settingsWindowID)
            }
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

/// One rail icon: quiet until hovered or lit (`RailIconFace`). The pointer
/// resting on it brings up a chip naming it: beside it on the rail, under it in
/// the title bar, where the window's edge leaves no room beside it.
struct RailButton: View {
    var placement = HoverChipPlacement.beside
    let systemImage: String
    let name: LocalizedStringResource
    /// The key that does the same, shown in the chip; `nil` when none is bound.
    let shortcut: String?
    /// Whether what it opens is open, as VoiceOver hears it.
    var isSelected = false
    /// Whether it draws lit, where that differs from `isSelected`: the rail
    /// lights one button at a time (`RailHighlight`).
    var isLit: Bool?
    /// The mark drawn on the icon: a count of unviewed turns, a dot for
    /// unread history. Optional because most icons carry none.
    var badge: RailBadge?
    /// What VoiceOver hears as a hint, when it says more than the name and
    /// the key the chip shows.
    var help: String?
    /// What VoiceOver reads as the button's value: its mark or its state.
    /// Optional because most icons have nothing to read.
    var value: String?
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            RailIconFace(
                systemImage: systemImage,
                isLit: isLit ?? isSelected,
                isHovering: isHovering,
                badge: badge,
                standsOnCorner: placement != .beside
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .hoverChip(name, shortcut: shortcut, placement: placement)
        .accessibilityLabel(Text(name))
        .accessibilityHint(Text(verbatim: help ?? ShortcutHelpText.make(name: name, shortcut: shortcut, locale: locale)))
        .accessibilityValue(Text(verbatim: value ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The face every icon control of the rail and the title bar's edge shares: the
/// icon in `railIcon`'s frame, its mark on the corner, cut into the icon.
struct RailIconFace: View {
    let systemImage: String
    let isLit: Bool
    let isHovering: Bool
    var badge: RailBadge?
    /// Out on the corner, clear of the art, as in the title bar, where a count
    /// is common.
    var standsOnCorner = false

    var body: some View {
        let outset = standsOnCorner ? WeirLayout.Supervision.spaceXS : 0
        Image(systemName: systemImage)
            .foregroundStyle(isLit || isHovering ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
            .railIcon(isSelected: isLit, isHovering: isHovering)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    RailBadgeMark(badge: badge)
                        .offset(x: outset, y: -outset)
                }
            }
            // The badge's ring cuts through the icon and its fill, and
            // no further.
            .compositingGroup()
    }
}

/// An icon's mark, a count in the blue kept for unread and unviewed or in amber,
/// with a ring cut out of the icon under it, so the window's ground shows
/// through, translucent or not, and the mark stands off the icon. The
/// icon draws it in a compositing group, which is all the ring cuts. The
/// dot is the history row's unread dot, centered where a count's center
/// would be, so the mark stays in one place on the icon whichever it is.
struct RailBadgeMark: View {
    let badge: RailBadge

    var body: some View {
        let ring = WeirLayout.Supervision.railBadgeRingWidth
        switch badge {
        case let .count(count, tone):
            let inner = WeirLayout.Supervision.railBadgeSize - 2 * ring
            Text(RailBadge.text(for: count))
                .font(.supervision(.badge, weight: .bold))
                .monospacedDigit()
                .foregroundStyle((tone == .blocking ? SupervisionTokens.onWaiting : SupervisionTokens.onUnreadCount).color)
                .padding(.horizontal, WeirLayout.Supervision.spaceXS)
                .frame(minWidth: inner, minHeight: inner)
                .background(Capsule().fill((tone == .blocking ? SupervisionTokens.waitingCount : SupervisionTokens.unreadCount).color))
                .padding(ring)
                .background(Capsule().fill(.black).blendMode(.destinationOut))
                .fixedSize()
                .offset(y: 1)
        case .dot:
            dot(color: SupervisionTokens.unread.color, size: WeirLayout.Supervision.notificationUnreadDotSize)
        case .waiting:
            dot(color: SupervisionTokens.waiting.color, size: WeirLayout.Supervision.notificationUnreadDotSize)
        case .stopped:
            dot(color: SupervisionTokens.stopped.color, size: WeirLayout.Supervision.usageLimitDotSize)
        }
    }

    private func dot(color: Color, size: CGFloat) -> some View {
        let ring = WeirLayout.Supervision.railBadgeRingWidth
        // How far the ringed dot's corner sits inside a ringed count's.
        let inset = (WeirLayout.Supervision.railBadgeSize - size) / 2 - ring
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .padding(ring)
            .background(Circle().fill(.black).blendMode(.destinationOut))
            .offset(x: -inset, y: 1 + inset)
    }
}

extension View {
    /// A rail icon's frame: 16pt art in a 32pt square, filled while
    /// selected or hovered. Every rail button draws its icon through this.
    /// The fill is as see-through as the window's ground under the rail
    /// (`SurfaceGround`), so an open panel's button is not an opaque box.
    func railIcon(isSelected: Bool, isHovering: Bool) -> some View {
        font(.supervision(WeirLayout.Supervision.railSymbolSize, weight: .regular))
            .frame(width: WeirLayout.Supervision.railButtonSize, height: WeirLayout.Supervision.railButtonSize)
            .background(SurfaceGround {
                RoundedRectangle(cornerRadius: WeirLayout.Supervision.railButtonCornerRadius, style: .continuous)
                    .fill(isSelected ? SupervisionTokens.railSelection.color : isHovering ? SupervisionTokens.hover.color : .clear)
            })
            .contentShape(Rectangle())
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
            .railIcon(isSelected: isLit, isHovering: isHovering)
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
