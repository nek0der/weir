//! Runs Kiro's hook calls through the hook runtime: Kiro has no prompt hook of
//! ours, so a turn is begun from its session log at the turn's first tool, or
//! at its stop when it ran none, and a worktree it routes is refused by exit
//! status 2. Unix only: the hook runtime itself only runs there.
#![cfg(unix)]

mod support;

use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use support::{PANE, RUN, git};
use weir_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, NoSnapshots, run_hook, run_worktree_hook,
};
use weir_agent_model::{
    ChangeSummary, HookContext, PermissionMode, RawHookInput, RunRecord, RunState, TurnRecord,
    run_record_file_name,
};

const PROVIDER: &str = "kiro";
const SESSION: &str = "sess_00000000-0000-4000-8000-000000000001";
const CWD: &str = "/Users/person/project";
/// `sha256(CWD)[:16]`, where Kiro keeps the folder's sessions.
const FOLDER_DIGEST: &str = "d9f5c1d735f7c068";

struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("weir-kiro-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).expect("scratch root");
        Self { root }
    }

    fn env(&self) -> HookEnv {
        HookEnv::from_pairs(vec![
            ("WEIR_PANE_ID".to_owned(), PANE.to_owned()),
            ("WEIR_AGENT_RUN_ID".to_owned(), RUN.to_owned()),
            (
                "WEIR_KIRO_AGENT_STATES_DIR".to_owned(),
                self.root.join("states").display().to_string(),
            ),
            (
                "WEIR_KIRO_SESSIONS_DIR".to_owned(),
                self.root.join("sessions").display().to_string(),
            ),
            ("WEIR_KIRO_PID".to_owned(), "4242".to_owned()),
            (
                "HOME".to_owned(),
                self.root.join("home").display().to_string(),
            ),
            (
                "WEIR_HOOK_INVOCATION_ID".to_owned(),
                uuid::Uuid::new_v4().to_string(),
            ),
        ])
    }

    /// Kiro's session log, as it stands when the next call is made.
    fn write_log(&self, lines: &[Value]) {
        let directory = self
            .root
            .join("home/.kiro/sessions")
            .join(FOLDER_DIGEST)
            .join(SESSION);
        fs::create_dir_all(&directory).expect("log directory");
        let mut text = String::new();
        for line in lines {
            text.push_str(&json!({ "id": "x", "payload": line }).to_string());
            text.push('\n');
        }
        fs::write(directory.join("messages.jsonl"), text).expect("log");
    }

    fn call(&self, payload: &Value) {
        let bytes = serde_json::to_vec(payload).expect("bytes");
        let env = self.env();
        assert_eq!(
            run_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &NoSnapshots)),
            HookOutcome::Applied,
            "{payload}"
        );
    }

    fn record(&self) -> RunRecord {
        let bytes =
            fs::read(self.root.join("states").join(run_record_file_name(RUN))).expect("record");
        RunRecord::decode(&bytes).expect("record decodes")
    }

    fn turns(&self) -> Vec<TurnRecord> {
        // A run that never began a turn has no turns folder at all.
        let mut turns = match support::read_turns(&self.root.join("states")) {
            Ok(turns) => turns,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => panic!("turns: {error}"),
        };
        turns.sort_by_key(|turn| turn.display_number);
        turns
    }
}

impl Scratch {
    /// Runs every payload of a recorded case, with Kiro's session log as it
    /// stood at that call where one was recorded.
    fn replay(&self, case: &str) {
        let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../fixtures/kiro/2026-11")
            .join(case);
        let mut payloads: Vec<PathBuf> = fs::read_dir(&directory)
            .expect("case")
            .map(|entry| entry.expect("entry").path())
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension == "json")
                    && path.file_name().is_some_and(|name| name != "expected.json")
            })
            .collect();
        payloads.sort();
        for path in payloads {
            let payload: Value =
                serde_json::from_slice(&fs::read(&path).expect("payload")).expect("json");
            let log = path.with_extension("transcript.jsonl");
            if log.exists() {
                let session = payload["session_id"].as_str().expect("session");
                let directory = self
                    .root
                    .join("home/.kiro/sessions")
                    .join(FOLDER_DIGEST)
                    .join(session);
                fs::create_dir_all(&directory).expect("log directory");
                fs::copy(&log, directory.join("messages.jsonl")).expect("log");
            }
            self.call(&payload);
        }
    }
}

