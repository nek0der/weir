//! Detection of `git worktree add` in a shell command the agent is about to
//! run. Both providers hand the Bash tool the same command string, so the
//! parse is provider-neutral; what a provider adds is only where the command
//! sits in its payload.

use crate::{MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderOutput, parse_object};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A `git worktree add -b <branch> …` the agent asked its shell tool to run.
/// The hook runtime may point it at the folder the project's placement rules
/// say, and finishes the worktree's setup once the command has run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeIntent {
    /// The full command line as the agent wrote it.
    pub command: String,
    /// The branch named by `-b`, `-B`, or `--branch=`.
    pub branch: String,
    /// The agent's working directory when it issued the command.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
}

impl WorktreeIntent {
    /// Reads the intent out of a `PreToolUse` hook payload in the shape
    /// Claude Code defined and Codex adopted: `tool_name` names the shell
    /// tool and `tool_input.command` carries the command line. Providers
    /// with that payload shape delegate here; others parse their own.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    pub fn from_hook_payload(
        bytes: &[u8],
        shell_tool: &str,
    ) -> Result<Option<Self>, NormalizeError> {
        Self::from_event_payload(bytes, shell_tool, "PreToolUse")
    }

    /// As `from_hook_payload`, for the `PostToolUse` of the same tool: the
    /// command the agent's shell tool ran, rewritten or not.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    pub fn from_finished_hook_payload(
        bytes: &[u8],
        shell_tool: &str,
    ) -> Result<Option<Self>, NormalizeError> {
        Self::from_event_payload(bytes, shell_tool, "PostToolUse")
    }

    fn from_event_payload(
        bytes: &[u8],
        shell_tool: &str,
        event: &str,
    ) -> Result<Option<Self>, NormalizeError> {
        let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
        let string = |key: &str| object.get(key).and_then(Value::as_str);
        if string("hook_event_name") != Some(event) || string("tool_name") != Some(shell_tool) {
            return Ok(None);
        }
        let Some(command) = object
            .get("tool_input")
            .and_then(|tool_input| tool_input.get("command"))
            .and_then(Value::as_str)
        else {
            return Ok(None);
        };
        Ok(Self::parse(command, string("cwd")))
    }

    /// Parses `command` the way the shell intercept did: the command must
    /// start with `git`, reach `worktree add` before any `|`, `;`, or `&`,
    /// and name a branch. Anything else is not an intent, because renaming a
    /// worktree on the agent's behalf would be noisier than letting the
    /// original command run.
    #[must_use]
    pub fn parse(command: &str, cwd: Option<&str>) -> Option<Self> {
        let tokens: Vec<&str> = command.split_whitespace().collect();
        if tokens.first() != Some(&"git") {
            return None;
        }
        let mut after_add = false;
        let mut previous = "";
        let mut branch: Option<&str> = None;
        for token in &tokens[1..] {
            if !after_add {
                if token.contains(['|', ';', '&']) {
                    return None;
                }
                if previous == "worktree" && *token == "add" {
                    after_add = true;
                }
                previous = token;
                continue;
            }
            match *token {
                "-b" | "-B" => previous = token,
                _ if token.starts_with("--branch=") => {
                    branch = Some(&token["--branch=".len()..]);
                    previous = "";
                }
                _ if token.starts_with('-') => previous = "",
                _ => {
                    if previous == "-b" || previous == "-B" {
                        branch = Some(token);
                    }
                    previous = "";
                }
            }
        }
        let branch = branch.filter(|value| !value.is_empty())?;
        after_add.then(|| Self {
            command: command.to_owned(),
            branch: branch.to_owned(),
            cwd: cwd.map(str::to_owned),
        })
    }

    /// The `-C` folders the command starts Git in, in order. `None` when it says
    /// anything else before `worktree`: `-c alias.x=!...` runs a command of its
    /// own, so nothing here is ever handed to Git to find out what it means.
    #[must_use]
    pub fn git_directories(&self) -> Option<Vec<&str>> {
        let mut tokens = self.command.split_whitespace().skip(1);
        let mut directories = Vec::new();
        loop {
            match tokens.next()? {
                "worktree" => return Some(directories),
                "-C" => directories.push(tokens.next()?),
                _ => return None,
            }
        }
    }

    /// Whether the command asks for a worktree with no files checked out. The
    /// last of `--checkout` and `--no-checkout` is the one Git obeys.
    #[must_use]
    pub fn skips_checkout(&self) -> bool {
        self.command
            .split_whitespace()
            .rev()
            .find(|token| matches!(*token, "--checkout" | "--no-checkout"))
            == Some("--no-checkout")
    }

    /// The command with its folder replaced by `quoted_path`, already quoted
    /// for a shell, and everything else as the agent wrote it, so a start point
    /// the agent named still counts. `None` for a command we cannot be sure of:
    /// one with shell syntax, whose later parts may name the folder the agent
    /// asked for, or an option we do not know, whose value could pass for the
    /// folder. That command then runs as written.
    #[must_use]
    pub fn rerouted_command(&self, quoted_path: &str) -> Option<String> {
        const SHELL_SYNTAX: &[char] = &[
            ';', '|', '&', '<', '>', '`', '$', '\'', '"', '\\', '(', ')', '\n', '*', '?', '#', '~',
        ];
        if self.command.contains(SHELL_SYNTAX) {
            return None;
        }
        let mut tokens: Vec<&str> = self.command.split_whitespace().collect();
        // Found as a pair, as `parse` does: `git -C add worktree add` has an
        // `add` that is a folder.
        let add = tokens
            .windows(2)
            .position(|pair| pair == ["worktree", "add"])?
            + 1;
        let mut takes_value = false;
        let mut folder = None;
        for (index, token) in tokens.iter().enumerate().skip(add + 1) {
            if takes_value {
                takes_value = false;
            } else if matches!(*token, "-b" | "-B") {
                takes_value = true;
            } else if token.starts_with('-') {
                let known = token.starts_with("--branch=")
                    || matches!(
                        *token,
                        "-f" | "--force"
                            | "-q"
                            | "--quiet"
                            | "--lock"
                            | "--checkout"
                            | "--no-checkout"
                            | "--track"
                            | "--no-track"
                            | "--guess-remote"
                            | "--no-guess-remote"
                    );
                if !known {
                    return None;
                }
            } else {
                folder = Some(index);
                break;
            }
        }
        tokens[folder?] = quoted_path;
        Some(tokens.join(" "))
    }
}

