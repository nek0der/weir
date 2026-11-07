//! Reads the plan usage Codex's app server reports.
//!
//! `account/rateLimits/read` is the call Codex's own interface makes for its
//! limits, and the app server keeps it outside its experimental surface
//! (<https://learn.chatgpt.com/docs/app-server>). Its result holds
//! `rateLimits` with a `primary` and a `secondary` window, each with
//! `usedPercent`, `windowDurationMins` and `resetsAt` in epoch seconds. Which
//! window is which is not fixed: a plan with a
//! weekly limit alone reports it as `primary`, so a window is named by its
//! length rather than by its slot. Beside them, `rateLimitResetCredits`
//! holds the resets the account was granted, each with its `status` and the
//! `expiresAt` it lapses at.

use serde_json::{Map, Value};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use weir_agent_model::{
    PlanResetCredits, PlanUsage, PlanUsageAnswer, PlanUsageWindow, format_utc_seconds, parse_object,
};

/// The largest response we read. The result is a few hundred bytes; the
/// bound keeps a runaway one from being held in memory.
const MAX_RATE_LIMITS_RESPONSE_BYTES: usize = 256 * 1024;

/// What an `account/rateLimits/read` response says, given the whole
/// JSON-RPC message or its `result`. An error response is `Unreadable`, not
/// `NoPlan`: the server failed, and the person has nothing to sign in to.
pub(crate) fn plan_usage(response: &[u8], now: SystemTime) -> PlanUsageAnswer {
    let Ok(message) = parse_object(response, MAX_RATE_LIMITS_RESPONSE_BYTES) else {
        return PlanUsageAnswer::Unreadable;
    };
    if message.contains_key("error") {
        return PlanUsageAnswer::Unreadable;
    }
    let result = match message.get("result") {
        Some(Value::Object(result)) => result,
        Some(_) => return PlanUsageAnswer::Unreadable,
        None => &message,
    };
    let Some(limits) = result.get("rateLimits").and_then(Value::as_object) else {
        return PlanUsageAnswer::NoPlan;
    };
    let mut windows: Vec<(u64, PlanUsageWindow)> = ["primary", "secondary"]
        .into_iter()
        .filter_map(|slot| window(slot, limits.get(slot)?.as_object()?))
        .collect();
    if windows.is_empty() {
        return PlanUsageAnswer::NoPlan;
    }
    windows.sort_by_key(|(minutes, _)| *minutes);
    // Two windows of one length would share a name, which the interface
    // keys its rows by. The sort is stable, so the second is the secondary
    // slot's, and it takes the slot's name as well.
    if let [(_, first), (_, second)] = windows.as_mut_slice()
        && first.kind == second.kind
    {
        second.kind.push_str("_secondary");
    }
    PlanUsageAnswer::Usage(PlanUsage {
        windows: windows.into_iter().map(|(_, window)| window).collect(),
        reset_credits: result
            .get("rateLimitResetCredits")
            .and_then(Value::as_object)
            .and_then(reset_credits),
        observed_at: format_utc_seconds(now),
    })
}

/// The resets still to spend, and when the first of them lapses. `None`
/// when there are none: nothing to offer the person.
fn reset_credits(value: &Map<String, Value>) -> Option<PlanResetCredits> {
    let available: Vec<&Map<String, Value>> = value
        .get("credits")
        .and_then(Value::as_array)
        .map(|credits| {
            credits
                .iter()
                .filter_map(Value::as_object)
                .filter(|credit| credit.get("status").and_then(Value::as_str) == Some("available"))
                .collect()
        })
        .unwrap_or_default();
    // The count the server gives, else the credits it lists as available.
    let count = value
        .get("availableCount")
        .and_then(Value::as_u64)
        .unwrap_or(available.len() as u64);
    let count = u32::try_from(count).ok().filter(|count| *count > 0)?;
    let expires_at = available
        .iter()
        .filter_map(|credit| credit.get("expiresAt").and_then(Value::as_u64))
        .min()
        .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
        .map(format_utc_seconds);
    Some(PlanResetCredits {
        available: count,
        expires_at,
    })
}

