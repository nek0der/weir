//! Replays recorded OpenCode sessions through the hook runtime: the start saved
//! ahead of a turn, what the plugin added up, and a run moved between sessions have
//! to come out right on disk. Unix only: the hook runtime itself only runs there.
#![cfg(unix)]

mod support;

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use support::{PANE, RUN, Repo, git};
use weir_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, NoSnapshots, run_hook, run_worktree_hook,
};
use weir_agent_model::{
    ChangeSummary, FailureKind, RunRecord, RunState, SnapshotStatus, TurnPhase, TurnRecord,
    UsageLimitScope, WaitKind, run_record_file_name, session_hint_file_name,
};

const PROVIDER: &str = "opencode";

fn case_directory(case: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures/opencode/2026-11")
        .join(case)
}

struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("weir-opencode-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("scratch");
        Self { root }
    }

    fn env(&self) -> HookEnv {
        HookEnv::from_pairs([
            ("WEIR_PANE_ID".to_owned(), PANE.to_owned()),
            ("WEIR_AGENT_RUN_ID".to_owned(), RUN.to_owned()),
            (
                "WEIR_OPENCODE_AGENT_STATES_DIR".to_owned(),
                self.root.join("states").display().to_string(),
            ),
            (
                "WEIR_OPENCODE_SESSIONS_DIR".to_owned(),
                self.root.join("sessions").display().to_string(),
            ),
            ("WEIR_OPENCODE_PID".to_owned(), "4242".to_owned()),
            (
                "WEIR_HOOK_INVOCATION_ID".to_owned(),
                uuid::Uuid::new_v4().to_string(),
            ),
        ])
    }

    fn replay(&self, case: &str) {
        let mut payloads: Vec<PathBuf> = fs::read_dir(case_directory(case))
            .expect("case")
            .map(|entry| entry.expect("entry").path())
            .filter(|path| {
                let name = path.file_name().expect("name").to_string_lossy();
                name.ends_with(".json") && name.as_bytes()[0].is_ascii_digit()
            })
            .collect();
        payloads.sort();
        assert!(!payloads.is_empty(), "no payloads in {case}");
        for path in payloads {
            self.replay_call(&path);
        }
    }

    fn replay_call(&self, path: &Path) {
        let payload: Value =
            serde_json::from_slice(&fs::read(path).expect("payload")).expect("json");
        self.call(&payload, &NoSnapshots);
    }

    fn replay_only(&self, case: &str, names: &[&str]) {
        let directory = case_directory(case);
        for name in names {
            self.replay_call(&directory.join(format!("{name}.json")));
        }
    }

    fn call(&self, payload: &Value, snapshots: &dyn weir_agent_hook::SnapshotRunner) {
        let bytes = serde_json::to_vec(payload).expect("bytes");
        let env = self.env();
        assert_eq!(
            run_hook(PROVIDER, &bytes, &HookRuntime::new(&env, snapshots)),
            HookOutcome::Applied,
            "{payload}"
        );
    }

    fn record(&self) -> RunRecord {
        let bytes =
            fs::read(self.root.join("states").join(run_record_file_name(RUN))).expect("record");
        RunRecord::decode(&bytes).expect("record decodes")
    }

    fn hint(&self) -> Value {
        let bytes = fs::read(
            self.root
                .join("sessions")
                .join(session_hint_file_name(PANE)),
        )
        .expect("hint");
        serde_json::from_slice(&bytes).expect("hint decodes")
    }

    fn turns(&self) -> Vec<TurnRecord> {
        let mut turns = support::read_turns(&self.root.join("states")).expect("turns");
        turns.sort_by_key(|turn| turn.display_number);
        turns
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn two_turns_keep_their_prompts_replies_and_what_each_used() {
    let scratch = Scratch::new();
    scratch.replay("two-turns");
    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0].phase, TurnPhase::Finished);
    assert_eq!(turns[1].phase, TurnPhase::Finished);
    assert_eq!(
        turns[0].prompt_head.as_deref(),
        Some("Reply with only the word ONE")
    );
    assert_eq!(
        turns[1].prompt_head.as_deref(),
        Some("Run the shell command echo TWO and then reply DONE")
    );
    assert_eq!(turns[0].reply_head.as_deref(), Some("ONE"));
    assert_eq!(turns[1].reply_head.as_deref(), Some("DONE"));
    let usage = turns[0].usage.expect("usage");
    assert_eq!(
        (
            usage.input_tokens,
            usage.output_tokens,
            usage.cache_read_tokens
        ),
        (6741, 3, 1664)
    );
    assert!(!usage.is_partial);
    assert_eq!(turns[1].usage.expect("usage").cache_read_tokens, 16768);
    let record = scratch.record();
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.model.as_deref(), Some("Big Pickle"));
    // A service that is the agent itself is the header's to leave out; the record
    // keeps what the agent said.
    assert_eq!(record.model_upstream.as_deref(), Some("OpenCode"));
    assert_eq!(record.effort, None);
    assert_eq!(record.agent_profile, None);
    assert_eq!(
        record.provider_session_title.as_deref(),
        Some("Reply with only ONE")
    );
    assert_eq!(
        scratch.hint()["sessionId"],
        json!("ses_e6811df99ffec906Lvdn0geRZZ")
    );
}