#[test]
fn a_recorded_session_of_two_turns_records_both() {
    let scratch = Scratch::new();
    scratch.replay("two-turns");
    assert_eq!(scratch.record().state, RunState::Finished);
    let turns = scratch.turns();
    let prompts: Vec<_> = turns
        .iter()
        .map(|turn| turn.prompt_head.as_deref())
        .collect();
    assert_eq!(
        prompts,
        [
            Some("Reply with the single word ok."),
            Some("Create a file named notes.txt containing the word hello, then reply done.")
        ]
    );
    let replies: Vec<_> = turns
        .iter()
        .map(|turn| turn.reply_head.as_deref())
        .collect();
    assert_eq!(replies, [Some("ok"), Some("done")]);
}

/// A resume sends no `SessionStart`: the launch names the session, its first
/// turn is recorded at its stop, and the next begins at its tool, which Esc
/// then stops with no hook.
#[test]
fn a_recorded_resume_names_its_session_and_records_its_turns() {
    let scratch = Scratch::new();
    scratch.call(&json!({
        "hook_event_name": "WeirLaunch",
        "session_id": SESSION,
        "cwd": CWD,
        "trust_all_tools": false,
    }));
    scratch.replay("resume-interrupted");
    let record = scratch.record();
    assert_eq!(record.session_id.as_deref(), Some(SESSION));
    assert_eq!(record.state, RunState::Running);
    let prompts: Vec<_> = scratch
        .turns()
        .iter()
        .map(|turn| turn.prompt_head.clone())
        .collect();
    assert_eq!(
        prompts,
        [
            Some("Reply with the single word resumed.".to_owned()),
            Some("Run exactly this one shell command and nothing else: sleep 30".to_owned())
        ]
    );
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn event(name: &str) -> Value {
    json!({ "session_id": SESSION, "hook_event_name": name, "cwd": CWD })
}

fn tool(name: &str, tool: &str, input: Value) -> Value {
    let mut payload = event(name);
    payload["tool_name"] = Value::from(tool);
    payload["tool_input"] = input;
    payload
}

fn person(text: &str, tag: &str) -> Value {
    json!({ "type": "user", "content": text, "_meta": { "kiro": { "userMessageTag": tag } } })
}

fn turn_start(turn: &str, tag: &str) -> Value {
    json!({ "type": "turn_start", "turnId": turn, "userMessageTag": tag })
}

fn answer(turn: &str, text: &str) -> Value {
    json!({ "type": "assistant", "content": text, "turnId": turn })
}

#[test]
fn a_turn_begins_at_its_first_tool_with_the_persons_words() {
    let scratch = Scratch::new();
    scratch.call(&event("SessionStart"));
    assert_eq!(scratch.record().state, RunState::Idle);

    let mut log = vec![
        person("Create notes.txt", "prompt_1"),
        turn_start("t1", "prompt_1"),
    ];
    scratch.write_log(&log);
    let write = tool(
        "PreToolUse",
        "fs_write",
        json!({ "path": "/Users/person/project/notes.txt" }),
    );
    scratch.call(&write);
    let record = scratch.record();
    assert_eq!(record.state, RunState::Running);
    assert!(record.run_started_at.is_some(), "the tool opened the turn");
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].prompt_head.as_deref(), Some("Create notes.txt"));
    assert_eq!(turns[0].provider_turn_id.as_deref(), Some("t1"));

    // Its second tool is the same turn.
    scratch.call(&tool("PostToolUse", "fs_write", json!({})));
    scratch.call(&write);
    assert_eq!(scratch.turns().len(), 1);

    log.push(answer("t1", "done"));
    scratch.write_log(&log);
    scratch.call(&event("Stop"));
    assert_eq!(scratch.record().state, RunState::Finished);
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].reply_head.as_deref(), Some("done"));
}

