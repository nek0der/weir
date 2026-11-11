//! Reads Kiro's session log, `messages.jsonl`, which Kiro keeps where its
//! sessions are rather than naming it in a payload.
//!
//! Each line is `{"id", "timestamp", "payload": {"type", ...}}`. Before the
//! first hook of a turn Kiro has written the person's `user` line, tagged
//! `_meta.kiro.userMessageTag`, and the turn's `turn_start`, which carries the
//! turn's `turnId` and the same tag. Its answers follow as `assistant` lines
//! with the `turnId`, each tool as a `tool_call` line with it when the tool
//! ends, a subagent as `sub_agent_start` and `sub_agent_complete` lines naming
//! the turn as their `parentExecutionId`, and `turn_end` comes after the `Stop`
//! hook (kiro-cli 2.37.1 and 3.2.0). The runtime hands us at most the file's
//! last 4 MiB, so the first line may be cut, and is skipped.

use crate::sha256;
use serde_json::Value;
use std::path::Path;
use std::time::{Duration, UNIX_EPOCH};
use weir_agent_model::{format_utc_seconds, parse_utc_seconds_with_fraction};

/// Returns the session log of `session_id`, run in `cwd`, under Kiro's folder `home`:
/// `sessions/<the first 16 hex digits of the SHA-256 of cwd>/<id>/messages.jsonl`.
/// `None` for an id that could name another place, or a folder that is not
/// absolute, as Kiro names none of those.
pub(crate) fn session_log(home: &Path, cwd: &str, session_id: &str) -> Option<String> {
    let is_plain_id = !session_id.is_empty()
        && session_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    if !is_plain_id || !cwd.starts_with('/') {
        return None;
    }
    let digest = sha256::hex_digest(cwd.as_bytes());
    let path = home
        .join("sessions")
        .join(&digest[..16])
        .join(session_id)
        .join("messages.jsonl");
    path.to_str().map(str::to_owned)
}

fn payloads(transcript: &[u8]) -> impl DoubleEndedIterator<Item = Value> + '_ {
    transcript
        .split(|byte| *byte == b'\n')
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .filter_map(|mut line| line.get_mut("payload").map(Value::take))
}

fn string<'a>(payload: &'a Value, key: &str) -> Option<&'a str> {
    payload.get(key).and_then(Value::as_str)
}

/// Returns the `turnId` of the last turn the log has begun. `None` when its start
/// lies before the part we were given.
pub(crate) fn last_turn(transcript: &[u8]) -> Option<String> {
    payloads(transcript)
        .rev()
        .find(|payload| string(payload, "type") == Some("turn_start"))
        .and_then(|payload| string(&payload, "turnId").map(str::to_owned))
        .filter(|turn| !turn.is_empty())
}

/// Returns what the person wrote to begin the turn `turn`: the `user` line whose tag
/// the turn's start names. `None` when the log does not hold both.
pub(crate) fn prompt(transcript: &[u8], turn: &str) -> Option<String> {
    let lines: Vec<Value> = payloads(transcript).collect();
    let tag = lines
        .iter()
        .rev()
        .find(|payload| {
            string(payload, "type") == Some("turn_start") && string(payload, "turnId") == Some(turn)
        })
        .and_then(|payload| string(payload, "userMessageTag"))?;
    lines
        .iter()
        .rev()
        .find(|payload| {
            string(payload, "type") == Some("user")
                && payload
                    .pointer("/_meta/kiro/userMessageTag")
                    .and_then(Value::as_str)
                    == Some(tag)
        })
        .and_then(|payload| string(payload, "content").map(str::to_owned))
}

