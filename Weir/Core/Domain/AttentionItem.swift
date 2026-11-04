// AttentionItem.swift
// Weir — one thing in the attention list: a request, a stop, or an unread turn.

import Foundation

/// An item's identity. One per request, stop, or turn, so dealing with one
/// item never settles another in the same pane.
package enum AttentionItemID: Hashable, Codable, Sendable {
    case approval(ApprovalKey)
    case question(ApprovalKey)
    /// The agent waits at its own prompt and Weir holds no request for
    /// it: the approval service is not running, or did not take the hook.
    case prompt(EpisodeKey)
    case stop(EpisodeKey)
    case unread(TurnID)

    /// The request an approval or a question names; `nil` for every other
    /// item, which has no request behind it.
    package var requestKey: ApprovalKey? {
        switch self {
        case let .approval(key), let .question(key): key
        case .prompt, .stop, .unread: nil
        }
    }
}

/// Where an item happened, which is where the person goes to deal with it.
package enum AttentionSubject: Equatable, Sendable {
    /// `tabID` is `nil` while the pane is not in any tab (being moved).
    case runtime(id: String, provider: AgentKind, paneID: UUID, tabID: UUID?, projectID: UUID?)
    /// A session row with no running agent: the CLI failed before it
    /// started, or the worktree is gone.
    case sessionRow(projectID: UUID?, worktreeRoot: URL)
    /// A request whose agent no pane is known to run yet. Listed rather
    /// than dropped, so a request the person must answer is never hidden
    /// because its session was not matched to a pane.
    case unplaced(provider: AgentKind)

    /// The agent the subject is about; `nil` for a session row's own.
    package var agentKind: AgentKind? {
        switch self {
        case let .runtime(_, provider, _, _, _), let .unplaced(provider): provider
        case .sessionRow: nil
        }
    }

    /// `nil` for a session row or an unplaced request, which have no pane
    /// to show.
    package var paneID: UUID? {
        switch self {
        case let .runtime(_, _, paneID, _, _): paneID
        case .sessionRow, .unplaced: nil
        }
    }

    /// The runtime the item came from; `nil` for a session row or an
    /// unplaced request.
    package var runtimeID: String? {
        switch self {
        case let .runtime(id, _, _, _, _): id
        case .sessionRow, .unplaced: nil
        }
    }

    package var projectID: UUID? {
        switch self {
        case let .runtime(_, _, _, _, projectID): projectID
        case let .sessionRow(projectID, _): projectID
        case .unplaced: nil
        }
    }

    /// Whether this is the session row of the folder at `root`, compared
    /// as the stop's key compares it (`EpisodeKey.Origin.sessionRow`).
    package func isSessionRow(at root: URL) -> Bool {
        guard case let .sessionRow(_, worktreeRoot) = self else { return false }
        return EpisodeKey.Origin.sessionRow(worktreeRoot: worktreeRoot) == .sessionRow(worktreeRoot: root)
    }

    /// The agent the item is about; `nil` for a session row, whose agent
    /// never started.
    package var provider: AgentKind? {
        switch self {
        case let .runtime(_, provider, _, _, _): provider
        case let .unplaced(provider): provider
        case .sessionRow: nil
        }
    }
}

/// The step of starting a new session that was running when it failed.
/// Signing in and the approval service's connection are not stages:
/// neither can be told from outside the agent, which asks in its own
/// terminal.
package enum NewSessionStage: Equatable, Sendable {
    case creatingWorktree
    /// The setup command at this index in the project's list.
    case setup(stepIndex: Int)
    case startingCLI
}

