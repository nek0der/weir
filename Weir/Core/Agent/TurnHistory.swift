// TurnHistory.swift
// Weir — every recorded turn, by conversation, as the last projection pass read them.

import Foundation
import Observation
import OSLog
import WeirDomain

private let log = Logger.weir("agent.turn-history")

/// The recorded turns of every conversation the hooks have written.
///
/// Replaced whole when a projection pass reports the turns (it leaves them
/// out when no turn and no run changed), and left as it was by one that
/// fails, like the runtimes. Views read a conversation's turns here by the
/// key a runtime carries (`AgentRuntimePresentation.conversation`).
@MainActor
@Observable
final class TurnHistory {
    /// Each conversation's turns, in display order.
    private(set) var conversations: [ConversationKey: [TurnSummary]] = [:]
    /// Whether a pass has reported the turns once. Before then an empty
    /// history says nothing about which turns are unread.
    private(set) var hasLoaded = false
    /// Counts each change of `conversations`, so a value derived from the
    /// whole history (`AppState.restoredTurnIDs`) is worked out again only
    /// when it changes, without comparing every turn to tell.
    private(set) var revision = 0
    /// How many conversations the last pass that reported them could not
    /// read, so the notice comes only on a change.
    @ObservationIgnored private var skipped = SkippedEntriesReport()

    /// Runs `body` once a pass has reported the turns: at once when one
    /// has, else on the first.
    func whenLoaded(_ body: @escaping @MainActor () -> Void) {
        if hasLoaded {
            body()
            return
        }
        withObservationTracking {
            _ = hasLoaded
        } onChange: { [weak self] in
            Task { @MainActor in self?.whenLoaded(body) }
        }
    }

    /// `skipped` counts the conversations the pass reported that did not
    /// decode (`AgentProjectionLossyList`).
    func replace(with list: [ConversationTurns], skipped skippedCount: Int = 0) {
        if !hasLoaded {
            hasLoaded = true
        }
        if let count = skipped.newCount(skippedCount) {
            log.notice("skipped \(count, privacy: .public) conversations this build cannot read")
        }
        let next = Dictionary(list.map { ($0.key, $0.turns) }, uniquingKeysWith: { first, _ in first })
        // Assigned only on a change, so a pass that read nothing new does not
        // invalidate every view that reads a conversation.
        if next != conversations {
            conversations = next
            revision &+= 1
        }
    }

    /// `key`'s turns, in display order; empty when it has none.
    func turns(of key: ConversationKey) -> [TurnSummary] {
        conversations[key] ?? []
    }

    /// The turn with `id`, in whichever conversation it is.
    func turn(_ id: TurnID) -> TurnSummary? {
        for turns in conversations.values {
            if let turn = turns.first(where: { $0.turnID == id }) {
                return turn
            }
        }
        return nil
    }
}

/// When to say that a list skipped entries. Every pass that reports the list
/// again skips the same ones, and a line for each would bury the log; so only
/// a count that changed is said. A pass that leaves the list out changed
/// nothing and is not asked.
struct SkippedEntriesReport {
    private var count = 0

    /// The count to log, or nil when there is nothing new to say: the count
    /// is what it was, or every entry decoded again.
    mutating func newCount(_ skipped: Int) -> Int? {
        guard skipped != count else { return nil }
        count = skipped
        return skipped > 0 ? skipped : nil
    }
}
