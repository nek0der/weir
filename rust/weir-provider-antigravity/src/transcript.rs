//! What the Antigravity transcript says of a turn.
//!
//! The transcript is one JSON object per step, numbered by `step_index`. The
//! person's words are `USER_INPUT` steps from `USER_EXPLICIT`, each model
//! request a `PLANNER_RESPONSE` with its tokens, and what the agent begins by
//! itself (a background command's end, a subagent's report) a step from
//! `SYSTEM` (agy 1.4.12).

use serde_json::{Map, Value};
use std::collections::VecDeque;
use weir_agent_model::{CommandRun, TurnReading, TurnUsage};

/// The tool `agy` starts a subagent with.
const SUBAGENT_TOOL: &str = "invoke_subagent";

fn steps(transcript: &[u8]) -> Vec<Map<String, Value>> {
    transcript
        .split(|byte| *byte == b'\n')
        .filter_map(|line| match serde_json::from_slice::<Value>(line) {
            Ok(Value::Object(step)) => Some(step),
            _ => None,
        })
        .collect()
}

fn text<'a>(step: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    step.get(key).and_then(Value::as_str)
}

fn is_person_input(step: &Map<String, Value>) -> bool {
    text(step, "type") == Some("USER_INPUT") && text(step, "source") == Some("USER_EXPLICIT")
}

/// Whether the transcript's latest step is the person's: a model request that
/// begins after it answers them, and one that begins after anything else is
/// the agent going on by itself. `None` for a transcript with no steps yet,
/// which says neither.
pub(crate) fn ends_with_person_input(transcript: &[u8]) -> Option<bool> {
    steps(transcript).last().map(is_person_input)
}

/// Whether the model has answered since the person's latest input. A `/compact`
/// alone writes only its checkpoint, and a turn the agent then begins by itself
/// writes the model's steps under the same input (agy 1.4.12).
pub(crate) fn has_answer_since_person_input(transcript: &[u8]) -> bool {
    steps(transcript)
        .iter()
        .rev()
        .take_while(|step| !is_person_input(step))
        .any(|step| text(step, "type") == Some("PLANNER_RESPONSE"))
}

/// The steps of the turn: from the step `marker` numbers up to the next input
/// of the person's, which the transcript can already hold when a stopped turn
/// is read. A turn with no marker, whose record predates them or whose request
/// gave no step, is what follows the latest input. The second value says the
/// turn's start lies before what was read.
fn turn_steps(transcript: &[u8], marker: Option<&str>) -> (Vec<Map<String, Value>>, bool) {
    let all = steps(transcript);
    let first_index = |step: &Map<String, Value>| step.get("step_index").and_then(Value::as_u64);
    if let Some(start) = marker.and_then(crate::normalize::marker_step) {
        let is_cut = all
            .first()
            .and_then(first_index)
            .is_some_and(|first| first > start);
        let turn = all
            .into_iter()
            .filter(|step| first_index(step).is_some_and(|index| index >= start))
            .take_while(|step| !is_person_input(step))
            .collect();
        return (turn, is_cut);
    }
    match all.iter().rposition(is_person_input) {
        Some(position) => (all.into_iter().skip(position + 1).collect(), false),
        None => (all, true),
    }
}

/// The turn's last reply: what the latest step says, when a stop's latest step
/// is the model's. A turn that ended on anything else wrote none, and has none
/// rather than the reply of the turn before it.
pub(crate) fn turn_reply(transcript: &[u8]) -> Option<String> {
    let all = steps(transcript);
    let last = all.last()?;
    if text(last, "type") != Some("PLANNER_RESPONSE") {
        return None;
    }
    text(last, "content")
        .filter(|content| !content.is_empty())
        .map(str::to_owned)
}

/// The exit status a command's result step opens with, after its times. `None`
/// for a command still running or one that never ran. Further on, a result can
/// hold any words: a running command's description, a finished one's output.
fn exit_code(result: &str) -> Option<i32> {
    let line = result
        .lines()
        .find(|line| !line.starts_with("Created At:") && !line.starts_with("Completed At:"))?;
    let rest = line.strip_prefix("Command exited with code ")?;
    rest.split('.').next()?.trim().parse().ok()
}

/// The command a tool call runs.
fn command_line(call: &Value) -> Option<String> {
    if call.get("name").and_then(Value::as_str) != Some("run_command") {
        return None;
    }
    let command = call.get("args")?.get("CommandLine")?.as_str()?;
    Some(command.to_owned())
}

/// Whether a tool's result says the person answered no at `agy`'s prompt, so
/// the tool never ran. `agy` need not have written that result when the turn is
/// read (agy 1.4.12). Other words, like no result, leave a command with no exit
/// status, which claims less than a run that did not happen would.
fn is_refused(result: &Map<String, Value>) -> bool {
    text(result, "error").is_some_and(|error| error.contains("user denied permission"))
}