/// Why an agent stopped.
package enum StopReason: Equatable, Sendable {
    case processExited
    /// The provider's own message, shown as is; `nil` when it gave none.
    case error(String?)
    /// The plan's usage limit, with when it resets and which it is, as far
    /// as the provider said.
    case usageLimit(UsageLimit)
    /// Whatever serves the model wants the person to sign in; the service's name
    /// when the agent gave one.
    case signInRequired(upstream: String?)
    /// No route to the model the session asked for; its name when known.
    case modelUnavailable(model: String?)
    case worktreeMissing
    /// The last lines of the failing step's output, for the person to read
    /// without opening a log.
    case launchFailed(NewSessionStage, logTail: String)
    /// The resume Weir typed at launch did not bring the conversation
    /// back: its command returned to the shell, or its deadline passed
    /// (`StopLedger.LaunchResume`). The agent's own words are in the pane.
    case notResumedAtLaunch
}

/// What a finished turn changed in the worktree.
///
/// Three outcomes the person can act on (changed, unchanged, unavailable)
/// plus two that only mean "not yet known". `unchanged` is reported only
/// when the comparison succeeded and found nothing, so "No file changes" is
/// never shown for a turn whose files we could not compare.
package enum ChangeSummary: Equatable, Sendable {
    /// No turn record has been read for this turn, or the record says
    /// something this build does not know (a newer writer's kind).
    case unknown
    /// The record exists but the end snapshot has not landed.
    case pending
    case changed(files: Int, added: Int, removed: Int)
    case unchanged
    /// The reason is for logs and the record view; the person sees one
    /// fixed sentence.
    case unavailable(reason: String)

    /// Whether the turn may have changed files: it did, or what it did is
    /// not known yet or not readable by this build. Such a turn waits for
    /// "Mark as Viewed"; any other is read by opening its pane.
    package var mayHaveChangedFiles: Bool {
        switch self {
        case .changed, .unknown, .pending: true
        case .unchanged, .unavailable: false
        }
    }

    /// Whether ⌘J opens the review on the turn ("Open review when moving to
    /// an unread turn"): it changed files, or its end snapshot is still
    /// being taken. Not a turn with no record (`unknown`), whose review
    /// would have no turn to show.
    package var opensReviewOnJump: Bool {
        switch self {
        case .changed, .pending: true
        case .unknown, .unchanged, .unavailable: false
        }
    }

    /// Whether the changes could not be taken because one of the turn's two
    /// snapshots was never written: an incomplete record, which the review
    /// says rather than guess. Every other reason the record gives
    /// (not a Git work tree, snapshots off, a failed or skipped snapshot, a
    /// diff that could not be judged) is a comparison that cannot be
    /// trusted even with both trees there.
    package var isLostSnapshot: Bool {
        guard case let .unavailable(reason) = self else { return false }
        // The reasons `ChangeSummary::judge` in `weir-agent-model` gives.
        return reason == "beginMissing" || reason == "endMissing"
    }
}

/// The check a turn ran, as the record reports it.
package struct CheckSummary: Equatable, Sendable {
    package let command: String
    /// Whether the output was filtered (for example `--filter`), so a pass
    /// covers only part of the suite.
    package let isFiltered: Bool
    /// `nil` while the check runs, or when the status was not the check's
    /// own (interrupted, in the background, piped on, `|| true`): the
    /// command is shown with no ✓ or ✗.
    package let exitCode: Int?
    /// How many of the turn's checks before this one failed: a pass after
    /// two failures says so, since the turn had trouble getting there.
    package var earlierFailures = 0

    package init(
        command: String,
        isFiltered: Bool,
        exitCode: Int?,
        earlierFailures: Int = 0
    ) {
        self.command = command
        self.isFiltered = isFiltered
        self.exitCode = exitCode
        self.earlierFailures = earlierFailures
    }

    /// The check's own exit code says it failed: the ✗ the receipt draws
    /// in red. Not an exit code that was another command's.
    package var hasFailed: Bool {
        exitCode.map { $0 != 0 } ?? false
    }
}

