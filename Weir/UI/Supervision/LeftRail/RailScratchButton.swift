// RailScratchButton.swift
// Weir — the left rail's entry to the tabs outside any project.

import AppKit
import SwiftUI
import WeirDomain

/// Opens the scratch tabs, the terminals that belong to no project. A place
/// of its own, reached with or without the sidebar. Its mark says what most
/// needs the person there, VoiceOver hears the rest, and its menu answers what
/// it waits on. A dragged tab or pane lands on it, and its menu holds what the
/// tabs share.
struct RailScratchButton: View {
    /// Whether this is the one button the rail lights (`RailHighlight`).
    let isHighlighted: Bool
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(WeirDragState.self) private var dragState
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.agentProjection) private var agentProjection
    @Environment(\.locale) private var locale

    /// The button's frame, which a card asked for from here hangs beside. Not
    /// read by `body`, so a move does not draw the button again.
    @State private var frame: CGRect?
    /// How often the spoken time steps: it says minutes.
    private static let clockInterval: TimeInterval = 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.clockInterval)) { context in
            button(now: context.date)
        }
        .modifier(SessionRowDropTarget(
            container: .loose,
            project: nil,
            rowDrop: SidebarRowDrop(session: session, dragState: dragState, window: window.id, locale: locale)
        ))
    }

    private func button(now: Date) -> some View {
        let queue = attentionQueue.queue
        let row = SessionSidebarModel.scratchRow(
            window: window.id,
            sources: SessionSidebarModel.Sources(
                session: session,
                index: SidebarRowIndex(session: session, queue: queue),
                runtimes: attention.allRuntimes,
                approvals: approvals.ledger,
                locale: locale
            ),
            usageLimits: UsageLimits(queue: queue)
        )
        let answer = answerAction(row)
        return RailScratchFace(
            isOnScratch: row.isActive,
            isHighlighted: isHighlighted,
            badge: RailBadge.state(of: row.fact.glyph),
            shortcut: settings.settings.keyboard.shortcut(for: .showScratch)?.displayString,
            hint: SessionRowFactText.scratchHint(startFolder: startFolder, locale: locale),
            spoken: SessionRowFactText.spokenLabel(for: row, projectName: nil, now: now, locale: locale)
        ) {
            SupervisionWindowActions.showScratch(in: window, session: session)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .contextMenu {
            if let answer {
                Button("Answer…", action: answer)
                Divider()
            }
            SessionRowActionsMenu(actions: actions)
        }
        .accessibilityActions {
            if let answer {
                Button("Answer…", action: answer)
            }
        }
    }

    /// Answer…, while a scratch tab's agent holds a request no card is up for.
    private func answerAction(_ row: SessionSidebarModel.Row) -> (() -> Void)? {
        guard let key = row.answerKey,
              let request = approvals.ledger.entries[key]?.presentation,
              !window.approvalCard.isPresenting(key, in: approvals)
        else { return nil }
        return { [window, frame] in
            window.approvalCard.present(request, from: approvals, openedFrom: frame, isOpenedFromRail: true)
        }
    }

    /// Where a new scratch tab starts, or the home folder when Settings
    /// follows the active tab and there is none to follow.
    private var startFolder: URL {
        session.scratchStartDirectory(in: window.id) ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The scratch tabs have no worktree to hide or delete: the menu closes
    /// them and shows the folder a new one starts in, as Settings' scratch
    /// folder resolves it (the previous tab's folder by default), and home
    /// when that names none. Home alone would name another folder than the
    /// scratch tabs' as soon as one had moved.
    private var actions: SessionRowActions {
        SessionRowActions(
            revealInFinder: {
                NSWorkspace.shared.activateFileViewerSelecting([startFolder])
            },
            closeAllTabs: session.tabs(in: .loose).isEmpty ? nil : {
                TabActions.closeAllTabs(session, registry: registry, in: .loose, agentProjection: agentProjection, from: window.id)
            }
        )
    }
}

/// The button itself, inside the drop target, which tells it through the
/// environment that a dragged tab or pane would land here: it lights as an
/// open rail button does.
private struct RailScratchFace: View {
    let isOnScratch: Bool
    let isHighlighted: Bool
    let badge: RailBadge?
    let shortcut: String?
    let hint: String
    let spoken: String
    let action: () -> Void
    @Environment(\.isDropTarget) private var isDropTarget

    var body: some View {
        RailButton(
            systemImage: WeirShortcutAction.showScratch.iconName,
            name: "Scratch",
            shortcut: shortcut,
            isSelected: isOnScratch,
            isLit: isHighlighted || isDropTarget,
            badge: badge,
            help: hint,
            value: spoken,
            action: action
        )
    }
}
