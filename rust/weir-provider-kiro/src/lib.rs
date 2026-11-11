//! Kiro CLI (`kiro-cli`, its v3 engine) adapter.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records. Kiro's `PreToolUse` can refuse a call or force its own
//! prompt, but not allow one, and Kiro asks again after every hook. So it
//! answers no approvals: it declares neither approval capability, and its own
//! prompt asks.

mod descriptor;
mod normalize;
mod sha256;
mod transcript;

use serde_json::Value;
use weir_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, CommandRun, HookContext, HookRefusal,
    InstallRecipe, NormalizeError, ProviderAdapter, ProviderDescriptor, ProviderOutput,
    RawHookInput, RunRecord, SessionSettings, UnpromptedPrompt, WorktreeIntent,
};

/// The Kiro CLI provider.
#[derive(Debug, Default, Clone, Copy)]
pub struct KiroAdapter;

/// Stable provider id.
pub const PROVIDER_ID: &str = "kiro";

impl ProviderAdapter for KiroAdapter {
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
        _input: RawHookInput<'_>,
    ) -> Result<Option<ApprovalRequest>, NormalizeError> {
        Ok(None)
    }

    fn approval_output(&self, _decision: &ApprovalDecision, _request: &Value) -> ProviderOutput {
        ProviderOutput { stdout: None }
    }

    fn session_settings(&self, input: RawHookInput<'_>, _context: &HookContext) -> SessionSettings {
        normalize::session_settings(input)
    }

    fn transcript_path(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Option<String>, NormalizeError> {
        normalize::transcript_path(input, context)
    }

    fn unprompted_turn_transcript_path(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Option<String>, NormalizeError> {
        normalize::transcript_path(input, context)
    }

    fn turn_marker(&self, input: RawHookInput<'_>) -> Option<String> {
        normalize::turn_marker(input)
    }

    /// Every turn of Kiro's begins with no hook of ours, so its record begins
    /// here: at the turn's first tool, or at its stop when it ran none.
    fn unprompted_prompt(&self, input: RawHookInput<'_>, marker: &str) -> UnpromptedPrompt {
        normalize::unprompted_prompt(input, marker)
    }

    fn applies_to(&self, input: RawHookInput<'_>, record: Option<&RunRecord>) -> bool {
        normalize::applies_to(input, record)
    }

    fn session_started_if_unseen(
        &self,
        input: RawHookInput<'_>,
        record: Option<&RunRecord>,
    ) -> Option<AgentEvent> {
        normalize::session_started_if_unseen(input, record)
    }

    fn command_run(&self, input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
        normalize::command_run(input)
    }

    fn worktree_intent(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        normalize::worktree_intent(input)
    }

    fn worktree_finished(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        normalize::finished_worktree_intent(input)
    }

    /// Kiro takes no rewritten input, so the model is given the command to
    /// run, and writes the folder itself.
    fn worktree_reroute_refusal(
        &self,
        _input: RawHookInput<'_>,
        command: &str,
    ) -> Option<HookRefusal> {
        Some(normalize::worktree_reroute_refusal(command))
    }
}
