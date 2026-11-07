//! The status line relay: a provider runs it as its status line, it keeps the
//! plan usage the input reports, and it names the person's own status line
//! for the helper to run in its place. What is provider-specific (the input's
//! shape, where settings live, which one wins) is the adapter's
//! (`StatusLineAdapter`); reading the files and keeping the record is ours.
//!
//! The usage is written only when it changed or the stored copy has aged past
//! `REFRESH_SECONDS`: a provider reruns its status line on every message and
//! on a timer, and the interface needs the time it was last seen, not a write
//! per redraw.

use crate::adapter_for;
use crate::env::HookEnv;
use crate::records::{atomic_write, ensure_user_only_directory};
use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use weir_agent_model::{
    FileEntry, FileKind, PlanUsage, ProviderAdapter, SettingsFiles, SettingsSource,
    StatusLineAdapter, parse_utc_seconds,
};

/// How old a stored copy may grow before an unchanged reading rewrites it,
/// so the interface's "last seen" stays within a minute of the truth.
const REFRESH_SECONDS: u64 = 60;

/// The largest settings document we read. Settings files are a few
/// kilobytes; the bound keeps a runaway one from being held in memory.
const MAX_SETTINGS_BYTES: usize = 1024 * 1024;

/// The status line command the relay runs after it has read the input, or
/// `None` when there is none to run: the person has no status line, or the
/// provider has no status line we relay.
///
/// Every failure to keep the usage is ignored: the status line the person
/// sees matters more than our copy of a number.
#[must_use]
pub fn run_status_line(
    provider: &str,
    input: &[u8],
    env: &HookEnv,
    now: SystemTime,
) -> Option<String> {
    let adapter = adapter_for(provider)?;
    let status_line = adapter.status_line()?;
    if let (Some(directory), Some(usage)) = (
        env.usage_directory(&adapter.install_recipe()),
        status_line.plan_usage(input, now),
    ) {
        keep_usage(&directory.join(format!("{provider}.json")), &usage);
    }
    let project = status_line.project_directory(input);
    let chosen = user_status_line(env, adapter, status_line, project.as_deref())?;
    status_line.command(&chosen).map(str::to_owned)
}

/// The status line setting the shim launches the provider with: the person's
/// own, as it stands for `working_directory`, with `relay_command` in place of
/// theirs. `None` when they have none: Claude Code keeps a row for a status
/// line even when it prints nothing, so taking an empty slot would add a
/// blank line to their screen.
#[must_use]
pub fn status_line_setting(
    provider: &str,
    env: &HookEnv,
    working_directory: &Path,
    relay_command: &str,
) -> Option<Value> {
    let adapter = adapter_for(provider)?;
    let status_line = adapter.status_line()?;
    let chosen = user_status_line(env, adapter, status_line, Some(working_directory))?;
    Some(status_line.relay(&chosen, relay_command, &|name| env.get(name)))
}

fn user_status_line(
    env: &HookEnv,
    adapter: &dyn ProviderAdapter,
    status_line: &dyn StatusLineAdapter,
    project: Option<&Path>,
) -> Option<Map<String, Value>> {
    let layers: Vec<Option<Value>> = status_line
        .settings_sources(project, &|name| env.get(name), &DiskSettingsFiles { env })
        .iter()
        .map(|source| read_source(env, adapter, source))
        .collect();
    status_line.user_status_line(&layers)
}

fn read_source(
    env: &HookEnv,
    adapter: &dyn ProviderAdapter,
    source: &SettingsSource,
) -> Option<Value> {
    match source {
        SettingsSource::File(path) => read_settings(path),
        SettingsSource::HomeFile(name) => env
            .provider_home(adapter.home_directory_variable(), adapter.descriptor())
            .and_then(|home| read_settings(&home.join(name))),
        SettingsSource::UserHomeFile(path) => env
            .get("HOME")
            .and_then(|home| read_settings(&Path::new(home).join(path))),
        // Inline JSON when it parses, otherwise the path of a file, the way
        // the provider reads its own flag.
        SettingsSource::LaunchVariable(variable) => {
            let value = env.get(variable)?;
            match serde_json::from_str::<Value>(value) {
                Ok(value @ Value::Object(_)) => Some(value),
                Ok(_) => None,
                Err(_) => read_settings(Path::new(value)),
            }
        }
    }
}

