//! Replays the recorded `agy` sessions through the hook runtime: what its
//! hooks do not say (a prompt, a resume, a turn it began itself) has to come
//! out right on disk. Unix only: the hook runtime itself only runs there.
#![cfg(unix)]

mod support;

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use support::{PANE, RUN};
use weir_agent_hook::{
    HookEnv, HookOutcome, HookRuntime, NoSnapshots, run_hook, run_worktree_hook,
};
use weir_agent_model::{
    RunRecord, RunState, TurnRecord, run_record_file_name, session_hint_file_name,
};

const PROVIDER: &str = "antigravity";

struct Scratch {
    root: PathBuf,
}

fn case_directory(case: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures/antigravity/2026-11")
        .join(case)
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("weir-agy-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("scratch root");
        Self { root }
    }

    fn env(&self) -> HookEnv {
        HookEnv::from_pairs(vec![
            ("WEIR_PANE_ID".to_owned(), PANE.to_owned()),
            ("WEIR_AGENT_RUN_ID".to_owned(), RUN.to_owned()),
            (
                "WEIR_ANTIGRAVITY_AGENT_STATES_DIR".to_owned(),
                self.root.join("states").display().to_string(),
            ),
            (
                "WEIR_ANTIGRAVITY_SESSIONS_DIR".to_owned(),
                self.root.join("sessions").display().to_string(),
            ),
            ("WEIR_ANTIGRAVITY_PID".to_owned(), "4242".to_owned()),
            (
                "WEIR_HOOK_INVOCATION_ID".to_owned(),
                uuid::Uuid::new_v4().to_string(),
            ),
        ])
    }

    /// Runs every payload of a recorded case, each with the transcript as it
    /// stood at that call.
    fn replay(&self, case: &str) {
        let directory = case_directory(case);
        let mut payloads: Vec<PathBuf> = fs::read_dir(&directory)
            .expect("case")
            .map(|entry| entry.expect("entry").path())
            .filter(|path| {
                let name = path
                    .file_name()
                    .expect("name")
                    .to_string_lossy()
                    .into_owned();
                path.extension()
                    .is_some_and(|extension| extension == "json")
                    && name != "expected.json"
            })
            .collect();
        payloads.sort();
        for path in payloads {
            self.replay_call(&path);
        }
    }

    /// Runs one recorded payload with the transcript recorded beside it.
    fn replay_call(&self, path: &Path) {
        let mut payload: Value =
            serde_json::from_slice(&fs::read(path).expect("payload")).expect("json");
        let transcript = path.with_extension("transcript.jsonl");
        if transcript.exists() {
            payload["transcriptPath"] = Value::from(transcript.display().to_string());
        }
        self.call(&payload, &path.display().to_string());
    }

    fn call(&self, payload: &Value, label: &str) {
        let bytes = serde_json::to_vec(payload).expect("bytes");
        let env = self.env();
        assert_eq!(
            run_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &NoSnapshots)),
            HookOutcome::Applied,
            "{label}"
        );
    }

    /// Runs the named payloads of a recorded case, in the order given.
    fn replay_only(&self, case: &str, names: &[&str]) {
        for name in names {
            self.replay_call(&case_directory(case).join(format!("{name}.json")));
        }
    }

    /// Runs `payload` with a transcript of `lines` beside it.
    fn call_with_transcript(&self, mut payload: Value, lines: &str) {
        let path = self.root.join(format!("{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(&path, lines).expect("transcript");
        payload["transcriptPath"] = Value::from(path.display().to_string());
        self.call(&payload, "a turn after /compact");
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
fn turns_with_the_same_words_are_two_turns() {
    let scratch = Scratch::new();
    scratch.replay("two-turns");
    assert_eq!(scratch.record().state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 3);
}

#[test]
fn a_resume_with_no_session_start_still_names_the_conversation() {
    let scratch = Scratch::new();
    scratch.replay("resume");
    let record = scratch.record();
    let session = record.session_id.clone().expect("session");
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(
        scratch.hint().get("sessionId").and_then(Value::as_str),
        Some(session.as_str())
    );
    assert_eq!(scratch.turns().len(), 1);
}

impl Scratch {
    fn report_launch(&self, conversation: &str) {
        let payload = serde_json::json!({
            "hook_event_name": "WeirLaunch",
            "conversationId": conversation,
            "workspacePaths": ["/Users/person/project"],
        });
        let bytes = serde_json::to_vec(&payload).expect("bytes");
        let env = self.env();
        assert_eq!(
            run_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &NoSnapshots)),
            HookOutcome::Applied
        );
    }
}

#[test]
fn a_resume_rests_with_its_conversation_from_the_launch() {
    let scratch = Scratch::new();
    scratch.report_launch("conversation-1");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.session_id.as_deref(), Some("conversation-1"));
    assert_eq!(record.has_prompt, Some(true));
    assert_eq!(
        scratch.hint().get("sessionId").and_then(Value::as_str),
        Some("conversation-1")
    );
}

