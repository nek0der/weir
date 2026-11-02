//! The model a session runs, how hard it reasons, and how freely it may act,
//! as the provider reports them.
//!
//! Both agents say the model and the mode on most hook calls: Codex sends `model` and
//! `permission_mode` on nearly every event, and Claude sends
//! `permission_mode` on most events and the model on `SessionStart` and
//! `PostModelSwitch`. Neither sends a hook when the person changes the mode
//! between turns, so a change shows with the next call that carries it.
//!
//! Claude says no model on the `SessionStart` of a resumed session, so we read
//! one from its transcript as the turn ends (`answered_model`).
//!
//! The effort comes on Claude's `effort.level`, on `PreToolUse` and `Stop`
//! among others, though not on `SessionStart` or `UserPromptSubmit`. No Codex
//! hook carries it: its rollout does (`turn_context`), which we read as a turn
//! ends, so Codex's shows from the end of the first turn.

use serde::{Deserialize, Serialize};

/// How freely the agent may act without asking, in Claude Code's words for
/// it, which Codex's hooks use too. Codex maps its approval policy onto two
/// of them: `bypassPermissions` for a policy that never asks, `default` for
/// every other.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionMode {
    /// The agent asks before each action its settings do not allow.
    Default,
    /// File edits go ahead without asking; other actions still ask.
    AcceptEdits,
    /// The agent plans and makes no change.
    Plan,
    /// A classifier decides each action, asking or stopping the risky ones.
    Auto,
    /// Actions its settings do not allow are refused rather than asked.
    DontAsk,
    /// Every action goes ahead without asking.
    BypassPermissions,
}

impl PermissionMode {
    /// The provider's `permission_mode` word; `None` for a word this build
    /// does not know, so a mode it cannot describe is not shown as another.
    #[must_use]
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "default" => Some(Self::Default),
            "acceptEdits" => Some(Self::AcceptEdits),
            "plan" => Some(Self::Plan),
            "auto" => Some(Self::Auto),
            "dontAsk" => Some(Self::DontAsk),
            "bypassPermissions" => Some(Self::BypassPermissions),
            _ => None,
        }
    }
}

/// What one hook call says of the session's settings. `None` means "not
/// said", never "cleared": the record keeps the value it has.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionSettings {
    /// The model, as the adapter names it for a person to read.
    pub model: Option<String>,
    /// The model the session's latest answer names, for a record that has
    /// none. It stays weaker than `model`, as it can lack what `model` says,
    /// such as Claude's `[1m]` for the long context window.
    pub answered_model: Option<String>,
    /// Whether the answer that names `answered_model` is not yet in the part
    /// of the transcript read: the provider may still be writing it as the
    /// hook runs, and the runtime may read the transcript again for it.
    pub is_awaiting_answer: bool,
    /// How hard the model reasons, in the provider's own word for it
    /// (`medium`, `xhigh`), which is the word its interface shows.
    ///
    /// Empty says the model is back at its default, for a provider that can
    /// change this during a session without changing the model; `None` says
    /// nothing, as for every other setting.
    pub effort: Option<String>,
    pub permission_mode: Option<PermissionMode>,
    /// Whom the provider goes through for the model, in words for a person to
    /// read (`OpenRouter`), for a CLI that is not tied to one vendor: one model
    /// name can have many routes, each with its own bill and handling of data.
    pub model_upstream: Option<String>,
    /// The role the session's agent has, in the provider's word for it, when
    /// it is one a person chose. It is not a `PermissionMode`: nothing says the
    /// role limits what the agent may do. Empty says the session is back at the
    /// provider's ordinary role.
    pub agent_profile: Option<String>,
    /// The session's name, for a provider that can say it apart from a turn.
    pub session_title: Option<String>,
    /// The launch's run this run's session shares a pane with
    /// (`RunRecord::pane_family_run_id`).
    pub pane_family_run_id: Option<String>,
    /// The run on screen now (`RunRecord::pane_shown_run_id`).
    pub pane_shown_run_id: Option<String>,
    /// Whether the screen shows no session (`RunRecord::pane_shows_home`).
    pub pane_shows_home: Option<bool>,
    /// The session of `pane_shown_run_id` and where it works, for the pane's one
    /// resume hint, which follows what is on screen.
    pub shown_session_id: Option<String>,
    pub shown_cwd: Option<String>,
}

impl SessionSettings {
    /// Whether the call says what a pane has on screen, which a person acts on: its
    /// write waits longer for a busy record, and one that is lost says so.
    #[must_use]
    pub fn reports_screen(&self) -> bool {
        self.pane_shown_run_id.is_some() || self.pane_shows_home.is_some()
    }

    /// Whether the call said nothing of any of them.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.model.is_none()
            && self.answered_model.is_none()
            && self.effort.is_none()
            && self.permission_mode.is_none()
            && self.model_upstream.is_none()
            && self.agent_profile.is_none()
            && self.session_title.is_none()
            && self.pane_family_run_id.is_none()
            && self.pane_shown_run_id.is_none()
            && self.pane_shows_home.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_word_parses_back_to_the_mode_it_is_written_as() {
        for mode in [
            PermissionMode::Default,
            PermissionMode::AcceptEdits,
            PermissionMode::Plan,
            PermissionMode::Auto,
            PermissionMode::DontAsk,
            PermissionMode::BypassPermissions,
        ] {
            let word = serde_json::to_value(mode).unwrap();
            assert_eq!(PermissionMode::parse(word.as_str().unwrap()), Some(mode));
        }
    }

    #[test]
    fn a_word_this_build_does_not_know_is_no_mode() {
        assert_eq!(PermissionMode::parse("yolo"), None);
    }
}
