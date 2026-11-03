//! What the platform needs to know about OpenCode.

use crate::PROVIDER_ID;
use std::collections::BTreeSet;
use std::sync::OnceLock;
use weir_agent_model::{
    Capability, InstallRecipe, ProviderDescriptor, ProviderId, RecipePlaceholder, RecipeVariable,
};

pub(crate) fn descriptor() -> &'static ProviderDescriptor {
    static DESCRIPTOR: OnceLock<ProviderDescriptor> = OnceLock::new();
    DESCRIPTOR.get_or_init(|| {
        let id = ProviderId::new(PROVIDER_ID).expect("static id is valid");
        ProviderDescriptor {
            display_name: "OpenCode".to_owned(),
            capabilities: BTreeSet::from([
                Capability::Resume,
                Capability::ResumeDefersToOtherLiveSession,
                Capability::WorktreeEvents,
                // No hook comes before its tools, so a worktree is only finished
                // after the fact, when its payload proves it.
                Capability::WorktreeFinishProven,
                Capability::ApprovalHook,
                // Its permission prompt stays up beside the card.
                Capability::ApprovalPromptBesideCard,
                Capability::TurnSnapshot,
                // Its events reach the pane after the service has begun, so the
                // plugin saves the start at the Enter that sends the input.
                Capability::TurnBeginPrepared,
                // The plugin's `cancelApproval` ends the helper with a SIGTERM
                // when the person answers at OpenCode's own prompt.
                Capability::ApprovalWithdrawnBySignal,
            ]),
            // Nothing says OpenCode's interface closed, so the host's pid sweep
            // is what retires a run.
            pid_sweep_interval_ms: 3_000,
            state_directory: ProviderDescriptor::default_state_directory(&id),
            session_directory: ProviderDescriptor::default_session_directory(&id),
            cwd_events_directory: None,
            process_names: vec!["opencode".to_owned()],
            session_end_drop_reasons: Vec::new(),
            internal_agent_directories: Vec::new(),
            // Its reports add up every session of the shared service, so they
            // say nothing of this pane's; only the plugin's events do. The name
            // tells the host the agent is in front of the pane.
            program_status_app: Some("opencode".to_owned()),
            id,
        }
    })
}

pub(crate) fn install_recipe() -> InstallRecipe {
    InstallRecipe {
        environment: vec![
            RecipeVariable {
                name: "WEIR_OPENCODE_AGENT_STATES_DIR".to_owned(),
                value: RecipePlaceholder::StateDirectory,
            },
            RecipeVariable {
                name: "WEIR_OPENCODE_SESSIONS_DIR".to_owned(),
                value: RecipePlaceholder::SessionDirectory,
            },
        ],
        settings_fragments: Vec::new(),
    }
}