/// The shell commands of the turn in call order. A model request lists its tool
/// calls, and the steps after it hold their results in that order. A command
/// whose result never came has no exit status: stopped, still running, or
/// refused before `agy` wrote so, which we cannot tell apart. One whose result
/// says it was refused did not run, as for Claude, whose refused command sends
/// no `PostToolUse`.
fn commands(turn: &[Map<String, Value>]) -> Vec<CommandRun> {
    let mut runs: Vec<Option<CommandRun>> = Vec::new();
    let mut pending: VecDeque<Option<usize>> = VecDeque::new();
    for step in turn {
        match text(step, "type") {
            Some("PLANNER_RESPONSE") => {
                let calls = step.get("tool_calls").and_then(Value::as_array);
                pending = calls
                    .into_iter()
                    .flatten()
                    .map(|call| {
                        command_line(call).map(|command| {
                            runs.push(Some(CommandRun {
                                command,
                                exit_code: None,
                                cwd: None,
                            }));
                            runs.len() - 1
                        })
                    })
                    .collect();
            }
            Some("GENERIC") => {
                if let Some(Some(index)) = pending.pop_front() {
                    if is_refused(step) {
                        runs[index] = None;
                    } else if let Some(run) = &mut runs[index] {
                        run.exit_code = text(step, "content").and_then(exit_code);
                    }
                }
            }
            _ => {}
        }
    }
    runs.into_iter().flatten().collect()
}

/// Whether a request of the turn hands work to a subagent, whose own requests
/// are in its own transcript, which we do not read.
fn invokes_a_subagent(turn: &[Map<String, Value>]) -> bool {
    turn.iter()
        .filter_map(|step| step.get("tool_calls")?.as_array())
        .flatten()
        .any(|call| call.get("name").and_then(Value::as_str) == Some(SUBAGENT_TOOL))
}