#[test]
fn a_command_that_fails_is_a_tool_that_worked_and_a_check_that_failed() {
    let scratch = Scratch::new();
    scratch.replay("failing-command");
    assert_eq!(scratch.record().state, RunState::Finished);

    let scratch = Scratch::new();
    let session = json!({"sessionID": "ses_a"});
    scratch.call(
        &json!({"hook_event_name": "session.execution.started", "data": session, "cwd": "/nowhere", "prompt": "go", "prompt_kind": "user"}),
        &NoSnapshots,
    );
    scratch.call(
        &json!({
            "hook_event_name": "session.tool.success",
            "command": "cargo test",
            "cwd": "/nowhere",
            "data": {"sessionID": "ses_a", "id": "t", "name": "shell", "metadata": {"exit": 101}},
        }),
        &NoSnapshots,
    );
    let check = scratch.turns()[0].last_check.clone().expect("a check");
    assert_eq!(check.command, "cargo test");
    assert_eq!(check.exit_code, Some(101));
}

#[test]
fn esc_ends_the_turn_as_interrupted_with_what_it_used() {
    let scratch = Scratch::new();
    scratch.replay("interrupted");
    let turns = scratch.turns();
    assert_eq!(turns[0].phase, TurnPhase::Interrupted);
    assert_eq!(turns[0].usage.expect("usage").input_tokens, 90);
}

#[test]
fn a_new_session_closes_the_turn_short_and_moves_the_run() {
    let scratch = Scratch::new();
    scratch.replay("new-session");
    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    // Each session numbers its own turns, so they are told apart by their words.
    let left = turns
        .iter()
        .find(|turn| {
            turn.prompt_head
                .as_deref()
                .is_some_and(|prompt| prompt.starts_with("Run the shell"))
        })
        .expect("the turn it left");
    assert_eq!(left.phase, TurnPhase::Interrupted);
    assert!(left.usage.expect("usage").is_partial);
    let other = turns
        .iter()
        .find(|turn| turn.turn_id != left.turn_id)
        .expect("the turn it went on to");
    assert_eq!(other.phase, TurnPhase::Finished);
    assert_eq!(
        scratch.hint()["sessionId"],
        json!("ses_e680131d1ffeFQvRzeIc51dMIq")
    );
}