/// Turns that ended and have not been read, as one item: one turn, or the
/// run of turns that changed files below the viewed line ("T6–T7").
package struct UnreadTurn: Equatable, Sendable {
    /// The first turn the item stands for, which names it: a later turn
    /// joining the run updates the item rather than adding another.
    package let turnID: TurnID
    /// The turns' numbers, first to last. `nil` for a finished episode no
    /// turn record stands for (a provider that keeps none).
    package let numbers: ClosedRange<Int>?
    /// What the turns changed, summed over a run of turns.
    package let changes: ChangeSummary
    /// The last check the latest of the turns ran.
    package let check: CheckSummary?
    /// The conversation whose viewed line reads these turns; `nil` for an
    /// episode no turn record stands for.
    package let conversation: ConversationKey?

    package init(
        turnID: TurnID,
        numbers: ClosedRange<Int>? = nil,
        changes: ChangeSummary,
        check: CheckSummary? = nil,
        conversation: ConversationKey? = nil
    ) {
        self.turnID = turnID
        self.numbers = numbers
        self.changes = changes
        self.check = check
        self.conversation = conversation
    }

    /// Whether the turns may have changed files, so they wait for "Mark as
    /// Viewed" rather than being read by opening their pane.
    package var mayHaveChangedFiles: Bool {
        changes.mayHaveChangedFiles
    }
}

/// An unread item a runtime's turn records ask for, and when it arrived.
package struct UnreadTurnEntry: Equatable, Sendable {
    package let turn: UnreadTurn
    /// When its latest turn ended; `nil` when the record does not say, and
    /// the runtime's own time stands in.
    package let arrivedAt: Date?
}

/// What an approval or question item knows about its request.
package struct ApprovalFact: Equatable, Sendable {
    package let key: ApprovalKey
    package let provider: AgentKind
    package let isQuestion: Bool
    /// Whether Weir can answer this kind of request at all. Codex's
    /// questions are never held, so they are always answered in the TUI.
    package let supportsNativeAnswer: Bool
    package let state: ApprovalRequestState
    /// Held by the request rather than its state, so the time left still
    /// shows after a failed send. `nil` when the service did not report its
    /// own clock (an older service): the card then shows no time left, and
    /// the broker's own expiry is the only timeout.
    package let deadline: ServiceDeadline?

    package init(
        key: ApprovalKey,
        provider: AgentKind,
        isQuestion: Bool,
        supportsNativeAnswer: Bool,
        state: ApprovalRequestState,
        deadline: ServiceDeadline?
    ) {
        self.key = key
        self.provider = provider
        self.isQuestion = isQuestion
        self.supportsNativeAnswer = supportsNativeAnswer
        self.state = state
        self.deadline = deadline
    }

    /// Whether Weir can answer the request on its card now
    /// (`ApprovalRequestState.isAnswerableOnCard(supportsNativeAnswer:)`).
    package var isAnswerableOnCard: Bool {
        state.isAnswerableOnCard(supportsNativeAnswer: supportsNativeAnswer)
    }
}

package enum AttentionItemKind: Equatable, Sendable {
    case approval(ApprovalFact)
    case question(ApprovalFact)
    /// A wait at the agent's own prompt with no request behind it: the
    /// approval or question its run's record says, else, for a record that
    /// does not say, one we cannot name (`PromptWait`).
    case prompt(PromptWait)
    case stop(StopReason)
    case unread(UnreadTurn)

    /// What an approval or a question knows about its request; `nil` for
    /// every other kind, which has no request behind it.
    package var approvalFact: ApprovalFact? {
        switch self {
        case let .approval(fact), let .question(fact): fact
        case .prompt, .stop, .unread: nil
        }
    }

    /// What the item is to the person: a wait at the agent's prompt is the
    /// approval or question its record says, else a wait for a response we
    /// cannot name, or for a sign-in. The one sorting the glyph, the list's
    /// row, the counts, the pane's frame, and the pane's priority read.
    package var category: AttentionCategory {
        switch self {
        case .question, .prompt(.question): .question
        case .approval, .prompt(.approval): .approval
        case .prompt(.unclassified): .response
        case .prompt(.signIn): .signIn
        case .stop: .stop
        case .unread: .unread
        }
    }

    /// Whether the agent asks the person something now: an approval, a
    /// question, or a wait at its own prompt. A stop asks nothing, and an
    /// unread turn waits only to be read.
    package var asksPerson: Bool {
        switch self {
        case .approval, .question, .prompt: true
        case .stop, .unread: false
        }
    }

    /// Whether the item holds the agent's work back until the person acts:
    /// one that asks them (`asksPerson`), or a stop. An unread turn does
    /// not: the agent is free to go on. `AttentionCounts.hasBlockingItems`
    /// counts the same items.
    package var isBlocking: Bool {
        switch self {
        case .approval, .question, .prompt, .stop: true
        case .unread: false
        }
    }
}

