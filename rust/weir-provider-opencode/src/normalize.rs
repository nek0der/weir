//! Maps what the plugin reports to neutral events.
//!
//! OpenCode's event is the payload's `data`; the plugin adds its own words beside
//! it, each named in the function that reads it. A name OpenCode does not have
//! starts with `weir.`.

use crate::failure;
use serde_json::{Map, Value};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use weir_agent_model::{
    AgentEvent, CommandRun, MAX_HOOK_INPUT_BYTES, NormalizeError, PermissionMode, PromptKind,
    RawHookInput, SessionSettings, SessionSource, Titles, TurnPreparation, TurnReading, TurnUsage,
    WorktreeIntent, parse_object,
};

/// The plugin started in a Weir pane.
const LAUNCH: &str = "weir.launch";
/// The pane moved to a session it sent input to.
const SESSION: &str = "weir.session";
/// Enter was pressed: save the start of the turn about to be sent.
const PREPARE: &str = "weir.prepare";
/// The pane moved to another of its sessions: says which run's is on screen, on the
/// launch's run, for all of them.
const SHOWN: &str = "weir.shown";
/// The tab of a session at rest was closed.
const CLOSED: &str = "weir.closed";
/// A session of this pane got a name.
const TITLE: &str = "weir.title";
/// What OpenCode calls its shell tool.
const SHELL_TOOL: &str = "shell";
/// OpenCode's ordinary agent, which the header does not name, as it does not name
/// the ordinary permission mode. Any other is one the person chose.
const ORDINARY_AGENT: &str = "build";
/// The model's default effort.
const DEFAULT_VARIANT: &str = "default";

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn event_name(object: &Map<String, Value>) -> Option<&str> {
    string(object, "hook_event_name")
}

fn data(object: &Map<String, Value>) -> Option<&Map<String, Value>> {
    object.get("data").and_then(Value::as_object)
}

fn data_string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    data(object)
        .and_then(|data| string(data, key))
        .filter(|value| !value.is_empty())
}

fn owned(value: Option<&str>) -> Option<String> {
    value.map(str::to_owned)
}

pub(crate) fn normalize(input: RawHookInput<'_>) -> Result<Vec<AgentEvent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let Some(name) = event_name(&object) else {
        return Ok(Vec::new());
    };
    let events = match name {
        LAUNCH => {
            let session_id = owned(data_string(&object, "sessionID"));
            vec![AgentEvent::SessionStarted {
                compact: false,
                source: Some(if session_id.is_some() {
                    SessionSource::Resume
                } else {
                    SessionSource::Startup
                }),
                session_id,
                session_title: None,
                cwd: owned(string(&object, "cwd")),
            }]
        }
        SESSION => vec![AgentEvent::SessionStarted {
            compact: false,
            source: SessionSource::parse(string(&object, "source")),
            session_id: owned(data_string(&object, "sessionID")),
            session_title: None,
            cwd: owned(string(&object, "cwd")),
        }],
        PREPARE => Vec::new(),
        CLOSED => vec![AgentEvent::SessionEnded {
            reason: Some("tab closed".to_owned()),
            session_id: owned(data_string(&object, "sessionID")),
        }],
        "session.execution.started" => vec![AgentEvent::PromptSubmitted {
            prompt: string(&object, "prompt").unwrap_or_default().to_owned(),
            kind: (string(&object, "prompt_kind") == Some("synthetic"))
                .then_some(PromptKind::Injected),
            titles: titles(&object),
            cwd: owned(string(&object, "cwd")),
        }],
        "session.tool.called" => vec![tool_started(&object)],
        "session.tool.success" | "session.tool.failed" => vec![AgentEvent::ToolFinished {
            tool: owned(data_string(&object, "name")),
            by_subagent: false,
        }],
        "permission.asked" => vec![AgentEvent::ApprovalRequested {
            detail: permission_detail(&object),
        }],
        "form.created" => vec![AgentEvent::WaitingForInput {
            detail: form_detail(&object),
        }],
        // The last wait is over and the agent goes on. A refusal is not reported
        // (the plugin leaves it to the end of the execution), and nothing else
        // puts a run that waited back to work.
        "permission.replied" => vec![AgentEvent::ToolStarted {
            tool: string(&object, "tool").unwrap_or_default().to_owned(),
            detail: None,
            by_subagent: false,
        }],
        "form.replied" | "form.cancelled" => vec![AgentEvent::ToolStarted {
            tool: "question".to_owned(),
            detail: None,
            by_subagent: false,
        }],
        // The service tries again by itself, so this is work going on rather than
        // a stop.
        "session.retry.scheduled" => vec![AgentEvent::ToolStarted {
            tool: "retry".to_owned(),
            detail: data(&object)
                .and_then(|data| data.get("error"))
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .map(str::to_owned),
            by_subagent: false,
        }],
        "session.compaction.started" => vec![AgentEvent::Compacting],
        "session.compaction.ended" | "session.compaction.failed" => {
            vec![AgentEvent::CompactionFinished]
        }
        "session.execution.succeeded" => vec![AgentEvent::TurnFinished {
            titles: titles(&object),
            cache: None,
            continues_after_stop_hook: false,
            reply: owned(string(&object, "reply").filter(|reply| !reply.is_empty())),
            background_work: None,
        }],
        "session.execution.failed" => vec![failed(&object)],
        "session.execution.interrupted" => vec![AgentEvent::Interrupted],
        // Says nothing of the run; the call's settings are what it brings
        // (`session_settings`).
        "session.step.started" | SHOWN | TITLE => vec![extension(name)],
        _ => vec![AgentEvent::Extension {
            name: name.to_owned(),
            payload: Value::Object(object.clone()),
        }],
    };
    Ok(events)
}

