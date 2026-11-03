//! What a hook call leaves on disk when the run record cannot be replaced:
//! one a newer build wrote stays as it is, and a turn whose run record did
//! not write goes with it, while one the record already named keeps its
//! snapshot. Unix only: the hook runtime itself only runs there, and the
//! failed write is made with directory permissions.
#![cfg(unix)]

mod support;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use support::{
    RUN, Repo, SESSION_START, STOP, call, only_turn, prompt, read_turns, turn_env, turn_ref,
};
use weir_agent_hook::{GitSnapshots, HookRuntime, TURNS_DIRECTORY, read_record, run_hook};
use weir_agent_model::{SnapshotStatus, run_record_file_name};

fn send(states: &Path, payload: &[u8]) {
    let env = turn_env(states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook("claude", payload, &HookRuntime::new(&env, &GitSnapshots));
}

#[test]
fn a_record_a_newer_build_wrote_is_left_as_it_is() {
    let scratch = tempfile::tempdir().expect("scratch");
    let states = scratch.path().join("states");
    fs::create_dir_all(&states).expect("states");
    let record = states.join(run_record_file_name(RUN));
    let newer = br#"{"schemaVersion":4,"paneId":"p","runId":"r","revision":9,"state":"running"}"#;
    fs::write(&record, newer).expect("record");

    send(&states, &prompt(scratch.path()));
    send(&states, STOP);

    assert_eq!(fs::read(&record).expect("record"), newer);
    assert!(
        read_turns(&states).unwrap_or_default().is_empty(),
        "no turn is begun over a run this build cannot read"
    );
}

/// Restores a directory's mode however the test ends.
struct Mode<'a>(&'a Path, u32);

impl Drop for Mode<'_> {
    fn drop(&mut self) {
        let _ = fs::set_permissions(self.0, fs::Permissions::from_mode(self.1));
    }
}

#[test]
fn a_run_record_that_fails_to_write_takes_its_begun_turn_with_it() {
    let scratch = tempfile::tempdir().expect("scratch");
    let states = scratch.path().join("states");
    call(&states, SESSION_START);
    let record = states.join(run_record_file_name(RUN));
    let before = fs::read(&record).expect("record");
    fs::create_dir_all(states.join(TURNS_DIRECTORY)).expect("turns");
    // The turns directory stays writable; the run record's cannot take the
    // replacement, while its lock sidecar is already there to open.
    let _mode = Mode(&states, 0o700);
    fs::set_permissions(&states, fs::Permissions::from_mode(0o500)).expect("chmod");
    // Root writes through the mode, so the write this test needs to fail
    // would not; there is nothing to take back then.
    if fs::write(states.join(".probe"), b"").is_ok() {
        return;
    }

    send(&states, &prompt(scratch.path()));

    // The counter is written just before the turn record, so the turn was
    // begun, and then taken back.
    let counters = fs::read_dir(states.join(TURNS_DIRECTORY))
        .expect("turns")
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().ends_with(".counter"))
        .count();
    assert_eq!(counters, 1, "the turn was begun");
    assert!(
        read_turns(&states).expect("turns").is_empty(),
        "the turn no run record names is taken back"
    );
    assert_eq!(fs::read(&record).expect("record"), before);
    assert_eq!(
        read_record(&record).and_then(|record| record.current_turn_id),
        None
    );
}

#[test]
fn a_turn_ended_while_its_run_record_fails_to_write_keeps_its_end_pinned() {
    let repo = Repo::new("unwritten-end");
    let states = repo.root.join("states");
    call(&states, SESSION_START);
    send(&states, &prompt(&repo.path));
    fs::write(repo.path.join("README.md"), "fixture\nchanged\n").expect("edit");
    let _mode = Mode(&states, 0o700);
    fs::set_permissions(&states, fs::Permissions::from_mode(0o500)).expect("chmod");
    if fs::write(states.join(".probe"), b"").is_ok() {
        return;
    }

    send(&states, STOP);

    // The run record still names the turn, so it stays, with the end the
    // stop wrote; the tree that end holds is pinned like any other.
    let turn = only_turn(&states);
    assert!(
        matches!(turn.end, SnapshotStatus::Captured { .. }),
        "the stop recorded the turn's end"
    );
    assert!(turn_ref(&repo, &turn.turn_id, "end").is_some());
}
