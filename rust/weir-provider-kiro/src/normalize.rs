//! Maps Kiro hook payloads to neutral events.
//!
//! Every payload carries `session_id`, `hook_event_name`, and `cwd`; tool
//! calls add `tool_name` and `tool_input`, and `PostToolUse` its
//! `tool_response`, a string. None names a transcript, a model, or a turn
//! (kiro-cli 2.37.1). We subscribe no prompt hook, as its output, even an
//! empty one, joins the model's context every turn; a turn's start is read
//! from Kiro's session log instead (`transcript`).

use crate::transcript;
use serde_json::{Map, Value};
use weir_agent_model::{
    AgentEvent, Caller, CommandRun, HookContext, HookRefusal, MAX_HOOK_INPUT_BYTES, NormalizeError,
    PermissionMode, RawHookInput, RunRecord, SessionSettings, SessionSource, UnpromptedPrompt,
    WorktreeIntent, parse_object,
};

/// The tool Kiro runs a shell command with.
const SHELL_TOOL: &str = "execute_bash";
/// What our shim names its report of a launch; Kiro has no event of this name.
const LAUNCH_EVENT: &str = "WeirLaunch";
/// The calls that read Kiro's session log: a tool's start may begin a turn,
/// and a stop ends one.
const LOG_EVENTS: [&str; 2] = ["PreToolUse", "Stop"];
/// Kiro's status for a refused tool call: its `PreToolUse` reads nothing on
/// standard output, and stops a call only on this exit status, handing
/// standard error to the model.
const REFUSAL_STATUS: i32 = 2;

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn event_name(object: &Map<String, Value>) -> Option<&str> {
    string(object, "hook_event_name")
}

fn session(object: &Map<String, Value>) -> Option<&str> {
    string(object, "session_id").filter(|id| !id.is_empty())
}

fn cwd(object: &Map<String, Value>) -> Option<String> {
    string(object, "cwd")
        .filter(|cwd| !cwd.is_empty())
        .map(str::to_owned)
}

fn tool(object: &Map<String, Value>) -> &str {
    string(object, "tool_name").unwrap_or_default()
}

pub(crate) fn normalize(input: RawHookInput<'_>) -> Result<Vec<AgentEvent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let events = match event_name(&object) {
        Some("SessionStart") => vec![AgentEvent::SessionStarted {
            compact: false,
            source: Some(SessionSource::Startup),
            session_id: session(&object).map(str::to_owned),
            session_title: None,
            cwd: cwd(&object),
        }],
        // Our shim's report of a launch: Kiro sends `SessionStart` only with
        // the first prompt, and none for a resume. A failure before the
        // first prompt then has a run to show on.
        Some(LAUNCH_EVENT) => {
            let session_id = session(&object).map(str::to_owned);
            vec![AgentEvent::SessionStarted {
                compact: false,
                source: Some(if session_id.is_some() {
                    SessionSource::Resume
                } else {
                    SessionSource::Startup
                }),
                session_id,
                session_title: None,
                cwd: cwd(&object),
            }]
        }
        // A subagent's own tools reach no hook in kiro-cli 3.2.0 (2.37.1 sent
        // them under the session that ran it); either way they fall within
        // that session's `invoke_sub_agent` call, so they read as its own.
        Some("PreToolUse") => vec![AgentEvent::ToolStarted {
            tool: tool(&object).to_owned(),
            detail: Some(tool_detail(&object)),
            caller: Caller::Agent,
        }],
        Some("PostToolUse") => vec![AgentEvent::ToolFinished {
            tool: Some(tool(&object).to_owned()),
            caller: Caller::Agent,
        }],
        Some("Stop") => vec![AgentEvent::TurnFinished {
            titles: None,
            cache: None,
            continues_after_stop_hook: false,
            reply: input.transcript.and_then(|log| {
                transcript::last_turn(log).and_then(|turn| transcript::reply(log, &turn))
            }),
            background_work: None,
        }],
        Some(name) => vec![AgentEvent::Extension {
            name: name.to_owned(),
            payload: Value::Object(object.clone()),
        }],
        None => Vec::new(),
    };
    Ok(events)
}

/// Returns the tool and the command it runs or the file it touches, as the other
/// providers' rows show them. Other tools name neither.
fn tool_detail(object: &Map<String, Value>) -> String {
    let tool = tool(object);
    let argument = ["command", "path", "file_path"]
        .iter()
        .filter_map(|key| object.get("tool_input")?.get(*key)?.as_str())
        .find(|argument| !argument.is_empty());
    match argument {
        Some(argument) => format!("{tool}: {argument}"),
        None => tool.to_owned(),
    }
}