/// What an attention item is to the person, as `AttentionItemKind.category`
/// sorts it.
package enum AttentionCategory: Equatable, Sendable, CaseIterable {
    case question
    case approval
    /// A wait at the agent's prompt we cannot name as an approval or a
    /// question.
    case response
    /// The agent waits for the person to sign in again.
    case signIn
    case stop
    case unread
}

/// Whether a row keeps offering "Answer…" while the card is up for the
/// request it would open (`AttentionItem.answerKey(isHeld:whileCardIsUp:)`).
/// Each surface chooses it, not the request, so each caller passes it.
package enum AnswerWhileCardIsUp {
    /// The button stays, and the row is lit as the card's source instead:
    /// the sidebar's rows, the Needs Attention list, and the all projects
    /// cards, which the card stands beside without covering.
    case staysOffered
    /// The button goes while `isCardUp` says the card shows the request:
    /// the rail's Scratch button has no row to light as the card's source,
    /// so a second Answer… in its menu would only point at the card already
    /// open beside the rail.
    case hidden(isCardUp: (ApprovalKey) -> Bool)
}

/// One entry in the attention list.
package struct AttentionItem: Identifiable, Equatable, Sendable {
    package let id: AttentionItemID
    package let kind: AttentionItemKind
    package let subject: AttentionSubject
    /// Assigned by the queue on insertion; the list's order.
    let arrivalSequence: UInt64
    package let arrivedAt: Date

    /// Whether the person answers the item at the agent's own prompt, and
    /// Weir can only take them to its pane: a wait Weir holds no
    /// request for, a request handed to the TUI or left there when its
    /// time ran out, or one Weir can never answer (Codex's questions).
    package var requiresTerminalAnswer: Bool {
        switch kind {
        case let .approval(fact), let .question(fact):
            !fact.supportsNativeAnswer || fact.state.isLeftToTerminal
        case .prompt:
            true
        case .stop, .unread:
            false
        }
    }

    /// Computed rather than stored so it cannot disagree with the request's
    /// state: a card's buttons follow the broker, not a flag someone forgot
    /// to clear.
    package var canAnswerInWeir: Bool {
        kind.approvalFact?.isAnswerableOnCard ?? false
    }

    /// The request a row's "Answer…" opens the card on, or `nil` when the
    /// row offers none: the item is a request Weir can still answer on its
    /// card (`canAnswerInWeir`), the ledger still holds it (`isHeld`), so
    /// the card has a request to show, and the surface does not hide the
    /// button while the card is up for it (`whileCardIsUp`). The one rule
    /// the sidebar, the rail, the Needs Attention list (and through its
    /// rows the menu bar), and All Projects read; every other item offers
    /// only the row, which goes to its pane.
    package func answerKey(
        isHeld: (ApprovalKey) -> Bool,
        whileCardIsUp: AnswerWhileCardIsUp
    ) -> ApprovalKey? {
        guard let key = kind.approvalFact?.key, canAnswerInWeir, isHeld(key) else { return nil }
        switch whileCardIsUp {
        case .staysOffered:
            return key
        case let .hidden(isCardUp):
            return isCardUp(key) ? nil : key
        }
    }
}