fn extension(name: &str) -> AgentEvent {
    AgentEvent::Extension {
        name: name.to_owned(),
        payload: Value::Object(Map::new()),
    }
}

/// The session's name, which the plugin keeps from `session.renamed` and carries
/// on a turn's start and end. It does not say who chose it, as Codex's does not.
fn titles(object: &Map<String, Value>) -> Option<Titles> {
    string(object, "title")
        .filter(|title| !title.is_empty())
        .map(|title| Titles {
            session_title: Some(title.to_owned()),
            generated_title: None,
        })
}

fn tool_started(object: &Map<String, Value>) -> AgentEvent {
    let tool = data_string(object, "name").unwrap_or_default();
    let argument = data(object)
        .and_then(|data| data.get("input"))
        .and_then(Value::as_object)
        .and_then(|input| {
            ["command", "filePath", "file_path", "path", "pattern", "url"]
                .iter()
                .find_map(|key| string(input, key).filter(|value| !value.is_empty()))
        });
    AgentEvent::ToolStarted {
        tool: tool.to_owned(),
        detail: Some(match argument {
            Some(argument) => format!("{tool}: {argument}"),
            None => tool.to_owned(),
        }),
        by_subagent: false,
    }
}

pub(crate) fn permission_detail(object: &Map<String, Value>) -> Option<String> {
    let data = data(object)?;
    let action = string(data, "action").unwrap_or_default();
    let resources = data
        .get("resources")
        .and_then(Value::as_array)
        .map(|resources| {
            resources
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(", ")
        })
        .filter(|resources| !resources.is_empty());
    match (action.is_empty(), resources) {
        (true, Some(resources)) => Some(resources),
        (false, Some(resources)) => Some(format!("{action}: {resources}")),
        (false, None) => Some(action.to_owned()),
        (true, None) => None,
    }
}

/// The form's first field in its own words: what a question asks, else its heading.
fn form_detail(object: &Map<String, Value>) -> Option<String> {
    let data = data(object)?;
    let field = data
        .get("fields")
        .and_then(Value::as_array)
        .and_then(|fields| fields.first())
        .and_then(Value::as_object);
    owned(
        field
            .and_then(|field| string(field, "description").or_else(|| string(field, "title")))
            .or_else(|| string(data, "title")),
    )
}

/// A limit's delay counts from when the failure was recorded, which the event's
/// envelope says; a report the plugin made up has none, and counts from now.
fn failed(object: &Map<String, Value>) -> AgentEvent {
    let now = object
        .get("created")
        .and_then(Value::as_u64)
        .and_then(|created| UNIX_EPOCH.checked_add(Duration::from_millis(created)))
        .unwrap_or_else(SystemTime::now);
    let error = data(object)
        .and_then(|data| data.get("error"))
        .and_then(Value::as_object);
    AgentEvent::Failed {
        error: error
            .and_then(|error| string(error, "message"))
            .unwrap_or_default()
            .to_owned(),
        usage_limit: error.and_then(|error| failure::usage_limit(error, now)),
        kind: error.and_then(failure::kind),
    }
}

