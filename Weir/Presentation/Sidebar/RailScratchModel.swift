// RailScratchModel.swift
// Weir — all the left rail's Scratch button draws from.

import Foundation
import WeirDomain

/// All the Scratch button draws from, so a change that touches none of it
/// draws nothing.
struct RailScratchModel: Equatable {
    let isOnScratch: Bool
    let isHighlighted: Bool
    let badge: IconBadge?
    let shortcut: String?
    let hint: String
    /// What VoiceOver reads. It holds the row's fact, so an agent's report on
    /// a scratch tab changes it.
    let spoken: String
    /// The request Answer… opens, while a scratch tab's agent holds one no
    /// card is up for.
    let answerKey: ApprovalKey?
    let hasTabs: Bool

    /// Where a new scratch tab starts, or the home folder when Settings
    /// follows the active tab and there is none to follow.
    @MainActor
    static func startFolder(session: WorkspaceSession, window: WindowID) -> URL {
        session.scratchStartDirectory(in: window) ?? FileManager.default.homeDirectoryForCurrentUser
    }

    @MainActor
    init(
        window: WindowID,
        session: WorkspaceSession,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation],
        approvals: ApprovalLedger,
        isCardUp: (ApprovalKey) -> Bool,
        isHighlighted: Bool,
        shortcut: String?,
        now: Date,
        locale: Locale
    ) {
        let row = SessionSidebarModel.scratchRow(
            window: window,
            sources: SessionSidebarModel.Sources(
                session: session,
                index: SidebarRowIndex(session: session, queue: queue),
                runtimes: runtimes,
                approvals: approvals,
                locale: locale
            ),
            usageLimits: UsageLimits(queue: queue)
        )
        isOnScratch = row.isActive
        self.isHighlighted = isHighlighted
        badge = IconBadge.state(of: row.fact.glyph)
        self.shortcut = shortcut
        hint = SessionRowFactText.scratchHint(startFolder: Self.startFolder(session: session, window: window), locale: locale)
        spoken = SessionRowFactText.spokenLabel(for: row, projectName: nil, now: now, locale: locale)
        answerKey = row.answerKey.flatMap { key in
            approvals.entries[key]?.presentation != nil && !isCardUp(key) ? key : nil
        }
        hasTabs = !session.tabs(in: .loose).isEmpty
    }
}
