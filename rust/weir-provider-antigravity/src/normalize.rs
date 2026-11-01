//! Maps Antigravity hook payloads to neutral events.
//!
//! `agy` names no event in its payload; `weir-dispatch`, which each hook of
//! the plugin runs, adds `hook_event_name` from its argument. It also has no
//! hook for a prompt: a model request (`PreInvocation`) numbered 0 is the
//! first of a turn, and the transcript says whose turn it is.

use crate::{transcript, usage};
use serde_json::{Map, Value, json};
use std::time::SystemTime;
use weir_agent_model::{
    AgentEvent, MAX_HOOK_INPUT_BYTES, NormalizeError, RawHookInput, RunRecord, SessionSettings,
    SessionSource, WorktreeIntent, parse_object,
};

/// The tool `agy` asks the person a question with.
const QUESTION_TOOL: &str = "ask_question";
/// What our shim names its report of a launch; `agy` has no event of this name.
const LAUNCH_EVENT: &str = "WeirLaunch";
/// The tool `agy` runs a shell command with.
const SHELL_TOOL: &str = "run_command";
/// The event a turn no person began reports, so the call has an event for the
/// runtime to begin that turn before (`unprompted_start`).
const UNPROMPTED_TURN: &str = "UnpromptedTurn";
/// The event `/compact` reports. `agy` has no hook for compaction, and one
/// the person stops with Esc sends no `Stop`, so a `Compacting` state outside
/// a turn would have nothing to end it.
const COMPACTION_REQUEST: &str = "CompactionRequest";

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn event_name(object: &Map<String, Value>) -> Option<&str> {
    string(object, "hook_event_name")
}

fn conversation(object: &Map<String, Value>) -> Option<&str> {
    string(object, "conversationId").filter(|id| !id.is_empty())
}

/// A subagent's calls reach the same hooks under its own conversation, and
/// only a subagent's have no input of the person's (agy 1.4.12).
fn is_subagents(object: &Map<String, Value>) -> bool {
    string(object, "lastUserInput").is_some_and(str::is_empty)
}

fn is_turn_opening_request(object: &Map<String, Value>) -> bool {
    event_name(object) == Some("PreInvocation")
        && object.get("invocationNum").and_then(Value::as_u64) == Some(0)
}

/// The folder the session runs in: its first workspace folder. A hook's own
/// working directory is the plugin's.
fn workspace(object: &Map<String, Value>) -> Option<String> {
    object
        .get("workspacePaths")?
        .as_array()?
        .first()?
        .as_str()
        .map(str::to_owned)
}

/// Only `/compact` alone: with a message `agy` goes on to answer it in the same
/// turn, under the same `lastUserInput` and with the tools it needs, so that
/// one is an ordinary turn (agy 1.4.12).
fn is_compact_command(input: &str) -> bool {
    input.trim() == "/compact"
}

fn is_compact_turn(object: &Map<String, Value>) -> bool {
    string(object, "lastUserInput").is_some_and(is_compact_command)
}

fn extension(name: &str) -> AgentEvent {
    AgentEvent::Extension {
        name: name.to_owned(),
        payload: json!({}),
    }
}

fn is_unprompted(object: &Map<String, Value>, input: RawHookInput<'_>) -> bool {
    is_turn_opening_request(object)
        && !is_subagents(object)
        && input
            .transcript
            .and_then(transcript::ends_with_person_input)
            .is_some_and(|ends_with_person| !ends_with_person)
}

