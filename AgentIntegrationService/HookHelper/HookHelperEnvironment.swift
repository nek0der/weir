// HookHelperEnvironment.swift
// Weir — the names the Hook Helper reads from the environment its hook runs in.

/// Variables the app's shim exports for the agent it starts, which every
/// hook the agent runs inherits.
enum HookHelperEnvironment {
    /// The agent run the hook belongs to, a UUID, which the shim sets for an
    /// agent started in a Weir pane.
    static let agentRunID = "WEIR_AGENT_RUN_ID"
}