#[test]
fn a_turn_with_no_tool_is_recorded_at_its_stop() {
    let scratch = Scratch::new();
    scratch.call(&event("SessionStart"));
    scratch.write_log(&[
        person("Reply with ok.", "prompt_1"),
        turn_start("t1", "prompt_1"),
        answer("t1", "ok"),
    ]);
    scratch.call(&event("Stop"));
    assert_eq!(scratch.record().state, RunState::Finished);
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].prompt_head.as_deref(), Some("Reply with ok."));
    assert_eq!(turns[0].reply_head.as_deref(), Some("ok"));

    // The next prompt's tool is a turn of its own.
    scratch.write_log(&[
        person("Reply with ok.", "prompt_1"),
        turn_start("t1", "prompt_1"),
        answer("t1", "ok"),
        person("Now list the files.", "prompt_2"),
        turn_start("t2", "prompt_2"),
    ]);
    scratch.call(&tool(
        "PreToolUse",
        "execute_bash",
        json!({ "command": "ls" }),
    ));
    assert_eq!(scratch.turns().len(), 2);
}

/// A turn whose start is no longer in the part of the log the runtime reads
/// names no turn, and begins no record, though its tools still show.
#[test]
fn a_turn_whose_start_the_log_tail_lost_opens_no_record() {
    let scratch = Scratch::new();
    scratch.call(&event("SessionStart"));
    scratch.write_log(&[answer("t1", "a long answer")]);
    scratch.call(&tool(
        "PreToolUse",
        "execute_bash",
        json!({ "command": "ls" }),
    ));
    assert_eq!(scratch.record().state, RunState::Running);
    assert!(scratch.turns().is_empty());
}

/// A launch that names no session (`--resume`) learns it from the first call,
/// since a resume sends no `SessionStart`.
#[test]
fn a_resume_learns_its_session_from_the_first_call() {
    let scratch = Scratch::new();
    let launch = json!({
        "hook_event_name": "WeirLaunch",
        "session_id": "",
        "cwd": CWD,
        "trust_all_tools": true,
    });
    scratch.call(&launch);
    let record = scratch.record();
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.session_id, None);
    // The launch says how freely Kiro acts, and no later call says otherwise.
    assert_eq!(
        record.permission_mode,
        Some(PermissionMode::BypassPermissions)
    );

    scratch.write_log(&[person("Go on.", "prompt_1"), turn_start("t1", "prompt_1")]);
    scratch.call(&tool(
        "PreToolUse",
        "read_file",
        json!({ "path": "README" }),
    ));
    let record = scratch.record();
    assert_eq!(record.session_id.as_deref(), Some(SESSION));
    assert_eq!(
        record.permission_mode,
        Some(PermissionMode::BypassPermissions)
    );
}

#[test]
fn a_call_outside_weir_writes_nothing() {
    let bytes = serde_json::to_vec(&event("Stop")).expect("bytes");
    let env = HookEnv::from_pairs(vec![("HOME", "/Users/person")]);
    assert_eq!(
        run_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &NoSnapshots)),
        HookOutcome::NotInWeir
    );
}

#[test]
fn a_worktree_it_routes_is_refused_by_exit_status_two() {
    let repo = support::Repo::new("kiro-worktree");
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
        ("WEIR_KIRO_AGENT_STATES_DIR", states.to_str().expect("path")),
        (
            "WEIR_KIRO_SESSIONS_DIR",
            repo.root.join("support/sessions").to_str().expect("path"),
        ),
    ]);
    let call = |name: &str, command: &str| {
        let mut payload = tool(name, "execute_bash", json!({ "command": command }));
        payload["cwd"] = Value::from(repo.path.display().to_string());
        serde_json::to_vec(&payload).expect("bytes")
    };
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    let outcome = run_worktree_hook(
        PROVIDER,
        &call("PreToolUse", "git worktree add -b demo ../demo"),
        &runtime,
    );
    assert_eq!(outcome.exit_code(), 2);
    let HookOutcome::Intercepted {
        message,
        stdout: None,
        ..
    } = outcome
    else {
        panic!("not refused: {outcome:?}");
    };
    let folder = repo.root.join("repo-demo");
    let command = format!("git worktree add -b demo {}", folder.display());
    assert!(message.contains(&command), "the model is told what to run");
    assert!(!folder.exists(), "nothing is made before Kiro's own prompt");

    // The model's next call names the folder, and goes to Kiro's prompt as is.
    assert_eq!(
        run_worktree_hook(PROVIDER, &call("PreToolUse", &command), &runtime),
        HookOutcome::Applied
    );
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-b",
            "demo",
            folder.to_str().expect("path"),
        ],
    );
    let finished = run_worktree_hook(PROVIDER, &call("PostToolUse", &command), &runtime);
    assert_eq!(finished.exit_code(), 0);
    assert!(
        matches!(finished, HookOutcome::Intercepted { stdout: None, .. }),
        "{finished:?}"
    );
}