pub(crate) fn session_settings(input: RawHookInput<'_>) -> SessionSettings {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return SessionSettings::default();
    };
    match event_name(&object) {
        Some(LAUNCH | SESSION) => {
            return SessionSettings {
                pane_family_run_id: owned(string(&object, "pane_family")),
                // `--auto` approves whatever is not denied, which is how the header
                // shows an agent that runs without asking.
                permission_mode: object
                    .get("auto_accept")
                    .and_then(Value::as_bool)
                    .map(|auto| {
                        if auto {
                            PermissionMode::BypassPermissions
                        } else {
                            PermissionMode::Default
                        }
                    }),
                ..SessionSettings::default()
            };
        }
        Some(SHOWN) => {
            return SessionSettings {
                pane_shown_run_id: owned(string(&object, "shown_run")),
                pane_shows_home: object.get("shown_home").and_then(Value::as_bool),
                shown_session_id: owned(data_string(&object, "sessionID")),
                shown_cwd: owned(string(&object, "cwd")),
                ..SessionSettings::default()
            };
        }
        Some(TITLE) => {
            return SessionSettings {
                session_title: owned(string(&object, "title")),
                ..SessionSettings::default()
            };
        }
        Some("session.step.started") => {}
        _ => return SessionSettings::default(),
    }
    let Some(data) = data(&object) else {
        return SessionSettings::default();
    };
    let info = object.get("model_info").and_then(Value::as_object);
    let model = data.get("model").and_then(Value::as_object);
    let named = |info_key: &str, model_key: &str| {
        info.and_then(|info| string(info, info_key))
            .or_else(|| model.and_then(|model| string(model, model_key)))
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    SessionSettings {
        model: named("name", "id"),
        model_upstream: named("provider_name", "providerID"),
        // Says the default outright: the person can go back to it with the
        // model unchanged, and a word kept from before would be false.
        effort: Some(
            model
                .and_then(|model| string(model, "variant"))
                .filter(|variant| *variant != DEFAULT_VARIANT)
                .unwrap_or_default()
                .to_owned(),
        ),
        agent_profile: string(data, "agent").map(|agent| {
            if agent == ORDINARY_AGENT {
                String::new()
            } else {
                agent.to_owned()
            }
        }),
        ..SessionSettings::default()
    }
}

pub(crate) fn turn_preparation(input: RawHookInput<'_>) -> Option<TurnPreparation> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    if event_name(&object) != Some(PREPARE) {
        return None;
    }
    Some(TurnPreparation {
        generation: string(&object, "preparation")?.to_owned(),
        cwd: string(&object, "cwd")?.to_owned(),
    })
}

pub(crate) fn prepared_begin(input: RawHookInput<'_>) -> Option<String> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    if event_name(&object) != Some("session.execution.started") {
        return None;
    }
    owned(string(&object, "preparation"))
}

/// A shell command's exit status, which OpenCode puts in the tool's metadata. A
/// command that exits non-zero still comes as `session.tool.success`, as the
/// tool itself worked; only `exit` tells them apart. The command is read from the
/// `input` the plugin carried on from `session.tool.called`.
pub(crate) fn command_run(input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let is_end = matches!(
        event_name(&object),
        Some("session.tool.success" | "session.tool.failed")
    );
    if !is_end || data_string(&object, "name") != Some(SHELL_TOOL) {
        return Ok(None);
    }
    let Some(command) = string(&object, "command").filter(|command| !command.is_empty()) else {
        return Ok(None);
    };
    Ok(Some(CommandRun {
        command: command.to_owned(),
        exit_code: exit_status(&object).and_then(|exit| i32::try_from(exit).ok()),
        cwd: owned(string(&object, "cwd")),
    }))
}

fn exit_status(object: &Map<String, Value>) -> Option<i64> {
    data(object)?.get("metadata")?.get("exit")?.as_i64()
}

/// A `git worktree add` the shell tool ran and that exited 0. OpenCode reports a
/// command that failed as a tool that worked, so the status is what says.
pub(crate) fn finished_worktree_intent(
    input: RawHookInput<'_>,
) -> Result<Option<WorktreeIntent>, NormalizeError> {
    Ok(finished_intent(&parse_object(
        input.bytes,
        MAX_HOOK_INPUT_BYTES,
    )?))
}