#[test]
fn a_fresh_launch_rests_and_its_own_session_start_does_no_harm() {
    let scratch = Scratch::new();
    scratch.report_launch("");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.session_id, None);
    assert_eq!(record.has_prompt, Some(false));

    scratch.replay("two-turns");
    assert_eq!(scratch.record().state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 3);
}

#[test]
fn a_continue_learns_its_conversation_from_the_first_request() {
    let scratch = Scratch::new();
    scratch.report_launch("");
    scratch.replay("resume");
    let record = scratch.record();
    assert!(record.session_id.is_some());
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 1);
}

#[test]
fn a_daemon_ending_after_the_stop_begins_the_turn_it_began_and_no_other() {
    let scratch = Scratch::new();
    scratch.replay("background-command");
    assert_eq!(scratch.record().state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 2);
}

#[test]
fn a_prompted_turn_keeps_the_step_it_began_at() {
    let scratch = Scratch::new();
    scratch.replay("two-turns");
    let mut steps: Vec<u64> = scratch
        .turns()
        .iter()
        .filter_map(|turn| turn.provider_turn_id.as_deref()?.rsplit_once('#'))
        .filter_map(|(_, step)| step.parse().ok())
        .collect();
    steps.sort_unstable();
    assert_eq!(steps, [1, 5, 7]);
}

#[test]
fn a_subagents_calls_are_not_the_runs() {
    let scratch = Scratch::new();
    scratch.replay("subagent");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Finished);
    let first: Value = serde_json::from_slice(
        &fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../fixtures/antigravity/2026-11/subagent/0001-SessionStart.json"),
        )
        .expect("payload"),
    )
    .expect("json");
    assert_eq!(
        record.session_id.as_deref(),
        first["conversationId"].as_str()
    );
}

#[test]
fn compact_leaves_the_run_at_rest_and_opens_no_turn() {
    let scratch = Scratch::new();
    scratch.replay("compact");
    assert_eq!(scratch.record().state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 1);
}

/// A background command's end after `/compact` begins a turn under the same
/// `lastUserInput`, as it does after any other input (`background-command`).
#[test]
fn a_turn_the_agent_begins_after_compact_ends_like_any_other() {
    let scratch = Scratch::new();
    scratch.replay("compact");
    let directory = case_directory("compact");
    let read = |name: &str| fs::read_to_string(directory.join(name)).expect("recorded");
    let json = |name: &str| serde_json::from_str::<Value>(&read(name)).expect("json");
    let turns = scratch.turns().len();

    let mut transcript = read("0006-Stop.transcript.jsonl");
    transcript.push_str(
        r#"{"step_index":4,"source":"SYSTEM","type":"GENERIC","status":"DONE","content":"Background task ended"}"#,
    );
    transcript.push('\n');
    let mut request = json("0005-PreInvocation.json");
    request["invocationNum"] = Value::from(0);
    request["initialNumSteps"] = Value::from(5);
    request["lastUserInput"] = Value::from("/compact");
    scratch.call_with_transcript(request, &transcript);
    assert_eq!(scratch.record().state, RunState::Running);
    assert_eq!(scratch.turns().len(), turns + 1);

    transcript.push_str(
        r#"{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"done"}"#,
    );
    transcript.push('\n');
    scratch.call_with_transcript(json("0006-Stop.json"), &transcript);
    assert_eq!(scratch.record().state, RunState::Finished);
}