/// Returns the path of Kiro's session log, for the calls whose events or turn
/// read it.
pub(crate) fn transcript_path(
    input: RawHookInput<'_>,
    context: &HookContext,
) -> Result<Option<String>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if !event_name(&object).is_some_and(|event| LOG_EVENTS.contains(&event)) {
        return Ok(None);
    }
    let (Some(home), Some(session), Some(cwd)) = (
        context.provider_home.as_deref(),
        session(&object),
        cwd(&object),
    ) else {
        return Ok(None);
    };
    Ok(transcript::session_log(home, &cwd, session))
}

/// Returns the turn the call is part of, by Kiro's own id for it: the last turn its
/// session log has begun. A turn whose start lies before the part of the log
/// the runtime reads names none, and so begins no turn record of its own.
pub(crate) fn turn_marker(input: RawHookInput<'_>) -> Option<String> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    if !event_name(&object).is_some_and(|event| LOG_EVENTS.contains(&event)) {
        return None;
    }
    input.transcript.and_then(transcript::last_turn)
}

/// Returns the person's words that began the turn `marker` names, the folder the
/// session runs in, when the turn began, and whether it has run a tool.
/// Every tool of Kiro's main agent passes `PreToolUse` before it runs, and a
/// subagent starts from a tool of its parent's (`invoke_sub_agent`), so a turn
/// whose log shows nothing but quiet lines changed nothing before the call:
/// the runtime then takes its begin even at its `Stop`. A log that does not
/// hold the turn's start says neither.
pub(crate) fn unprompted_prompt(input: RawHookInput<'_>, marker: &str) -> UnpromptedPrompt {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok();
    let so_far = input
        .transcript
        .and_then(|log| transcript::turn_so_far(log, marker));
    UnpromptedPrompt {
        prompt: input
            .transcript
            .and_then(|log| transcript::prompt(log, marker))
            .unwrap_or_default(),
        kind: None,
        cwd: object.as_ref().and_then(cwd),
        started_at: so_far.as_ref().and_then(|turn| turn.started_at.clone()),
        has_run_no_tool: so_far.is_some_and(|turn| turn.has_run_no_tool),
    }
}

/// Returns whether the call is of the session the run is in. Kiro can open
/// another session in the same process while the first finishes its turn,
/// and the first one's calls are then ignored.
pub(crate) fn applies_to(input: RawHookInput<'_>, record: Option<&RunRecord>) -> bool {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return true;
    };
    if matches!(event_name(&object), Some("SessionStart" | LAUNCH_EVENT)) {
        return true;
    }
    let current = record.and_then(|record| record.session_id.as_deref());
    match (current, session(&object)) {
        (Some(current), Some(called)) => current == called,
        _ => true,
    }
}

/// Returns the start of the call's session for a run that has none, so the
/// record and the resume hint name the session. Kiro sends no `SessionStart`
/// for `--resume-id` or `--resume`, and our launch report knows no session for
/// the latter, so the first call of such a run stands for that start.
pub(crate) fn session_started_if_unseen(
    input: RawHookInput<'_>,
    record: Option<&RunRecord>,
) -> Option<AgentEvent> {
    if record.is_some_and(|record| record.session_id.is_some()) {
        return None;
    }
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    if !matches!(
        event_name(&object),
        Some("PreToolUse" | "PostToolUse" | "Stop")
    ) {
        return None;
    }
    Some(AgentEvent::SessionStarted {
        compact: false,
        source: Some(SessionSource::Resume),
        session_id: Some(session(&object)?.to_owned()),
        session_title: None,
        cwd: cwd(&object),
    })
}

/// Returns the permission mode of a launch, from its arguments, which our shim read:
/// `--trust-all-tools` runs every tool without asking. No hook carries it,
/// and the person can turn it on or off in the session, so only the launch
/// says it.
pub(crate) fn session_settings(input: RawHookInput<'_>) -> SessionSettings {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return SessionSettings::default();
    };
    if event_name(&object) != Some(LAUNCH_EVENT) {
        return SessionSettings::default();
    }
    let trusts_all = object
        .get("trust_all_tools")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    SessionSettings {
        permission_mode: Some(if trusts_all {
            PermissionMode::BypassPermissions
        } else {
            PermissionMode::Default
        }),
        ..SessionSettings::default()
    }
}

pub(crate) fn worktree_intent(
    input: RawHookInput<'_>,
) -> Result<Option<WorktreeIntent>, NormalizeError> {
    WorktreeIntent::from_hook_payload(input.bytes, SHELL_TOOL)
}

pub(crate) fn finished_worktree_intent(
    input: RawHookInput<'_>,
) -> Result<Option<WorktreeIntent>, NormalizeError> {
    WorktreeIntent::from_finished_hook_payload(input.bytes, SHELL_TOOL)
}

