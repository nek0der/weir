//! A subscription usage limit the agent stopped at, and the plan usage the
//! agent last reported.

use serde::{Deserialize, Serialize};

/// The agent's plan ran out of usage, so its turn stopped until the limit
/// resets. Carried by the failure that reports it and kept on the run's
/// record while the run rests in error, so the interface can name the stop
/// and say when it ends.
///
/// Serialized in camel case like the record and the projection badge that
/// carry it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageLimit {
    /// When the limit resets, as an ISO-8601 UTC timestamp with second
    /// precision like every other record time. `None` when the provider did
    /// not say, which the interface shows as a limit with no time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    /// Which limit it is, as the provider names it (Claude's `five_hour`,
    /// `seven_day`, …). Kept verbatim for the interface to word; `None` when
    /// not given.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
    /// Whom the limit holds. Absent means `Account`, which is what every limit
    /// was before the field existed; the app reads a record's absent value by
    /// its window, as those records' model limits named themselves there.
    #[serde(
        default,
        skip_serializing_if = "UsageLimitScope::is_account",
        deserialize_with = "UsageLimitScope::read"
    )]
    pub scope: UsageLimitScope,
    /// The name of the limit in the provider's words, for a limit the interface
    /// has no word for (`Free usage`), as `window` names one it has. `None` when
    /// not given.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// Which of the agent's work a usage limit stops.
///
/// A CLI with one vendor's plan behind it has one limit for all of its sessions.
/// A CLI that reaches many services and models does not: a limit on one of them
/// says nothing of a session on another, which goes on or could by changing
/// model. The rules go by this, never by which provider it is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UsageLimitScope {
    /// Every session of the agent on this account.
    #[default]
    Account,
    /// The sessions going through one service the agent reaches its models by.
    Upstream,
    /// The sessions on one model.
    Model,
}

impl UsageLimitScope {
    /// A word this build does not know says the limit holds less than the account,
    /// as every word but the default does. It reads as `Upstream`, which marks no
    /// other agent; the app reads it the same (`UsageLimitScope` there), and the limit
    /// itself stands.
    fn read<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(
            match serde_json::Value::deserialize(deserializer)?.as_str() {
                Some("account") => Self::Account,
                Some("model") => Self::Model,
                _ => Self::Upstream,
            },
        )
    }

    #[allow(clippy::trivially_copy_pass_by_ref)] // serde passes the field by reference.
    fn is_account(&self) -> bool {
        *self == Self::Account
    }
}

/// How much of a subscription plan's limits an agent's account has used, as
/// the agent last reported it.
///
/// Each provider reports it its own way (Claude Code through the status line,
/// Codex through its app server); this is the one shape the interface reads.
/// Serialized in camel case like the other records.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanUsage {
    /// The plan's limit windows, the shortest first.
    pub windows: Vec<PlanUsageWindow>,
    /// The resets the account may spend to start its windows over, when
    /// the provider grants them (Codex). `None` when it does not say, as
    /// Claude Code's status line does not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_credits: Option<PlanResetCredits>,
    /// When the provider reported these values, as an ISO-8601 UTC timestamp
    /// with second precision. The interface says how old they are, because a
    /// value read from a status line is only as fresh as the last turn.
    pub observed_at: String,
}

/// The resets an account may spend to start its limit windows over.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanResetCredits {
    /// How many are left to spend.
    pub available: u32,
    /// When the first of them lapses, as an ISO-8601 UTC timestamp: the one
    /// the person has to spend first. `None` when the provider did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
}

/// One limit window of a plan: what share of it is used and when it resets.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanUsageWindow {
    /// Which window it is, in the shared vocabulary: `five_hour` and
    /// `seven_day` when the length is one of those, otherwise the provider's
    /// own name, kept for the interface to word.
    pub kind: String,
    /// The share used, from 0 to 100. Not clamped: a provider that reports
    /// past 100 is shown as at the limit, which is the interface's call.
    pub used_percent: f64,
    /// When the window resets, as an ISO-8601 UTC timestamp. `None` when the
    /// provider did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
}

impl PlanUsageWindow {
    /// The shared name of the five-hour window.
    pub const FIVE_HOUR: &'static str = "five_hour";
    /// The shared name of the seven-day window.
    pub const SEVEN_DAY: &'static str = "seven_day";
    /// The weekly windows of one model (Claude's), whose limit stops only the
    /// sessions on that model.
    pub const MODEL_WEEKLY: [&'static str; 2] = ["seven_day_opus", "seven_day_sonnet"];
    /// What a window with no shared name is named by before its length in
    /// minutes (`minutes_1440`). The app reads the length back from the name
    /// (`PlanUsageWindow.minutesPrefix`); the two sides check the names
    /// against `rust/fixtures/contract/shared-values.json`.
    pub const MINUTES_PREFIX: &'static str = "minutes_";

    /// The shared name of a window `minutes` long, for a provider that gives
    /// its windows by length rather than by name (Codex). `None` for a length
    /// with no shared name.
    #[must_use]
    pub fn kind_for_minutes(minutes: u64) -> Option<&'static str> {
        match minutes {
            300 => Some(Self::FIVE_HOUR),
            10_080 => Some(Self::SEVEN_DAY),
            _ => None,
        }
    }

