// ReviewSessionFocus.swift
// Weir — a review's session on screen in its pane before anything is pasted there.

import Foundation
import WeirDomain

/// A paste goes to the session on screen, whichever that is, and text sent to the wrong
/// conversation is worse than none. So for a process with tabs, even one tab, the review
/// asks its plugin to bring the session forward and say what it shows, and pastes only
/// on that answer. Its home screen, a tab closed since, and a tab behind all go this way,
/// and a closed one opens again.
///
/// The answer is a read of the screen milliseconds old, not a guarantee: a person switching
/// tabs in the moment between that read and the paste still moves it to the tab
/// they went to. Nothing outside OpenCode can close that window.
@MainActor
enum ReviewSessionFocus {
    /// Longer than the plugin's look for a request and a tab coming forward on a busy
    /// machine; short enough to still feel like pressing Insert.
    static let limit: Duration = .seconds(4)

    /// The conversation a paste into `pane` goes to, as `show` brings it forward: the
    /// reviewed one, when it is one of the sessions of an agent with tabs in that pane;
    /// else `nil`, and the pane's header names what is on screen. The destination menu
    /// names a pane by this, so what it says is where the text lands.
    static func conversation(
        reviewed: ConversationKey?,
        inPane pane: UUID,
        runtimes: [AgentRuntimePresentation]
    ) -> ConversationKey? {
        guard let reviewed else { return nil }
        let isInPane = runtimes.contains { run in
            run.conversation == reviewed
                && run.paneIDs.contains(pane)
                && run.tabChannel != nil
                && (run.tmuxLocations[pane]?.isActive ?? true)
        }
        return isInPane ? reviewed : nil
    }

    /// Whether the session a review of `conversation` belongs to is in front of what
    /// will take the text. Only the agent the pane hosts counts, in the tmux pane in front:
    /// another agent's run there, or a process gone since, has no say, and its
    /// channel would answer nothing. An agent with no tabs, or a pane with no run of
    /// one, has nothing to ask. The run gives both channel and session, as one pair.
    static func show(
        conversation: ConversationKey?,
        destination: ReviewDestination,
        runtimes: () -> [AgentRuntimePresentation],
        limit: Duration = limit,
        isAlive: (pid_t) -> Bool = ProcessLiveness.isLive,
        under root: URL = WeirPaths.applicationSupportDirectory()
    ) async -> Bool {
        // A run with a channel is one of an agent with tabs; no other has one.
        guard let agent = destination.agent else { return true }
        let pane = destination.paneID
        let receivers = runtimes().filter { run in
            run.kind == agent
                && run.paneIDs.contains(pane)
                && (run.tmuxLocations[pane]?.isActive ?? true)
                && run.tabChannel != nil
                && run.processID.map(isAlive) ?? true
        }
        let wanted = receivers.first { $0.conversation != nil && $0.conversation == conversation }
        // With none named, the latest of a live family: a closed tab may be all that is left.
        let latest = receivers.max { $0.badge.updatedAt < $1.badge.updatedAt }
        guard let channel = (wanted ?? latest)?.tabChannel else { return true }
        return await AgentTabFocus.confirm(
            sessionID: wanted?.sessionID,
            channel: channel,
            limit: limit,
            under: root
        )
    }
}
