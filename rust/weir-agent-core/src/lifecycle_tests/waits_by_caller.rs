//! Whose a wait is. A subagent works beside the agent and can outlive its
//! turn, so its wait is not the agent's: the parent's stop leaves it open,
//! another caller's tools leave it as it is, and only its own tool ends it.

use super::*;

fn stop() -> AgentEvent {
    AgentEvent::TurnFinished {
        continues_after_stop_hook: false,
        titles: None,
        cache: None,
        reply: None,
        background_work: None,
    }
}

fn tool_start(caller: Caller) -> AgentEvent {
    AgentEvent::ToolStarted {
        tool: "Bash".into(),
        detail: Some("Bash: ls".into()),
        caller,
    }
}

fn tool_end(caller: Caller) -> AgentEvent {
    AgentEvent::ToolFinished {
        tool: Some("Bash".into()),
        caller,
    }
}

fn approval(caller: Caller) -> AgentEvent {
    AgentEvent::ApprovalRequested {
        detail: None,
        caller,
    }
}

fn other_subagent() -> Caller {
    Caller::Subagent("a2".into())
}

/// The record after each event, from the first that writes one.
fn records(descriptor: &ProviderDescriptor, events: &[AgentEvent]) -> Vec<RunRecord> {
    let mut record: Option<RunRecord> = None;
    let mut seen = Vec::new();
    for event in events {
        if let Some(next) = apply(record.as_ref(), event, &context(), descriptor, NOW).run {
            record = Some(next);
        }
        seen.extend(record.clone());
    }
    seen
}

/// The state after each payload, each normalized through `adapter`.
fn replay_payloads<'a>(
    adapter: &dyn ProviderAdapter,
    descriptor: &ProviderDescriptor,
    payloads: impl IntoIterator<Item = (String, Vec<u8>)> + 'a,
) -> Vec<(String, RunState)> {
    let mut record: Option<RunRecord> = None;
    let mut seen = Vec::new();
    for (name, bytes) in payloads {
        let input = weir_agent_model::RawHookInput {
            bytes: &bytes,
            transcript: None,
        };
        for event in adapter
            .normalize(input, &weir_agent_model::HookContext::fixture())
            .expect("normalize")
        {
            if let Some(next) = apply(record.as_ref(), &event, &context(), descriptor, NOW).run {
                record = Some(next);
            }
        }
        seen.push((name, record.as_ref().expect("record").state));
    }
    seen
}

/// The payloads of the recorded case at `case` under `fixtures`, in order.
fn recorded(case: &str) -> Vec<(String, Vec<u8>)> {
    let case = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures")
        .join(case);
    let mut names: Vec<_> = std::fs::read_dir(&case)
        .expect("case")
        .map(|entry| entry.expect("fixture entry"))
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| {
            name.starts_with('0')
                && std::path::Path::new(name)
                    .extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("json"))
        })
        .collect();
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let bytes = std::fs::read(case.join(&name)).expect("payload");
            (name, bytes)
        })
        .collect()
}

/// Claude's payloads, named by their hook, as `lines` give them.
fn claude_payloads(lines: &[&str]) -> Vec<(String, Vec<u8>)> {
    lines
        .iter()
        .enumerate()
        .map(|(index, line)| {
            let object: serde_json::Value = serde_json::from_str(line).expect("json");
            let name = object["hook_event_name"].as_str().expect("name");
            (format!("{index:04}-{name}"), line.as_bytes().to_vec())
        })
        .collect()
}

fn states(steps: &[(&str, RunState)]) -> Vec<(String, RunState)> {
    steps
        .iter()
        .map(|(name, state)| ((*name).to_owned(), *state))
        .collect()
}