/// A window with its length in minutes, for ordering. A window with no
/// length sorts last and is named by its slot, so two of them stay apart.
fn window(slot: &str, value: &Map<String, Value>) -> Option<(u64, PlanUsageWindow)> {
    let used_percent = value.get("usedPercent")?.as_f64()?;
    if !used_percent.is_finite() {
        return None;
    }
    let minutes = value.get("windowDurationMins").and_then(Value::as_u64);
    let kind = match minutes {
        Some(minutes) => PlanUsageWindow::kind_named_for_minutes(minutes),
        None => slot.to_owned(),
    };
    let resets_at = value
        .get("resetsAt")
        .and_then(Value::as_u64)
        .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
        .map(format_utc_seconds);
    Some((
        minutes.unwrap_or(u64::MAX),
        PlanUsageWindow {
            kind,
            used_percent,
            resets_at,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_weekly_only_plan_is_read_from_its_primary_slot() {
        // The shape codex-cli 0.165.0 answers with for a plan with a weekly limit alone.
        let response = json!({
            "id": 2,
            "result": {
                "rateLimits": {
                    "limitId": "codex",
                    "primary": { "usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1_793_776_116_u64 },
                    "secondary": null,
                    "planType": "prolite"
                }
            }
        })
        .to_string();
        let usage = usage(&response);
        assert_eq!(
            usage,
            PlanUsage {
                windows: vec![PlanUsageWindow {
                    kind: "seven_day".to_owned(),
                    used_percent: 12.0,
                    resets_at: Some("2026-11-04T07:08:36Z".to_owned()),
                }],
                reset_credits: None,
                observed_at: "1970-01-01T00:00:00Z".to_owned(),
            }
        );
    }

    #[test]
    fn windows_are_ordered_by_length_whatever_their_slot() {
        let result = json!({
            "rateLimits": {
                "primary": { "usedPercent": 30.5, "windowDurationMins": 10080 },
                "secondary": { "usedPercent": 80, "windowDurationMins": 300 }
            }
        })
        .to_string();
        let usage = usage(&result);
        assert_eq!(
            usage.windows,
            vec![
                PlanUsageWindow {
                    kind: "five_hour".to_owned(),
                    used_percent: 80.0,
                    resets_at: None
                },
                PlanUsageWindow {
                    kind: "seven_day".to_owned(),
                    used_percent: 30.5,
                    resets_at: None
                },
            ]
        );
    }

    #[test]
    fn an_unfamiliar_length_is_named_by_its_minutes() {
        let result = json!({
            "rateLimits": { "primary": { "usedPercent": 1, "windowDurationMins": 1440 } }
        })
        .to_string();
        assert_eq!(usage(&result).windows[0].kind, "minutes_1440");
    }

    #[test]
    fn windows_with_no_length_are_named_by_their_slot() {
        let result = json!({
            "rateLimits": { "primary": { "usedPercent": 1 }, "secondary": { "usedPercent": 2 } }
        })
        .to_string();
        let kinds: Vec<String> = usage(&result).windows.into_iter().map(|w| w.kind).collect();
        assert_eq!(kinds, ["primary", "secondary"]);
    }

    #[test]
    fn two_windows_of_one_length_keep_apart() {
        let result = json!({
            "rateLimits": {
                "primary": { "usedPercent": 1, "windowDurationMins": 300 },
                "secondary": { "usedPercent": 2, "windowDurationMins": 300 }
            }
        })
        .to_string();
        assert_eq!(
            usage(&result).windows,
            vec![
                PlanUsageWindow {
                    kind: "five_hour".to_owned(),
                    used_percent: 1.0,
                    resets_at: None
                },
                PlanUsageWindow {
                    kind: "five_hour_secondary".to_owned(),
                    used_percent: 2.0,
                    resets_at: None
                },
            ]
        );
    }

    #[test]
    fn reset_credits_count_and_the_first_to_lapse() {
        let mut result = json!({
            "rateLimits": { "primary": { "usedPercent": 1, "windowDurationMins": 10080 } },
            "rateLimitResetCredits": {
                "credits": [
                    { "status": "available", "expiresAt": 1_794_007_137_u64 },
                    { "status": "used", "expiresAt": 1_700_000_000_u64 },
                    { "status": "available", "expiresAt": 1_793_299_653_u64 }
                ]
            }
        });
        let expected = PlanResetCredits {
            available: 2,
            expires_at: Some("2026-10-29T18:47:33Z".to_owned()),
        };
        assert_eq!(
            usage(&result.to_string()).reset_credits,
            Some(expected.clone())
        );

        result["rateLimitResetCredits"]["availableCount"] = json!(3);
        assert_eq!(
            usage(&result.to_string()).reset_credits,
            Some(PlanResetCredits {
                available: 3,
                ..expected
            })
        );
    }

    #[test]
    fn no_credits_left_says_nothing() {
        for credits in [
            json!({ "availableCount": 0, "credits": [{ "status": "available", "expiresAt": 1 }] }),
            json!({ "credits": [{ "status": "used", "expiresAt": 1 }] }),
        ] {
            let result = json!({
                "rateLimits": { "primary": { "usedPercent": 1, "windowDurationMins": 10080 } },
                "rateLimitResetCredits": credits
            })
            .to_string();
            assert_eq!(usage(&result).reset_credits, None, "{credits}");
        }
    }

    #[test]
    fn an_answer_without_windows_has_no_plan() {
        for response in [
            json!({ "id": 2, "result": { "rateLimits": { "primary": null, "secondary": null } } }),
            json!({ "id": 2, "result": {} }),
        ] {
            assert_eq!(
                plan_usage(response.to_string().as_bytes(), UNIX_EPOCH),
                PlanUsageAnswer::NoPlan,
                "{response}"
            );
        }
    }

    #[test]
    fn an_error_or_something_else_is_unreadable() {
        for response in [
            json!({ "id": 2, "error": { "code": -32600, "message": "failed" } }).to_string(),
            json!({ "id": 2, "result": "nonsense" }).to_string(),
            "garbage".to_owned(),
        ] {
            assert_eq!(
                plan_usage(response.as_bytes(), UNIX_EPOCH),
                PlanUsageAnswer::Unreadable,
                "{response}"
            );
        }
    }

    #[test]
    fn an_unrepresentable_window_reset_keeps_usage_and_other_windows() {
        let result = json!({
            "rateLimits": {
                "primary": { "usedPercent": 30.5, "windowDurationMins": 10080, "resetsAt": u64::MAX },
                "secondary": { "usedPercent": 80, "windowDurationMins": 300, "resetsAt": 1_793_776_116_u64 }
            }
        });
        assert_eq!(
            usage(&result.to_string()).windows,
            vec![
                PlanUsageWindow {
                    kind: "five_hour".to_owned(),
                    used_percent: 80.0,
                    resets_at: Some("2026-11-04T07:08:36Z".to_owned()),
                },
                PlanUsageWindow {
                    kind: "seven_day".to_owned(),
                    used_percent: 30.5,
                    resets_at: None,
                },
            ]
        );
    }

    #[test]
    fn an_unrepresentable_credit_expiry_keeps_the_available_count() {
        let result = json!({
            "rateLimits": { "primary": { "usedPercent": 1 } },
            "rateLimitResetCredits": {
                "credits": [{ "status": "available", "expiresAt": u64::MAX }]
            }
        });
        assert_eq!(
            usage(&result.to_string()).reset_credits,
            Some(PlanResetCredits {
                available: 1,
                expires_at: None
            })
        );
    }

    fn usage(response: &str) -> PlanUsage {
        match plan_usage(response.as_bytes(), UNIX_EPOCH) {
            PlanUsageAnswer::Usage(usage) => usage,
            other => panic!("expected usage, got {other:?}"),
        }
    }
}