/// Returns the refusal that has Kiro's model run `command` itself. Kiro takes
/// no rewritten input, so the command then meets Kiro's own prompt like any
/// other.
pub(crate) fn worktree_reroute_refusal(command: &str) -> HookRefusal {
    HookRefusal {
        exit_code: REFUSAL_STATUS,
        message: format!(
            "This project keeps its worktrees in another folder. Nothing was created. Run this command instead: {command}"
        ),
    }
}

/// Returns a shell command and the status it exited with, which Kiro writes at
/// the end of the tool's response (`Exit Code: 0`). A call refused or stopped before it
/// ran says `-1` or nothing, which is no status of the command's.
pub(crate) fn command_run(input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if event_name(&object) != Some("PostToolUse") || tool(&object) != SHELL_TOOL {
        return Ok(None);
    }
    let tool_input = object.get("tool_input");
    let Some(command) = tool_input
        .and_then(|tool_input| tool_input.get("command"))
        .and_then(Value::as_str)
        .filter(|command| !command.is_empty())
    else {
        return Ok(None);
    };
    let exit_code = string(&object, "tool_response")
        .and_then(|response| response.rsplit_once("Exit Code: "))
        .and_then(|(_, rest)| {
            rest.split_whitespace()
                .next()
                .and_then(|code| code.parse::<i32>().ok())
        })
        .filter(|code| *code >= 0);
    Ok(Some(CommandRun {
        command: command.to_owned(),
        exit_code,
        cwd: tool_input
            .and_then(|tool_input| tool_input.get("cwd"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| cwd(&object)),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn input(payload: &str) -> RawHookInput<'_> {
        RawHookInput {
            bytes: payload.as_bytes(),
            transcript: None,
        }
    }

    fn context() -> HookContext {
        HookContext {
            provider_home: Some(PathBuf::from("/Users/person/.kiro")),
            ..HookContext::fixture()
        }
    }

    #[test]
    fn only_a_tools_start_and_a_stop_read_the_session_log() {
        let tool = r#"{"hook_event_name":"PreToolUse","session_id":"sess_1","cwd":"/Users/person/project","tool_name":"fs_write"}"#;
        assert_eq!(
            transcript_path(input(tool), &context())
                .expect("an object")
                .as_deref(),
            crate::transcript::tests::expected_log().as_deref()
        );
        let stop =
            r#"{"hook_event_name":"Stop","session_id":"sess_1","cwd":"/Users/person/project"}"#;
        assert!(
            transcript_path(input(stop), &context())
                .expect("an object")
                .is_some()
        );
        let finished = r#"{"hook_event_name":"PostToolUse","session_id":"sess_1","cwd":"/Users/person/project"}"#;
        assert_eq!(
            transcript_path(input(finished), &context()).expect("an object"),
            None
        );
        // Without a home there is nowhere to look.
        assert_eq!(
            transcript_path(input(stop), &HookContext::fixture()).expect("an object"),
            None
        );
    }

    #[test]
    fn a_command_reads_the_status_kiro_writes_after_it() {
        let run = |response: &str| {
            let payload = serde_json::json!({
                "hook_event_name": "PostToolUse",
                "session_id": "sess_1",
                "cwd": "/Users/person/project",
                "tool_name": "execute_bash",
                "tool_input": {"command": "cargo test"},
                "tool_response": response,
            })
            .to_string();
            command_run(input(&payload))
                .expect("an object")
                .expect("a run")
        };
        assert_eq!(run("Output:\nok\n\nExit Code: 0").exit_code, Some(0));
        assert_eq!(
            run("Output:\nfailed\n\nExit Code: 101").exit_code,
            Some(101)
        );
        assert_eq!(
            run("Output:\nThe tool call was cancelled before it was approved.\n\nExit Code: -1")
                .exit_code,
            None
        );
        assert_eq!(
            run("This tool was interrupted before it reported a result").exit_code,
            None
        );
        assert_eq!(
            run("Exit Code: 0").cwd.as_deref(),
            Some("/Users/person/project")
        );
    }

    #[test]
    fn a_launch_says_whether_every_tool_is_trusted() {
        let mode = |payload: &str| session_settings(input(payload)).permission_mode;
        assert_eq!(
            mode(r#"{"hook_event_name":"WeirLaunch","trust_all_tools":true}"#),
            Some(PermissionMode::BypassPermissions)
        );
        assert_eq!(
            mode(r#"{"hook_event_name":"WeirLaunch","trust_all_tools":false}"#),
            Some(PermissionMode::Default)
        );
        assert_eq!(mode(r#"{"hook_event_name":"PreToolUse"}"#), None);
    }

    #[test]
    fn a_reroute_is_refused_by_the_status_kiro_reads() {
        let refusal = worktree_reroute_refusal("git worktree add ../wt -b topic");
        assert_eq!(refusal.exit_code, 2);
        assert!(refusal.message.ends_with("git worktree add ../wt -b topic"));
    }
}
