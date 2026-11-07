//! Claude Code's status line: the plan usage its input carries, and where
//! the person's own status line is set.
//!
//! Claude Code runs one status line command and hands it a JSON document on
//! stdin. For Pro and Max accounts that document carries the plan's usage as
//! `rate_limits.five_hour` and `rate_limits.seven_day`, each with
//! `used_percentage` (0 to 100) and `resets_at` (epoch seconds), once the
//! session's first answer has come back
//! (<https://code.claude.com/docs/en/statusline>). It is the one documented
//! place the plan's usage is given out. So when the person has a status line,
//! the shim puts our relay in its slot, and the relay runs theirs after it
//! has read the usage; `user_status_line` decides which one is theirs the way
//! Claude Code would have, from only the settings Claude Code reads for that
//! launch (`settings_sources`).

use crate::project_settings::project_files;
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use weir_agent_model::{
    LaunchVariables, PlanUsage, PlanUsageWindow, SettingsFiles, SettingsSource, StatusLineAdapter,
    format_utc_seconds, parse_object,
};

/// The largest status line input we read. Claude Code's document is a few
/// kilobytes; the bound keeps a runaway one from being held in memory.
const MAX_STATUS_LINE_INPUT_BYTES: usize = 1024 * 1024;

/// The arguments our relay takes after the helper's path, as the shim writes
/// them and `rust/fixtures/contract/shared-values.json` pins. A status line
/// whose command ends with them is ours, which a person's settings can carry
/// only by copying it, and running it would run itself.
pub const RELAY_ARGUMENTS: &str = "statusline claude";

/// The variable the shim moves a person's own `--settings` value into, since
/// its flag has to carry ours.
pub const LAUNCH_SETTINGS_VARIABLE: &str = "WEIR_CLAUDE_USER_SETTINGS";

/// The variable the shim writes the launch's setting sources into, as
/// `rust/fixtures/contract/shared-values.json` pins it: one line per value,
/// the first `user,project,local` (Claude Code's own default), then each
/// `--setting-sources` value the arguments hold, and an empty line for
/// `--restricted`, which loads none of the three files. The launch reads the
/// sources every line names (`LoadedSources::from_launch`). The relay's own
/// command sets it again, to the one value those lines come to (`relay`).
pub const SETTING_SOURCES_VARIABLE: &str = "WEIR_CLAUDE_SETTING_SOURCES";

/// The settings files a Claude Code launch reads, besides the managed
/// settings and `--settings`, which it always reads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct LoadedSources {
    user: bool,
    project: bool,
    local: bool,
}

impl LoadedSources {
    const NONE: Self = Self {
        user: false,
        project: false,
        local: false,
    };

    /// The sources one `--setting-sources` value names, read as Claude Code
    /// 2.1.319 reads it: names split at commas with the blanks around each
    /// trimmed, matched exactly, and an empty value naming none. `None` for a
    /// value Claude Code refuses to start with (an unknown or empty name).
    fn from_flag(value: &str) -> Option<Self> {
        let mut sources = Self::NONE;
        if value.is_empty() {
            return Some(sources);
        }
        for name in value.split(',') {
            match name.trim() {
                "user" => sources.user = true,
                "project" => sources.project = true,
                "local" => sources.local = true,
                _ => return None,
            }
        }
        Some(sources)
    }

    /// The sources as one `--setting-sources` value names them, in Claude
    /// Code's order: plain words and commas, which need no quoting in a
    /// shell command.
    fn flag_value(self) -> String {
        [
            (self.user, "user"),
            (self.project, "project"),
            (self.local, "local"),
        ]
        .into_iter()
        .filter_map(|(loaded, name)| loaded.then_some(name))
        .collect::<Vec<_>>()
        .join(",")
    }

    /// The sources a launch reads, from what the shim wrote into
    /// `SETTING_SOURCES_VARIABLE`: those every line names. Claude Code takes
    /// the last `--setting-sources` and the shim cannot always tell a flag
    /// from another option's value, so taking the sources all of them name
    /// never reads one the launch does not. With the variable unset, or a
    /// line Claude Code would refuse, the launch cannot be read and none is.
    fn from_launch(value: Option<&str>) -> Self {
        let Some(value) = value else {
            return Self::NONE;
        };
        value
            .split('\n')
            .try_fold(
                Self {
                    user: true,
                    project: true,
                    local: true,
                },
                |loaded, line| {
                    let named = Self::from_flag(line)?;
                    Some(Self {
                        user: loaded.user && named.user,
                        project: loaded.project && named.project,
                        local: loaded.local && named.local,
                    })
                },
            )
            .unwrap_or(Self::NONE)
    }
}