/// The recorded case: Codex 0.166.0 starts a subagent whose `touch` asks for
/// approval, runs `sleep 12` itself, and ends its turn while the request is
/// still on screen. The parent's own `PostToolUse` and its `Stop` leave the
/// subagent's wait open; before, the first put the run to work and the
/// second showed it finished while Codex still waited on the person. The
/// person then declined it with Esc, which ran no hook.
#[test]
fn a_codex_subagents_wait_before_the_parents_stop_outlives_it() {
    let payloads = recorded("codex/2026-11/subagent-wait-before-stop");
    assert_eq!(
        replay_payloads(&weir_provider_codex::CodexAdapter, &codex(), payloads),
        states(&[
            ("0000-SessionStart.json", RunState::Idle),
            ("0001-UserPromptSubmit.json", RunState::Running),
            ("0002-PreToolUse.json", RunState::Running),
            ("0003-PostToolUse.json", RunState::Running),
            ("0004-PreToolUse.json", RunState::Running),
            ("0005-PreToolUse.json", RunState::Running),
            ("0006-PermissionRequest.json", RunState::NeedsInput),
            ("0007-PostToolUse.json", RunState::NeedsInput),
            ("0008-Stop.json", RunState::NeedsInput),
        ])
    );
}

/// The parent's stop ends its turn while the subagent's wait stays: the turn
/// is over, the wait keeps its words, kind, and caller and stays in the
/// episode that announced it, and it returns to the stop's finish when the
/// subagent's own tool ends it.
#[test]
fn the_parents_stop_ends_the_turn_and_keeps_the_subagents_wait() {
    let seen = records(
        &codex(),
        &[
            started(None),
            prompt("go"),
            tool_start(subagent()),
            approval(subagent()),
            stop(),
            tool_end(subagent()),
        ],
    );
    let (waiting, stopped, ended) = (&seen[3], &seen[4], &seen[5]);
    assert_eq!(waiting.caller, Some(subagent()));
    assert_eq!(stopped.state, RunState::NeedsInput);
    assert_eq!(stopped.run_started_at, None, "the turn is over");
    assert_eq!(stopped.wait_kind, Some(WaitKind::Approval));
    assert_eq!(stopped.detail.as_deref(), Some("Bash: ls"));
    assert_eq!(stopped.tool.as_deref(), Some("Bash"));
    assert_eq!(stopped.caller, Some(subagent()));
    assert_eq!(stopped.outside_turn_rest, Some(RunState::Finished));
    assert_eq!(stopped.state_episode_token, waiting.state_episode_token);
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.wait_kind, None);
    assert_eq!(ended.caller, None);
    assert_eq!(ended.outside_turn_rest, None);
    assert_ne!(ended.state_episode_token, stopped.state_episode_token);
}