#[test]
fn a_manual_compaction_opens_no_turn_and_leaves_the_run_at_rest() {
    let scratch = Scratch::new();
    scratch.replay_only(
        "compact",
        &[
            "0001-weir.launch",
            "0002-weir.prepare",
            "0003-weir.session",
            "0004-session.execution.started",
            "0005-session.step.started",
            "0006-session.execution.succeeded",
        ],
    );
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].phase, TurnPhase::Finished);
    scratch.replay_only("compact", &["0007-session.compaction.started"]);
    assert_eq!(scratch.record().state, RunState::Compacting);
    assert_eq!(scratch.turns(), turns);
    scratch.replay_only("compact", &["0008-session.compaction.ended"]);
    assert_eq!(scratch.record().state, RunState::Idle);
    assert_eq!(scratch.turns(), turns);
}

#[test]
fn a_waiting_run_goes_back_to_work_once_its_approval_is_answered() {
    let scratch = Scratch::new();
    let asked = json!({
        "hook_event_name": "permission.asked",
        "tool": "shell",
        "data": {"id": "per_1", "sessionID": "ses_a", "action": "shell", "resources": ["touch a"]},
    });
    scratch.call(
        &json!({"hook_event_name": "weir.session", "data": {"sessionID": "ses_a"}, "cwd": "/nowhere", "source": "startup"}),
        &NoSnapshots,
    );
    scratch.call(
        &json!({"hook_event_name": "session.execution.started", "data": {"sessionID": "ses_a"}, "cwd": "/nowhere", "prompt": "go", "prompt_kind": "user"}),
        &NoSnapshots,
    );
    scratch.call(&asked, &NoSnapshots);
    assert_eq!(scratch.record().state, RunState::NeedsInput);
    scratch.call(
        &json!({"hook_event_name": "permission.replied", "tool": "shell", "data": {"requestID": "per_1", "sessionID": "ses_a", "reply": "once"}}),
        &NoSnapshots,
    );
    assert_eq!(scratch.record().state, RunState::Running);
}

#[test]
fn a_real_free_limit_holds_its_service_and_says_when_it_resets() {
    let scratch = Scratch::new();
    scratch.replay("free-limit");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Error);
    let limit = record.usage_limit.expect("a limit");
    assert_eq!(limit.scope, UsageLimitScope::Upstream);
    assert!(limit.resets_at.is_some());
    assert!(
        limit
            .label
            .as_deref()
            .is_some_and(|label| label.starts_with("Free usage limit reached"))
    );
    assert_eq!(scratch.turns()[0].phase, TurnPhase::Failed);
}

#[test]
fn a_real_sign_in_failure_names_itself_with_no_limit() {
    let scratch = Scratch::new();
    scratch.replay("sign-in");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Error);
    assert_eq!(record.failure_kind, Some(FailureKind::SignIn));
    assert_eq!(record.usage_limit, None);
}

#[test]
fn a_rate_limit_being_retried_is_work_going_on() {
    let scratch = Scratch::new();
    scratch.replay("rate-limited");
    assert_eq!(scratch.record().state, RunState::Running);
}

#[test]
fn an_approval_answered_goes_back_to_work_and_a_refused_one_still_ends_the_turn() {
    for (case, reply, completion) in [
        (
            "approval-card-once",
            "0008-permission.replied",
            &[
                "0009-session.tool.success",
                "0010-session.execution.succeeded",
            ][..],
        ),
        (
            "approval-card-reject",
            "0008-session.tool.failed",
            &["0009-session.execution.succeeded"][..],
        ),
    ] {
        let scratch = Scratch::new();
        scratch.replay_only(
            case,
            &[
                "0001-weir.launch",
                "0002-weir.prepare",
                "0003-weir.session",
                "0004-session.execution.started",
                "0005-session.step.started",
                "0006-session.tool.called",
                "0007-permission.asked",
            ],
        );
        assert_eq!(scratch.record().state, RunState::NeedsInput, "{case}");
        scratch.replay_only(case, &[reply]);
        assert_eq!(scratch.record().state, RunState::Running, "{case}");
        assert_eq!(scratch.record().wait_kind, None, "{case}");
        scratch.replay_only(case, completion);
        assert_eq!(scratch.record().state, RunState::Finished, "{case}");
        let turns = scratch.turns();
        let [turn] = turns.as_slice() else {
            panic!("{case}: expected one turn: {turns:?}");
        };
        assert_eq!(turn.phase, TurnPhase::Finished, "{case}");
    }
}

