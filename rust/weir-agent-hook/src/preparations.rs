//! Turn starts saved ahead of the turn, for a provider whose report that a turn
//! began comes after the agent may have started on it
//! (`Capability::TurnBeginPrepared`).
//!
//! A preparation is a begin snapshot with no turn yet. One call takes it and
//! leaves it here, under the generation the provider's side named; the call that
//! says the turn began takes that one and no other. Between the two nothing in
//! the run's record changes, so an input that never becomes a turn leaves no trace
//! of one. A tree nobody names is an unreferenced object until `git gc` gets to
//! it, like any begin before its pin.
//!
//! The file is the run's, so a run keeps at most one: a new preparation means the
//! one before it was not followed by a turn.

use crate::records::{HookLog, atomic_write, ensure_user_only_directory};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use weir_agent_core::SnapshotTaken;
use weir_agent_model::{GitContext, SkippedFile, SnapshotStatus};

const DIRECTORY: &str = "turn-preparations";
/// Files a run left behind with no turn to take them, which the next preparation
/// of any run in this directory clears.
const ABANDONED_AFTER: Duration = Duration::from_hours(24);
/// A start older than this says nothing of what the turn began from. The side
/// that names a generation gives up long before this, so it only guards a clock
/// or a process that stopped in between.
const LIFETIME: Duration = Duration::from_mins(10);

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    generation: String,
    status: SnapshotStatus,
    skipped: Vec<SkippedFile>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git_context: Option<GitContext>,
}

fn path(state: &Path, run_id: &str) -> PathBuf {
    state.join(DIRECTORY).join(format!("{run_id}.json"))
}

/// Keeps `taken` for the turn that names `generation`. A failure costs that turn
/// its start, which it then says it has none of.
pub(crate) fn store(
    state: &Path,
    run_id: &str,
    generation: &str,
    taken: SnapshotTaken,
    log: &HookLog,
) {
    let directory = state.join(DIRECTORY);
    ensure_user_only_directory(&directory);
    sweep(&directory);
    let stored = Stored {
        generation: generation.to_owned(),
        status: taken.status,
        skipped: taken.skipped,
        git_context: taken.git_context,
    };
    let written = serde_json::to_vec(&stored)
        .map_err(|error| error.to_string())
        .and_then(|bytes| {
            atomic_write(&path(state, run_id), &bytes).map_err(|error| error.to_string())
        });
    if let Err(error) = written {
        log.line(&format!("write turn preparation: {error}"));
    }
}

/// The start `generation` names, gone from the directory once taken: a retried
/// call's turn already began from it. `None` when it is missing, stale, or
/// another generation's, which leaves the turn with no start.
pub(crate) fn take(state: &Path, run_id: &str, generation: &str) -> Option<SnapshotTaken> {
    let path = path(state, run_id);
    let bytes = std::fs::read(&path).ok()?;
    let age = std::fs::metadata(&path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| SystemTime::now().duration_since(modified).ok());
    let stored: Stored = serde_json::from_slice(&bytes).ok()?;
    if stored.generation != generation {
        return None;
    }
    let _ = std::fs::remove_file(&path);
    if age.is_none_or(|age| age > LIFETIME) {
        return None;
    }
    Some(SnapshotTaken {
        status: stored.status,
        skipped: stored.skipped,
        git_context: stored.git_context,
    })
}

fn sweep(directory: &Path) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let is_abandoned = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
            .is_some_and(|age| age > ABANDONED_AFTER);
        if is_abandoned {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn taken(tree: &str) -> SnapshotTaken {
        SnapshotTaken {
            status: SnapshotStatus::Captured {
                tree: tree.to_owned(),
                root: "/repo".to_owned(),
            },
            skipped: Vec::new(),
            git_context: None,
        }
    }

    #[test]
    fn a_turn_takes_its_own_generation_once_and_no_other() {
        let state = tempfile::tempdir().expect("directory");
        let log = HookLog::disabled();
        store(state.path(), "RUN", "one", taken("aaa"), &log);
        assert_eq!(take(state.path(), "RUN", "two"), None);
        assert_eq!(take(state.path(), "RUN", "one"), Some(taken("aaa")));
        assert_eq!(take(state.path(), "RUN", "one"), None);
    }

    #[test]
    fn a_new_preparation_replaces_one_no_turn_followed() {
        let state = tempfile::tempdir().expect("directory");
        let log = HookLog::disabled();
        store(state.path(), "RUN", "one", taken("aaa"), &log);
        store(state.path(), "RUN", "two", taken("bbb"), &log);
        assert_eq!(take(state.path(), "RUN", "one"), None);
        assert_eq!(take(state.path(), "RUN", "two"), Some(taken("bbb")));
        assert_eq!(take(state.path(), "RUN", "two"), None);
    }

    #[test]
    fn runs_keep_their_preparations_apart() {
        let state = tempfile::tempdir().expect("directory");
        let log = HookLog::disabled();
        store(state.path(), "A", "one", taken("aaa"), &log);
        assert_eq!(take(state.path(), "B", "one"), None);
        store(state.path(), "B", "one", taken("bbb"), &log);
        assert_eq!(take(state.path(), "A", "one"), Some(taken("aaa")));
        assert_eq!(take(state.path(), "B", "one"), Some(taken("bbb")));
    }
}