/// The stop that keeps a subagent's wait is a write at its own time, so the
/// record says when the turn ended, while the wait keeps the time it opened,
/// which the agent's status reports are read against (`projection`).
#[test]
fn the_stop_that_keeps_a_wait_writes_its_own_time_and_keeps_the_waits() {
    let seen = records(
        &codex(),
        &[started(None), prompt("go"), approval(subagent())],
    );
    let waiting = seen.last().expect("record");
    assert_eq!(waiting.wait_started_at.as_deref(), Some(NOW));
    let stopped = apply(Some(waiting), &stop(), &context(), &codex(), LATER)
        .run
        .expect("record");
    assert_eq!(stopped.state, RunState::NeedsInput);
    assert_eq!(stopped.updated_at, LATER);
    assert_eq!(stopped.wait_started_at.as_deref(), Some(NOW));
    let ended = apply(
        Some(&stopped),
        &tool_end(subagent()),
        &context(),
        &codex(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.wait_started_at, None);
}

/// A second request renews the wait: the record holds the latest, whose
/// caller and time replace the first's.
#[test]
fn a_second_request_renews_the_waits_caller_and_time() {
    let seen = records(
        &codex(),
        &[started(None), prompt("go"), approval(subagent())],
    );
    let first = seen.last().expect("record");
    let second = apply(
        Some(first),
        &approval(other_subagent()),
        &context(),
        &codex(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(first.wait_started_at.as_deref(), Some(NOW));
    assert_eq!(second.state, RunState::NeedsInput);
    assert_eq!(second.caller, Some(other_subagent()));
    assert_eq!(second.wait_started_at.as_deref(), Some(LATER));
    let old_tool = apply(
        Some(&second),
        &tool_end(subagent()),
        &context(),
        &codex(),
        LATER,
    );
    assert_eq!(
        old_tool.run, None,
        "the older caller cannot end the new wait"
    );
    let ended = apply(
        Some(&second),
        &tool_end(other_subagent()),
        &context(),
        &codex(),
        LATER,
    )
    .run
    .expect("the latest caller ends its wait");
    assert_eq!(ended.state, RunState::Running);
    assert_eq!(ended.wait_kind, None);
}

/// An inferred wait at the parent's stop is a subagent's, whatever caller
/// was inferred: Claude cannot stop while its own call's prompt is open. The
/// stop keeps it, and a subagent's tool after it returns the run to the
/// finish.
#[test]
fn the_stop_keeps_a_wait_of_any_inferred_caller() {
    let seen = records(
        &claude(),
        &[
            started(None),
            prompt("go"),
            tool_start(Caller::Agent),
            approval(Caller::Unnamed),
            stop(),
            tool_start(subagent()),
        ],
    );
    let (waiting, stopped, ended) = (&seen[3], &seen[4], &seen[5]);
    assert_eq!(waiting.caller, Some(Caller::Agent));
    assert_eq!(waiting.is_caller_inferred, Some(true));
    assert_eq!(stopped.state, RunState::NeedsInput);
    assert_eq!(stopped.run_started_at, None);
    assert_eq!(ended.state, RunState::Finished);
}

/// The agent's own wait still ends with its turn's stop, as before.
#[test]
fn the_agents_own_wait_ends_with_its_stop() {
    let seen = records(
        &codex(),
        &[started(None), prompt("go"), approval(Caller::Agent), stop()],
    );
    let waiting = &seen[2];
    assert_eq!(waiting.state, RunState::NeedsInput);
    assert_eq!(waiting.caller, Some(Caller::Agent));
    let stopped = &seen[3];
    assert_eq!(stopped.state, RunState::Finished);
    assert_eq!(stopped.wait_kind, None);
    assert_eq!(stopped.wait_started_at, None);
    assert_eq!(stopped.caller, None);
}

/// One subagent's tool, or the agent's own, leaves another subagent's wait
/// open, inside the turn and after it; before, any tool ended it. Only the
/// subagent that asked ends it.
#[test]
fn another_callers_tool_leaves_a_subagents_wait() {
    for in_a_turn in [true, false] {
        let mut events = vec![started(None), prompt("go")];
        if !in_a_turn {
            events.push(stop());
        }
        events.push(approval(subagent()));
        let seen = records(&codex(), &events);
        let waiting = seen.last().expect("record");
        assert_eq!(waiting.state, RunState::NeedsInput);
        for tool in [
            tool_start(other_subagent()),
            tool_end(other_subagent()),
            tool_start(Caller::Agent),
            tool_end(Caller::Agent),
        ] {
            let writes = apply(Some(waiting), &tool, &context(), &codex(), NOW);
            assert_eq!(writes.run, None, "{tool:?}, in a turn: {in_a_turn}");
        }
        let ended = apply(
            Some(waiting),
            &tool_start(subagent()),
            &context(),
            &codex(),
            NOW,
        )
        .run
        .expect("record");
        let expected = if in_a_turn {
            RunState::Running
        } else {
            RunState::Finished
        };
        assert_eq!(ended.state, expected, "in a turn: {in_a_turn}");
    }
}

/// A subagent's tool leaves the agent's own wait as it is: the agent still
/// waits on the person while the subagent works beside it.
#[test]
fn a_subagents_tool_leaves_the_agents_own_wait() {
    let seen = records(
        &codex(),
        &[started(None), prompt("go"), approval(Caller::Agent)],
    );
    let waiting = seen.last().expect("record");
    for tool in [tool_start(subagent()), tool_end(subagent())] {
        let writes = apply(Some(waiting), &tool, &context(), &codex(), NOW);
        assert_eq!(writes.run, None, "{tool:?}");
    }
}

/// A wait whose caller the record does not know, such as one an earlier
/// build wrote, ends with any tool and with the stop, as before.
#[test]
fn a_wait_of_no_known_caller_ends_as_before() {
    let seen = records(
        &codex(),
        &[started(None), prompt("go"), approval(Caller::Agent)],
    );
    let unknown = RunRecord {
        caller: None,
        ..seen.last().expect("record").clone()
    };
    let by_subagent = apply(
        Some(&unknown),
        &tool_end(subagent()),
        &context(),
        &codex(),
        NOW,
    );
    let ended = by_subagent.run.expect("record");
    assert_eq!(ended.state, RunState::Running);
    assert_eq!(ended.wait_kind, None);
    let stopped = apply(Some(&unknown), &stop(), &context(), &codex(), NOW);
    let stopped = stopped.run.expect("record");
    assert_eq!(stopped.state, RunState::Finished);
    assert_eq!(stopped.wait_kind, None);
}

/// A subagent's wait opened at a rest returns to that rest: `idle` after a
/// session start, `finished` after a failure. Claude's subagent's tools
/// reopen the run at `idle` (its end opens a turn of Claude's), so there its
/// tool shows the run working instead.
#[test]
fn a_subagents_wait_at_a_rest_returns_to_it() {
    let failure = AgentEvent::Failed {
        error: "server_error".into(),
        usage_limit: None,
        kind: None,
    };
    for (descriptor, before, rest) in [
        (codex(), vec![started(None)], RunState::Idle),
        (
            codex(),
            vec![started(None), prompt("go"), failure.clone()],
            RunState::Finished,
        ),
        (claude(), vec![started(None)], RunState::Running),
        (
            claude(),
            vec![started(None), prompt("go"), stop()],
            RunState::Finished,
        ),
    ] {
        let mut events = before;
        events.push(approval(subagent()));
        events.push(tool_start(subagent()));
        let seen = records(&descriptor, &events);
        assert_eq!(
            seen[seen.len() - 2].state,
            RunState::NeedsInput,
            "{}",
            descriptor.display_name
        );
        assert_eq!(
            seen.last().expect("record").state,
            rest,
            "{}",
            descriptor.display_name
        );
    }
}

const CLAUDE_SUBAGENT: &str = r#""agent_id":"a1","agent_type":"general-purpose""#;
const CLAUDE_OTHER_SUBAGENT: &str = r#""agent_id":"a2","agent_type":"general-purpose""#;

fn claude_prompt() -> String {
    r#"{"hook_event_name":"UserPromptSubmit","prompt":"go","session_id":"s"}"#.to_owned()
}

fn claude_tool(marker: &str, command: &str) -> String {
    let marker = if marker.is_empty() {
        String::new()
    } else {
        format!(",{marker}")
    };
    format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{"command":"{command}"}},"session_id":"s"{marker}}}"#
    )
}

