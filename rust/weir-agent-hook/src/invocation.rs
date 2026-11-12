//! Payload completion for hook fields passed outside the provider's JSON.

use crate::{HookLog, HookOutcome, HookRuntime, run_hook, run_worktree_hook};
use serde::Deserialize;
use serde_json::{Map, Value};
use weir_agent_model::{MAX_HOOK_INPUT_BYTES, parse_object};

/// Largest encoded invocation envelope, allowing JSON escaping of a bounded payload.
pub const MAX_INVOCATION_BYTES: usize = 8 * MAX_HOOK_INPUT_BYTES;

#[derive(Deserialize)]
struct Invocation {
    arguments: Vec<String>,
    payload: String,
}

/// Completes an out-of-band invocation before using the ordinary hook paths.
#[must_use]
pub fn run_hook_invocation(provider: &str, input: &[u8], runtime: &HookRuntime<'_>) -> HookOutcome {
    let result = (|| {
        if input.len() > MAX_INVOCATION_BYTES {
            return Err("hook invocation is too large".to_owned());
        }
        let invocation: Invocation =
            serde_json::from_slice(input).map_err(|error| error.to_string())?;
        complete_payload(&invocation.arguments, invocation.payload.as_bytes())
    })();
    match result {
        Ok((payload, true)) => run_worktree_hook(provider, &payload, runtime),
        Ok((payload, false)) => run_hook(provider, &payload, runtime),
        Err(error) => {
            HookLog::from_env(runtime.env).line(&format!("hook invocation rejected: {error}"));
            HookOutcome::Rejected(error)
        }
    }
}

fn complete_payload(arguments: &[String], input: &[u8]) -> Result<(Vec<u8>, bool), String> {
    let (mode, rest) = arguments.split_first().ok_or("missing hook mode")?;
    let (event, rest) = rest.split_first().ok_or("missing hook event")?;
    let (mut object, worktree) = match mode.as_str() {
        "event" => {
            let worktree = match rest {
                [] => false,
                [kind] if kind.is_empty() => false,
                [kind] if kind == "worktree" => true,
                _ => return Err("invalid event hook kind".to_owned()),
            };
            (
                parse_object(input, MAX_HOOK_INPUT_BYTES).map_err(|error| error.to_string())?,
                worktree,
            )
        }
        "report" => {
            if !input.is_empty() {
                return Err("report hooks do not accept a payload".to_owned());
            }
            let mut object = Map::new();
            let mut fields = rest;
            while let Some((kind, remaining)) = fields.split_first() {
                let (name, remaining) =
                    remaining.split_first().ok_or("missing report field name")?;
                if name == "hook_event_name" || object.contains_key(name) {
                    return Err("duplicate report field".to_owned());
                }
                let value;
                if kind == "--empty-object" {
                    value = Value::Object(Map::new());
                    fields = remaining;
                } else {
                    let (text, remaining) = remaining
                        .split_first()
                        .ok_or("missing report field value")?;
                    value = match kind.as_str() {
                        "--string" => Value::String(text.clone()),
                        "--string-array" => Value::Array(vec![Value::String(text.clone())]),
                        "--boolean" => {
                            Value::Bool(text.parse().map_err(|_| "invalid report boolean")?)
                        }
                        _ => return Err("unknown report field type".to_owned()),
                    };
                    fields = remaining;
                }
                object.insert(name.clone(), value);
            }
            (object, false)
        }
        _ => return Err("unknown hook invocation mode".to_owned()),
    };
    object.insert("hook_event_name".to_owned(), Value::String(event.clone()));
    let payload = serde_json::to_vec(&object).map_err(|error| error.to_string())?;
    if payload.len() > MAX_HOOK_INPUT_BYTES {
        return Err("completed hook payload is too large".to_owned());
    }
    Ok((payload, worktree))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use weir_agent_model::MAX_HOOK_INPUT_BYTES;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn event_completes_objects_without_relying_on_their_spelling() {
        for input in [
            "{}",
            " \n\t { }",
            r#"{"hook_event_name":"wrong","conversationId":"a"}"#,
        ] {
            let (payload, worktree) = complete_payload(
                &args(&["event", "PreToolUse", "worktree"]),
                input.as_bytes(),
            )
            .unwrap();
            let object: serde_json::Value = serde_json::from_slice(&payload).unwrap();
            assert_eq!(object["hook_event_name"], "PreToolUse");
            assert_eq!(
                object.get("conversationId"),
                serde_json::from_str::<serde_json::Value>(input)
                    .unwrap()
                    .get("conversationId")
            );
            assert!(worktree);
        }
    }

    #[test]
    fn reports_preserve_named_values_and_types() {
        let folder = "/tmp/tab\tquote\"backslash\\end\n";
        for fields in [
            args(&[
                "report",
                "WeirLaunch",
                "--string",
                "session_id",
                folder,
                "--string",
                "cwd",
                folder,
                "--boolean",
                "trust_all_tools",
                "true",
            ]),
            args(&[
                "report",
                "WeirLaunch",
                "--string",
                "conversationId",
                folder,
                "--string-array",
                "workspacePaths",
                folder,
            ]),
            args(&[
                "report",
                "weir.prepare",
                "--string",
                "preparation",
                folder,
                "--string",
                "cwd",
                folder,
                "--empty-object",
                "data",
            ]),
        ] {
            let (payload, worktree) = complete_payload(&fields, b"").unwrap();
            let object: serde_json::Value = serde_json::from_slice(&payload).unwrap();
            assert!(!worktree);
            match object.get("session_id") {
                Some(id) => {
                    assert_eq!(id, folder);
                    assert_eq!(object["cwd"], folder);
                    assert_eq!(object["trust_all_tools"], true);
                }
                None if object.get("conversationId").is_some() => {
                    assert_eq!(object["conversationId"], folder);
                    assert_eq!(object["workspacePaths"], json!([folder]));
                }
                None => {
                    assert_eq!(object["preparation"], folder);
                    assert_eq!(object["cwd"], folder);
                    assert_eq!(object["data"], json!({}));
                }
            }
        }
    }

    #[test]
    fn invalid_or_oversized_inputs_and_fields_are_rejected() {
        let event = args(&["event", "Stop"]);
        for input in [b"".as_slice(), b"[]", b"null", b"{", b"false"] {
            assert!(complete_payload(&event, input).is_err());
        }
        assert!(complete_payload(&event, &vec![b' '; MAX_HOOK_INPUT_BYTES + 1]).is_err());
        for fields in [
            args(&[
                "report",
                "WeirLaunch",
                "--boolean",
                "trust_all_tools",
                "yes",
            ]),
            args(&["report", "WeirLaunch", "--string", "cwd"]),
            args(&["report", "WeirLaunch", "--unknown", "cwd", "x"]),
        ] {
            assert!(complete_payload(&fields, b"").is_err());
        }
        let huge = "x".repeat(MAX_HOOK_INPUT_BYTES);
        assert!(
            complete_payload(
                &args(&["report", "WeirLaunch", "--string", "cwd", &huge]),
                b""
            )
            .is_err()
        );
    }
}