/// What the turn's requests used. `input_tokens` leaves out what was read from
/// the cache, as `TurnUsage` does: a request can read more from the cache than
/// its input (agy 1.4.12).
pub(crate) fn turn_reading(transcript: &[u8], marker: Option<&str>) -> TurnReading {
    let (turn, is_cut) = turn_steps(transcript, marker);
    let count =
        |step: &Map<String, Value>, key: &str| step.get(key).and_then(Value::as_u64).unwrap_or(0);
    let mut usage = TurnUsage {
        is_partial: is_cut || invokes_a_subagent(&turn),
        ..TurnUsage::default()
    };
    let mut has_request = false;
    for step in turn
        .iter()
        .filter(|step| text(step, "type") == Some("PLANNER_RESPONSE"))
    {
        has_request = true;
        usage.input_tokens += count(step, "input_tokens");
        usage.cache_read_tokens += count(step, "cache_read_tokens");
        usage.output_tokens += count(step, "output_tokens");
    }
    TurnReading {
        marker: marker.map(str::to_owned),
        usage: has_request.then_some(usage),
        commands: Some(commands(&turn)),
        are_commands_partial: is_cut,
        ..TurnReading::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const TURN: &str = concat!(
        r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"x"}"#,
        "\n",
        r#"{"step_index":1,"type":"PLANNER_RESPONSE","input_tokens":10,"cache_read_tokens":4,"output_tokens":2,"tool_calls":[{"name":"run_command","args":{"CommandLine":"make test"}},{"name":"view_file","args":{}},{"name":"run_command","args":{"CommandLine":"sleep 9"}}]}"#,
        "\n",
        r#"{"step_index":2,"type":"GENERIC","content":"Created At: t\nCommand exited with code 2.\n\nCommand output:\nno"}"#,
        "\n",
        r#"{"step_index":3,"type":"GENERIC","content":"file"}"#,
        "\n",
        r#"{"step_index":4,"type":"GENERIC","content":"Tool is running as a background task"}"#,
        "\n",
    );

    #[test]
    fn a_requests_input_does_not_include_what_it_read_from_the_cache() {
        // The counts of a real turn (agy 1.4.12). A request can read more from
        // the cache than its input, which could not be if one held the other.
        let requests = [
            (1, 6_921, 0),
            (3, 22_899, 0),
            (5, 15_472, 22_930),
            (7, 15_409, 38_424),
            (9, 2_269, 51_778),
        ];
        let mut lines = vec![
            r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"x"}"#
                .to_owned(),
        ];
        lines.extend(requests.map(|(step, input, cached)| {
            format!(
                r#"{{"step_index":{step},"type":"PLANNER_RESPONSE","input_tokens":{input},"cache_read_tokens":{cached}}}"#
            )
        }));
        let transcript = lines.join("\n") + "\n";
        let usage = turn_reading(transcript.as_bytes(), None)
            .usage
            .expect("usage");
        assert_eq!(usage.input_tokens, 62_970);
        assert_eq!(usage.cache_read_tokens, 113_132);
    }

    #[test]
    fn a_turn_reads_its_commands_in_call_order_with_their_results() {
        let reading = turn_reading(TURN.as_bytes(), None);
        let runs = reading.commands.expect("commands");
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].command, "make test");
        assert_eq!(runs[0].exit_code, Some(2));
        assert_eq!(runs[1].exit_code, None);
        let usage = reading.usage.expect("usage");
        assert_eq!(usage.input_tokens, 10);
        assert_eq!(usage.cache_read_tokens, 4);
    }

    #[test]
    fn a_turn_that_hands_work_to_a_subagent_uses_at_least_what_it_read() {
        let turn = concat!(
            r#"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"x"}"#,
            "\n",
            r#"{"step_index":1,"type":"PLANNER_RESPONSE","input_tokens":10,"output_tokens":2,"tool_calls":[{"name":"invoke_subagent","args":{}}]}"#,
            "\n",
        );
        assert!(
            turn_reading(turn.as_bytes(), None)
                .usage
                .expect("usage")
                .is_partial
        );
        let usage = turn_reading(TURN.as_bytes(), None).usage.expect("usage");
        assert!(!usage.is_partial);
    }

    #[test]
    fn a_stop_that_does_not_end_on_the_models_words_has_no_reply() {
        assert_eq!(turn_reply(TURN.as_bytes()), None);
        let earlier = concat!(
            r#"{"step_index":0,"type":"PLANNER_RESPONSE","content":"earlier"}"#,
            "\n",
            r#"{"step_index":1,"source":"SYSTEM","type":"SYSTEM_MESSAGE","content":"x"}"#,
            "\n",
        );
        assert_eq!(turn_reply(earlier.as_bytes()), None);
    }

    #[test]
    fn a_turn_with_a_marker_counts_from_its_step_and_not_the_turn_before() {
        let reading = turn_reading(TURN.as_bytes(), Some("conversation#2"));
        assert_eq!(reading.usage, None);
    }

    #[test]
    fn a_turn_no_person_began_ends_at_the_next_input() {
        let transcript = concat!(
            r#"{"step_index":4,"source":"SYSTEM","type":"SYSTEM_MESSAGE"}"#,
            "\n",
            r#"{"step_index":5,"type":"PLANNER_RESPONSE","input_tokens":10}"#,
            "\n",
            r#"{"step_index":6,"source":"USER_EXPLICIT","type":"USER_INPUT"}"#,
            "\n",
            r#"{"step_index":7,"type":"PLANNER_RESPONSE","input_tokens":500}"#,
            "\n",
        );
        let reading = turn_reading(transcript.as_bytes(), Some("c#4"));
        assert_eq!(reading.usage.expect("usage").input_tokens, 10);
    }

    #[test]
    fn a_turn_with_no_marker_is_what_follows_the_latest_input() {
        let usage = turn_reading(TURN.as_bytes(), None).usage.expect("usage");
        assert_eq!(usage.output_tokens, 2);
    }

    /// Steps 6 to 13 of a recorded session of `agy` 1.4.12: a command stopped
    /// by Esc, with no result step, and the next turn's.
    fn stopped_session() -> String {
        let call = |command: &str| {
            json!({"name": "run_command", "args": {
                "CommandLine": command,
                "IsDaemon": false,
                "WaitMsBeforeAsync": 10000,
            }})
        };
        [
            json!({"step_index": 6, "source": "USER_EXPLICIT", "type": "USER_INPUT"}),
            json!({"step_index": 7, "source": "SYSTEM", "type": "SYSTEM_MESSAGE"}),
            json!({"step_index": 8, "source": "MODEL", "type": "PLANNER_RESPONSE",
                "tool_calls": [call(STOPPED_COMMAND)]}),
            json!({"step_index": 10, "source": "USER_EXPLICIT", "type": "USER_INPUT"}),
            json!({"step_index": 11, "source": "MODEL", "type": "PLANNER_RESPONSE",
                "tool_calls": [call("echo SECOND_TURN_CMD")]}),
            json!({"step_index": 12, "source": "MODEL", "type": "GENERIC",
                "content": "Created At: t\nCommand exited with code 0.\n\nCommand output:\n"}),
            json!({"step_index": 13, "source": "MODEL", "type": "PLANNER_RESPONSE"}),
        ]
        .map(|step| step.to_string())
        .join("\n")
    }

    const STOPPED_COMMAND: &str =
        "python3 -c 'import time; time.sleep(90)'; echo INTERRUPTED_TURN_CMD";

    fn commands_of(transcript: &str, marker: &str) -> Vec<(String, Option<i32>)> {
        turn_reading(transcript.as_bytes(), Some(marker))
            .commands
            .expect("commands")
            .into_iter()
            .map(|run| (run.command, run.exit_code))
            .collect()
    }

    #[test]
    fn the_words_of_a_running_command_are_not_its_exit_status() {
        let call = json!({"step_index": 1, "type": "PLANNER_RESPONSE", "tool_calls": [{
            "name": "run_command",
            "args": {"CommandLine": "printf 'Command exited with code 1.'; sleep 30"},
        }]});
        let result = json!({"step_index": 2, "type": "GENERIC", "status": "RUNNING", "content":
            "Created At: t\nTool is running as a background task with task id: c/task-2\nTask Description: printf 'Command exited with code 1.'; sleep 30\nCommand exited with code 1."});
        let transcript = format!("{call}\n{result}\n");
        assert_eq!(commands_of(&transcript, "c#1")[0].1, None);
    }

    #[test]
    fn a_result_reads_its_status_after_its_times() {
        let call = json!({"step_index": 1, "type": "PLANNER_RESPONSE", "tool_calls": [{
            "name": "run_command", "args": {"CommandLine": "false"},
        }]});
        let result = json!({"step_index": 2, "type": "GENERIC", "content":
            "Created At: t\nCompleted At: t\nCommand exited with code 1.\n\nCommand output:\nCommand exited with code 7."});
        let transcript = format!("{call}\n{result}\n");
        assert_eq!(commands_of(&transcript, "c#1")[0].1, Some(1));
    }

    #[test]
    fn a_stopped_command_with_no_result_stays_with_no_exit_status() {
        let session = stopped_session();
        assert_eq!(
            commands_of(&session, "c#7"),
            [(STOPPED_COMMAND.to_owned(), None)]
        );
        assert_eq!(
            commands_of(&session, "c#11"),
            [("echo SECOND_TURN_CMD".to_owned(), Some(0))]
        );
    }

    #[test]
    fn a_plain_command_keeps_the_quotes_it_was_given() {
        for command in [r#""/opt/my tool""#, r#"echo "a b""#, "python3 -c 'x'"] {
            let call =
                json!({"name": "run_command", "args": {"CommandLine": command, "IsDaemon": false}});
            let step = json!({"step_index": 1, "type": "PLANNER_RESPONSE", "tool_calls": [call]});
            assert_eq!(
                commands_of(&step.to_string(), "c#1"),
                [(command.to_owned(), None)]
            );
        }
    }

    #[test]
    fn a_request_after_one_with_no_result_keeps_both_in_call_order() {
        let call = |command: &str| json!({"name": "run_command", "args": {"CommandLine": command}});
        let transcript = [
            json!({"step_index": 1, "type": "PLANNER_RESPONSE",
                "tool_calls": [call("a"), call("b")]}),
            json!({"step_index": 2, "type": "GENERIC", "content": "Command exited with code 1."}),
            json!({"step_index": 3, "type": "PLANNER_RESPONSE", "tool_calls": [call("c")]}),
            json!({"step_index": 4, "type": "GENERIC", "content": "Command exited with code 0."}),
        ]
        .map(|step| step.to_string())
        .join("\n");
        assert_eq!(
            commands_of(&transcript, "c#1"),
            [
                ("a".to_owned(), Some(1)),
                ("b".to_owned(), None),
                ("c".to_owned(), Some(0)),
            ]
        );
    }

    #[test]
    fn a_command_the_person_refused_is_not_a_run() {
        let call = |command: &str| json!({"name": "run_command", "args": {"CommandLine": command}});
        let transcript = [
            json!({"step_index": 1, "type": "PLANNER_RESPONSE",
                "tool_calls": [call("a"), call("cargo test"), call("c")]}),
            json!({"step_index": 2, "type": "GENERIC", "status": "DONE",
                "content": "Command exited with code 1."}),
            json!({"step_index": 3, "type": "GENERIC", "status": "ERROR",
                "error": "permission check failed for unsandboxed \"cargo test\": user denied permission to run command:\ncargo test",
                "content": "Encountered error in step execution: permission check failed"}),
            json!({"step_index": 4, "type": "GENERIC", "status": "DONE",
                "content": "Command exited with code 0."}),
            json!({"step_index": 5, "type": "PLANNER_RESPONSE", "tool_calls": [call("d")]}),
            json!({"step_index": 6, "type": "GENERIC", "status": "ERROR",
                "error": "something else went wrong", "content": "Encountered error"}),
        ]
        .map(|step| step.to_string())
        .join("\n");
        assert_eq!(
            commands_of(&transcript, "c#1"),
            [
                ("a".to_owned(), Some(1)),
                ("c".to_owned(), Some(0)),
                ("d".to_owned(), None),
            ]
        );
    }
}
