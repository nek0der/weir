//! `agy`'s status line: the one place it gives out the plan's usage.
//!
//! Its input carries `quota`, keyed by bucket, each with `remaining_fraction`
//! and `reset_time` (agy 1.4.12). As for Claude Code, the shim puts our relay
//! in the slot of the person's own status line, and the relay runs theirs on
//! the same input. Without one the slot stays theirs, as the row a status
//! line takes would change what `agy` shows them.

use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use weir_agent_model::{
    PlanUsage, PlanUsageWindow, SettingsSource, StatusLineAdapter, format_utc_seconds, parse_object,
};

const MAX_STATUS_LINE_INPUT_BYTES: usize = 1024 * 1024;

/// The arguments our relay takes after the helper's path. A status line whose
/// command ends with them is ours, and running it would run itself.
pub const RELAY_ARGUMENTS: &str = "statusline antigravity";

/// The bucket for Gemini models, which every plan has, and which resets
/// weekly. `3p-weekly` counts the third-party models and only some plans can
/// use those.
const GEMINI_BUCKET: &str = "gemini-weekly";

#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct AntigravityStatusLine;

impl StatusLineAdapter for AntigravityStatusLine {
    fn plan_usage(&self, input: &[u8], now: SystemTime) -> Option<PlanUsage> {
        let object = parse_object(input, MAX_STATUS_LINE_INPUT_BYTES).ok()?;
        let bucket = object.get("quota")?.get(GEMINI_BUCKET)?.as_object()?;
        let remaining = bucket.get("remaining_fraction")?.as_f64()?;
        if !remaining.is_finite() {
            return None;
        }
        Some(PlanUsage {
            windows: vec![PlanUsageWindow {
                kind: PlanUsageWindow::SEVEN_DAY.to_owned(),
                used_percent: (1.0 - remaining) * 100.0,
                resets_at: bucket
                    .get("reset_time")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            }],
            reset_credits: None,
            observed_at: format_utc_seconds(now),
        })
    }

    fn project_directory(&self, input: &[u8]) -> Option<PathBuf> {
        let object = parse_object(input, MAX_STATUS_LINE_INPUT_BYTES).ok()?;
        object
            .get("workspace")
            .and_then(|workspace| workspace.get("project_dir"))
            .and_then(Value::as_str)
            .or_else(|| object.get("cwd").and_then(Value::as_str))
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
    }

    /// `agy` reads its settings from this one file (`--settings` aside: the
    /// shim adds no relay to a launch that passes its own).
    fn settings_sources(&self, _project: Option<&Path>) -> Vec<SettingsSource> {
        vec![SettingsSource::UserHomeFile(
            ".gemini/antigravity-cli/settings.json",
        )]
    }

    fn user_status_line(&self, layers: &[Option<Value>]) -> Option<Map<String, Value>> {
        let status_line = layers
            .iter()
            .flatten()
            .filter_map(|settings| settings.get("statusLine"))
            .find(|status_line| !is_relay(status_line))?
            .as_object()?;
        self.command(status_line)?;
        Some(status_line.clone())
    }

    fn command<'a>(&self, status_line: &'a Map<String, Value>) -> Option<&'a str> {
        if status_line
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind != "command")
        {
            return None;
        }
        status_line
            .get("command")
            .and_then(Value::as_str)
            .filter(|command| !command.trim().is_empty())
    }

    fn relay(&self, user: &Map<String, Value>, relay_command: &str) -> Value {
        let mut setting = user.clone();
        setting.insert("command".to_owned(), Value::from(relay_command));
        Value::Object(setting)
    }
}

fn is_relay(status_line: &Value) -> bool {
    status_line
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| command.trim_end().ends_with(RELAY_ARGUMENTS))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::UNIX_EPOCH;

    #[test]
    fn the_gemini_bucket_reads_as_the_weekly_window_used() {
        let input = br#"{"quota":{"3p-weekly":{"remaining_fraction":1},"gemini-weekly":{"remaining_fraction":0.75,"reset_time":"2026-11-08T04:03:03Z"}}}"#;
        let usage = AntigravityStatusLine
            .plan_usage(input, UNIX_EPOCH)
            .expect("usage");
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].kind, PlanUsageWindow::SEVEN_DAY);
        assert!((usage.windows[0].used_percent - 25.0).abs() < f64::EPSILON);
        assert_eq!(
            usage.windows[0].resets_at.as_deref(),
            Some("2026-11-08T04:03:03Z")
        );
    }

    #[test]
    fn input_before_the_first_answer_reports_no_usage() {
        assert!(
            AntigravityStatusLine
                .plan_usage(br#"{"model":null}"#, UNIX_EPOCH)
                .is_none()
        );
    }

    #[test]
    fn our_own_relay_is_never_the_persons_status_line() {
        let layer = serde_json::json!({"statusLine":{"type":"command","command":"/x/helper statusline antigravity"}});
        assert!(
            AntigravityStatusLine
                .user_status_line(&[Some(layer)])
                .is_none()
        );
    }
}
