// ProviderCapabilityName.swift
// Weir — the Rust names of the provider capabilities Swift branches on, in one place for the app and the Hook Helper.

import Foundation

/// The capabilities Swift reads from a provider's descriptor
/// (`AgentProviderRegistry.has`, `RustProviderBridge.capabilities`), by the
/// names the Rust model serializes. Kept here, where both the app and the
/// Hook Helper compile it, so a name has one spelling on this side.
/// `ProviderCapabilityTableTests` checks each against the descriptors.
enum ProviderCapabilityName {
    /// The provider reports worktree creation.
    static let worktreeEvents = "worktree_events"
    /// A `git worktree add` can be stopped before it runs and sent to the
    /// project's placement; the project settings give it a toggle.
    static let worktreePlacement = "worktree_placement"
    /// A `git worktree add` already run is proven by its payload alone, and
    /// gets the setup when it lands at the placement.
    static let worktreeFinishProven = "worktree_finish_proven"
    /// Weir never holds the provider's question: its own prompt answers it.
    static let questionAnsweredByAgent = "question_answered_by_agent"
    /// A question's request ends with the turn it was asked in.
    static let questionEndsWithTurn = "question_ends_with_turn"
    /// A permission request the helper does not answer is recorded by it.
    static let approvalHookRecordsLifecycle = "approval_hook_records_lifecycle"
    /// A SIGTERM to the helper withdraws the request.
    static let approvalWithdrawnBySignal = "approval_withdrawn_by_signal"
    /// The agent's own prompt answers a request Weir holds, beside the card.
    static let approvalPromptBesideCard = "approval_prompt_beside_card"
}