/// A pane whose Kiro works in a Git repository, with snapshots taken, for
/// what a turn changed.
struct InRepo {
    scratch: Scratch,
    repo: support::Repo,
}

impl InRepo {
    fn new(name: &str) -> Self {
        Self {
            scratch: Scratch::new(),
            repo: support::Repo::new(name),
        }
    }

    fn cwd(&self) -> String {
        self.repo.path.display().to_string()
    }

    /// Kiro's session log, each line with the time Kiro stamps it with.
    fn write_log(&self, lines: &[(&str, Value)]) {
        let path = PathBuf::from(self.log_path());
        fs::create_dir_all(path.parent().expect("log directory")).expect("log directory");
        let mut text = String::new();
        for (time, line) in lines {
            text.push_str(&json!({ "id": "x", "timestamp": time, "payload": line }).to_string());
            text.push('\n');
        }
        fs::write(path, text).expect("log");
    }

    /// Where the adapter itself looks for this folder's session log, so the
    /// test names it as the runtime does.
    fn log_path(&self) -> String {
        let payload =
            json!({ "session_id": SESSION, "hook_event_name": "Stop", "cwd": self.cwd() });
        let bytes = serde_json::to_vec(&payload).expect("bytes");
        let context = HookContext {
            run_id: RUN.parse().expect("run"),
            pane_id: PANE.parse().expect("pane"),
            tmux: None,
            pid: None,
            invocation_id: None,
            provider_home: Some(self.scratch.root.join("home/.kiro")),
            hook_directory: None,
            resolved_provider_home: None,
            resolved_hook_directory: None,
            received_at: std::time::UNIX_EPOCH,
        };
        weir_agent_hook::adapter_for(PROVIDER)
            .expect("kiro")
            .unprompted_turn_transcript_path(
                RawHookInput {
                    bytes: &bytes,
                    transcript: None,
                },
                &context,
            )
            .expect("path")
            .expect("a session log")
    }

    fn call(&self, payload: &Value) {
        let mut payload = payload.clone();
        payload["cwd"] = Value::from(self.cwd());
        let bytes = serde_json::to_vec(&payload).expect("bytes");
        let env = self.scratch.env();
        assert_eq!(
            run_hook(PROVIDER, &bytes, &HookRuntime::new(&env, &GitSnapshots)),
            HookOutcome::Applied,
            "{payload}"
        );
    }
}

fn tool_call(turn: &str) -> Value {
    json!({ "type": "tool_call", "toolName": "execute_bash", "status": "completed", "turnId": turn })
}

/// A turn whose log shows nothing run is first seen at its stop, and changed
/// nothing of the agent's: the main agent's tools all pass `PreToolUse` before
/// they run, and a subagent leaves lines of its own. So its changes read as
/// none rather than as lost, and it began when the log says, not when its
/// stop came.
#[test]
fn a_turn_with_no_tool_changes_nothing_and_began_when_the_log_says() {
    let pane = InRepo::new("kiro-no-tool");
    pane.call(&event("SessionStart"));
    pane.write_log(&[
        (
            "2026-11-11T04:38:28.900Z",
            person("Count to 400.", "prompt_1"),
        ),
        ("2026-11-11T04:38:29.097Z", turn_start("t1", "prompt_1")),
        ("2026-11-11T04:38:47.120Z", answer("t1", "1 one 2 two")),
    ]);
    pane.call(&event("Stop"));
    let turns = pane.scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].changes, ChangeSummary::Unchanged);
    assert_eq!(turns[0].started_at, "2026-11-11T04:38:29Z");
}

