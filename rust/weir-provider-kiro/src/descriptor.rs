//! What the platform needs to know about the Kiro CLI.

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
            display_name: "Kiro".to_owned(),
            capabilities: BTreeSet::from([
                Capability::Resume,
                Capability::ResumeDefersToOtherLiveSession,
                Capability::WorktreeEvents,
                // Its `PreToolUse` refuses a call by exit status 2, which
                // keeps the agent's command from running and tells its model
                // the one to run instead.
                Capability::WorktreePlacement,
                Capability::TurnSnapshot,
                // Esc sends no hook, and Kiro reports `idle` (kiro-cli 2.37.1).
                Capability::ProgramStatusIdleStopsTurn,
                // No hook says it waits on the person's leave: its own prompt
                // asks after every hook, and only its status report says so.
                Capability::ProgramStatusAnnouncesPermission,
                // No hook carries an error: only its status report says a
                // turn failed.
                Capability::ProgramStatusAnnouncesFailure,
            ]),
            // We do not subscribe Kiro's `SessionEnd`, so the host's pid
            // sweep is what retires a run.
            pid_sweep_interval_ms: 3_000,
            state_directory: ProviderDescriptor::default_state_directory(&id),
            session_directory: ProviderDescriptor::default_session_directory(&id),
            cwd_events_directory: None,
            // `kiro-cli` stays the parent of the engine it starts.
            process_names: vec!["kiro-cli".to_owned()],
            session_end_drop_reasons: Vec::new(),
            internal_agent_directories: Vec::new(),
            program_status_app: Some("kiro-cli".to_owned()),
            id,
        }
    })
}

pub(crate) fn install_recipe() -> InstallRecipe {
    InstallRecipe {
        environment: vec![
            RecipeVariable {
                name: "WEIR_KIRO_AGENT_STATES_DIR".to_owned(),
                value: RecipePlaceholder::StateDirectory,
            },
            RecipeVariable {
                name: "WEIR_KIRO_SESSIONS_DIR".to_owned(),
                value: RecipePlaceholder::SessionDirectory,
            },
        ],
        settings_fragments: Vec::new(),
    }
}