#[test]
fn a_question_keeps_the_run_waiting_until_it_is_answered() {
    let scratch = Scratch::new();
    scratch.replay_only(
        "question",
        &[
            "0001-weir.launch",
            "0002-weir.prepare",
            "0003-weir.session",
            "0004-session.execution.started",
            "0005-session.step.started",
            "0006-session.tool.called",
            "0007-form.created",
        ],
    );
    let record = scratch.record();
    assert_eq!(record.state, RunState::NeedsInput);
    assert_eq!(record.wait_kind, Some(WaitKind::Question));

    scratch.replay_only("question", &["0008-form.replied"]);
    let record = scratch.record();
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.wait_kind, None);

    scratch.replay_only(
        "question",
        &[
            "0009-session.tool.success",
            "0010-session.execution.succeeded",
        ],
    );
    assert_eq!(scratch.record().state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 1);
}

#[test]
fn a_subagents_steps_count_for_the_turn_that_ran_it() {
    let scratch = Scratch::new();
    scratch.replay("subagent");
    assert_eq!(scratch.turns()[0].usage.expect("usage").input_tokens, 300);
}

#[test]
fn a_limit_on_one_service_and_a_sign_in_say_what_they_hold() {
    let scratch = Scratch::new();
    let started = json!({"hook_event_name": "session.execution.started", "data": {"sessionID": "ses_a"}, "cwd": "/nowhere", "prompt": "go", "prompt_kind": "user"});
    scratch.call(&started, &NoSnapshots);
    scratch.call(
        &json!({
            "hook_event_name": "session.execution.failed",
            "data": {"sessionID": "ses_a", "error": {"type": "provider.free-limit", "message": "Free usage limit reached", "retryAfterMs": 60_000}},
        }),
        &NoSnapshots,
    );
    let record = scratch.record();
    assert_eq!(record.state, RunState::Error);
    let limit = record.usage_limit.expect("a limit");
    assert_eq!(limit.scope, UsageLimitScope::Upstream);
    assert_eq!(limit.label.as_deref(), Some("Free usage limit reached"));
    assert!(limit.resets_at.is_some());
    assert_eq!(record.failure_kind, None);

    scratch.call(&started, &NoSnapshots);
    scratch.call(
        &json!({
            "hook_event_name": "session.execution.failed",
            "data": {"sessionID": "ses_a", "error": {"type": "provider.auth", "message": "Unauthorized"}},
        }),
        &NoSnapshots,
    );
    let record = scratch.record();
    assert_eq!(record.failure_kind, Some(FailureKind::SignIn));
    assert_eq!(record.usage_limit, None);
    assert_eq!(record.detail.as_deref(), Some("Unauthorized"));
}

#[test]
fn a_rate_limit_is_an_ordinary_failure() {
    let scratch = Scratch::new();
    scratch.call(
        &json!({
            "hook_event_name": "session.execution.failed",
            "data": {"sessionID": "ses_a", "error": {"type": "provider.rate-limit", "message": "Slow down", "retryAfterMs": 1000}},
        }),
        &NoSnapshots,
    );
    assert_eq!(scratch.record().usage_limit, None);
}