fn finished_intent(object: &Map<String, Value>) -> Option<WorktreeIntent> {
    if event_name(object) != Some("session.tool.success")
        || data_string(object, "name") != Some(SHELL_TOOL)
        || exit_status(object) != Some(0)
    {
        return None;
    }
    string(object, "command")
        .and_then(|command| WorktreeIntent::parse(command, string(object, "cwd")))
}

/// Whether the status is `git worktree add`'s own, for exactly the worktree its words
/// name. Anything else in the command (a second one chained after it, a comment that
/// looks like an option, quoting) could let a failed add exit 0, or name another
/// worktree than the one it made, and one that was already there would be set up
/// again. A command the plugin had to cut is not the command that ran.
pub(crate) fn finished_worktree_is_proven(input: RawHookInput<'_>) -> bool {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return false;
    };
    object.get("command_complete").and_then(Value::as_bool) == Some(true)
        && finished_intent(&object).is_some_and(|intent| intent.plain_add_folder().is_some())
}

/// What the execution used, which the plugin added up from `session.step.ended`:
/// the session's running totals also hold the title's and aren't the turn's.
/// OpenCode's `input` leaves out what the cache served, so nothing is taken off
/// it, and its `output` leaves out reasoning, which is billed as output.
pub(crate) fn turn_reading(input: RawHookInput<'_>) -> TurnReading {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return TurnReading::default();
    };
    let Some(usage) = object.get("usage").and_then(Value::as_object) else {
        return TurnReading::default();
    };
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    TurnReading {
        usage: Some(TurnUsage {
            input_tokens: count("input"),
            cache_write_tokens: count("cacheWrite"),
            cache_read_tokens: count("cacheRead"),
            output_tokens: count("output").saturating_add(count("reasoning")),
            is_partial: usage
                .get("isPartial")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        }),
        ..TurnReading::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn input(value: &Value) -> Vec<u8> {
        serde_json::to_vec(value).expect("serializes")
    }

    fn settings(value: &Value) -> SessionSettings {
        let bytes = input(value);
        session_settings(RawHookInput {
            bytes: &bytes,
            transcript: None,
        })
    }

    #[test]
    fn a_launch_with_auto_says_it_runs_without_asking() {
        let auto =
            settings(&json!({"hook_event_name": "weir.launch", "auto_accept": true, "data": {}}));
        assert_eq!(
            auto.permission_mode,
            Some(PermissionMode::BypassPermissions)
        );
        let plain =
            settings(&json!({"hook_event_name": "weir.session", "auto_accept": false, "data": {}}));
        assert_eq!(plain.permission_mode, Some(PermissionMode::Default));
        let older = settings(&json!({"hook_event_name": "weir.launch", "data": {}}));
        assert_eq!(older.permission_mode, None);
    }

    #[test]
    fn a_step_says_the_model_the_route_and_the_effort_it_used() {
        let read = settings(&json!({
            "hook_event_name": "session.step.started",
            "data": {"agent": "plan", "model": {"id": "gpt-5.5", "providerID": "openrouter", "variant": "high"}},
            "model_info": {"name": "GPT-5.5", "provider_name": "OpenRouter"},
        }));
        assert_eq!(read.model.as_deref(), Some("GPT-5.5"));
        assert_eq!(read.model_upstream.as_deref(), Some("OpenRouter"));
        assert_eq!(read.effort.as_deref(), Some("high"));
        assert_eq!(read.agent_profile.as_deref(), Some("plan"));
        assert_eq!(read.permission_mode, None);
    }

    #[test]
    fn the_ordinary_agent_and_the_default_effort_clear_what_was_said() {
        let read = settings(&json!({
            "hook_event_name": "session.step.started",
            "data": {"agent": "build", "model": {"id": "m", "providerID": "p", "variant": "default"}},
        }));
        assert_eq!(read.model.as_deref(), Some("m"));
        assert_eq!(read.model_upstream.as_deref(), Some("p"));
        assert_eq!(read.effort.as_deref(), Some(""));
        assert_eq!(read.agent_profile.as_deref(), Some(""));
    }

    #[test]
    fn any_other_event_says_nothing_of_the_settings() {
        assert!(settings(&json!({"hook_event_name": "session.tool.called"})).is_empty());
    }

    #[test]
    fn a_failing_command_comes_as_a_success_and_keeps_its_exit_status() {
        let bytes = input(&json!({
            "hook_event_name": "session.tool.success",
            "command": "cargo test",
            "cwd": "/repo",
            "data": {"name": "shell", "metadata": {"exit": 101}},
        }));
        let run = command_run(RawHookInput {
            bytes: &bytes,
            transcript: None,
        })
        .expect("an object")
        .expect("a command");
        assert_eq!(run.command, "cargo test");
        assert_eq!(run.exit_code, Some(101));
        assert_eq!(run.cwd.as_deref(), Some("/repo"));
    }

    /// What a payload can prove is a whole, plain command: a comment that looks like
    /// an option, or one the plugin had to cut, proves nothing.
    #[test]
    fn a_worktree_is_proven_only_by_a_whole_plain_command() {
        let proven = |command: &str, is_whole: Option<bool>| {
            let mut payload = json!({
                "hook_event_name": "session.tool.success",
                "command": command,
                "cwd": "/repo",
                "data": {"name": "shell", "metadata": {"exit": 0}},
            });
            if let Some(is_whole) = is_whole {
                payload["command_complete"] = json!(is_whole);
            }
            let bytes = input(&payload);
            finished_worktree_is_proven(RawHookInput {
                bytes: &bytes,
                transcript: None,
            })
        };
        assert!(proven("git worktree add -b x ../x", Some(true)));
        assert!(!proven("git worktree add -b x ../x", Some(false)));
        assert!(!proven("git worktree add -b x ../x", None));
        assert!(!proven("git worktree add -b y /tmp/y # -b x", Some(true)));
        assert!(!proven("git worktree add -b x ../x ; true", Some(true)));
    }

    #[test]
    fn a_worktree_counts_as_made_only_on_its_own_exit_status() {
        let payload = |event: &str, command: &str, exit: i64| {
            input(&json!({
                "hook_event_name": event,
                "command": command,
                "command_complete": true,
                "cwd": "/repo",
                "data": {"name": "shell", "metadata": {"exit": exit}},
            }))
        };
        let read = |bytes: &[u8]| {
            let raw = RawHookInput {
                bytes,
                transcript: None,
            };
            (
                finished_worktree_intent(raw).expect("an object"),
                finished_worktree_is_proven(raw),
            )
        };
        let add = "git worktree add -b x ../x";
        let (intent, is_proven) = read(&payload("session.tool.success", add, 0));
        assert_eq!(intent.expect("an intent").branch, "x");
        assert!(is_proven);
        assert_eq!(
            read(&payload("session.tool.success", add, 128)),
            (None, false)
        );
        assert_eq!(read(&payload("session.tool.failed", add, 0)), (None, false));
        assert_eq!(
            read(&payload("session.tool.success", "ls", 0)),
            (None, false)
        );
        assert!(
            !read(&payload(
                "session.tool.success",
                "git worktree add -b x ../x ; true",
                0
            ))
            .1
        );
    }

    #[test]
    fn usage_counts_reasoning_as_output_and_leaves_the_cache_apart() {
        let bytes = input(&json!({
            "usage": {"input": 10, "output": 3, "reasoning": 2, "cacheRead": 5, "cacheWrite": 1, "isPartial": true},
        }));
        let usage = turn_reading(RawHookInput {
            bytes: &bytes,
            transcript: None,
        })
        .usage
        .expect("usage");
        assert_eq!(usage.input_tokens, 10);
        assert_eq!(usage.output_tokens, 5);
        assert_eq!(usage.cache_read_tokens, 5);
        assert_eq!(usage.cache_write_tokens, 1);
        assert!(usage.is_partial);
    }

    #[test]
    fn a_turn_names_its_preparation_and_a_prepare_call_asks_for_one() {
        let begun =
            input(&json!({"hook_event_name": "session.execution.started", "preparation": "g1"}));
        assert_eq!(
            prepared_begin(RawHookInput {
                bytes: &begun,
                transcript: None
            })
            .as_deref(),
            Some("g1")
        );
        let asked =
            input(&json!({"hook_event_name": PREPARE, "preparation": "g1", "cwd": "/repo"}));
        let preparation = turn_preparation(RawHookInput {
            bytes: &asked,
            transcript: None,
        })
        .expect("a preparation");
        assert_eq!(preparation.generation, "g1");
        assert_eq!(preparation.cwd, "/repo");
        assert_eq!(
            turn_preparation(RawHookInput {
                bytes: &begun,
                transcript: None
            }),
            None
        );
    }
}
