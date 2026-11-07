//! `PermissionRequest` translation, producing the same JSON the Swift adapter
//! it replaces emitted (serde does not escape `/`, which JSON treats alike). Codex uses Claude's hook output shape and adds a `turn_id`,
//! which becomes the neutral operation id.

use serde_json::{Value, json};
use weir_agent_model::{
    APPROVAL_TIMEOUT_MS, ApprovalDecision, ApprovalRequest, MAX_HOOK_INPUT_BYTES, NormalizeError,
    ProviderId, ProviderOutput, parse_object,
};

pub(crate) fn approval_request(bytes: &[u8]) -> Result<Option<ApprovalRequest>, NormalizeError> {
    let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
    if object.get("hook_event_name").and_then(Value::as_str) != Some("PermissionRequest") {
        return Ok(None);
    }
    let Some(tool_name) = object
        .get("tool_name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
    else {
        return Ok(None);
    };
    let Some(input) = object
        .get("tool_input")
        .filter(|value| value.is_object() || value.is_array())
    else {
        return Ok(None);
    };
    // The Swift adapter fell back to `description` when `command` was
    // present but not a string, so each key is checked as a string in turn.
    let summary = input
        .get("command")
        .and_then(Value::as_str)
        .or_else(|| input.get("description").and_then(Value::as_str))
        .map(str::to_owned);
    Ok(Some(ApprovalRequest {
        provider: ProviderId::new(crate::PROVIDER_ID).expect("static id is valid"),
        session_id: object
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        operation_id: object
            .get("turn_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        tool_name: tool_name.to_owned(),
        summary,
        input: input.clone(),
        timeout_ms: APPROVAL_TIMEOUT_MS,
        questions: Vec::new(),
    }))
}

pub(crate) fn approval_output(decision: &ApprovalDecision, _request: &Value) -> ProviderOutput {
    let body = match decision {
        ApprovalDecision::AllowOnce => json!({"behavior": "allow"}),
        ApprovalDecision::Deny {
            message: Some(message),
        } => {
            json!({"behavior": "deny", "message": message})
        }
        ApprovalDecision::Deny { message: None } => json!({"behavior": "deny"}),
        // Codex's question tool, `request_user_input`, never reaches this
        // hook: it waits at Codex's own TUI. So no request here carries a
        // question, an answer has nothing to be rendered into, and it
        // delegates like an explicit `Delegate`.
        ApprovalDecision::Delegate | ApprovalDecision::Answer { .. } => {
            return ProviderOutput { stdout: None };
        }
    };
    // serde_json's default map keeps keys sorted, which is what the Swift
    // adapter emitted with `.sortedKeys`, so the documents stay identical.
    let output = json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": body,
        }
    });
    ProviderOutput {
        stdout: Some(serde_json::to_vec(&output).expect("static shape serializes")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_turn_identifier_as_correlation_metadata() {
        let payload = br#"{"hook_event_name":"PermissionRequest","session_id":"codex-session","turn_id":"turn-7","tool_name":"shell","tool_input":{"command":["git","status"],"description":"Inspect status"}}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert_eq!(request.provider.as_str(), "codex");
        assert_eq!(request.session_id.as_deref(), Some("codex-session"));
        assert_eq!(request.operation_id.as_deref(), Some("turn-7"));
        assert_eq!(request.tool_name, "shell");
        assert_eq!(request.summary.as_deref(), Some("Inspect status"));
        assert_eq!(
            request.input,
            json!({ "command": ["git", "status"], "description": "Inspect status" })
        );
        assert_eq!(request.timeout_ms, APPROVAL_TIMEOUT_MS);
        assert!(request.questions.is_empty());
    }

    #[test]
    fn other_events_and_malformed_requests_are_not_approvals() {
        for payload in [
            &br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#[..],
            br#"{"hook_event_name":"PermissionRequest","tool_name":"","tool_input":{}}"#,
            br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":7}"#,
        ] {
            assert_eq!(approval_request(payload).expect("ok"), None, "{}", String::from_utf8_lossy(payload));
        }
        assert_eq!(approval_request(b"\"x\""), Err(NormalizeError::NotAnObject));
    }

    #[test]
    fn decisions_render_the_hook_output_the_agent_reads() {
        for (decision, output) in [
            (
                ApprovalDecision::AllowOnce,
                r#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#,
            ),
            (
                ApprovalDecision::Deny { message: None },
                r#"{"hookSpecificOutput":{"decision":{"behavior":"deny"},"hookEventName":"PermissionRequest"}}"#,
            ),
            (
                ApprovalDecision::Deny {
                    message: Some("Blocked".into()),
                },
                r#"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Blocked"},"hookEventName":"PermissionRequest"}}"#,
            ),
        ] {
            assert_eq!(
                approval_output(&decision, &Value::Null).stdout.as_deref(),
                Some(output.as_bytes()),
                "{decision:?}"
            );
        }
    }

    #[test]
    fn delegate_and_answer_emit_no_output() {
        for decision in [
            ApprovalDecision::Delegate,
            ApprovalDecision::Answer {
                answers: std::collections::BTreeMap::from([(
                    "Which license?".to_owned(),
                    "MIT".to_owned(),
                )]),
            },
        ] {
            assert_eq!(
                approval_output(&decision, &json!({})).stdout,
                None,
                "{decision:?}"
            );
        }
    }
}
