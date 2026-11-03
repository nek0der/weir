// AgentBadge.swift
// Weir — the badge and session structs the interface holds for each pane's agent.
//
// The lifecycle rules live in Rust behind `AgentProjectionAdapter`, so
// nothing here reads or reasons about an on-disk record: the projection
// rewrites these structs on every pass.

import Foundation
import WeirDomain

// MARK: - Unified Badge

/// In-memory mirror of one pane's agent lifecycle. Lives on
/// `Tab.agentBadges` keyed by provider and then by split-leaf UUID; the
/// projection is the authority and rewrites this struct to match on every
/// pass.
///
/// Codex populates `firstPrompt`; Claude also supplies its provider title
/// observations so the Rust reducer can select the automatic tab label.
/// All other fields apply to both.
struct AgentBadge: Codable, Equatable {
    /// Strict lifecycle; the views derive the state's glyph from it.
    var state: AgentState

    /// Free-form tag used by the hover tooltip: `tool_name`
    /// (PreToolUse), `error` (StopFailure), Claude's permission-prompt
    /// message (Notification) or `"permission"`, etc. Empty / nil when
    /// there is nothing to add.
    var detail: String?

    /// Wall-clock instant `UserPromptSubmit` was observed: set while a
    /// turn is open. Cleared when the turn ends (`Stop`, `StopFailure`, an
    /// interrupt, or the idle prompt after a turn that stopped without a
    /// `Stop`), on `SessionEnd`, and on a session start other than a
    /// compaction, which keeps the turn it came in open. A run shown at work
    /// without it is working outside a turn (`docs/provider-adapters.md`,
    /// "Work outside a turn"). The tooltip's elapsed-seconds value is computed at render
    /// time as `Date().timeIntervalSince(runStartedAt)` so it never goes
    /// stale.
    var runStartedAt: Date?

    /// `true` while the agent runs inside a tmux session Weir hosts for
    /// it, so the pane strip's tab can mark the pane as one that outlives a quit.
    /// Optional rather than defaulted because synthesized `Codable` applies
    /// no defaults, and a badge persisted before this field existed has to
    /// keep decoding.
    var isTmuxHosted: Bool?

    /// Wall-clock stamp of the record write this badge mirrors. The rules
    /// order writes by `revision` and fall back to this stamp only for records
    /// from before revisions existed; the interface uses it for retention and
    /// as when an attention item arrived.
    var updatedAt: Date

    /// User prompt captured at `UserPromptSubmit` and carried through every
    /// subsequent hook event of the same turn. Used by the "agent finished"
    /// notification body so the user can identify *which* request just
    /// completed. May be `nil` when the hook missed the field.
    var lastPrompt: String?

    /// Base for showing what changed since the prompt was sent. Both values
    /// are optional because older runs and prompts outside Git repositories
    /// have no turn comparison to offer.
    var turnBaseTree: String?
    var turnRoot: String?
    /// The worktree the run's latest prompt was given in, whether or not
    /// its snapshot was taken: where the restore gate looks for the agent,
    /// as Rust does under the worktree lock.
    var worktreeRoot: String?

    /// Session opening prompt, captured once and held as the lowest-priority
    /// agent title. Both providers pass it through Rust.
    var firstPrompt: String?

    /// Provider conversation ID associated with the title observations.
    /// Missing for a run whose session start was not seen, which names
    /// nothing (`PaneHeaderRules.agentTitle`), and in a Codex badge saved
    /// by a build before Codex's ids counted.
    var conversationID: String?

    /// The name the provider keeps for the session: Claude's
    /// `session_title` or `custom-title` (`/rename`), or Codex's thread
    /// name from its `session_index.jsonl`.
    var providerSessionTitle: String?

    /// The title the provider generated, below the session's name: Claude's
    /// `ai-title`.
    var providerGeneratedTitle: String?

    /// Wall-clock instant the agent session began (`SessionStart`).
    /// `Tab.latestAgentSessionPaneID` compares this across Claude /
    /// Codex panes so the most recent session wins the tab title.
    var sessionStartedAt: Date?

    /// The invocation's monotonic launch stamp. Nil for older records that
    /// did not distinguish launches within one wall-clock second.
    var runLaunchOrder: UInt64?

    /// The enclosing invocation, absent for a root launch or older records.
    var parentRunID: String?
    /// The monotonic stamp of the latest hook reporting this run's own
    /// model or permission mode. Older records may lack this stamp.
    var runObservedOrder: UInt64?

    /// The prompt cache window the last finished turn left. Optional
    /// because only a provider with the cache window capability reports
    /// one, a turn may leave it unknown, and a badge persisted before this
    /// field existed has to keep decoding.
    var cacheWindow: AgentCacheWindow?

    /// The usage limit the run stopped at, present only while it rests in
    /// error. Optional so a badge persisted before this field existed
    /// keeps decoding.
    var usageLimit: UsageLimit?

    /// What the run waits on, as the projection spells it ("approval",
    /// "question"), present only while it waits. Kept as the word rather
    /// than `PromptWaitKind` so a kind a newer build writes still decodes,
    /// as none (`promptWaitKind`).
    var waitKind: String?

