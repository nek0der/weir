//! What the platform needs to know about the Antigravity CLI.

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
            display_name: "Antigravity".to_owned(),
            capabilities: BTreeSet::from([
                Capability::Resume,
                Capability::ResumeDefersToOtherLiveSession,
                Capability::WorktreeEvents,
                Capability::Subagents,
                Capability::TurnSnapshot,
                // `agy` sends no hook for Esc, Ctrl+C, or a "No" at its own
                // prompt, and reports `idle` for each (agy 1.4.12).
                Capability::ProgramStatusIdleStopsTurn,
                // It has no `PermissionRequest`: only its status report says
                // that it waits on the person's leave.
                Capability::ProgramStatusAnnouncesPermission,
                // A failure before the first request sends no hook, and only
                // its status report says so (agy 1.4.12, offline).
                Capability::ProgramStatusAnnouncesFailure,
                // Signed in, it reports `auth` for up to 2.1 seconds as it
                // starts, then `idle` or its trust prompt (agy 1.4.12).
                Capability::ProgramStatusAuthSettles,
            ]),
            // `agy` has no session end hook, so the host's pid sweep is what
            // retires a run.
            pid_sweep_interval_ms: 3_000,
            state_directory: ProviderDescriptor::default_state_directory(&id),
            session_directory: ProviderDescriptor::default_session_directory(&id),
            cwd_events_directory: None,
            // The cask's `agy` is a symlink to a binary named `antigravity`.
            process_names: vec!["agy".to_owned(), "antigravity".to_owned()],
            session_end_drop_reasons: Vec::new(),
            internal_agent_directories: Vec::new(),
            program_status_app: Some("antigravity".to_owned()),
            id,
        }
    })
}

pub(crate) fn install_recipe() -> InstallRecipe {
    InstallRecipe {
        environment: vec![
            RecipeVariable {
                name: "WEIR_ANTIGRAVITY_AGENT_STATES_DIR".to_owned(),
                value: RecipePlaceholder::StateDirectory,
            },
            RecipeVariable {
                name: "WEIR_ANTIGRAVITY_SESSIONS_DIR".to_owned(),
                value: RecipePlaceholder::SessionDirectory,
            },
            RecipeVariable {
                name: "WEIR_USAGE_DIR".to_owned(),
                value: RecipePlaceholder::UsageDirectory,
            },
        ],
        settings_fragments: Vec::new(),
    }
}