pub(crate) fn normalize(input: RawHookInput<'_>) -> Result<Vec<AgentEvent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if is_subagents(&object) {
        return Ok(Vec::new());
    }
    let tool = || {
        object
            .get("toolCall")
            .and_then(|call| call.get("name"))
            .and_then(Value::as_str)
            .unwrap_or_default()
    };
    let events = match event_name(&object) {
        Some("SessionStart") => vec![AgentEvent::SessionStarted {
            compact: false,
            source: Some(SessionSource::Startup),
            session_id: conversation(&object).map(str::to_owned),
            session_title: None,
            cwd: workspace(&object),
        }],
        // Our shim's report of a launch, which `agy` makes none of: it sends
        // `SessionStart` only with the first prompt, and none for a resume. A
        // failure before the first prompt then has a run to show on.
        Some(LAUNCH_EVENT) => {
            let session_id = conversation(&object).map(str::to_owned);
            vec![AgentEvent::SessionStarted {
                compact: false,
                source: Some(if session_id.is_some() {
                    SessionSource::Resume
                } else {
                    SessionSource::Startup
                }),
                session_id,
                session_title: None,
                cwd: workspace(&object),
            }]
        }
        Some("PreInvocation") => {
            if !is_turn_opening_request(&object) {
                Vec::new()
            } else if is_unprompted(&object, input) {
                vec![extension(UNPROMPTED_TURN)]
            } else if is_compact_turn(&object) {
                vec![extension(COMPACTION_REQUEST)]
            } else {
                vec![AgentEvent::PromptSubmitted {
                    prompt: string(&object, "lastUserInput")
                        .unwrap_or_default()
                        .to_owned(),
                    kind: None,
                    titles: None,
                    cwd: workspace(&object),
                }]
            }
        }
        Some("PreToolUse") if tool() == QUESTION_TOOL => vec![AgentEvent::WaitingForInput {
            detail: question(&object),
        }],
        Some("PreToolUse") => vec![AgentEvent::ToolStarted {
            tool: tool().to_owned(),
            detail: Some(tool_detail(&object, tool())),
            by_subagent: false,
        }],
        // A daemon's call ends after the `Stop` of the turn that started it
        // (agy 1.4.12); the turn its end begins reports by itself.
        Some("PostInvocation" | "PostToolUse") if is_invisible(&object) => Vec::new(),
        Some("PostToolUse") => vec![AgentEvent::ToolFinished {
            tool: Some(tool().to_owned()),
            by_subagent: false,
        }],
        Some("Stop") => stop_events(&object, input),
        Some(name) => vec![AgentEvent::Extension {
            name: name.to_owned(),
            payload: Value::Object(object.clone()),
        }],
        None => Vec::new(),
    };
    Ok(events)
}

fn is_invisible(object: &Map<String, Value>) -> bool {
    event_name(object) == Some("PostInvocation") || is_daemon(object)
}

fn stop_events(object: &Map<String, Value>, input: RawHookInput<'_>) -> Vec<AgentEvent> {
    if let Some(error) = string(object, "error").filter(|error| !error.is_empty()) {
        return vec![AgentEvent::Failed {
            error: error.to_owned(),
            usage_limit: usage::usage_limit(error, SystemTime::now()),
        }];
    }
    // A turn the agent began by itself after `/compact` keeps that input, and
    // has to end as any turn does.
    let is_answered = input
        .transcript
        .is_some_and(transcript::has_answer_since_person_input);
    if is_compact_turn(object) && !is_answered {
        return vec![extension(COMPACTION_REQUEST)];
    }
    // We do not read `fullyIdle` as a running subagent: a pending `schedule`
    // timer also leaves it false, and no later `Stop` need come to clear what
    // it would claim.
    vec![AgentEvent::TurnFinished {
        titles: None,
        cache: None,
        continues_after_stop_hook: false,
        reply: input.transcript.and_then(transcript::turn_reply),
        background_work: None,
    }]
}

/// The tool and the command it runs or the file it touches, as Claude's and
/// Codex's rows show them. Other tools name neither.
fn tool_detail(object: &Map<String, Value>, tool: &str) -> String {
    let args = object.get("toolCall").and_then(|call| call.get("args"));
    let argument = ["CommandLine", "Path", "AbsolutePath"]
        .iter()
        .filter_map(|key| args?.get(*key)?.as_str())
        .find(|argument| !argument.is_empty());
    match argument {
        Some(argument) => format!("{tool}: {argument}"),
        None => tool.to_owned(),
    }
}

fn question(object: &Map<String, Value>) -> Option<String> {
    object
        .get("toolCall")?
        .get("args")?
        .get("questions")?
        .get(0)?
        .get("question")?
        .as_str()
        .map(str::to_owned)
}