/// The largest text file an adapter reads to find its settings (a Git
/// worktree's `.git`, `commondir`, and `gitdir` are one line each).
const MAX_LOCATING_TEXT_BYTES: u64 = 64 * 1024;

/// The file system as the status line's process sees it.
struct DiskSettingsFiles<'a> {
    env: &'a HookEnv,
}

impl SettingsFiles for DiskSettingsFiles<'_> {
    fn entry(&self, path: &Path) -> Option<FileEntry> {
        fs::symlink_metadata(path)
            .ok()
            .map(|metadata| file_entry(&metadata))
    }

    fn target(&self, path: &Path) -> Option<FileEntry> {
        fs::metadata(path)
            .ok()
            .map(|metadata| file_entry(&metadata))
    }

    fn real_path(&self, path: &Path) -> Option<PathBuf> {
        fs::canonicalize(path).ok()
    }

    fn read_text(&self, path: &Path) -> Option<String> {
        let metadata = fs::metadata(path).ok()?;
        if !metadata.is_file() || metadata.len() > MAX_LOCATING_TEXT_BYTES {
            return None;
        }
        fs::read_to_string(path).ok()
    }

    #[cfg(unix)]
    fn user_id(&self) -> Option<u32> {
        // SAFETY: `geteuid` takes nothing and cannot fail.
        Some(unsafe { libc::geteuid() })
    }

    #[cfg(not(unix))]
    fn user_id(&self) -> Option<u32> {
        None
    }

    fn home(&self) -> Option<PathBuf> {
        fs::canonicalize(self.env.get("HOME")?).ok()
    }
}

fn file_entry(metadata: &fs::Metadata) -> FileEntry {
    let kind = if metadata.file_type().is_symlink() {
        FileKind::Link
    } else if metadata.is_dir() {
        FileKind::Directory
    } else if metadata.is_file() {
        FileKind::File
    } else {
        FileKind::Other
    };
    #[cfg(unix)]
    let owner = {
        use std::os::unix::fs::MetadataExt;
        Some(metadata.uid())
    };
    #[cfg(not(unix))]
    let owner = None;
    FileEntry { kind, owner }
}

fn read_settings(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    if bytes.len() > MAX_SETTINGS_BYTES {
        return None;
    }
    serde_json::from_slice::<Map<String, Value>>(&bytes)
        .ok()
        .map(Value::Object)
}

