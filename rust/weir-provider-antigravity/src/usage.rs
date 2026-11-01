//! Reads the usage limit a failed turn hit from the words of its failure.
//!
//! `Stop` carries the error as text and nothing else about it. The words a
//! limit uses come from `agy`'s binary and a 429 we relayed ourselves (agy
//! 1.4.12); no real limit has been read yet. So only words that say the quota
//! ran out count, and what is not read leaves an ordinary failure, or a limit
//! with no time.

use std::time::{Duration, SystemTime};
use weir_agent_model::{UsageLimit, format_utc_seconds};

/// How `agy` says a quota ran out, in lower case.
const LIMIT_WORDS: [&str; 4] = [
    "exhausted your quota",
    "exhausted your capacity",
    "individual quota reached",
    "out of quota",
];

/// The limit `error` names, whose reset is counted from `now`. A bare
/// `RESOURCE_EXHAUSTED` or 429 may be a passing rate limit, and
/// `MODEL_CAPACITY_EXHAUSTED` is the server short of capacity, so neither has
/// a reset to wait for.
pub(crate) fn usage_limit(error: &str, now: SystemTime) -> Option<UsageLimit> {
    let message = error.to_lowercase();
    if message.contains("model_capacity_exhausted")
        || !LIMIT_WORDS.iter().any(|words| message.contains(words))
    {
        return None;
    }
    Some(UsageLimit {
        resets_at: reset_delay(&message)
            .and_then(|delay| now.checked_add(delay))
            .map(format_utc_seconds),
        window: None,
    })
}

/// The delay in "reset after 3h0m0s", which is a Go duration. `None` for any
/// other form, so a misread time never stands in for the real one.
fn reset_delay(error: &str) -> Option<Duration> {
    let message = error.to_lowercase();
    let (_, rest) = message.split_once("reset after ")?;
    let token = rest
        .split(|character: char| !character.is_ascii_alphanumeric() && character != '.')
        .next()?
        .trim_end_matches('.');
    let mut seconds = 0_u64;
    let mut left = token;
    while !left.is_empty() {
        let end = left.find(|character: char| !character.is_ascii_digit() && character != '.')?;
        let (number, tail) = left.split_at(end);
        let mut units = tail.chars();
        let unit = match units.next()? {
            'h' => 3_600,
            'm' => 60,
            's' => 1,
            _ => return None,
        };
        // Only the seconds of a Go duration carry a fraction, too small to
        // matter to a reset.
        let whole = match number.split_once('.') {
            Some((whole, _)) if unit == 1 => whole,
            Some(_) => return None,
            None => number,
        };
        let part = whole.parse::<u64>().ok()?.checked_mul(unit)?;
        seconds = seconds.checked_add(part)?;
        left = units.as_str();
    }
    (!token.is_empty()).then(|| Duration::from_secs(seconds))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::UNIX_EPOCH;

    fn at() -> SystemTime {
        UNIX_EPOCH + Duration::from_hours(497_598)
    }

    #[test]
    fn words_of_the_persons_quota_are_a_limit_with_the_reset_they_name() {
        let limit = usage_limit(
            "generating and executing: RESOURCE_EXHAUSTED (code 429): You have exhausted your capacity on this model. Your quota will reset after 3h0m0s.",
            at(),
        )
        .expect("a limit");
        assert_eq!(limit.resets_at.as_deref(), Some("2026-10-07T09:00:00Z"));
        assert_eq!(limit.window, None);
    }

    #[test]
    fn each_form_agy_uses_for_its_quota_is_a_limit() {
        for error in [
            "You have exhausted your quota on this model.",
            "individual quota reached",
            "model gemini-3.8 is out of quota until tomorrow",
        ] {
            assert!(usage_limit(error, at()).is_some(), "{error}");
        }
    }

    #[test]
    fn a_limit_whose_time_cannot_be_read_has_no_time() {
        for error in [
            "You have exhausted your quota on this model.",
            "You have exhausted your quota. Your quota will reset after soon.",
            "You have exhausted your quota. Your quota will reset after 500ms.",
            "You have exhausted your quota. Your quota will reset after 3h0x.",
            "You have exhausted your quota. Your quota will reset after 99999999999999999999h.",
        ] {
            assert_eq!(
                usage_limit(error, at()),
                Some(UsageLimit::default()),
                "{error}"
            );
        }
    }

    #[test]
    fn a_reset_reads_each_part_of_the_duration() {
        for (delay, seconds) in [("45s", 45), ("2m", 120), ("1h2m3s", 3_723), ("1m30.5s", 90)] {
            let error = format!("You have exhausted your quota. Reset after {delay}.");
            assert_eq!(
                reset_delay(&error),
                Some(Duration::from_secs(seconds)),
                "{error}"
            );
        }
    }

    #[test]
    fn other_failures_are_not_a_limit() {
        for error in [
            "generating and executing: RESOURCE_EXHAUSTED (code 429): slow down",
            "RESOURCE_EXHAUSTED (code 429): Your quota will reset after 3h0m0s.",
            "MODEL_CAPACITY_EXHAUSTED",
            "MODEL_CAPACITY_EXHAUSTED: You have exhausted your capacity on this model.",
            "connection reset by peer",
        ] {
            assert_eq!(usage_limit(error, at()), None, "{error}");
        }
    }
}