/// What the log says of the turn `turn` so far, read from its lines.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TurnSoFar {
    /// When the turn began, from its `turn_start` line, in the record
    /// timestamp format: whole seconds, as Kiro's milliseconds are cut.
    /// `None` when the line carries no time the record format can hold.
    pub(crate) started_at: Option<String>,
    /// Whether every line from the turn's start to the next turn's is of a
    /// kind that runs nothing (`QUIET_KINDS`). A tool leaves a `tool_call`
    /// line as it ends, and a subagent a `sub_agent_start` naming the turn as
    /// its `parentExecutionId` (kiro-cli 3.2.0); a kind not known here, or a
    /// line that cannot be read, counts as one that may have run something,
    /// so neither a new kind Kiro adds nor a damaged line reads as changing
    /// nothing.
    pub(crate) has_run_no_tool: bool,
}

/// The kinds of line a turn that runs nothing writes, as kiro-cli 3.2.0
/// writes them: its answers and reasoning, its own notes and hooks' output,
/// the session's bookkeeping, the turn's end, and the person's next words.
const QUIET_KINDS: &[&str] = &[
    "user",
    "assistant",
    "agent_note",
    "ContextualHookInvoked",
    "session_metadata",
    "usage_summary",
    "session_event",
    "turn_end",
];

/// Returns a whole log line's kind, its payload's `type`.
fn kind(line: &Value) -> Option<&str> {
    line.get("payload")
        .and_then(|payload| string(payload, "type"))
}

/// Returns what the log says of the turn `turn`. `None` when the turn's start lies
/// before the part we were given, which says nothing of what came before it.
pub(crate) fn turn_so_far(transcript: &[u8], turn: &str) -> Option<TurnSoFar> {
    // Every line with something on it, `None` for one that is not JSON: the
    // first, which the tail may have cut, or one damaged in the turn.
    let lines: Vec<Option<Value>> = transcript
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.trim_ascii().is_empty())
        .map(|line| serde_json::from_slice::<Value>(line).ok())
        .collect();
    let start = lines.iter().rposition(|line| {
        line.as_ref().is_some_and(|line| {
            kind(line) == Some("turn_start")
                && line
                    .get("payload")
                    .and_then(|payload| string(payload, "turnId"))
                    == Some(turn)
        })
    })?;
    // The lines of no turn (an `agent_note`) carry no `turnId`, so the turn's
    // are the ones between its start and the next turn's.
    let has_run_no_tool = lines[start + 1..]
        .iter()
        .take_while(|line| line.as_ref().and_then(kind) != Some("turn_start"))
        .all(|line| {
            line.as_ref()
                .and_then(kind)
                .is_some_and(|kind| QUIET_KINDS.contains(&kind))
        });
    Some(TurnSoFar {
        started_at: lines[start]
            .as_ref()
            .and_then(|line| string(line, "timestamp"))
            .and_then(parse_utc_seconds_with_fraction)
            .map(|seconds| format_utc_seconds(UNIX_EPOCH + Duration::from_secs(seconds))),
        has_run_no_tool,
    })
}