/// `/clear` starts another conversation while the first may still finish its
/// turn, so its `Stop` can come when the new one is at work.
#[test]
fn a_late_stop_of_the_left_conversation_does_not_touch_the_new_one() {
    let scratch = Scratch::new();
    let started = [
        "0001-SessionStart",
        "0002-PreInvocation",
        "0003-PostInvocation",
        "0005-SessionStart",
        "0006-PreInvocation",
    ];
    scratch.replay_only("clear", &started);
    let at_work = scratch.record();
    assert_eq!(at_work.state, RunState::Running);
    let turns = scratch.turns();

    scratch.replay_only("clear", &["0004-Stop"]);
    let record = scratch.record();
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.session_id, at_work.session_id);
    assert_eq!(scratch.turns(), turns);
}

#[test]
fn clear_moves_the_run_to_the_new_conversation() {
    let scratch = Scratch::new();
    scratch.replay("clear");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.first_prompt.as_deref(), Some("say two"));
}

#[test]
fn a_declined_write_leaves_the_turn_open_for_the_status_report_to_end() {
    let scratch = Scratch::new();
    scratch.replay("write-declined");
    let record = scratch.record();
    assert_eq!(record.state, RunState::Running);
    assert!(
        record.transcript_path.is_some(),
        "the app reads it to end the turn"
    );
}

#[test]
fn a_question_waits_until_its_tool_returns() {
    let scratch = Scratch::new();
    scratch.replay("question");
    assert_eq!(scratch.record().state, RunState::Finished);
    assert_eq!(scratch.turns().len(), 1);
}

#[test]
fn a_worktree_it_routes_cancels_the_call_with_a_deny_and_exit_zero() {
    let repo = support::Repo::new("agy-worktree");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{}","placement":{{"kind":"siblingPrefixed"}},"routing":{{}}}}]}}"#,
            repo.path.display()
        ),
    )
    .expect("routing");
    let env = HookEnv::from_pairs(vec![
        ("WEIR_PANE_ID", PANE),
        (
            "WEIR_ANTIGRAVITY_AGENT_STATES_DIR",
            states.to_str().expect("path"),
        ),
        (
            "WEIR_ANTIGRAVITY_SESSIONS_DIR",
            repo.root.join("support/sessions").to_str().expect("path"),
        ),
    ]);
    let payload = format!(
        r#"{{"hook_event_name":"PreToolUse","lastUserInput":"x","workspacePaths":["{}"],"toolCall":{{"name":"run_command","args":{{"CommandLine":"git worktree add -b demo ../demo"}}}}}}"#,
        repo.path.display()
    );
    let outcome = run_worktree_hook(
        PROVIDER,
        payload.as_bytes(),
        &HookRuntime::new(&env, &NoSnapshots),
    );
    assert_eq!(outcome.exit_code(), 0);
    let HookOutcome::Intercepted {
        stdout: Some(stdout),
        ..
    } = outcome
    else {
        panic!("not intercepted: {outcome:?}");
    };
    let reply: Value = serde_json::from_slice(&stdout).expect("json");
    assert_eq!(reply["decision"], "deny");
    assert!(
        reply["reason"]
            .as_str()
            .expect("reason")
            .contains("repo-demo")
    );
}
