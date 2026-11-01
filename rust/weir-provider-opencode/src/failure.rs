//! What the error of a failed execution means.
//!
//! OpenCode names each failure with a `type`, so no words of a message are read.
//! The names and how each holds its sessions stop here. The source is
//! `packages/core/src/session/to-session-error.ts` at v2.2.5, and only
//! `provider.free-limit` has been met for real. The reset comes only from
//! `retryAfterMs`, as nothing else says it.

use serde_json::{Map, Value};
use std::time::{Duration, SystemTime};
use weir_agent_model::{FailureKind, UsageLimit, UsageLimitScope, format_utc_seconds};

/// The limit `error` reports, counted from `now`. A rate limit is not one: it
/// passes on its own, and OpenCode retries it (`session.retry.scheduled`), so
/// one that still ended the execution is an ordinary failure.
pub(crate) fn usage_limit(error: &Map<String, Value>, now: SystemTime) -> Option<UsageLimit> {
    let scope = match error.get("type")?.as_str()? {
        // A model's own budget too: the agent can go on with another one, which is
        // what the interface takes `Upstream` to say.
        "provider.go-limit"
        | "provider.budget-limit"
        | "provider.free-limit"
        | "provider.chatgpt-limit"
        | "provider.quota"
        | "provider.model-budget-limit" => UsageLimitScope::Upstream,
        _ => return None,
    };
    Some(UsageLimit {
        resets_at: error
            .get("retryAfterMs")
            .and_then(Value::as_u64)
            .and_then(|delay| now.checked_add(Duration::from_millis(delay)))
            .map(format_utc_seconds),
        window: None,
        scope,
        label: error
            .get("message")
            .and_then(Value::as_str)
            .filter(|message| !message.is_empty())
            .map(str::to_owned),
    })
}

pub(crate) fn kind(error: &Map<String, Value>) -> Option<FailureKind> {
    match error.get("type")?.as_str()? {
        "provider.auth" => Some(FailureKind::SignIn),
        "provider.no-route" => Some(FailureKind::ModelUnavailable),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::time::UNIX_EPOCH;

    fn error(value: &Value) -> Map<String, Value> {
        value.as_object().expect("an object").clone()
    }

    #[test]
    fn each_limit_holds_what_it_names() {
        for (name, scope) in [
            ("provider.go-limit", UsageLimitScope::Upstream),
            ("provider.budget-limit", UsageLimitScope::Upstream),
            ("provider.free-limit", UsageLimitScope::Upstream),
            ("provider.chatgpt-limit", UsageLimitScope::Upstream),
            ("provider.quota", UsageLimitScope::Upstream),
            ("provider.model-budget-limit", UsageLimitScope::Upstream),
        ] {
            let limit = usage_limit(
                &error(&json!({"type": name, "message": "Over"})),
                UNIX_EPOCH,
            )
            .expect(name);
            assert_eq!(limit.scope, scope, "{name}");
            assert_eq!(limit.label.as_deref(), Some("Over"));
            assert_eq!(limit.resets_at, None);
        }
    }

    #[test]
    fn a_reset_comes_only_from_the_delay_it_names() {
        let limit = usage_limit(
            &error(&json!({"type": "provider.quota", "message": "x", "retryAfterMs": 90_000})),
            UNIX_EPOCH,
        )
        .expect("a limit");
        assert_eq!(limit.resets_at.as_deref(), Some("1970-01-01T00:01:30Z"));
    }

    #[test]
    fn a_rate_limit_and_other_failures_are_no_limit() {
        for name in ["provider.rate-limit", "provider.error", "unknown"] {
            assert_eq!(
                usage_limit(&error(&json!({"type": name})), UNIX_EPOCH),
                None
            );
        }
        assert_eq!(usage_limit(&error(&json!({})), UNIX_EPOCH), None);
    }

    #[test]
    fn sign_in_and_a_missing_route_have_kinds_of_their_own() {
        assert_eq!(
            kind(&error(&json!({"type": "provider.auth"}))),
            Some(FailureKind::SignIn)
        );
        assert_eq!(
            kind(&error(&json!({"type": "provider.no-route"}))),
            Some(FailureKind::ModelUnavailable)
        );
        assert_eq!(kind(&error(&json!({"type": "provider.quota"}))), None);
    }
}
