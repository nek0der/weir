//! The values the app defines for itself but the Rust side depends on, or
//! the other way round, checked against the one file both sides read
//! (`rust/fixtures/contract/shared-values.json`). The app's
//! `SharedValuesContractTests` check its own constants against the same file.

use crate::projection::MAX_PROJECTION_INPUT_BYTES;
use serde::Deserialize;
use std::path::Path;
use weir_agent_core::MAX_TITLE_BYTES;
use weir_agent_hook::{PANE_ID_VARIABLE, WORKTREE_ROUTING_FILE};
use weir_agent_model::{MAX_HOOK_INPUT_BYTES, PlanUsageWindow, RunState, UsageLimitScope};
use weir_agent_protocol::MAXIMUM_DECISION_BYTES;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SharedValues {
    maximum_decision_bytes: usize,
    maximum_hook_input_bytes: usize,
    maximum_projection_input_bytes: usize,
    maximum_title_bytes: usize,
    worktree_routing_file_name: String,
    pane_identifier_variable: String,
    at_work_states: Vec<RunState>,
    not_at_work_states: Vec<RunState>,
    usage_limit_scopes: Vec<String>,
    usage_windows: UsageWindows,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageWindows {
    five_hour: String,
    seven_day: String,
    model_weekly: Vec<String>,
    minutes_prefix: String,
}

fn shared_values() -> SharedValues {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/contract/shared-values.json");
    let bytes = std::fs::read(&path).expect("the shared values file");
    serde_json::from_slice(&bytes).expect("the shared values decode")
}

#[test]
fn the_limits_are_the_ones_the_app_checks_against() {
    let shared = shared_values();
    assert_eq!(MAXIMUM_DECISION_BYTES, shared.maximum_decision_bytes);
    // The Hook Helper reads no more of a payload than the adapters accept.
    assert_eq!(MAX_HOOK_INPUT_BYTES, shared.maximum_hook_input_bytes);
    assert_eq!(
        MAX_PROJECTION_INPUT_BYTES,
        shared.maximum_projection_input_bytes
    );
    // The app's buffer for a resolved title holds the longest one the core
    // returns.
    assert_eq!(MAX_TITLE_BYTES, shared.maximum_title_bytes);
}

#[test]
fn the_usage_names_are_the_ones_the_app_words() {
    let shared = shared_values();
    // Every scope, written as the record carries it. The match has no
    // wildcard, so a new scope does not compile until it is listed here.
    let every = [
        UsageLimitScope::Account,
        UsageLimitScope::Upstream,
        UsageLimitScope::Model,
    ];
    for scope in every {
        match scope {
            UsageLimitScope::Account | UsageLimitScope::Upstream | UsageLimitScope::Model => {}
        }
    }
    let words: Vec<String> = every
        .iter()
        .map(|scope| {
            serde_json::to_value(scope)
                .expect("a scope encodes")
                .as_str()
                .expect("a word")
                .to_owned()
        })
        .collect();
    assert_eq!(words, shared.usage_limit_scopes);
    let windows = &shared.usage_windows;
    assert_eq!(PlanUsageWindow::FIVE_HOUR, windows.five_hour);
    assert_eq!(PlanUsageWindow::SEVEN_DAY, windows.seven_day);
    assert_eq!(
        PlanUsageWindow::MODEL_WEEKLY.map(str::to_owned).to_vec(),
        windows.model_weekly
    );
    assert_eq!(PlanUsageWindow::MINUTES_PREFIX, windows.minutes_prefix);
    assert_eq!(
        PlanUsageWindow::kind_named_for_minutes(1440),
        format!("{}1440", windows.minutes_prefix)
    );
}

#[test]
fn the_names_are_the_ones_the_app_writes() {
    let shared = shared_values();
    assert_eq!(WORKTREE_ROUTING_FILE, shared.worktree_routing_file_name);
    assert_eq!(PANE_ID_VARIABLE, shared.pane_identifier_variable);
}

#[test]
fn the_at_work_states_are_the_ones_the_app_counts_as_mid_turn() {
    let shared = shared_values();
    // Every state this build knows is in one of the lists, so a new one has
    // to be placed in the file before either side can ship it. The match has
    // no wildcard: a new variant does not compile until it is listed here.
    let every = [
        RunState::Idle,
        RunState::Running,
        RunState::NeedsInput,
        RunState::Compacting,
        RunState::Finished,
        RunState::Error,
        RunState::Unknown,
    ];
    for state in every {
        match state {
            RunState::Idle
            | RunState::Running
            | RunState::NeedsInput
            | RunState::Compacting
            | RunState::Finished
            | RunState::Error
            | RunState::Unknown => {}
        }
        assert!(
            shared.at_work_states.contains(&state) || shared.not_at_work_states.contains(&state),
            "{state:?} is in neither list"
        );
    }
    for state in shared.at_work_states {
        assert!(state.is_at_work(), "{state:?}");
    }
    for state in shared.not_at_work_states {
        assert!(!state.is_at_work(), "{state:?}");
    }
}