/// The `PreToolUse` reply that gives the tool `command` in place of the one it
/// was going to run, in the shape Claude Code defined and Codex adopted. The
/// rest of the tool's input is kept. `decision` is what the provider needs
/// beside the new input (see each adapter). `None` when the payload has no tool
/// input to change.
#[must_use]
pub fn rerouted_hook_output(
    bytes: &[u8],
    command: &str,
    decision: Option<&str>,
) -> Option<ProviderOutput> {
    let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    let mut tool_input = object.get("tool_input")?.as_object()?.clone();
    tool_input.insert("command".to_owned(), Value::from(command));
    let mut output = serde_json::Map::new();
    output.insert("hookEventName".to_owned(), Value::from("PreToolUse"));
    if let Some(decision) = decision {
        output.insert("permissionDecision".to_owned(), Value::from(decision));
    }
    output.insert("updatedInput".to_owned(), Value::Object(tool_input));
    Some(ProviderOutput {
        stdout: Some(
            serde_json::json!({ "hookSpecificOutput": output })
                .to_string()
                .into_bytes(),
        ),
    })
}

/// The `PostToolUse` reply that tells the model `message`, in the same shape.
/// The output of `git worktree add` does not name the folder, so without this
/// the model would go on believing the one it asked for.
#[must_use]
pub fn finished_hook_output(message: &str) -> ProviderOutput {
    ProviderOutput {
        stdout: Some(
            serde_json::json!({
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": message,
                }
            })
            .to_string()
            .into_bytes(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_branch_flags_in_every_spelling() {
        for command in [
            "git worktree add -b demo ../demo",
            "  git -C repo worktree add ../demo -B demo",
            "git worktree add --branch=demo ../demo && git worktree list",
        ] {
            let intent = WorktreeIntent::parse(command, Some("/repo")).expect(command);
            assert_eq!(intent.branch, "demo");
            assert_eq!(intent.cwd.as_deref(), Some("/repo"));
        }
    }

    #[test]
    fn a_rerouted_command_changes_only_the_folder() {
        for (command, expected) in [
            (
                "git worktree add -b demo ../demo",
                "git worktree add -b demo /to",
            ),
            (
                "git worktree add ../demo -b demo",
                "git worktree add /to -b demo",
            ),
            (
                "git -C add worktree add -b demo ../demo",
                "git -C add worktree add -b demo /to",
            ),
            (
                "git -C repo worktree add -b demo ../demo origin/main",
                "git -C repo worktree add -b demo /to origin/main",
            ),
            (
                "git worktree add -f --no-track -B demo ../demo main",
                "git worktree add -f --no-track -B demo /to main",
            ),
        ] {
            let intent = WorktreeIntent::parse(command, None).expect(command);
            assert_eq!(intent.rerouted_command("/to").as_deref(), Some(expected));
        }
    }

    #[test]
    fn a_command_we_cannot_be_sure_of_is_not_rerouted() {
        for command in [
            "git worktree add -b demo ../demo && cd ../demo",
            "git worktree add -b demo '../my demo'",
            "git worktree add -b demo $HOME/demo",
            "git worktree add -b demo ~/demo",
            "git worktree add --reason why --lock -b demo ../demo",
            "git worktree add -b demo",
        ] {
            let intent = WorktreeIntent::parse(command, None).expect(command);
            assert_eq!(intent.rerouted_command("/to"), None, "{command}");
        }
    }

    #[test]
    fn only_a_folder_counts_before_worktree() {
        let directories = |command: &str| {
            WorktreeIntent::parse(command, None)
                .expect(command)
                .git_directories()
                .map(|found| found.join(" "))
        };
        assert_eq!(directories("git worktree add -b d x").as_deref(), Some(""));
        assert_eq!(
            directories("git -C a -C worktree worktree add -b d x").as_deref(),
            Some("a worktree")
        );
        for command in [
            "git -c alias.x=!touch${IFS}y x worktree add -b d x",
            "git --git-dir=../o/.git worktree add -b d x",
            "git --git-dir ../o/.git worktree add -b d x",
        ] {
            assert_eq!(directories(command), None, "{command}");
        }
    }

    #[test]
    fn a_rerouted_reply_keeps_the_rest_of_the_input() {
        let payload = br#"{"tool_input":{"command":"old","description":"keep"}}"#;
        let output = rerouted_hook_output(payload, "new", None).expect("output");
        let reply: Value = serde_json::from_slice(&output.stdout.expect("stdout")).expect("json");
        let inner = &reply["hookSpecificOutput"];
        assert_eq!(inner["updatedInput"]["command"], "new");
        assert_eq!(inner["updatedInput"]["description"], "keep");
        assert!(inner.get("permissionDecision").is_none());
    }

    #[test]
    fn ignores_commands_that_are_not_a_worktree_add() {
        for command in [
            "git worktree list",
            "git worktree add ../demo",
            "ls | git worktree add -b demo ../demo",
            "echo git worktree add -b demo x",
            "git status; git worktree add -b demo ../demo",
        ] {
            assert_eq!(WorktreeIntent::parse(command, None), None, "{command}");
        }
    }
}
