//! `permission.asked` translated for the approval card.
//!
//! OpenCode's own prompt stays on screen while the card shows, as no plugin can
//! hide it; an answer at either one withdraws the other (the plugin's
//! `cancelApproval`). The card has one way to allow, so OpenCode's "always" stays
//! at its own prompt.

use serde_json::{Value, json};
use weir_agent_model::{
    APPROVAL_TIMEOUT_MS, ApprovalDecision, ApprovalRequest, MAX_HOOK_INPUT_BYTES, NormalizeError,
    ProviderId, ProviderOutput, parse_object,
};

pub(crate) fn approval_request(bytes: &[u8]) -> Result<Option<ApprovalRequest>, NormalizeError> {
    let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
    if object.get("hook_event_name").and_then(Value::as_str) != Some("permission.asked") {
        return Ok(None);
    }
    let Some(data) = object.get("data").and_then(Value::as_object) else {
        return Ok(None);
    };
    let text = |key: &str| data.get(key).and_then(Value::as_str);
    let Some(action) = text("action").filter(|action| !action.is_empty()) else {
        return Ok(None);
    };
    let resources: Vec<&str> = data
        .get("resources")
        .and_then(Value::as_array)
        .map(|resources| resources.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let joined = resources.join("\n");
    // The card shows a command only for the tool name it knows one by, which
    // reads a shell command from `command`.
    let (tool_name, input) = if action == "shell" {
        ("Bash".to_owned(), json!({ "command": joined }))
    } else {
        (
            object
                .get("tool")
                .and_then(Value::as_str)
                .unwrap_or(action)
                .to_owned(),
            json!({ "action": action, "resources": resources }),
        )
    };
    Ok(Some(ApprovalRequest {
        provider: ProviderId::new(crate::PROVIDER_ID).expect("static id is valid"),
        session_id: text("sessionID").map(str::to_owned),
        operation_id: text("id").map(str::to_owned),
        tool_name,
        summary: text("message")
            .filter(|message| !message.is_empty())
            .map(str::to_owned)
            .or_else(|| (!joined.is_empty()).then_some(joined)),
        input,
        timeout_ms: APPROVAL_TIMEOUT_MS,
        questions: Vec::new(),
    }))
}

/// What the plugin reads from the helper and replies with. Nothing leaves the
/// person to OpenCode's own prompt.
pub(crate) fn approval_output(decision: &ApprovalDecision) -> ProviderOutput {
    let body = match decision {
        ApprovalDecision::AllowOnce => json!({"decision": "once"}),
        ApprovalDecision::Deny {
            message: Some(message),
        } => json!({"decision": "reject", "message": message}),
        ApprovalDecision::Deny { message: None } => json!({"decision": "reject"}),
        ApprovalDecision::Delegate | ApprovalDecision::Answer { .. } => {
            return ProviderOutput { stdout: None };
        }
    };
    ProviderOutput {
        stdout: Some(serde_json::to_vec(&body).expect("static shape serializes")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shell_request_reads_as_a_command_on_the_card() {
        let request = approval_request(
            json!({
                "hook_event_name": "permission.asked",
                "tool": "shell",
                "data": {"id": "per_1", "sessionID": "ses_1", "action": "shell", "resources": ["touch a"]},
            })
            .to_string()
            .as_bytes(),
        )
        .expect("an object")
        .expect("a request");
        assert_eq!(request.tool_name, "Bash");
        assert_eq!(request.input, json!({"command": "touch a"}));
        assert_eq!(request.summary.as_deref(), Some("touch a"));
        assert_eq!(request.operation_id.as_deref(), Some("per_1"));
        assert_eq!(request.session_id.as_deref(), Some("ses_1"));
    }

    #[test]
    fn another_action_keeps_its_own_words() {
        let request = approval_request(
            json!({
                "hook_event_name": "permission.asked",
                "tool": "write",
                "data": {"id": "per_2", "action": "edit", "resources": ["src/a.rs"], "message": "Edit a file"},
            })
            .to_string()
            .as_bytes(),
        )
        .expect("an object")
        .expect("a request");
        assert_eq!(request.tool_name, "write");
        assert_eq!(
            request.input,
            json!({"action": "edit", "resources": ["src/a.rs"]})
        );
        assert_eq!(request.summary.as_deref(), Some("Edit a file"));
    }

    #[test]
    fn any_other_event_is_no_request() {
        assert_eq!(
            approval_request(br#"{"hook_event_name":"session.tool.called"}"#),
            Ok(None)
        );
    }

    #[test]
    fn a_decision_renders_as_what_opencode_takes() {
        let output = |decision| approval_output(&decision).stdout.map(String::from_utf8);
        assert_eq!(
            output(ApprovalDecision::AllowOnce),
            Some(Ok(r#"{"decision":"once"}"#.to_owned()))
        );
        assert_eq!(
            output(ApprovalDecision::Deny {
                message: Some("not now".to_owned())
            }),
            Some(Ok(r#"{"decision":"reject","message":"not now"}"#.to_owned()))
        );
        assert_eq!(output(ApprovalDecision::Delegate), None);
    }
}