/// The call that says a turn began comes after the agent may have started on it,
/// so the turn's start has to be the one saved at Enter.
#[test]
fn an_edit_after_the_enter_counts_as_the_turns_and_is_not_in_its_start() {
    let repo = Repo::new("opencode-prepared");
    let scratch = Scratch::new();
    let cwd = repo.path.display().to_string();
    scratch.call(
        &json!({"hook_event_name": "weir.prepare", "preparation": "g1", "cwd": cwd, "data": {}}),
        &GitSnapshots,
    );
    assert!(
        !scratch
            .root
            .join("states")
            .join(run_record_file_name(RUN))
            .exists(),
        "a preparation writes no run record"
    );
    fs::write(repo.path.join("README.md"), "fixture\nby the agent\n").expect("edit");
    scratch.call(
        &json!({"hook_event_name": "session.execution.started", "preparation": "g1", "data": {"sessionID": "ses_a"}, "cwd": cwd, "prompt": "go", "prompt_kind": "user"}),
        &GitSnapshots,
    );
    scratch.call(
        &json!({"hook_event_name": "session.execution.succeeded", "data": {"sessionID": "ses_a"}, "cwd": cwd}),
        &GitSnapshots,
    );
    let turns = scratch.turns();
    assert!(matches!(turns[0].begin, SnapshotStatus::Captured { .. }));
    assert!(
        matches!(turns[0].changes, ChangeSummary::Changed { files: 1, .. }),
        "{:?}",
        turns[0].changes
    );
}

/// With no saved start the turn says so rather than taking one that could hold the
/// agent's first edits.
#[test]
fn a_turn_no_enter_came_before_has_no_start() {
    let repo = Repo::new("opencode-unprepared");
    let scratch = Scratch::new();
    let cwd = repo.path.display().to_string();
    scratch.call(
        &json!({"hook_event_name": "session.execution.started", "data": {"sessionID": "ses_a"}, "cwd": cwd, "prompt": "", "prompt_kind": "none"}),
        &GitSnapshots,
    );
    assert_eq!(scratch.turns()[0].begin, SnapshotStatus::Pending);
    // Another generation's start is no start either.
    scratch.call(
        &json!({"hook_event_name": "weir.prepare", "preparation": "g1", "cwd": cwd, "data": {}}),
        &GitSnapshots,
    );
    scratch.call(
        &json!({"hook_event_name": "session.execution.started", "preparation": "other", "data": {"sessionID": "ses_a"}, "cwd": cwd, "prompt": "go", "prompt_kind": "user"}),
        &GitSnapshots,
    );
    assert_eq!(scratch.turns()[1].begin, SnapshotStatus::Pending);
}

/// `/cd` as the input went: a start in another repository would make the turn's
/// Changes and Restore Code about that one.
#[test]
fn a_start_saved_in_another_worktree_is_no_start() {
    let saved_in = Repo::new("opencode-saved-in");
    let runs_in = Repo::new("opencode-runs-in");
    let scratch = Scratch::new();
    scratch.call(
        &json!({"hook_event_name": "weir.prepare", "preparation": "g1", "cwd": saved_in.path.display().to_string(), "data": {}}),
        &GitSnapshots,
    );
    scratch.call(
        &json!({"hook_event_name": "session.execution.started", "preparation": "g1", "data": {"sessionID": "ses_a"}, "cwd": runs_in.path.display().to_string(), "prompt": "go", "prompt_kind": "user"}),
        &GitSnapshots,
    );
    assert_eq!(scratch.turns()[0].begin, SnapshotStatus::Pending);
}

#[test]
fn a_limits_words_keep_to_the_records_text_contract() {
    let scratch = Scratch::new();
    let long = "x".repeat(64 * 1024);
    scratch.call(
        &json!({
            "hook_event_name": "session.execution.failed",
            "data": {"sessionID": "ses_a", "error": {"type": "provider.quota", "message": format!("over\u{1b}[31m{long}")}},
        }),
        &NoSnapshots,
    );
    let label = scratch
        .record()
        .usage_limit
        .expect("a limit")
        .label
        .expect("words");
    assert!(!label.contains('\u{1b}'));
    assert!(label.starts_with("over"));
    assert!(label.len() <= weir_agent_model::MAX_RECORD_TEXT_BYTES);
}