/// A turn whose log shows a tool, yet whose first call is its stop (the tool's
/// hook was turned off, say), may have changed what no snapshot holds: it
/// still reads as missing its begin.
#[test]
fn a_turn_first_seen_at_its_stop_after_a_tool_keeps_its_begin_missing() {
    let pane = InRepo::new("kiro-missed-tool");
    pane.call(&event("SessionStart"));
    pane.write_log(&[
        (
            "2026-11-11T04:38:28.900Z",
            person("Write notes.txt.", "prompt_1"),
        ),
        ("2026-11-11T04:38:29.097Z", turn_start("t1", "prompt_1")),
        ("2026-11-11T04:38:31.000Z", tool_call("t1")),
        ("2026-11-11T04:38:32.000Z", answer("t1", "done")),
    ]);
    fs::write(pane.repo.path.join("notes.txt"), "hello\n").expect("write");
    pane.call(&event("Stop"));
    let turns = pane.scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(
        turns[0].changes,
        ChangeSummary::Unavailable {
            reason: "beginMissing".to_owned()
        }
    );
}

/// A turn begun at its first tool still shows what the tool changed, and it
/// too began when the log says.
#[test]
fn a_turn_begun_at_its_first_tool_shows_its_change_and_starts_at_that_call() {
    let pane = InRepo::new("kiro-tool");
    pane.call(&event("SessionStart"));
    let mut log = vec![
        (
            "2026-11-11T04:38:56.104Z",
            person("Write notes.txt.", "prompt_1"),
        ),
        ("2026-11-11T04:38:56.104Z", turn_start("t1", "prompt_1")),
    ];
    pane.write_log(&log);
    pane.call(&tool(
        "PreToolUse",
        "fs_write",
        json!({ "path": "notes.txt" }),
    ));
    fs::write(pane.repo.path.join("notes.txt"), "hello\n").expect("write");
    pane.call(&tool("PostToolUse", "fs_write", json!({})));
    log.push(("2026-11-11T04:39:44.116Z", tool_call("t1")));
    log.push(("2026-11-11T04:39:45.000Z", answer("t1", "done")));
    pane.write_log(&log);
    pane.call(&event("Stop"));
    let turns = pane.scratch.turns();
    assert_eq!(turns.len(), 1);
    assert!(
        matches!(turns[0].changes, ChangeSummary::Changed { files: 1, .. }),
        "{:?}",
        turns[0].changes
    );
    // The start orders the turn for a restore by its begin snapshot, which
    // the tool's call took, not by the person's words in the log.
    assert_ne!(turns[0].started_at, "2026-11-11T04:38:56Z");
}

/// A turn that handed its work to a subagent leaves `sub_agent_start` lines
/// and no `tool_call` (kiro-cli 3.2.0), and the subagent's own tools run no
/// hook. First seen at its stop, it may have changed what no snapshot holds,
/// so it still reads as missing its begin.
#[test]
fn a_turn_first_seen_at_its_stop_after_a_subagent_keeps_its_begin_missing() {
    let pane = InRepo::new("kiro-subagent");
    pane.call(&event("SessionStart"));
    pane.write_log(&[
        (
            "2026-11-11T05:01:14.000Z",
            person("Have a subagent write notes.txt.", "prompt_1"),
        ),
        ("2026-11-11T05:01:14.100Z", turn_start("t1", "prompt_1")),
        (
            "2026-11-11T05:01:18.261Z",
            json!({ "type": "sub_agent_start", "parentExecutionId": "t1", "subSessionId": "s" }),
        ),
        (
            "2026-11-11T05:01:22.381Z",
            json!({ "type": "sub_agent_complete", "parentExecutionId": "t1", "subSessionId": "s", "status": "success" }),
        ),
        ("2026-11-11T05:01:24.000Z", answer("t1", "done")),
    ]);
    fs::write(pane.repo.path.join("notes.txt"), "hello\n").expect("write");
    pane.call(&event("Stop"));
    let turns = pane.scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(
        turns[0].changes,
        ChangeSummary::Unavailable {
            reason: "beginMissing".to_owned()
        }
    );
}