fn claude_question(marker: &str) -> String {
    format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{{"questions":[{{"question":"Which?"}}]}},"session_id":"s",{marker}}}"#
    )
}

fn claude_answer(marker: &str) -> String {
    format!(
        r#"{{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","session_id":"s",{marker}}}"#
    )
}

fn claude_permission_prompt() -> String {
    r#"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission","session_id":"s"}"#.to_owned()
}

fn claude_stop() -> String {
    r#"{"hook_event_name":"Stop","session_id":"s","stop_hook_active":false,"background_tasks":[{"id":"a1","type":"subagent","status":"running"}]}"#.to_owned()
}

/// Claude's background subagent asks permission before the parent's `Stop`.
/// The prompt names no one, so the subagent's tool just before it is taken
/// for the call that asks, and the stop leaves the wait open; the subagent's
/// next tool returns the run to the stop's finish. Before, the stop showed the
/// run finished while Claude still waited on the person. The caller is only
/// inferred, so any tool ends the wait, the agent's own too: a wait taken for
/// the wrong caller must not outlive the request.
#[test]
fn a_claude_subagents_permission_before_the_stop_outlives_it() {
    let payloads = claude_payloads(&[
        &claude_prompt(),
        &claude_tool(CLAUDE_SUBAGENT, "touch made-by-subagent"),
        &claude_permission_prompt(),
        &claude_stop(),
        &claude_tool(CLAUDE_SUBAGENT, "ls"),
    ]);
    assert_eq!(
        replay_payloads(&weir_provider_claude::ClaudeAdapter, &claude(), payloads),
        states(&[
            ("0000-UserPromptSubmit", RunState::Running),
            ("0001-PreToolUse", RunState::Running),
            ("0002-Notification", RunState::NeedsInput),
            ("0003-Stop", RunState::NeedsInput),
            ("0004-PreToolUse", RunState::Finished),
        ])
    );
    let payloads = claude_payloads(&[
        &claude_prompt(),
        &claude_tool(CLAUDE_SUBAGENT, "touch made-by-subagent"),
        &claude_permission_prompt(),
        &claude_tool("", "ls"),
    ]);
    assert_eq!(
        replay_payloads(&weir_provider_claude::ClaudeAdapter, &claude(), payloads)
            .last()
            .map(|step| step.1),
        Some(RunState::Running),
        "the agent's own tool ends an inferred wait"
    );
}

