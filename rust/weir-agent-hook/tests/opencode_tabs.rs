//! Several OpenCode sessions in one pane, one run each, through the hook runtime and
//! real Git: the run a call belongs to is what its environment says.
#![cfg(unix)]

mod support;

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use support::{PANE, Repo};
use weir_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, SnapshotRunner, TurnSide, run_hook,
};
use weir_agent_model::{
    ChangeSummary, RunRecord, RunState, SnapshotStatus, TurnRecord, run_record_file_name,
    session_hint_file_name,
};

const A: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";
const B: &str = "BBBBBBBB-1111-4111-8111-BBBBBBBBBBB2";

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("weir-tabs-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("scratch");
        Self(root)
    }

    fn call(&self, run: &str, repo: Option<&Path>, payload: &Value) {
        let pairs: Vec<(String, String)> = vec![
            ("WEIR_PANE_ID".into(), PANE.into()),
            ("WEIR_AGENT_RUN_ID".into(), run.into()),
            ("WEIR_AGENT_LAUNCH_ORDER".into(), "77".into()),
            (
                "WEIR_OPENCODE_AGENT_STATES_DIR".into(),
                self.0.join("states").display().to_string(),
            ),
            (
                "WEIR_OPENCODE_SESSIONS_DIR".into(),
                self.0.join("sessions").display().to_string(),
            ),
            ("WEIR_OPENCODE_PID".into(), "4242".into()),
            (
                "WEIR_HOOK_INVOCATION_ID".into(),
                uuid::Uuid::new_v4().to_string(),
            ),
        ];
        let env = HookEnv::from_pairs(pairs);
        let env = match repo {
            Some(repo) => env.in_directory(repo.to_path_buf()),
            None => env,
        };
        let bytes = serde_json::to_vec(payload).expect("bytes");
        assert_eq!(
            run_hook("opencode", &bytes, &HookRuntime::new(&env, &GitSnapshots)),
            HookOutcome::Applied,
            "{payload}"
        );
    }

    fn record(&self, run: &str) -> RunRecord {
        let path = self.0.join("states").join(run_record_file_name(run));
        RunRecord::decode(&fs::read(path).expect("record")).expect("decodes")
    }

    fn hint(&self) -> Value {
        let path = self.0.join("sessions").join(session_hint_file_name(PANE));
        serde_json::from_slice(&fs::read(path).expect("hint")).expect("json")
    }

    fn turns(&self) -> Vec<TurnRecord> {
        support::read_turns(&self.0.join("states")).expect("turns")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn session(id: &str) -> Value {
    json!({
        "hook_event_name": "weir.session", "data": {"sessionID": id}, "source": "startup",
        "pane_family": A,
    })
}

fn started(id: &str) -> Value {
    json!({
        "hook_event_name": "session.execution.started", "prompt": "go", "prompt_kind": "user",
        "data": {"sessionID": id},
    })
}

fn shown(run: &str, id: &str) -> Value {
    json!({"hook_event_name": "weir.shown", "shown_run": run, "cwd": "/repo", "data": {"sessionID": id}})
}

#[test]
fn each_session_keeps_its_own_record_under_the_run_the_call_names() {
    let scratch = Scratch::new();
    scratch.call(
        A,
        None,
        &json!({"hook_event_name": "weir.launch", "pane_family": A, "data": {}}),
    );
    scratch.call(A, None, &session("ses_a"));
    scratch.call(B, None, &session("ses_b"));
    let (a, b) = (scratch.record(A), scratch.record(B));
    assert_eq!(a.run_id.as_deref(), Some(A));
    assert_eq!(b.run_id.as_deref(), Some(B));
    assert_eq!(a.session_id.as_deref(), Some("ses_a"));
    assert_eq!(b.session_id.as_deref(), Some("ses_b"));
    assert_eq!(a.pane_family_run_id.as_deref(), Some(A));
    assert_eq!(b.pane_family_run_id.as_deref(), Some(A));
    // A tab is no nested launch: the tmux family rules go by this.
    assert_eq!(b.parent_run_id, None);
    assert_eq!(
        (a.pid.as_deref(), b.pid.as_deref()),
        (Some("4242"), Some("4242"))
    );
    assert_eq!(
        (a.run_launch_order, b.run_launch_order),
        (Some(77), Some(77))
    );
}

#[test]
fn a_wait_in_the_session_behind_leaves_the_shown_sessions_record_alone() {
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    scratch.call(B, None, &session("ses_b"));
    scratch.call(A, None, &started("ses_a"));
    scratch.call(B, None, &started("ses_b"));
    scratch.call(A, None, &shown(B, "ses_b"));
    assert_eq!(scratch.record(A).pane_shown_run_id.as_deref(), Some(B));
    let shown_before = scratch.record(B);
    assert_eq!(shown_before.state, RunState::Running);
    scratch.call(
        A,
        None,
        &json!({
            "hook_event_name": "permission.asked", "tool": "shell",
            "data": {"id": "per_1", "sessionID": "ses_a", "action": "shell"},
        }),
    );
    assert_eq!(scratch.record(A).state, RunState::NeedsInput);
    assert_eq!(scratch.record(B), shown_before);
}

#[test]
fn being_shown_and_getting_a_name_write_only_what_they_say() {
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    scratch.call(A, None, &started("ses_a"));
    let before = scratch.record(A);
    scratch.call(A, None, &shown(B, "ses_b"));
    scratch.call(
        A,
        None,
        &json!({"hook_event_name": "weir.title", "title": "Fix login", "data": {"sessionID": "ses_a"}}),
    );
    let after = scratch.record(A);
    assert_eq!(after.state, RunState::Running);
    assert_eq!(after.pane_shown_run_id.as_deref(), Some(B));
    assert_eq!(after.provider_session_title.as_deref(), Some("Fix login"));
    assert_eq!(after.state_episode_token, before.state_episode_token);
    assert_eq!(after.run_started_at, before.run_started_at);
    assert_eq!(after.session_id, before.session_id);
}

#[test]
fn the_hint_follows_the_session_on_screen_even_past_a_siblings_start() {
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    scratch.call(A, None, &shown(A, "ses_a"));
    scratch.call(A, None, &shown(B, "ses_b"));
    assert_eq!(scratch.hint()["sessionId"], "ses_b");
    assert_eq!(scratch.hint()["runId"], B);
    assert_eq!(scratch.hint()["cwd"], "/repo");
    // A report held up behind a snapshot lands late and takes the hint; the same
    // fact, said again, gives it back.
    scratch.call(A, None, &session("ses_a"));
    scratch.call(A, None, &shown(B, "ses_b"));
    assert_eq!(scratch.hint()["runId"], B);
}

fn try_call(scratch: &Scratch, run: &str, payload: &Value) -> HookOutcome {
    let env = HookEnv::from_pairs([
        ("WEIR_PANE_ID".to_owned(), PANE.to_owned()),
        ("WEIR_AGENT_RUN_ID".to_owned(), run.to_owned()),
        (
            "WEIR_OPENCODE_AGENT_STATES_DIR".to_owned(),
            scratch.0.join("states").display().to_string(),
        ),
        (
            "WEIR_OPENCODE_SESSIONS_DIR".to_owned(),
            scratch.0.join("sessions").display().to_string(),
        ),
        (
            "WEIR_HOOK_INVOCATION_ID".to_owned(),
            uuid::Uuid::new_v4().to_string(),
        ),
    ]);
    let bytes = serde_json::to_vec(payload).expect("bytes");
    run_hook("opencode", &bytes, &HookRuntime::new(&env, &GitSnapshots))
}

/// Its caller holds the fact and says it again, so a write that did not happen says so.
#[test]
fn what_is_on_screen_says_when_it_was_not_written() {
    let scratch = Scratch::new();
    let shown = shown(A, "ses_a");
    let no_record = try_call(&scratch, A, &shown);
    assert!(
        matches!(no_record, HookOutcome::NotRecorded(_)),
        "{no_record:?}"
    );
    assert_ne!(no_record.exit_code(), 0);
    scratch.call(A, None, &session("ses_a"));

    let path = scratch.0.join("states").join(run_record_file_name(A));
    let mut sidecar = path.into_os_string();
    sidecar.push(weir_agent_model::LOCK_FILE_SUFFIX);
    let held = fs::File::create(&sidecar).expect("sidecar");
    held.lock().expect("hold it");
    let busy = try_call(&scratch, A, &shown);
    assert!(matches!(busy, HookOutcome::NotRecorded(_)), "{busy:?}");
    assert_eq!(scratch.record(A).pane_shown_run_id, None);
    held.unlock().expect("let go");
    assert_eq!(try_call(&scratch, A, &shown), HookOutcome::Applied);
    assert_eq!(scratch.record(A).pane_shown_run_id.as_deref(), Some(A));
}

/// A save that fails is as much a loss as a busy lock.
#[test]
fn what_is_on_screen_says_when_its_save_failed() {
    use std::os::unix::fs::PermissionsExt;
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    // Sidecars exist from here, so only the replacing write can fail.
    assert_eq!(
        try_call(&scratch, A, &shown(A, "ses_a")),
        HookOutcome::Applied
    );
    let before_record = scratch.record(A);
    let before_hint = scratch.hint();
    let protect = |directory: &str, mode: u32| {
        fs::set_permissions(scratch.0.join(directory), fs::Permissions::from_mode(mode))
            .expect("mode");
    };
    protect("states", 0o500);
    let record = try_call(&scratch, A, &shown(B, "ses_b"));
    protect("states", 0o700);
    assert!(matches!(record, HookOutcome::NotRecorded(_)), "{record:?}");
    assert_eq!(scratch.record(A), before_record);
    assert_eq!(scratch.hint(), before_hint);
    protect("sessions", 0o500);
    let hint = try_call(&scratch, A, &shown(B, "ses_b"));
    protect("sessions", 0o700);
    assert!(matches!(hint, HookOutcome::NotRecorded(_)), "{hint:?}");
    assert_eq!(scratch.record(A).pane_shown_run_id.as_deref(), Some(B));
    assert_eq!(scratch.hint(), before_hint);
    assert_eq!(
        try_call(&scratch, A, &shown(B, "ses_b")),
        HookOutcome::Applied
    );
    assert_eq!(scratch.hint()["runId"], B);
    assert_eq!(scratch.hint()["sessionId"], "ses_b");
}

/// Longer than an ordinary event's wait: a short hold is no loss.
#[test]
fn what_is_on_screen_waits_out_a_short_hold() {
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    let path = scratch.0.join("states").join(run_record_file_name(A));
    let mut sidecar = path.into_os_string();
    sidecar.push(weir_agent_model::LOCK_FILE_SUFFIX);
    let held = fs::File::create(&sidecar).expect("sidecar");
    held.lock().expect("hold it");
    let release = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(500));
        held.unlock().expect("let go");
    });
    assert_eq!(
        try_call(&scratch, A, &shown(A, "ses_a")),
        HookOutcome::Applied
    );
    release.join().expect("release");
    assert_eq!(scratch.record(A).pane_shown_run_id.as_deref(), Some(A));
}