    /// The name of a window `minutes` long: its shared name, else one made
    /// of its length (`MINUTES_PREFIX`).
    #[must_use]
    pub fn kind_named_for_minutes(minutes: u64) -> String {
        Self::kind_for_minutes(minutes).map_or_else(
            || format!("{}{minutes}", Self::MINUTES_PREFIX),
            str::to_owned,
        )
    }
}

/// What a provider's answer to a plan usage request says.
#[derive(Clone, Debug, PartialEq)]
pub enum PlanUsageAnswer {
    /// The account's windows.
    Usage(PlanUsage),
    /// An answer, but no plan in it: an account signed in with an API key,
    /// or not signed in.
    NoPlan,
    /// No answer to read: an error response, or something that is not the
    /// provider's answer at all. Kept apart from `NoPlan` so the interface
    /// does not tell the person to sign in when the server failed.
    Unreadable,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_limit_serializes_in_camel_case_and_leaves_out_what_is_unknown() {
        let limit = UsageLimit {
            resets_at: Some("2026-10-13T06:40:00Z".to_owned()),
            window: Some("five_hour".to_owned()),
            ..UsageLimit::default()
        };
        assert_eq!(
            serde_json::to_value(&limit).unwrap(),
            serde_json::json!({"resetsAt": "2026-10-13T06:40:00Z", "window": "five_hour"})
        );
        assert_eq!(serde_json::to_string(&UsageLimit::default()).unwrap(), "{}");
        assert_eq!(
            serde_json::from_str::<UsageLimit>("{}").unwrap(),
            UsageLimit::default()
        );
    }

    #[test]
    fn a_limit_that_holds_less_than_the_account_says_so() {
        for (scope, word) in [
            (UsageLimitScope::Upstream, "upstream"),
            (UsageLimitScope::Model, "model"),
        ] {
            let limit = UsageLimit {
                scope,
                label: Some("Free usage".to_owned()),
                ..UsageLimit::default()
            };
            let value = serde_json::to_value(&limit).unwrap();
            assert_eq!(
                value,
                serde_json::json!({"scope": word, "label": "Free usage"})
            );
            assert_eq!(serde_json::from_value::<UsageLimit>(value).unwrap(), limit);
        }
    }

    #[test]
    fn an_unknown_or_unreadable_scope_preserves_the_limit_as_upstream() {
        for scope in [
            serde_json::json!("from-a-newer-build"),
            serde_json::json!(7),
            serde_json::Value::Null,
        ] {
            let limit: UsageLimit =
                serde_json::from_value(serde_json::json!({"window": "w", "scope": scope})).unwrap();
            assert_eq!(limit.scope, UsageLimitScope::Upstream);
            assert_eq!(limit.window.as_deref(), Some("w"));
        }
    }

    #[test]
    fn plan_usage_serializes_in_camel_case_and_leaves_out_what_is_unknown() {
        let usage = PlanUsage {
            windows: vec![PlanUsageWindow {
                kind: PlanUsageWindow::FIVE_HOUR.to_owned(),
                used_percent: 42.0,
                resets_at: None,
            }],
            reset_credits: None,
            observed_at: "2026-10-29T03:00:00Z".to_owned(),
        };
        let wire = serde_json::json!({
            "windows": [{"kind": "five_hour", "usedPercent": 42.0}],
            "observedAt": "2026-10-29T03:00:00Z"
        });
        assert_eq!(serde_json::to_value(&usage).unwrap(), wire);
        assert_eq!(serde_json::from_value::<PlanUsage>(wire).unwrap(), usage);
    }

    #[test]
    fn plan_usage_round_trips_reported_resets_and_credits() {
        let usage = PlanUsage {
            windows: vec![PlanUsageWindow {
                kind: PlanUsageWindow::SEVEN_DAY.to_owned(),
                used_percent: 83.5,
                resets_at: Some("2026-11-04T05:00:00Z".to_owned()),
            }],
            reset_credits: Some(PlanResetCredits {
                available: 2,
                expires_at: Some("2026-11-03T06:00:00Z".to_owned()),
            }),
            observed_at: "2026-10-29T03:00:00Z".to_owned(),
        };
        let wire = serde_json::json!({
            "windows": [{
                "kind": "seven_day",
                "usedPercent": 83.5,
                "resetsAt": "2026-11-04T05:00:00Z"
            }],
            "resetCredits": {"available": 2, "expiresAt": "2026-11-03T06:00:00Z"},
            "observedAt": "2026-10-29T03:00:00Z"
        });
        assert_eq!(serde_json::to_value(&usage).unwrap(), wire);
        assert_eq!(serde_json::from_value::<PlanUsage>(wire).unwrap(), usage);
    }
}
