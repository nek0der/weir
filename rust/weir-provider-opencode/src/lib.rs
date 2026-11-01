//! OpenCode adapter.
//!
//! OpenCode runs its sessions on a background service that many terminals share,
//! and it is not tied to one vendor's models. The only part of it that knows which
//! pane a session belongs to is the terminal interface in that pane, so Weir's
//! report comes from a plugin there (`Weir/Resources/opencode-plugin/tui.js`),
//! which runs `weir-hook` for each event of a session the pane sent input to.
//!
//! The plugin keeps OpenCode's event as the payload's `data`, beside the
//! envelope and what one execution added up to. It decides whose an event is;
//! what it means is decided here. The words `anthropic`, `free-limit`, and the
//! like stop at this crate: past it there are only the neutral vocabulary and
//! capabilities.

mod approval;
mod descriptor;
mod failure;
mod normalize;

use serde_json::Value;
use weir_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, CommandRun, HookContext, InstallRecipe,
    NormalizeError, ProviderAdapter, ProviderDescriptor, ProviderOutput, RawHookInput,
    SessionSettings, TurnPreparation, TurnReading, WorktreeIntent,
};

/// The OpenCode provider.
#[derive(Debug, Default, Clone, Copy)]
pub struct OpenCodeAdapter;

/// Stable provider id.
pub const PROVIDER_ID: &str = "opencode";

impl ProviderAdapter for OpenCodeAdapter {
    fn descriptor(&self) -> &ProviderDescriptor {
        descriptor::descriptor()
    }

    fn install_recipe(&self) -> InstallRecipe {
        descriptor::install_recipe()
    }

    fn normalize(
        &self,
        input: RawHookInput<'_>,
        _context: &HookContext,
    ) -> Result<Vec<AgentEvent>, NormalizeError> {
        normalize::normalize(input)
    }

    fn approval_request(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<ApprovalRequest>, NormalizeError> {
        approval::approval_request(input.bytes)
    }

    fn approval_output(&self, decision: &ApprovalDecision, _request: &Value) -> ProviderOutput {
        approval::approval_output(decision)
    }

    fn session_settings(&self, input: RawHookInput<'_>, _context: &HookContext) -> SessionSettings {
        normalize::session_settings(input)
    }

    fn turn_preparation(&self, input: RawHookInput<'_>) -> Option<TurnPreparation> {
        normalize::turn_preparation(input)
    }

    fn prepared_begin(&self, input: RawHookInput<'_>) -> Option<String> {
        normalize::prepared_begin(input)
    }

    fn command_run(&self, input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
        normalize::command_run(input)
    }

    /// The interface can neither stop nor change a tool, so a `git worktree add`
    /// runs as written: no `worktree_intent`, and no reroute. Once it has run, one
    /// that landed in the project's folder gets the project's setup.
    fn worktree_finished(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        normalize::finished_worktree_intent(input)
    }

    fn worktree_finish_is_proven(&self, input: RawHookInput<'_>) -> bool {
        normalize::finished_worktree_is_proven(input)
    }

    fn turn_reading(&self, input: RawHookInput<'_>, _marker: Option<&str>) -> TurnReading {
        normalize::turn_reading(input)
    }
}