fn is_daemon(object: &Map<String, Value>) -> bool {
    object
        .get("toolCall")
        .and_then(|call| call.get("args"))
        .and_then(|args| args.get("IsDaemon"))
        .and_then(Value::as_bool)
        == Some(true)
}

/// The transcript the runtime reads with this call: only for the calls whose
/// events it decides.
pub(crate) fn transcript_path(input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let is_read = is_turn_opening_request(&object) || event_name(&object) == Some("Stop");
    Ok(is_read.then(|| path(&object)).flatten())
}

fn path(object: &Map<String, Value>) -> Option<String> {
    string(object, "transcriptPath")
        .filter(|path| {
            std::path::Path::new(path)
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
        })
        .map(str::to_owned)
}

/// The transcript a stopped turn is read from: named by the call that opens
/// the turn or a wait, as no hook comes when the person stops it.
pub(crate) fn turn_transcript_path(
    input: RawHookInput<'_>,
) -> Result<Option<String>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if is_subagents(&object) {
        return Ok(None);
    }
    let is_question = event_name(&object) == Some("PreToolUse")
        && object
            .get("toolCall")
            .and_then(|call| call.get("name"))
            .and_then(Value::as_str)
            == Some(QUESTION_TOOL);
    let is_named = is_turn_opening_request(&object) || is_question;
    Ok(is_named.then(|| path(&object)).flatten())
}

/// Ignores a subagent's calls, and those of a conversation the run has left
/// (`/clear` starts another while the first may still finish its turn).
pub(crate) fn applies_to(input: RawHookInput<'_>, record: Option<&RunRecord>) -> bool {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return true;
    };
    if is_subagents(&object) {
        return false;
    }
    if event_name(&object) == Some("SessionStart") {
        return true;
    }
    let current = record.and_then(|record| record.session_id.as_deref());
    match (current, conversation(&object)) {
        (Some(current), Some(called)) => current == called,
        _ => true,
    }
}

/// `agy --conversation` sends no `SessionStart`. The first request of a run
/// with no session stands for it, so the record and the resume hint name the
/// conversation. `SessionStart` comes first when there is one, as `agy` waits
/// for that hook before its first request, so this never replaces it.
pub(crate) fn session_started_if_unseen(
    input: RawHookInput<'_>,
    record: Option<&RunRecord>,
) -> Option<AgentEvent> {
    if record.is_some_and(|record| record.session_id.is_some()) {
        return None;
    }
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    if !is_turn_opening_request(&object) || is_subagents(&object) {
        return None;
    }
    Some(AgentEvent::SessionStarted {
        compact: false,
        source: Some(SessionSource::Resume),
        session_id: Some(conversation(&object)?.to_owned()),
        session_title: None,
        cwd: workspace(&object),
    })
}

/// `<conversation>#<first step>`: `agy` names no turn, and only a turn's first
/// request gives where it begins. The transcript then ends at the step before
/// (agy 1.4.12). A `/compact` alone begins no turn, and names none.
pub(crate) fn turn_marker(input: RawHookInput<'_>) -> Option<String> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    if !is_turn_opening_request(&object) || is_subagents(&object) {
        return None;
    }
    if is_compact_turn(&object) && !is_unprompted(&object, input) {
        return None;
    }
    let step = object.get("initialNumSteps").and_then(Value::as_u64)?;
    Some(format!("{}#{step}", conversation(&object)?))
}

/// The first step of the turn a marker names.
pub(crate) fn marker_step(marker: &str) -> Option<u64> {
    marker.rsplit_once('#')?.1.parse().ok()
}

pub(crate) fn unprompted_cwd(input: RawHookInput<'_>) -> Option<String> {
    workspace(&parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?)
}