#[test]
fn the_home_screen_is_said_apart_from_the_session_it_left() {
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    scratch.call(A, None, &shown(A, "ses_a"));
    scratch.call(
        A,
        None,
        &json!({"hook_event_name": "weir.shown", "shown_home": true, "data": {}}),
    );
    let record = scratch.record(A);
    assert_eq!(record.pane_shows_home, Some(true));
    assert_eq!(record.pane_shown_run_id.as_deref(), Some(A));
}

#[test]
fn a_closed_tab_rests_as_unknown_and_its_run_revives_on_reopening() {
    let scratch = Scratch::new();
    scratch.call(A, None, &session("ses_a"));
    scratch.call(B, None, &session("ses_b"));
    scratch.call(
        B,
        None,
        &json!({"hook_event_name": "weir.closed", "data": {"sessionID": "ses_b"}}),
    );
    let closed = scratch.record(B);
    assert_eq!(closed.state, RunState::Unknown);
    // What a resume's end is told by (`session_lifecycle::ended_since_its_resume`): the
    // closed tab's own session, never a sibling's.
    assert_eq!(closed.last_hook_event.as_deref(), Some("session_ended"));
    assert_eq!(closed.session_id.as_deref(), Some("ses_b"));
    scratch.call(B, None, &session("ses_b"));
    assert_eq!(scratch.record(B).state, RunState::Idle);
    assert_eq!(scratch.record(B).pane_family_run_id.as_deref(), Some(A));
}