/// A project whose placement puts branch `x` at `<repo>-x`, whose bootstrap leaves a
/// file, with the routing file where the runtime looks: beside the state directory.
fn routed_project(scratch: &Scratch, repo: &Repo) {
    fs::create_dir_all(scratch.root.join("states")).expect("states");
    fs::write(
        scratch.root.join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[{{"command":"touch bootstrapped"}}],"worktrees":[]}}]}}"#,
            repo.path.display()
        ),
    )
    .expect("routing");
}

fn tool_success(repo: &Repo, command: &str, exit: i64) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "hook_event_name": "session.tool.success",
        "command": command,
        "command_complete": true,
        "cwd": repo.path,
        "data": {"sessionID": "ses_a", "id": "t", "name": "shell", "metadata": {"exit": exit}},
    }))
    .expect("bytes")
}

fn worktree_events(scratch: &Scratch) -> usize {
    fs::read_dir(
        scratch
            .root
            .join("states")
            .join(weir_agent_model::WORKTREE_EVENTS_DIRECTORY),
    )
    .map_or(0, Iterator::count)
}

#[test]
fn a_worktree_it_made_in_the_projects_folder_gets_the_setup_and_the_event_with_no_mark() {
    let repo = Repo::new("opencode-worktree");
    let scratch = Scratch::new();
    routed_project(&scratch, &repo);
    let folder = repo.path.with_file_name("repo-x");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "x",
            folder.to_str().expect("path"),
        ],
    );
    let command = format!("git worktree add -b x {}", folder.display());
    let env = scratch.env();
    let outcome = run_worktree_hook(
        PROVIDER,
        &tool_success(&repo, &command, 0),
        &HookRuntime::new(&env, &NoSnapshots),
    );
    assert!(
        matches!(outcome, HookOutcome::Intercepted { code: 0, ref stdout, .. } if stdout.is_none()),
        "{outcome:?}"
    );
    assert!(folder.join("bootstrapped").exists());
    assert_eq!(worktree_events(&scratch), 1);
    assert!(!scratch.root.join("worktrees-awaited").exists());
}

/// A worktree that was already there is not set up again on the strength of words
/// that only look like they made it: a comment naming its branch, another folder, or a
/// command the plugin had to cut.
#[test]
fn an_existing_worktree_is_not_set_up_on_words_that_only_name_it() {
    let repo = Repo::new("opencode-worktree-existing");
    let scratch = Scratch::new();
    routed_project(&scratch, &repo);
    let folder = repo.path.with_file_name("repo-x");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "x",
            folder.to_str().expect("path"),
        ],
    );
    let other = repo.root.join("y");
    let env = scratch.env();
    let finish =
        |bytes: Vec<u8>| run_worktree_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &NoSnapshots));
    for command in [
        format!("git worktree add -b y {} # -b x", other.display()),
        format!("git worktree add -b x {}", other.display()),
    ] {
        let outcome = finish(tool_success(&repo, &command, 0));
        assert_eq!(outcome, HookOutcome::Applied, "{command}");
    }
    let mut cut: Value = serde_json::from_slice(&tool_success(
        &repo,
        &format!("git worktree add -b x {}", folder.display()),
        0,
    ))
    .expect("json");
    cut["command_complete"] = json!(false);
    let outcome = finish(serde_json::to_vec(&cut).expect("bytes"));
    assert_eq!(outcome, HookOutcome::Applied);
    assert!(!folder.join("bootstrapped").exists());
    assert_eq!(worktree_events(&scratch), 0);
}