/// Returns the last thing the agent said in the turn `turn`. Kiro writes its
/// reasoning as `assistant` lines too, with `operationType` `Reasoning`, and
/// what it says to the person with `Say` (kiro-cli 2.37.1).
pub(crate) fn reply(transcript: &[u8], turn: &str) -> Option<String> {
    payloads(transcript)
        .rev()
        .find(|payload| {
            string(payload, "type") == Some("assistant")
                && string(payload, "turnId") == Some(turn)
                && string(payload, "operationType") != Some("Reasoning")
        })
        .and_then(|payload| string(&payload, "content").map(str::to_owned))
        .filter(|reply| !reply.is_empty())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Returns the log of `sess_1`, run in `/Users/person/project`, under
    /// `/Users/person/.kiro`, joined as the platform joins a path.
    pub(crate) fn expected_log() -> Option<String> {
        let path = Path::new("/Users/person/.kiro")
            .join("sessions")
            .join("d9f5c1d735f7c068")
            .join("sess_1")
            .join("messages.jsonl");
        path.to_str().map(str::to_owned)
    }

    const LOG: &str = concat!(
        r#"cut line from before the tail"#,
        "\n",
        r#"{"id":"a","payload":{"type":"user","content":"first","_meta":{"kiro":{"userMessageTag":"prompt_1"}}}}"#,
        "\n",
        r#"{"id":"b","payload":{"type":"turn_start","turnId":"t1","userMessageTag":"prompt_1"}}"#,
        "\n",
        r#"{"id":"c","payload":{"type":"assistant","content":"working on it","turnId":"t1"}}"#,
        "\n",
        r#"{"id":"d","payload":{"type":"assistant","content":"done","operationType":"Say","turnId":"t1"}}"#,
        "\n",
        r#"{"id":"d2","payload":{"type":"assistant","content":"The person may want more.","operationType":"Reasoning","turnId":"t1"}}"#,
        "\n",
        r#"{"id":"e","payload":{"type":"turn_end","stopReason":"end_turn","turnId":"t1"}}"#,
        "\n",
        r#"{"id":"f","payload":{"type":"user","content":"second","_meta":{"kiro":{"userMessageTag":"prompt_2"}}}}"#,
        "\n",
        r#"{"id":"g","payload":{"type":"turn_start","turnId":"t2","userMessageTag":"prompt_2"}}"#,
        "\n",
    );

    #[test]
    fn the_last_turn_begun_is_the_calls() {
        assert_eq!(last_turn(LOG.as_bytes()).as_deref(), Some("t2"));
    }

    #[test]
    fn a_turn_begun_before_the_tail_has_no_marker() {
        let tail =
            r#"{"id":"c","payload":{"type":"assistant","content":"a long reply","turnId":"t1"}}"#;
        assert_eq!(last_turn(tail.as_bytes()), None);
        assert_eq!(prompt(tail.as_bytes(), "t1"), None);
    }

    #[test]
    fn a_turns_prompt_is_the_person_line_its_start_names() {
        assert_eq!(prompt(LOG.as_bytes(), "t1").as_deref(), Some("first"));
        assert_eq!(prompt(LOG.as_bytes(), "t2").as_deref(), Some("second"));
        assert_eq!(prompt(LOG.as_bytes(), "t3"), None);
    }

    #[test]
    fn a_turns_reply_is_its_last_answer_and_not_its_reasoning() {
        assert_eq!(reply(LOG.as_bytes(), "t1").as_deref(), Some("done"));
        assert_eq!(reply(LOG.as_bytes(), "t2"), None);
    }

    /// Lines as kiro-cli 3.2.0 wrote them: a turn that ran nothing, one that
    /// ran a shell command, and one that handed its work to a subagent, which
    /// leaves no `tool_call` of its own.
    const TURNS: &str = concat!(
        r#"{"timestamp":"2026-11-11T04:38:29.097Z","payload":{"type":"turn_start","turnId":"t1"}}"#,
        "\n",
        r#"{"payload":{"type":"agent_note","content":"Output:\n\n\nExit Code: 0"}}"#,
        "\n",
        r#"{"payload":{"type":"assistant","content":"ok","operationType":"Say","turnId":"t1"}}"#,
        "\n",
        r#"{"payload":{"type":"session_metadata"}}"#,
        "\n",
        r#"{"payload":{"type":"ContextualHookInvoked","name":"weir-stop","turnId":"t1"}}"#,
        "\n",
        r#"{"payload":{"type":"usage_summary","status":"success","turnId":"t1"}}"#,
        "\n",
        r#"{"payload":{"type":"session_event"}}"#,
        "\n",
        r#"{"payload":{"type":"turn_end","stopReason":"end_turn","turnId":"t1"}}"#,
        "\n",
        r#"{"payload":{"type":"user","content":"run ls"}}"#,
        "\n",
        r#"{"timestamp":"2026-11-11T04:38:56.104Z","payload":{"type":"turn_start","turnId":"t2"}}"#,
        "\n",
        r#"{"payload":{"type":"tool_call","toolName":"execute_bash","turnId":"t2"}}"#,
        "\n",
        r#"{"payload":{"type":"turn_start","turnId":"t3"}}"#,
        "\n",
        r#"{"payload":{"type":"ContextualHookInvoked","name":"weir-tool-start","turnId":"t3"}}"#,
        "\n",
        r#"{"payload":{"type":"sub_agent_start","parentExecutionId":"t3"}}"#,
        "\n",
        r#"{"payload":{"type":"sub_agent_complete","parentExecutionId":"t3"}}"#,
        "\n",
    );

    #[test]
    fn a_turn_so_far_says_when_it_began_and_whether_it_ran_anything() {
        assert_eq!(
            turn_so_far(TURNS.as_bytes(), "t1"),
            Some(TurnSoFar {
                started_at: Some("2026-11-11T04:38:29Z".to_owned()),
                has_run_no_tool: true,
            })
        );
        assert_eq!(
            turn_so_far(TURNS.as_bytes(), "t2"),
            Some(TurnSoFar {
                started_at: Some("2026-11-11T04:38:56Z".to_owned()),
                has_run_no_tool: false,
            })
        );
        // A subagent's work leaves no `tool_call` of the turn's.
        assert_eq!(
            turn_so_far(TURNS.as_bytes(), "t3"),
            Some(TurnSoFar {
                started_at: None,
                has_run_no_tool: false,
            })
        );
        // A turn whose start the tail lost says nothing, tools or not.
        assert_eq!(turn_so_far(TURNS.as_bytes(), "t0"), None);
    }

    /// A kind of line this build does not know, or a line that cannot be
    /// read, may be one that ran something. A cut line before the turn's
    /// start says nothing of the turn.
    #[test]
    fn an_unknown_or_unreadable_line_of_the_turn_is_not_quiet() {
        let start = r#"{"payload":{"type":"turn_start","turnId":"t1"}}"#;
        for line in [
            r#"{"payload":{"type":"workflow_step","turnId":"t1"}}"#,
            r#"{"payload":{"type":"tool_call","toolName":"execute_b"#,
        ] {
            let log = format!("{start}\n{line}\n");
            assert_eq!(
                turn_so_far(log.as_bytes(), "t1").map(|turn| turn.has_run_no_tool),
                Some(false),
                "{line}"
            );
        }
        let cut_before = format!("{{\"payload\":{{\"type\":\"tool_c\n{start}\n\n");
        assert_eq!(
            turn_so_far(cut_before.as_bytes(), "t1").map(|turn| turn.has_run_no_tool),
            Some(true)
        );
    }

    /// The start's time is kept only in the shape Kiro writes it.
    #[test]
    fn a_start_time_in_another_shape_is_left_out() {
        for time in [
            "2026-11-11T04:38:29.097+09:00",
            "2026-11-11T04:38:29.oopsZ",
            "",
        ] {
            let log = format!(
                r#"{{"timestamp":"{time}","payload":{{"type":"turn_start","turnId":"t1"}}}}"#
            );
            assert_eq!(
                turn_so_far(log.as_bytes(), "t1").map(|turn| turn.started_at),
                Some(None),
                "{time}"
            );
        }
    }

    #[test]
    fn the_log_lies_under_the_folders_digest() {
        assert_eq!(
            session_log(
                Path::new("/Users/person/.kiro"),
                "/Users/person/project",
                "sess_1"
            )
            .as_deref(),
            crate::transcript::tests::expected_log().as_deref()
        );
        let home = Path::new("/Users/person/.kiro");
        assert_eq!(session_log(home, "/Users/person/project", "../../x"), None);
        assert_eq!(session_log(home, "/Users/person/project", ""), None);
        assert_eq!(session_log(home, "project", "sess_1"), None);
    }
}