fn keep_usage(path: &Path, usage: &PlanUsage) {
    if let Some(stored) = fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<PlanUsage>(&bytes).ok())
    {
        let is_same = stored.windows == usage.windows;
        let age = parse_utc_seconds(&usage.observed_at)
            .zip(parse_utc_seconds(&stored.observed_at))
            .map(|(now, then)| now.saturating_sub(then));
        if is_same && age.is_some_and(|age| age < REFRESH_SECONDS) {
            return;
        }
    }
    let Ok(body) = serde_json::to_vec(usage) else {
        return;
    };
    if let Some(directory) = path.parent() {
        ensure_user_only_directory(directory);
    }
    let _ = atomic_write(path, &body);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::PathBuf;
    use std::time::{Duration, UNIX_EPOCH};
    use weir_provider_claude::{LAUNCH_SETTINGS_VARIABLE, SETTING_SOURCES_VARIABLE};

    /// What the shim writes for a launch with no `--setting-sources`.
    const EVERY_SOURCE: &str = "user,project,local";

    struct Fixture {
        _root: tempfile::TempDir,
        usage: PathBuf,
        project: PathBuf,
        config: PathBuf,
    }

    fn fixture() -> Fixture {
        let root = tempfile::tempdir().expect("temp");
        let usage = root.path().join("usage");
        let project = root.path().join("project");
        let config = root.path().join("config");
        fs::create_dir_all(project.join(".claude")).expect("project");
        fs::create_dir_all(&config).expect("config");
        Fixture {
            usage,
            project,
            config,
            _root: root,
        }
    }

    /// The environment of a status line the shim launched with no
    /// `--setting-sources`, with `extra` laid over it.
    fn env(fixture: &Fixture, extra: &[(&str, &str)]) -> HookEnv {
        let mut pairs = vec![
            (SETTING_SOURCES_VARIABLE.to_owned(), EVERY_SOURCE.to_owned()),
            (
                "WEIR_USAGE_DIR".to_owned(),
                fixture.usage.display().to_string(),
            ),
            (
                "CLAUDE_CONFIG_DIR".to_owned(),
                fixture.config.display().to_string(),
            ),
        ];
        for (name, value) in extra {
            pairs.retain(|(existing, _)| existing != name);
            pairs.push(((*name).to_owned(), (*value).to_owned()));
        }
        HookEnv::from_pairs(pairs)
    }

    fn input(fixture: &Fixture, used: f64) -> Vec<u8> {
        json!({
            "workspace": { "project_dir": fixture.project },
            "rate_limits": { "five_hour": { "used_percentage": used, "resets_at": 1_793_247_600_u64 } }
        })
        .to_string()
        .into_bytes()
    }

    fn write(path: &Path, value: &Value) {
        fs::write(path, value.to_string()).expect("write");
    }

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    #[test]
    fn the_relay_keeps_the_usage_and_names_the_user_status_line() {
        let fixture = fixture();
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "~/status.sh", "padding": 0 } }),
        );
        let command = run_status_line(
            "claude",
            &input(&fixture, 42.0),
            &env(&fixture, &[]),
            at(100),
        );
        assert_eq!(command.as_deref(), Some("~/status.sh"));
        let stored: PlanUsage =
            serde_json::from_slice(&fs::read(fixture.usage.join("claude.json")).expect("usage"))
                .expect("json");
        assert_eq!(stored.windows.len(), 1);
        assert_eq!(stored.observed_at, "1970-01-01T00:01:40Z");
        assert_eq!(stored.windows[0].kind, "five_hour");
        assert!((stored.windows[0].used_percent - 42.0).abs() < f64::EPSILON);
    }

    #[test]
    fn the_project_and_the_launch_settings_outrank_the_user_file() {
        let fixture = fixture();
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "user.sh" } }),
        );
        write(
            &fixture.project.join(".claude/settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "project.sh" } }),
        );
        let env_plain = env(&fixture, &[]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env_plain, at(0)).as_deref(),
            Some("project.sh")
        );
        let launch =
            json!({ "statusLine": { "type": "command", "command": "launch.sh" } }).to_string();
        let env_launch = env(&fixture, &[(LAUNCH_SETTINGS_VARIABLE, &launch)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env_launch, at(0)).as_deref(),
            Some("launch.sh")
        );
    }

    /// A project whose shared settings set a status line command, and a
    /// person who has one of their own.
    fn project_and_user_status_lines(fixture: &Fixture) {
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "user.sh", "padding": 1 } }),
        );
        write(
            &fixture.project.join(".claude/settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "project.sh" } }),
        );
    }

    /// `claude --setting-sources user` reads no project file, so neither the
    /// relay nor the setting the shim launches with takes the project's
    /// command, which Claude Code would not run.
    #[test]
    fn a_launch_that_leaves_the_project_out_never_runs_its_command() {
        let fixture = fixture();
        project_and_user_status_lines(&fixture);
        let user_only = format!("{EVERY_SOURCE}\nuser");
        let env = env(&fixture, &[(SETTING_SOURCES_VARIABLE, &user_only)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env, at(0)).as_deref(),
            Some("user.sh")
        );
        assert_eq!(
            status_line_setting("claude", &env, &fixture.project, "/h statusline claude"),
            Some(json!({ "type": "command",
                "command": format!("{SETTING_SOURCES_VARIABLE}=user /h statusline claude"),
                "padding": 1 }))
        );
    }

    /// A settings file the launch loads may set the status line's
    /// environment (`env`), so the relay goes by the sources its own command
    /// names, which the launch settings carry.
    #[test]
    fn the_relay_s_command_outranks_an_env_block_that_widens_the_sources() {
        let fixture = fixture();
        project_and_user_status_lines(&fixture);
        let user_only = format!("{EVERY_SOURCE}\nuser");
        let launch = env(&fixture, &[(SETTING_SOURCES_VARIABLE, &user_only)]);
        let setting =
            status_line_setting("claude", &launch, &fixture.project, "/h statusline claude")
                .expect("the person's own");
        let command = setting["command"].as_str().expect("a command");
        let assignment = command
            .strip_suffix(" /h statusline claude")
            .and_then(|prefix| prefix.strip_prefix(&format!("{SETTING_SOURCES_VARIABLE}=")))
            .expect("the relay command sets the sources");
        // What the shell running that command hands the relay, whatever a
        // project's `env` block put in the variable before.
        let run = env(&fixture, &[(SETTING_SOURCES_VARIABLE, assignment)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &run, at(0)).as_deref(),
            Some("user.sh")
        );
    }

    /// `--restricted` reads none of the three files; `--settings` still
    /// applies.
    #[test]
    fn a_restricted_launch_runs_only_its_launch_settings() {
        let fixture = fixture();
        project_and_user_status_lines(&fixture);
        let restricted = format!("{EVERY_SOURCE}\n");
        let env_none = env(&fixture, &[(SETTING_SOURCES_VARIABLE, &restricted)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env_none, at(0)),
            None
        );
        let launch =
            json!({ "statusLine": { "type": "command", "command": "launch.sh" } }).to_string();
        let env_launch = env(
            &fixture,
            &[
                (SETTING_SOURCES_VARIABLE, &restricted),
                (LAUNCH_SETTINGS_VARIABLE, &launch),
            ],
        );
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env_launch, at(0)).as_deref(),
            Some("launch.sh")
        );
    }

    /// A status line started without the shim's word on its sources, or
    /// with a word Claude Code would not start with, cannot tell which files
    /// the launch reads: it runs no command from them.
    #[test]
    fn a_launch_it_cannot_read_runs_no_file_s_command() {
        let fixture = fixture();
        project_and_user_status_lines(&fixture);
        let unset = HookEnv::from_pairs([
            ("WEIR_USAGE_DIR", fixture.usage.display().to_string()),
            ("CLAUDE_CONFIG_DIR", fixture.config.display().to_string()),
        ]);
        let refused = env(
            &fixture,
            &[(SETTING_SOURCES_VARIABLE, "user,project,local\nbogus")],
        );
        for env in [unset, refused] {
            assert_eq!(
                run_status_line("claude", &input(&fixture, 1.0), &env, at(0)),
                None
            );
            assert_eq!(
                status_line_setting("claude", &env, &fixture.project, "/h statusline claude"),
                None
            );
        }
    }

    /// Claude Code reads a worktree session's local settings from the main
    /// checkout's root, and the worktree's own local file from an earlier
    /// version below it; the shared file is the worktree's. Unix only: off
    /// it Claude Code keeps the local file in the starting folder.
    #[cfg(unix)]
    #[test]
    fn a_worktree_session_takes_the_local_file_of_the_main_checkout() {
        let fixture = fixture();
        // Git writes the paths it resolved, so the fixture's are resolved too.
        let root = fs::canonicalize(fixture.project.parent().expect("parent")).expect("real");
        let main = root.join("main");
        let worktree = root.join("worktree");
        fs::create_dir_all(&main).expect("main");
        let git = |args: &[&str]| crate::restore::tests::git_runner::required(&main, args);
        git(&["init", "-q", "-b", "main"]);
        git(&[
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.com",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "base",
        ]);
        git(&[
            "worktree",
            "add",
            "-q",
            "--detach",
            worktree.to_str().expect("utf-8"),
        ]);
        for (folder, name, command) in [
            (&main, "settings.local.json", "main-local.sh"),
            (&worktree, "settings.local.json", "worktree-local.sh"),
            (&worktree, "settings.json", "worktree-shared.sh"),
        ] {
            fs::create_dir_all(folder.join(".claude")).expect(".claude");
            write(
                &folder.join(".claude").join(name),
                &json!({ "statusLine": { "type": "command", "command": command } }),
            );
        }
        let input = json!({ "workspace": { "project_dir": worktree } }).to_string();
        let env = env(&fixture, &[]);
        let run = || run_status_line("claude", input.as_bytes(), &env, at(0));
        assert_eq!(run().as_deref(), Some("main-local.sh"));
        fs::remove_file(main.join(".claude/settings.local.json")).expect("remove");
        assert_eq!(run().as_deref(), Some("worktree-local.sh"));
        fs::remove_file(worktree.join(".claude/settings.local.json")).expect("remove");
        assert_eq!(run().as_deref(), Some("worktree-shared.sh"));
        // Leaving local settings out leaves out both local files.
        write(
            &main.join(".claude/settings.local.json"),
            &json!({ "statusLine": { "type": "command", "command": "main-local.sh" } }),
        );
        let project_only = format!("{EVERY_SOURCE}\nproject");
        let env = super::tests::env(&fixture, &[(SETTING_SOURCES_VARIABLE, &project_only)]);
        assert_eq!(
            run_status_line("claude", input.as_bytes(), &env, at(0)).as_deref(),
            Some("worktree-shared.sh")
        );
    }

    #[test]
    fn a_launch_setting_may_be_a_file() {
        let fixture = fixture();
        let file = fixture.project.join("mine.json");
        write(
            &file,
            &json!({ "statusLine": { "type": "command", "command": "file.sh" } }),
        );
        let path = file.display().to_string();
        let env = env(&fixture, &[(LAUNCH_SETTINGS_VARIABLE, &path)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env, at(0)).as_deref(),
            Some("file.sh")
        );
    }

    #[test]
    fn no_status_line_of_their_own_leaves_nothing_to_run() {
        let fixture = fixture();
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env(&fixture, &[]), at(0)),
            None
        );
        let stored: PlanUsage =
            serde_json::from_slice(&fs::read(fixture.usage.join("claude.json")).expect("usage"))
                .expect("json");
        assert_eq!(stored.windows.len(), 1);
        assert_eq!(stored.windows[0].kind, "five_hour");
        assert!((stored.windows[0].used_percent - 1.0).abs() < f64::EPSILON);
        assert_eq!(stored.observed_at, "1970-01-01T00:00:00Z");
    }

    #[test]
    fn a_provider_without_a_status_line_relays_nothing() {
        let fixture = fixture();
        assert_eq!(
            run_status_line("codex", &input(&fixture, 1.0), &env(&fixture, &[]), at(0)),
            None
        );
        assert!(!fixture.usage.join("codex.json").exists());
    }

    #[test]
    fn an_unchanged_reading_is_rewritten_only_once_it_has_aged() {
        let fixture = fixture();
        let env = env(&fixture, &[]);
        let path = fixture.usage.join("claude.json");
        let observed = |path: &Path| {
            serde_json::from_slice::<PlanUsage>(&fs::read(path).expect("usage"))
                .expect("json")
                .observed_at
        };
        let _ = run_status_line("claude", &input(&fixture, 5.0), &env, at(1_000));
        let first = observed(&path);
        let _ = run_status_line("claude", &input(&fixture, 5.0), &env, at(1_030));
        assert_eq!(observed(&path), first, "unchanged and young: kept");
        let _ = run_status_line("claude", &input(&fixture, 6.0), &env, at(1_031));
        assert_ne!(observed(&path), first, "changed: rewritten");
        let changed = observed(&path);
        let _ = run_status_line("claude", &input(&fixture, 6.0), &env, at(1_090));
        assert_eq!(observed(&path), changed, "before refresh deadline: kept");
        let _ = run_status_line("claude", &input(&fixture, 6.0), &env, at(1_091));
        assert_eq!(
            observed(&path),
            "1970-01-01T00:18:11Z",
            "at refresh deadline: rewritten"
        );
    }

    #[test]
    fn the_launch_setting_carries_the_person_s_options_onto_the_relay() {
        let fixture = fixture();
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "user.sh", "padding": 0 } }),
        );
        let setting = status_line_setting(
            "claude",
            &env(&fixture, &[]),
            &fixture.project,
            "/h statusline claude",
        );
        assert_eq!(
            setting,
            Some(json!({ "type": "command",
                "command": format!("{SETTING_SOURCES_VARIABLE}=user,project,local /h statusline claude"),
                "padding": 0 }))
        );
    }

    #[test]
    fn no_status_line_of_their_own_leaves_the_slot_empty_at_launch() {
        let fixture = fixture();
        let setting = status_line_setting(
            "claude",
            &env(&fixture, &[]),
            &fixture.project,
            "/h statusline claude",
        );
        assert_eq!(setting, None);
    }
}