/// Claude Code's status line.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct ClaudeStatusLine;

impl StatusLineAdapter for ClaudeStatusLine {
    fn plan_usage(&self, input: &[u8], now: SystemTime) -> Option<PlanUsage> {
        let object = parse_object(input, MAX_STATUS_LINE_INPUT_BYTES).ok()?;
        let limits = object.get("rate_limits")?.as_object()?;
        // In window order rather than the document's, so the shorter window
        // reads first wherever the record is shown.
        let windows: Vec<PlanUsageWindow> =
            [PlanUsageWindow::FIVE_HOUR, PlanUsageWindow::SEVEN_DAY]
                .into_iter()
                .filter_map(|kind| window(kind, limits.get(kind)?))
                .collect();
        if windows.is_empty() {
            return None;
        }
        Some(PlanUsage {
            windows,
            reset_credits: None,
            observed_at: format_utc_seconds(now),
        })
    }

    /// The project directory the input names, else its working directory.
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

    /// Claude Code's settings precedence
    /// (<https://code.claude.com/docs/en/settings#settings-precedence>):
    /// managed, the launch's `--settings`, the project's local and shared
    /// files where Claude Code keeps them (`project_settings`), then the user
    /// file in the configuration directory, which `CLAUDE_CONFIG_DIR` moves.
    /// The three kinds of file only as far as the launch
    /// loads them (`--setting-sources`, `--restricted`), which the shim
    /// writes into `SETTING_SOURCES_VARIABLE`; managed settings and
    /// `--settings` are read whatever those say.
    fn settings_sources(
        &self,
        project: Option<&Path>,
        launch: &LaunchVariables<'_>,
        files: &dyn SettingsFiles,
    ) -> Vec<SettingsSource> {
        let loaded = LoadedSources::from_launch(launch(SETTING_SOURCES_VARIABLE));
        let mut sources = vec![
            SettingsSource::File(managed_settings_path()),
            SettingsSource::LaunchVariable(LAUNCH_SETTINGS_VARIABLE),
        ];
        if let Some(project) = project.filter(|_| loaded.local || loaded.project) {
            let project = project_files(project, files);
            if loaded.local {
                sources.extend(project.local.into_iter().map(SettingsSource::File));
            }
            if loaded.project {
                sources.extend(project.shared.map(SettingsSource::File));
            }
        }
        if loaded.user {
            sources.push(SettingsSource::HomeFile("settings.json"));
        }
        sources
    }

    /// The status line of the highest layer that sets one, as Claude Code
    /// takes a setting from the highest layer that has it. `None` when that
    /// one is not a command: Claude Code then runs none either. A layer whose
    /// status line is our relay is passed over, so a copied relay cannot
    /// call itself.
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
        if status_line.get("type").and_then(Value::as_str) != Some("command") {
            return None;
        }
        status_line
            .get("command")
            .and_then(Value::as_str)
            .filter(|command| !command.trim().is_empty())
    }

    /// Their setting with our command, so the options they chose (`padding`)
    /// still apply to what they see. The command sets
    /// `SETTING_SOURCES_VARIABLE` to the sources this launch loads before it
    /// starts the relay: a settings file's `env` block reaches the status
    /// line's environment too, and one the launch loads could otherwise name
    /// a file it does not. `--settings`, which carries this command, outranks
    /// every file but managed settings.
    fn relay(
        &self,
        user: &Map<String, Value>,
        relay_command: &str,
        launch: &LaunchVariables<'_>,
    ) -> Value {
        let loaded = LoadedSources::from_launch(launch(SETTING_SOURCES_VARIABLE));
        let command = format!(
            "{SETTING_SOURCES_VARIABLE}={} {relay_command}",
            loaded.flag_value()
        );
        let mut setting = user.clone();
        setting.insert("command".to_owned(), Value::from(command));
        Value::Object(setting)
    }
}

/// Whether a status line setting is our relay.
fn is_relay(status_line: &Value) -> bool {
    status_line
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| command.trim_end().ends_with(RELAY_ARGUMENTS))
}