    /// The tool the run waits to use, present only while it waits.
    /// Optional so a badge persisted before these fields existed keeps
    /// decoding.
    var tool: String?

    /// Why the run stopped when no hook said so, as the projection spells
    /// it ("processExited"), present only on the one pass that shows a run
    /// whose process died at work in error before its record is retired,
    /// or ("waitDeclined") while a run whose wait the person declined at
    /// the agent's prompt shows its turn stopped before its record says so,
    /// or ("interrupted") while a run whose work the person stopped with
    /// Esc or Ctrl+C does.
    /// Kept as the word, as `waitKind` is, so a reason a newer build writes
    /// still decodes.
    var stopReason: String?

    /// Whether the session holds a conversation to resume: `false` for one
    /// started anew and never prompted, which has no transcript, so a stop
    /// of it offers no resume. Optional so a badge persisted before
    /// this field existed keeps decoding, and `nil` when the record does
    /// not say.
    var hasPrompt: Bool?

    /// The work the run left running in the background when its turn
    /// ended, present only while the run rests finished: the projection
    /// drops it once a turn starts, and reports it for Claude alone, as
    /// Codex's hooks do not list what it leaves running. The run stays
    /// finished either way, so the attention list, its counts, and the
    /// notifications do not change with it; the state marks draw the work
    /// on that rest (`SessionRowFact.Agent.isWorkingAfterTurn`), and the
    /// decision bar and the session row say what it is. Optional so a badge
    /// persisted before this field existed keeps decoding.
    var backgroundWork: BackgroundWork?

    /// The model the session runs, as the provider's adapter names it for a
    /// person (`Opus 5.5`, `gpt-6.1-sol`), for the pane header. `nil` until
    /// a hook has said, and in a badge persisted before this field existed.
    var model: String?

    /// How hard the session's model reasons, in the provider's own word
    /// (`medium`, `xhigh`), for the pane header. `nil` until the agent has
    /// said, and in a badge persisted before this field existed.
    var effort: String?

    /// How freely the session may act without asking, as the projection
    /// spells it ("bypassPermissions"). Kept as the word, as `waitKind` is,
    /// so a mode a newer build writes still decodes, as none
    /// (`agentPermissionMode`).
    var permissionMode: String?

    /// Whom the provider goes through for the model, in words for a person
    /// (`OpenRouter`), for a CLI not tied to one vendor; `nil` for one that is,
    /// and in a badge persisted before this field existed.
    var modelUpstream: String?

    /// The role the person chose for the session's agent, in the agent's word
    /// (`plan`); `nil` when it is the ordinary one. Not a permission mode: nothing
    /// says it limits what the agent may do.
    var agentProfile: String?

    /// What the person has to do about the failure the run rests in, as the
    /// projection spells it ("signIn"). Kept as the word, as `waitKind` is.
    var failureKind: String?

    /// `failureKind` with the words it needs, for the attention list.
    var runtimeFailure: RuntimeFailure? {
        switch failureKind {
        case "signIn": .signIn(upstream: modelUpstream)
        case "modelUnavailable": .modelUnavailable(model: model)
        default: nil
        }
    }

    var agentPermissionMode: AgentPermissionMode? {
        permissionMode.flatMap(AgentPermissionMode.init(rawValue:))
    }

    var promptWaitKind: PromptWaitKind? {
        waitKind.flatMap(PromptWaitKind.init(rawValue:))
    }

    /// Whether the run is in error because its process died at work, which
    /// no hook reports.
    var hasProcessExited: Bool {
        stopReason == Self.processExitedReason
    }

    /// The projection's word for a run whose process died at work.
    static let processExitedReason = "processExited"

    /// Whether the run's turn stopped because the person declined the
    /// question or permission prompt it waited on, which no hook reports:
    /// the projection read it from the agent's transcript, and says so
    /// until the record it asks to be written says the turn stopped.
    var isWaitDeclined: Bool {
        stopReason == Self.waitDeclinedReason
    }

    /// This is the projection's word for a wait the person declined at the
    /// agent's own prompt.
    static let waitDeclinedReason = "waitDeclined"
}

// MARK: - Unified SessionInfo

/// In-memory mirror of one pane's resumable agent session. Lives on
/// `Tab.agentSessions` keyed by provider and then by split-leaf UUID; the
/// projection is the authority and rewrites this struct to match.
///
/// The resume builders consume both fields: `sessionId` plugs into
/// the agent's own `resume`/`--resume` flag; `cwd` lets the builder
/// prepend `cd '<cwd>' && …` so the agent finds the original
/// rollout (Claude rejects mismatched cwd; Codex resolves by cwd
/// when `--last` is implied).
struct AgentSessionInfo: Codable, Equatable {
    /// Agent's own session id, suitable for `claude --resume <id>` or
    /// `codex resume <id>`.
    var sessionId: String

    /// Working directory at the time the session was captured. `nil`
    /// (or empty after normalization) means "no usable cwd recorded"
    /// — callers fall back to the surface's cwd.
    var cwd: String?
}
