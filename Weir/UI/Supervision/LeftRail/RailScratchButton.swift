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
    @Environment(\.locale) private var locale

    /// How often the spoken time steps: it says minutes.
    private static let clockInterval: TimeInterval = 60

    /// Only the model is made here. The runs it reads change with every word
    /// an agent reports, and the button below is drawn again only when the model
    /// it is handed differs: an agent on another row draws nothing, while one on
    /// a scratch tab changes what VoiceOver reads here.
    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.clockInterval)) { context in
            RailScratchContent(model: RailScratchModel(
                window: window.id,
                session: session,
                queue: attentionQueue.queue,
                runtimes: attention.allRuntimes,
                approvals: approvals.ledger,
                isCardUp: { window.approvalCard.isPresenting($0, in: approvals) },
                isHighlighted: isHighlighted,
                shortcut: settings.settings.keyboard.shortcut(for: .showScratch)?.displayString,
                now: context.date,
                locale: locale
            ))
            .equatable()
        }
        .modifier(SessionRowDropTarget(
            container: .loose,
            project: nil,
            rowDrop: SidebarRowDrop(session: session, dragState: dragState, window: window.id, locale: locale)
        ))
    }
}

/// The button with its menu, drawn from its model (`RailScratchButton`). What
/// its actions need beyond the model they read when they run, not in `body`.
private struct RailScratchContent: View, Equatable {
    let model: RailScratchModel
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.agentProjection) private var agentProjection

    /// The button's frame, which a card asked for from here hangs beside. Not
    /// read by `body`, so a move does not draw the button again.
    @State private var frame: CGRect?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        let answer = answerAction
        RailScratchFace(
            isOnScratch: model.isOnScratch,
            isHighlighted: model.isHighlighted,
            badge: model.badge,
            shortcut: model.shortcut,
            hint: model.hint,
            spoken: model.spoken
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

    /// Answer…, while the model says a request waits for one.
    private var answerAction: (() -> Void)? {
        guard let key = model.answerKey else { return nil }
        return { [window, approvals] in
            guard let request = approvals.ledger.entries[key]?.presentation else { return }
            window.approvalCard.present(request, from: approvals, openedFrom: frame, isOpenedFromRail: true)
        }
    }

    /// The scratch tabs have no worktree to hide or delete: the menu closes
    /// them and shows the folder a new one starts in, as Settings' scratch
    /// folder resolves it (the previous tab's folder by default), and home
    /// when that names none. Home alone would name another folder than the
    /// scratch tabs' as soon as one had moved.
    private var actions: SessionRowActions {
        SessionRowActions(
            revealInFinder: { [session, window] in
                NSWorkspace.shared.activateFileViewerSelecting([RailScratchModel.startFolder(session: session, window: window.id)])
            },
            closeAllTabs: model.hasTabs ? {
                TabActions.closeAllTabs(session, registry: registry, in: .loose, agentProjection: agentProjection, from: window.id)
            } : nil
        )
    }
}

/// The button itself, inside the drop target, which tells it through the
/// environment that a dragged tab or pane would land here: it lights as an
/// open rail button does.
private struct RailScratchFace: View {
    let isOnScratch: Bool
    let isHighlighted: Bool
    let badge: IconBadge?
    let shortcut: String?
    let hint: String
    let spoken: String
    let action: () -> Void
    @Environment(\.isDropTarget) private var isDropTarget

    var body: some View {
        IconControlButton(
            systemImage: WeirShortcutAction.showScratch.iconName,
            name: "Scratch",
            shortcut: shortcut,
            isSelected: isOnScratch,
            isLit: isHighlighted || isDropTarget,
            badge: badge,
            hint: hint,
            value: spoken,
            action: action
        )
    }
}