fn window(kind: &str, value: &Value) -> Option<PlanUsageWindow> {
    let value = value.as_object()?;
    let used_percent = value.get("used_percentage")?.as_f64()?;
    if !used_percent.is_finite() {
        return None;
    }
    let resets_at = value
        .get("resets_at")
        .and_then(Value::as_u64)
        .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
        .map(format_utc_seconds);
    Some(PlanUsageWindow {
        kind: kind.to_owned(),
        used_percent,
        resets_at,
    })
}

/// The managed settings file of this system
/// (<https://code.claude.com/docs/en/settings#settings-files>). Only the
/// file: a status line set through drop-in files beside it or a device
/// management profile is not seen, and the person's own is run instead.
fn managed_settings_path() -> PathBuf {
    if cfg!(target_os = "macos") {
        PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json")
    } else if cfg!(windows) {
        PathBuf::from(r"C:\Program Files\ClaudeCode\managed-settings.json")
    } else {
        PathBuf::from("/etc/claude-code/managed-settings.json")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    #[test]
    fn plan_usage_reads_both_windows_in_window_order() {
        let input = json!({
            "rate_limits": {
                "seven_day": { "used_percentage": 83, "resets_at": 1_793_822_400_u64 },
                "five_hour": { "used_percentage": 42.5, "resets_at": 1_793_247_600_u64 }
            }
        })
        .to_string();
        let usage = ClaudeStatusLine
            .plan_usage(input.as_bytes(), at(1_793_240_000))
            .expect("usage");
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].kind, "five_hour");
        assert!((usage.windows[0].used_percent - 42.5).abs() < f64::EPSILON);
        assert_eq!(
            usage.windows[0].resets_at.as_deref(),
            Some("2026-10-29T04:20:00Z")
        );
        assert_eq!(usage.windows[1].kind, "seven_day");
        assert_eq!(usage.observed_at, "2026-10-29T02:13:20Z");
    }

    #[test]
    fn plan_usage_keeps_the_window_that_is_still_reported() {
        // Claude Code drops a window from the document once it has reset.
        let input = json!({ "rate_limits": { "seven_day": { "used_percentage": 4 } } }).to_string();
        let usage = ClaudeStatusLine
            .plan_usage(input.as_bytes(), at(0))
            .expect("usage");
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].kind, "seven_day");
        assert_eq!(usage.windows[0].resets_at, None);
    }

    #[test]
    fn an_unrepresentable_reset_keeps_usage_and_the_other_window() {
        let input = json!({
            "rate_limits": {
                "seven_day": { "used_percentage": 83, "resets_at": u64::MAX },
                "five_hour": { "used_percentage": 42.5, "resets_at": 1_793_247_600_u64 }
            }
        });
        let usage = ClaudeStatusLine
            .plan_usage(input.to_string().as_bytes(), at(1_793_240_000))
            .expect("usage");
        assert_eq!(
            usage.windows,
            vec![
                PlanUsageWindow {
                    kind: "five_hour".into(),
                    used_percent: 42.5,
                    resets_at: Some("2026-10-29T04:20:00Z".into()),
                },
                PlanUsageWindow {
                    kind: "seven_day".into(),
                    used_percent: 83.0,
                    resets_at: None,
                },
            ]
        );
    }

    #[test]
    fn plan_usage_is_none_without_rate_limits() {
        for input in [
            json!({ "model": { "display_name": "Opus" } }).to_string(),
            json!({ "rate_limits": {} }).to_string(),
            json!({ "rate_limits": { "five_hour": { "resets_at": 1 } } }).to_string(),
            "not json".to_owned(),
        ] {
            assert_eq!(
                ClaudeStatusLine.plan_usage(input.as_bytes(), at(0)),
                None,
                "{input}"
            );
        }
    }

    #[test]
    fn project_directory_prefers_the_project_over_the_working_directory() {
        let input = json!({ "cwd": "/w/sub", "workspace": { "project_dir": "/w" } }).to_string();
        assert_eq!(
            ClaudeStatusLine.project_directory(input.as_bytes()),
            Some(PathBuf::from("/w"))
        );
        let input = json!({ "cwd": "/w/sub" }).to_string();
        assert_eq!(
            ClaudeStatusLine.project_directory(input.as_bytes()),
            Some(PathBuf::from("/w/sub"))
        );
    }

    /// The sources for a launch whose shim wrote `value`.
    fn sources(project: Option<&Path>, value: Option<&str>) -> Vec<SettingsSource> {
        ClaudeStatusLine.settings_sources(
            project,
            &|name| {
                (name == SETTING_SOURCES_VARIABLE)
                    .then_some(value)
                    .flatten()
            },
            &NoRepository,
        )
    }

    /// A file system with no Git repository anywhere, so both project files
    /// are in the project folder (`project_settings` covers the rest).
    struct NoRepository;

    impl SettingsFiles for NoRepository {
        fn entry(&self, _path: &Path) -> Option<weir_agent_model::FileEntry> {
            None
        }
        fn target(&self, _path: &Path) -> Option<weir_agent_model::FileEntry> {
            None
        }
        fn real_path(&self, _path: &Path) -> Option<PathBuf> {
            None
        }
        fn read_text(&self, _path: &Path) -> Option<String> {
            None
        }
        fn user_id(&self) -> Option<u32> {
            Some(501)
        }
        fn home(&self) -> Option<PathBuf> {
            None
        }
    }

    // Built by joining, and compared as paths rather than as text, so the
    // tests hold whatever separator the platform writes.
    fn local() -> SettingsSource {
        SettingsSource::File(Path::new("/w").join(".claude").join("settings.local.json"))
    }

    fn shared() -> SettingsSource {
        SettingsSource::File(Path::new("/w").join(".claude").join("settings.json"))
    }

    const USER: SettingsSource = SettingsSource::HomeFile("settings.json");

    #[test]
    fn settings_sources_follow_claude_precedence() {
        let listed = sources(Some(Path::new("/w")), Some("user,project,local"));
        assert_eq!(
            listed[1..],
            [
                SettingsSource::LaunchVariable(LAUNCH_SETTINGS_VARIABLE),
                local(),
                shared(),
                USER,
            ]
        );
        assert_eq!(sources(None, Some("user,project,local")).len(), 3);
    }

    /// `claude --setting-sources user` reads no project file, so its
    /// status line command must not run either (`--restricted` reads none of
    /// the three files).
    #[test]
    fn settings_sources_keep_only_what_the_launch_loads() {
        let project = Some(Path::new("/w"));
        let default = "user,project,local";
        for (value, expected) in [
            (format!("{default}\nuser"), vec![USER]),
            (
                format!("{default}\n project , local"),
                vec![local(), shared()],
            ),
            (format!("{default}\nlocal"), vec![local()]),
            (format!("{default}\n"), vec![]),
            (format!("{default}\nuser\n"), vec![]),
        ] {
            assert_eq!(sources(project, Some(&value))[2..], expected, "{value:?}");
        }
    }

    /// The shim writes every value it saw, since Claude Code takes the last
    /// and the shim may take another option's value for a flag. Only what
    /// all of them name is read, which is never more than the last names.
    #[test]
    fn settings_sources_take_what_every_value_names() {
        let value = "user,project,local\nuser,project\nproject,local";
        assert_eq!(sources(Some(Path::new("/w")), Some(value))[2..], [shared()]);
    }

    /// Without the shim's word, or with a value Claude Code would not start
    /// with, Weir cannot tell which files the launch reads, so it reads none
    /// of them: only managed settings and `--settings`, which every launch
    /// reads.
    #[test]
    fn settings_sources_fail_closed_on_a_launch_they_cannot_read() {
        let project = Some(Path::new("/w"));
        for value in [
            None,
            Some("user,project,local\nbogus"),
            Some("user,project,local\nUser"),
            Some("user,project,local\nuser,"),
            Some("user,project,local\n "),
            Some("nonsense"),
        ] {
            assert_eq!(
                sources(project, value),
                [
                    SettingsSource::File(managed_settings_path()),
                    SettingsSource::LaunchVariable(LAUNCH_SETTINGS_VARIABLE),
                ],
                "{value:?}"
            );
        }
    }

    #[test]
    fn a_flag_value_is_read_as_claude_code_reads_it() {
        let all = LoadedSources {
            user: true,
            project: true,
            local: true,
        };
        assert_eq!(LoadedSources::from_flag("user,project,local"), Some(all));
        assert_eq!(
            LoadedSources::from_flag(" local ,user"),
            Some(LoadedSources {
                user: true,
                project: false,
                local: true
            })
        );
        assert_eq!(LoadedSources::from_flag(""), Some(LoadedSources::NONE));
        for refused in ["bogus", "USER", "user,,local", "user,", " ", "-p"] {
            assert_eq!(LoadedSources::from_flag(refused), None, "{refused:?}");
        }
    }

    #[test]
    fn user_status_line_takes_the_highest_layer_that_sets_a_command() {
        let user =
            json!({ "statusLine": { "type": "command", "command": "user.sh", "padding": 0 } });
        let project = json!({ "statusLine": { "type": "command", "command": "project.sh" } });
        let layers = [None, None, None, Some(project), Some(user)];
        let chosen = ClaudeStatusLine
            .user_status_line(&layers)
            .expect("a status line");
        assert_eq!(ClaudeStatusLine.command(&chosen), Some("project.sh"));
    }

    #[test]
    fn user_status_line_skips_layers_that_set_none() {
        let layers = [
            None,
            Some(json!({ "permissions": {} })),
            Some(json!({ "statusLine": { "type": "command", "command": "user.sh" } })),
        ];
        let chosen = ClaudeStatusLine
            .user_status_line(&layers)
            .expect("a status line");
        assert_eq!(ClaudeStatusLine.command(&chosen), Some("user.sh"));
        assert_eq!(
            ClaudeStatusLine.user_status_line(&[None, Some(json!({}))]),
            None
        );
    }

    #[test]
    fn user_status_line_is_none_when_the_highest_one_is_not_a_command() {
        // The higher layer's setting is the one Claude Code takes, so the
        // lower command does not run there either.
        for higher in [
            json!({ "statusLine": { "type": "command", "command": "  " } }),
            json!({ "statusLine": "nonsense" }),
        ] {
            let lower = json!({ "statusLine": { "type": "command", "command": "user.sh" } });
            assert_eq!(
                ClaudeStatusLine.user_status_line(&[Some(higher.clone()), Some(lower)]),
                None,
                "{higher}"
            );
        }
    }

    #[test]
    fn user_status_line_never_picks_our_own_relay() {
        let relay = json!({ "statusLine": { "type": "command",
            "command": format!("/tmp/x/AgentIntegrationHookHelper {RELAY_ARGUMENTS}") } });
        let user = json!({ "statusLine": { "type": "command", "command": "user.sh" } });
        assert_eq!(
            ClaudeStatusLine.user_status_line(&[Some(relay.clone())]),
            None
        );
        let chosen = ClaudeStatusLine
            .user_status_line(&[Some(relay), Some(user)])
            .expect("the person's own below the copied relay");
        assert_eq!(ClaudeStatusLine.command(&chosen), Some("user.sh"));
    }

    /// The shim writes the arguments and the app's tests check its output
    /// against the same file, so the three agree on what our relay is.
    #[test]
    fn the_relay_arguments_are_the_ones_the_shim_writes() {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/contract/shared-values.json");
        let shared: Value =
            serde_json::from_slice(&std::fs::read(path).expect("the shared values file"))
                .expect("the shared values decode");
        assert_eq!(
            shared["claudeStatusLineRelayArguments"].as_str(),
            Some(RELAY_ARGUMENTS)
        );
        assert_eq!(
            shared["claudeSettingSourcesVariable"].as_str(),
            Some(SETTING_SOURCES_VARIABLE)
        );
    }

    #[test]
    fn relay_keeps_the_person_s_options() {
        let user = json!({ "type": "command", "command": "user.sh", "padding": 0 });
        let relay = ClaudeStatusLine.relay(
            user.as_object().expect("object"),
            "/h statusline claude",
            &|_| Some("user,project,local"),
        );
        assert_eq!(
            relay,
            json!({ "type": "command",
                "command": format!("{SETTING_SOURCES_VARIABLE}=user,project,local /h statusline claude"),
                "padding": 0 })
        );
        assert!(is_relay(&relay));
    }

    /// The relay's command names the sources the launch loads itself, so
    /// an `env` block in a settings file the launch loads cannot widen them.
    #[test]
    fn relay_names_the_sources_the_launch_loads() {
        let user = json!({ "type": "command", "command": "user.sh" });
        for (value, named) in [
            (Some("user,project,local\nuser"), "user"),
            (Some("user,project,local\n local,project"), "project,local"),
            (Some("user,project,local\n"), ""),
            (None, ""),
        ] {
            let relay = ClaudeStatusLine.relay(
                user.as_object().expect("object"),
                "/h statusline claude",
                &|_| value,
            );
            assert_eq!(
                relay["command"],
                format!("{SETTING_SOURCES_VARIABLE}={named} /h statusline claude"),
                "{value:?}"
            );
        }
    }
}