fn legacy_scratch(repo: &Repo, name: &str) -> PathBuf {
    let directory = repo.git_dir().join("weir");
    fs::create_dir_all(&directory).expect("directory");
    let path = directory.join(format!("turn-{}.{name}", PANE.to_lowercase()));
    fs::write(&path, b"").expect("scratch");
    path
}

/// Two turns open at once in one tree: an edit is in the end of each that closes
/// after it, as Git cannot say whose it was.
#[test]
fn two_open_turns_in_one_tree_each_count_the_others_edits() {
    let repo = Repo::new("opencode-tabs");
    let scratch = Scratch::new();
    let cwd = repo.path.display().to_string();
    let path = Some(repo.path.as_path());
    for (run, id, generation) in [(A, "ses_a", "g1"), (B, "ses_b", "g2")] {
        scratch.call(
            run,
            path,
            &json!({"hook_event_name": "weir.prepare", "preparation": generation, "cwd": cwd, "data": {}}),
        );
        scratch.call(
            run,
            path,
            &json!({"hook_event_name": "weir.session", "cwd": cwd, "source": "startup", "data": {"sessionID": id}}),
        );
        scratch.call(
            run,
            path,
            &json!({
                "hook_event_name": "session.execution.started", "preparation": generation, "cwd": cwd,
                "prompt": "go", "prompt_kind": "user", "data": {"sessionID": id},
            }),
        );
    }
    fs::write(repo.path.join("by-a.txt"), "a\n").expect("a");
    fs::write(repo.path.join("by-b.txt"), "b\n").expect("b");
    for (run, id) in [(A, "ses_a"), (B, "ses_b")] {
        scratch.call(
            run,
            path,
            &json!({"hook_event_name": "session.execution.succeeded", "cwd": cwd, "data": {"sessionID": id}}),
        );
    }
    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    assert!(
        turns
            .iter()
            .any(|turn| turn.run_id == A && turn.conversation.conversation_id == "ses_a")
    );
    assert!(
        turns
            .iter()
            .any(|turn| turn.run_id == B && turn.conversation.conversation_id == "ses_b")
    );
    for turn in &turns {
        assert!(
            matches!(
                turn.changes,
                ChangeSummary::Changed {
                    files: 2,
                    added: 2,
                    removed: 0,
                    ..
                }
            ),
            "{:?}",
            turn.changes
        );
    }
}