/// Claude's subagent asks a question (its `AskUserQuestion` names it) and
/// another subagent works on: the other's tools leave the question, the
/// parent's stop leaves it open, and its own answer returns the run to the
/// stop's finish.
#[test]
fn a_claude_subagents_question_waits_through_another_subagents_tools() {
    let payloads = claude_payloads(&[
        &claude_prompt(),
        &claude_question(CLAUDE_SUBAGENT),
        &claude_tool(CLAUDE_OTHER_SUBAGENT, "ls"),
        &claude_stop(),
        &claude_tool(CLAUDE_OTHER_SUBAGENT, "pwd"),
        &claude_answer(CLAUDE_SUBAGENT),
    ]);
    assert_eq!(
        replay_payloads(&weir_provider_claude::ClaudeAdapter, &claude(), payloads),
        states(&[
            ("0000-UserPromptSubmit", RunState::Running),
            ("0001-PreToolUse", RunState::NeedsInput),
            ("0002-PreToolUse", RunState::NeedsInput),
            ("0003-Stop", RunState::NeedsInput),
            ("0004-PreToolUse", RunState::NeedsInput),
            ("0005-PostToolUse", RunState::Finished),
        ])
    );
}

/// Claude's own permission prompt is taken for the agent's when its own
/// tool asked, and, being inferred, ends with any tool, a subagent's too.
#[test]
fn claudes_own_permission_prompt_is_inferred_and_ends_with_any_tool() {
    let seen = records(
        &claude(),
        &[
            started(None),
            prompt("go"),
            tool_start(Caller::Agent),
            approval(Caller::Unnamed),
        ],
    );
    let waiting = seen.last().expect("record");
    assert_eq!(waiting.caller, Some(Caller::Agent));
    assert_eq!(waiting.is_caller_inferred, Some(true));
    let ended = apply(
        Some(waiting),
        &tool_start(subagent()),
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(ended.state, RunState::Running);
    assert_eq!(ended.is_caller_inferred, None);
}

/// A permission prompt that names no one, while a subagent's own question
/// waits, may be another call's (the agent's tools leave the question and
/// write nothing, so nothing tells it apart from the question's own prompt).
/// The question keeps its words, but its caller is only inferred from then
/// on, so any tool ends it rather than only the subagent's answer.
#[test]
fn an_unnamed_prompt_during_a_subagents_question_leaves_its_caller_inferred() {
    let seen = records(
        &claude(),
        &[
            started(None),
            prompt("go"),
            AgentEvent::WaitingForInput {
                detail: Some("Which?".into()),
                caller: subagent(),
            },
            tool_start(Caller::Agent),
            approval(Caller::Unnamed),
        ],
    );
    let waiting = seen.last().expect("record");
    assert_eq!(waiting.wait_kind, Some(WaitKind::Question));
    assert_eq!(waiting.caller, Some(subagent()));
    assert_eq!(waiting.is_caller_inferred, Some(true));
    let ended = apply(
        Some(waiting),
        &tool_start(Caller::Agent),
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(ended.state, RunState::Running);
}