/// Another agent's mark for the same worktree, left by its `PreToolUse`, is no proof of
/// OpenCode's command: a chained one that fails on the worktree still exits 0.
#[test]
fn another_agents_mark_never_stands_in_for_a_failed_proof() {
    let repo = Repo::new("opencode-worktree-mark");
    let scratch = Scratch::new();
    routed_project(&scratch, &repo);
    let folder = repo.path.with_file_name("repo-x");
    let intent = weir_agent_model::WorktreeIntent::parse(
        "git worktree add -b x ../elsewhere",
        Some(&repo.path.display().to_string()),
    )
    .expect("intent");
    // Claude's hook marks the worktree it is about to send to the placement.
    let planned = weir_agent_hook::plan_worktree(&intent, "claude", &scratch.root.join("states"));
    assert!(
        matches!(planned, weir_agent_hook::InterceptResult::Reroute { .. }),
        "the mark is left: {planned:?}"
    );
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "x",
            folder.to_str().expect("path"),
        ],
    );
    let env = scratch.env();
    let outcome = run_worktree_hook(
        PROVIDER,
        &tool_success(
            &repo,
            &format!("git worktree add -b x {} ; true", folder.display()),
            0,
        ),
        &HookRuntime::new(&env, &NoSnapshots),
    );
    assert!(
        !matches!(outcome, HookOutcome::Intercepted { .. }),
        "{outcome:?}"
    );
    assert!(!folder.join("bootstrapped").exists());
    assert_eq!(worktree_events(&scratch), 0);
}

#[test]
fn a_worktree_elsewhere_gets_no_setup_and_no_event() {
    let repo = Repo::new("opencode-worktree-elsewhere");
    let scratch = Scratch::new();
    routed_project(&scratch, &repo);
    let folder = repo.root.join("somewhere-else");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "x",
            folder.to_str().expect("path"),
        ],
    );
    let command = format!("git worktree add -b x {}", folder.display());
    let env = scratch.env();
    assert_eq!(
        run_worktree_hook(
            PROVIDER,
            &tool_success(&repo, &command, 0),
            &HookRuntime::new(&env, &NoSnapshots),
        ),
        HookOutcome::Applied
    );
    assert!(!folder.join("bootstrapped").exists());
    assert_eq!(worktree_events(&scratch), 0);
}

/// `git worktree add` on a branch and folder that already exist: the command failed,
/// and what is there has had its setup.
#[test]
fn a_command_that_failed_or_may_have_gets_no_setup_on_a_worktree_already_there() {
    let repo = Repo::new("opencode-worktree-failed");
    let scratch = Scratch::new();
    routed_project(&scratch, &repo);
    let folder = repo.path.with_file_name("repo-x");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "x",
            folder.to_str().expect("path"),
        ],
    );
    let env = scratch.env();
    let plain = format!("git worktree add -b x {}", folder.display());
    let chained = format!("git worktree add -b x {} ; true", folder.display());
    for (command, exit) in [(&plain, 128), (&chained, 0)] {
        assert_eq!(
            run_worktree_hook(
                PROVIDER,
                &tool_success(&repo, command, exit),
                &HookRuntime::new(&env, &NoSnapshots),
            ),
            HookOutcome::Applied,
            "{command}"
        );
    }
    assert!(!folder.join("bootstrapped").exists());
    assert_eq!(worktree_events(&scratch), 0);
}

/// Nothing happens before the tool: the plugin calls this only for a tool's end, and
/// no other event of OpenCode's reads as a worktree to act on.
#[test]
fn a_tools_start_leaves_no_mark_and_changes_nothing() {
    let repo = Repo::new("opencode-worktree-start");
    let scratch = Scratch::new();
    routed_project(&scratch, &repo);
    let bytes = serde_json::to_vec(&json!({
        "hook_event_name": "session.tool.called",
        "cwd": repo.path,
        "data": {"name": "shell", "input": {"command": "git worktree add -b x ../x"}},
    }))
    .expect("bytes");
    let env = scratch.env();
    assert_eq!(
        run_worktree_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &NoSnapshots)),
        HookOutcome::Applied
    );
    assert!(!scratch.root.join("worktrees-awaited").exists());
    assert_eq!(worktree_events(&scratch), 0);
    assert!(!repo.path.with_file_name("repo-x").exists());
}