const CHILD_REPO: &str = "WEIR_TEST_CAPTURE_REPO";

/// Not a test of its own: what `two_processes_capture_one_pane_at_once` starts, as a
/// capture's scratch index is named for its process.
#[test]
#[ignore = "child entry point run by two_processes_capture_one_pane_at_once"]
fn capture_as_a_child_process() {
    let repo = std::env::var(CHILD_REPO).expect("parent passes its scratch repository");
    for _ in 0..12 {
        let taken = GitSnapshots.capture(Path::new(&repo), PANE, TurnSide::End);
        assert!(
            matches!(taken.status, SnapshotStatus::Captured { .. }),
            "{:?}",
            taken.status
        );
    }
    println!("child completed its captures");
}

/// Git fails on an index another process holds the lock of, so one scratch index per
/// pane costs a turn its snapshot whenever two captures meet.
#[test]
fn two_processes_capture_one_pane_at_once() {
    let repo = Repo::new("capture-concurrency");
    for file in 0..200 {
        fs::write(repo.path.join(format!("f{file}.txt")), "x\n".repeat(100)).expect("file");
    }
    let children: Vec<_> = (0..3)
        .map(|_| {
            Command::new(std::env::current_exe().expect("test binary"))
                .args([
                    "--ignored",
                    "--exact",
                    "capture_as_a_child_process",
                    "--nocapture",
                ])
                .env(CHILD_REPO, &repo.path)
                .output_in_background()
        })
        .collect();
    for child in children {
        let output = child.wait_with_output().expect("child");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success(),
            "{stdout}\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(stdout.contains("child completed its captures"), "{stdout}");
    }
    let left: Vec<_> = fs::read_dir(repo.git_dir().join("weir"))
        .expect("directory")
        .flatten()
        .map(|entry| entry.file_name())
        .filter(|name| name.to_string_lossy().contains(".index"))
        .collect();
    assert!(left.is_empty(), "{left:?}");
}

trait Background {
    fn output_in_background(&mut self) -> std::process::Child;
}

impl Background for Command {
    fn output_in_background(&mut self) -> std::process::Child {
        self.stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("spawn")
    }
}

#[test]
fn a_killed_captures_file_goes_with_the_next_and_a_live_ones_stays() {
    let repo = Repo::new("capture-stale");
    // A real process, gone by the time it is asked about.
    let mut gone = Command::new("/usr/bin/true").spawn().expect("spawn");
    let gone_pid = gone.id();
    gone.wait().expect("wait");
    let stale = legacy_scratch(&repo, &format!("{gone_pid}.index"));
    let stale_lock = legacy_scratch(&repo, &format!("{gone_pid}.end.index.lock"));
    let older_build = legacy_scratch(&repo, "index");
    let live = legacy_scratch(&repo, &format!("{}.index", std::process::id()));
    let mut parent = Command::new("/bin/sleep").arg("30").spawn().expect("spawn");
    let other_live = legacy_scratch(&repo, &format!("{}.end.index", parent.id()));

    let taken = GitSnapshots.capture(&repo.path, PANE, TurnSide::Begin);
    assert!(matches!(taken.status, SnapshotStatus::Captured { .. }));
    assert!(!stale.exists() && !stale_lock.exists() && !older_build.exists());
    assert!(other_live.exists(), "another capture is using it");
    assert!(!live.exists(), "this capture's own goes as it ends");

    GitSnapshots.remove(&repo.path, PANE).expect("remove");
    assert!(other_live.exists(), "removal takes no live capture's file");
    parent.kill().expect("kill");
    parent.wait().expect("wait");
    GitSnapshots.remove(&repo.path, PANE).expect("remove");
    assert!(!other_live.exists());
}