/// The model and how hard it reasons. `agy` writes both in one id
/// (`gemini-3.8-flash-high`), and reports no permission mode to a hook.
pub(crate) fn session_settings(input: RawHookInput<'_>) -> SessionSettings {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return SessionSettings::default();
    };
    let Some(id) = string(&object, "modelName").filter(|_| !is_subagents(&object)) else {
        return SessionSettings::default();
    };
    let (id, effort) = match id.rsplit_once('-') {
        Some((model, effort @ ("low" | "medium" | "high"))) => (model, Some(effort.to_owned())),
        _ => (id, None),
    };
    SessionSettings {
        model: Some(model_name(id)),
        effort,
        ..SessionSettings::default()
    }
}

/// `gemini-3.8-flash` as `Gemini 3.8 Flash`, and `claude-opus-4-6-thinking`
/// as `Claude Opus 4.6`. An id of another shape stays as `agy` wrote it.
fn model_name(id: &str) -> String {
    let id = id.strip_suffix("-thinking").unwrap_or(id);
    if !(id.starts_with("gemini-") || id.starts_with("claude-")) {
        return id.to_owned();
    }
    let mut words: Vec<String> = Vec::new();
    for word in id.split('-') {
        let is_version = word.chars().all(|c| c.is_ascii_digit() || c == '.');
        match words.last_mut() {
            Some(last) if is_version && last.starts_with(|c: char| c.is_ascii_digit()) => {
                last.push('.');
                last.push_str(word);
            }
            _ => {
                let mut chars = word.chars();
                words.push(chars.next().map_or_else(String::new, |first| {
                    first.to_ascii_uppercase().to_string() + chars.as_str()
                }));
            }
        }
    }
    words.join(" ")
}

pub(crate) fn worktree_intent(
    input: RawHookInput<'_>,
) -> Result<Option<WorktreeIntent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let call = object.get("toolCall");
    if event_name(&object) != Some("PreToolUse") {
        return Ok(None);
    }
    if call
        .and_then(|call| call.get("name"))
        .and_then(Value::as_str)
        != Some(SHELL_TOOL)
    {
        return Ok(None);
    }
    let Some(command) = call
        .and_then(|call| call.get("args"))
        .and_then(|args| args.get("CommandLine"))
        .and_then(Value::as_str)
    else {
        return Ok(None);
    };
    Ok(WorktreeIntent::parse(
        command,
        workspace(&object).as_deref(),
    ))
}

