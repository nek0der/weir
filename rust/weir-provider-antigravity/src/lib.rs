//! Antigravity CLI (`agy`) adapter.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records. `agy` has no hook that says it is about to ask the
//! person's leave, so it answers no approvals: it declares neither approval
//! capability, and its own prompt asks.

mod descriptor;
mod normalize;
mod status_line;
mod transcript;
mod usage;

use serde_json::Value;
use weir_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, HookContext, InstallRecipe, NormalizeError,
    ProviderAdapter, ProviderDescriptor, ProviderOutput, RawHookInput, RunRecord, SessionSettings,
    StatusLineAdapter, TurnReading, UnpromptedPrompt, WorktreeIntent,
};

/// The Antigravity CLI provider.
#[derive(Debug, Default, Clone, Copy)]
pub struct AntigravityAdapter;

/// Stable provider id.
pub const PROVIDER_ID: &str = "antigravity";

impl ProviderAdapter for AntigravityAdapter {
    fn descriptor(&self) -> &ProviderDescriptor {
        descriptor::descriptor()
    }

    fn install_recipe(&self) -> InstallRecipe {
        descriptor::install_recipe()
    }

    fn status_line(&self) -> Option<&dyn StatusLineAdapter> {
        Some(&status_line::AntigravityStatusLine)
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

    /// `agy` has no way we know of to change a tool's input, so its model is
    /// told to run the command itself, which then meets `agy`'s own policy.
    /// The model wrote the folder, so nothing more needs saying afterward.
    fn worktree_reroute_output(
        &self,
        _input: RawHookInput<'_>,
        command: &str,
    ) -> Option<ProviderOutput> {
        Some(ProviderOutput {
            stdout: Some(normalize::deny_output(&format!(
                "This project keeps its worktrees in another folder. Nothing was created. Run this command instead: {command}"
            ))),
        })
    }

    fn transcript_path(&self, input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
        normalize::transcript_path(input)
    }

    fn turn_transcript_path(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<String>, NormalizeError> {
        normalize::turn_transcript_path(input)
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

    fn turn_marker(&self, input: RawHookInput<'_>) -> Option<String> {
        normalize::turn_marker(input)
    }

    fn unprompted_prompt(&self, input: RawHookInput<'_>, _marker: &str) -> UnpromptedPrompt {
        UnpromptedPrompt {
            cwd: normalize::unprompted_cwd(input),
            ..UnpromptedPrompt::default()
        }
    }

    fn turn_reading(&self, input: RawHookInput<'_>, marker: Option<&str>) -> TurnReading {
        input
            .transcript
            .map_or_else(TurnReading::default, |transcript| {
                transcript::turn_reading(transcript, marker)
            })
    }

    fn transcript_turn_reading(&self, transcript: &[u8], marker: Option<&str>) -> TurnReading {
        transcript::turn_reading(transcript, marker)
    }
}