/// The reply that cancels a tool call. A hook that exits non-zero is an error
/// to `agy`, which the model retries; a `deny` shows it the reason.
pub(crate) fn deny_output(message: &str) -> Vec<u8> {
    json!({"decision": "deny", "reason": message})
        .to_string()
        .into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_ids_read_as_a_person_would_say_them() {
        assert_eq!(model_name("gemini-3.8-flash"), "Gemini 3.8 Flash");
        assert_eq!(model_name("claude-opus-4-6-thinking"), "Claude Opus 4.6");
        assert_eq!(model_name("gpt-oss-120b"), "gpt-oss-120b");
    }

    #[test]
    fn compact_is_the_command_alone() {
        assert!(is_compact_command("/compact"));
        assert!(!is_compact_command("/compact keep the tests"));
        assert!(!is_compact_command("/compactness"));
    }

    fn normalized(payload: &Value) -> Vec<AgentEvent> {
        let bytes = payload.to_string().into_bytes();
        normalize(RawHookInput {
            bytes: &bytes,
            transcript: None,
        })
        .expect("normalizes")
    }

    #[test]
    fn a_launch_is_a_start_and_a_resume_only_when_it_names_a_conversation() {
        let source = |conversation: &str| match normalized(&json!({
            "hook_event_name": LAUNCH_EVENT,
            "conversationId": conversation,
            "workspacePaths": ["/project"],
        }))
        .as_slice()
        {
            [
                AgentEvent::SessionStarted {
                    source,
                    session_id,
                    cwd,
                    ..
                },
            ] => {
                assert_eq!(cwd.as_deref(), Some("/project"));
                (*source, session_id.clone())
            }
            other => panic!("{other:?}"),
        };
        assert_eq!(source(""), (Some(SessionSource::Startup), None));
        assert_eq!(
            source("abc"),
            (Some(SessionSource::Resume), Some("abc".to_owned()))
        );
    }

    #[test]
    fn a_tools_detail_prefers_what_it_runs_or_touches_then_its_name() {
        let detail = |name: &str, args: Value| match normalized(&json!({
            "hook_event_name": "PreToolUse",
            "toolCall": {"name": name, "args": args},
        }))
        .as_slice()
        {
            [AgentEvent::ToolStarted { detail, .. }] => detail.clone(),
            other => panic!("{other:?}"),
        };
        let expect = |text: &str| Some(text.to_owned());
        assert_eq!(
            detail("run_command", json!({"CommandLine": "ls"})),
            expect("run_command: ls")
        );
        assert_eq!(
            detail("write_file", json!({"Path": "/a.txt"})),
            expect("write_file: /a.txt")
        );
        assert_eq!(
            detail("view_file", json!({"AbsolutePath": "/a.txt"})),
            expect("view_file: /a.txt")
        );
        assert_eq!(
            detail("write_file", json!({"Path": "", "AbsolutePath": "/b"})),
            expect("write_file: /b")
        );
        assert_eq!(detail("list_dir", json!({"Other": 1})), expect("list_dir"));
    }

    #[test]
    fn a_marker_names_the_step_its_turn_begins_at() {
        assert_eq!(marker_step("abc#12"), Some(12));
        assert_eq!(marker_step("abc"), None);
    }

    /// A request numbered 0 at step `steps`, with the transcript as it stands.
    fn opening_request(steps: u64, input: &str) -> String {
        json!({
            "hook_event_name": "PreInvocation",
            "conversationId": "c",
            "invocationNum": 0,
            "initialNumSteps": steps,
            "lastUserInput": input,
        })
        .to_string()
    }

    fn marker_of(payload: &str, transcript: &str) -> Option<String> {
        turn_marker(RawHookInput {
            bytes: payload.as_bytes(),
            transcript: Some(transcript.as_bytes()),
        })
    }

    #[test]
    fn a_stopped_turn_does_not_read_the_turn_the_next_input_began() {
        let input = |step: u64| {
            format!(r#"{{"step_index":{step},"source":"USER_EXPLICIT","type":"USER_INPUT"}}"#)
        };
        let marker = marker_of(&opening_request(1, "first"), &(input(0) + "\n"));
        let transcript = [
            input(0),
            r#"{"step_index":1,"type":"PLANNER_RESPONSE","input_tokens":10,"output_tokens":1,"tool_calls":[{"name":"run_command","args":{"CommandLine":"first"}}]}"#.to_owned(),
            r#"{"step_index":2,"type":"GENERIC","content":"Command exited with code 0."}"#.to_owned(),
            input(3),
            r#"{"step_index":4,"type":"PLANNER_RESPONSE","input_tokens":500,"output_tokens":50,"tool_calls":[{"name":"run_command","args":{"CommandLine":"second"}}]}"#.to_owned(),
            r#"{"step_index":5,"type":"GENERIC","content":"Command exited with code 0."}"#.to_owned(),
        ]
        .join("\n");
        let reading = transcript::turn_reading(transcript.as_bytes(), marker.as_deref());
        assert_eq!(reading.usage.expect("usage").input_tokens, 10);
        let commands = reading.commands.expect("commands");
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].command, "first");
    }

    #[test]
    fn a_stop_at_the_quota_is_a_failure_with_a_limit_and_another_error_has_none() {
        let limit_of = |error: &str| {
            let events = normalized(&json!({"hook_event_name": "Stop", "error": error}));
            match events.as_slice() {
                [AgentEvent::Failed { usage_limit, .. }] => usage_limit.clone(),
                other => panic!("{other:?}"),
            }
        };
        assert!(limit_of("You have exhausted your quota on this model.").is_some());
        assert_eq!(limit_of("RESOURCE_EXHAUSTED (code 429)"), None);
    }

    #[test]
    fn a_compact_command_alone_names_no_turn() {
        let transcript = r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT"}"#;
        assert_eq!(marker_of(&opening_request(1, "/compact"), transcript), None);
        assert_eq!(
            marker_of(&opening_request(1, "/compact keep it short"), transcript).as_deref(),
            Some("c#1")
        );
    }
}
