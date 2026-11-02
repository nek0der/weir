//! Routes the agent's `git worktree add` to where the active project's placement
//! rules say, then runs the project's bootstrap steps.
//!
//! The rules are those of `weir-pretool-worktree-hook`: anything that is not a
//! confident match passes through untouched. Nothing the agent wrote runs before
//! the provider's own permission checks: `PreToolUse` comes ahead of them, so there
//! we only change the folder in the command, and the person's "No", a deny rule, or
//! a sandbox still stops it. The bootstrap waits for `PostToolUse` and a worktree
//! Git lists.

use serde_json::Value;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};
use weir_agent_model::WorktreeIntent;

/// The routing file version this build reads.
const ROUTING_SCHEMA_VERSION: u64 = 1;

/// The routing file's name in the application support folder. The application
/// writes it (`WorktreeRouting.fileName`); the two sides check the name against
/// `rust/fixtures/contract/shared-values.json`.
pub const WORKTREE_ROUTING_FILE: &str = "worktree-routing.json";

/// What to do with a `git worktree add` the agent is about to run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InterceptResult {
    /// Let the agent's own command run.
    Passthrough,
    /// Have the provider run `command`, which makes the worktree at `path`.
    Reroute { path: PathBuf, command: String },
}

/// A worktree that reached the project's place and has had its setup run. The
/// caller records the creation, so one writer owns the event format.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreatedWorktree {
    pub repo_root: PathBuf,
    pub path: PathBuf,
    pub branch: String,
    pub message: String,
}

/// The folder beside the routing file for `awaited_mark`, shared by the
/// providers as the worktrees are.
const AWAITED_DIRECTORY: &str = "worktrees-awaited";

/// How long a command of ours counts as on its way, which also covers a person
/// reading the prompt.
const AWAITED_FOR: Duration = Duration::from_hours(1);

/// How long a bootstrap waits for a checkout, under the 600 seconds a hook has.
const CHECKOUT_WAIT: Duration = Duration::from_mins(5);

/// The routing entry that owns `cwd`.
struct ProjectRules {
    root: PathBuf,
    placement: Placement,
    bootstrap: Vec<BootstrapStep>,
}

enum Placement {
    SiblingPrefixed,
    InsideHidden,
    Custom(PathBuf),
}

struct BootstrapStep {
    command: String,
    cwd: Option<String>,
}

/// Decides what happens to `intent` before its command runs, on behalf of
/// `provider_id`. `state_dir` is the provider's agent-state directory; the
/// routing file sits beside it. Creates no worktree.
#[must_use]
pub fn plan(intent: &WorktreeIntent, provider_id: &str, state_dir: &Path) -> InterceptResult {
    let Some((project, worktree)) = routed(intent, provider_id, state_dir) else {
        return InterceptResult::Passthrough;
    };
    // One that exists was set up by whoever made it, or still has its own
    // `PostToolUse` to come. Either way this command is going to fail on it.
    // A folder holding something else, such as another branch whose name gives the
    // same folder, would fail a command that works where the agent asked.
    // Checked last, right before the mark, so another call's whole command has
    // next to no room to finish in between. We leave that room open rather than
    // hold a lock over Git: it costs a second bootstrap, for two agents making
    // one branch at one moment.
    if !adds_to_project(intent, &project.root)
        || listed_worktree(&project.root, &worktree, &intent.branch).is_some()
        || is_taken(&worktree)
    {
        return InterceptResult::Passthrough;
    }
    await_worktree(state_dir, &worktree);
    let quoted = shell_quoted(&worktree);
    if names_folder(&intent.command, &quoted) {
        return InterceptResult::Passthrough;
    }
    match intent.rerouted_command(&quoted) {
        Some(command) => InterceptResult::Reroute {
            path: worktree,
            command,
        },
        None => InterceptResult::Passthrough,
    }
}

/// Finishes `intent` once its command has run: when Git lists the worktree at
/// the project's folder on the branch asked for, and a call of ours was on its
/// way to making it, runs the bootstrap. `None` otherwise, which covers a command
/// that failed, one that went elsewhere, and a worktree made elsewhere. We go by
/// what Git lists rather than how the command spelled the folder: a model may
/// quote it its own way.
#[must_use]
pub fn finish(
    intent: &WorktreeIntent,
    provider_id: &str,
    state_dir: &Path,
) -> Option<CreatedWorktree> {
    let (project, worktree) = routed(intent, provider_id, state_dir)?;
    // A mark left by a refused command says nothing about one for another repository.
    if !adds_to_project(intent, &project.root) {
        return None;
    }
    listed_worktree(&project.root, &worktree, &intent.branch)?;
    if !take_awaited(state_dir, &worktree) || !wait_for_checkout(intent, &project.root, &worktree) {
        return None;
    }
    run_bootstrap(&project.bootstrap, &worktree);
    Some(CreatedWorktree {
        // The model named another folder and Git's output does not say where this
        // is, so without the "not" it takes the two for a contradiction.
        message: format!(
            "Weir sent this worktree to the project's folder. It is at {}, not any other folder the command named.",
            worktree.display()
        ),
        repo_root: project.root,
        path: worktree,
        branch: intent.branch.clone(),
    })
}

/// Whether the command adds to the project's repository, as `-C` can point it at
/// another, whose worktree does not belong in this project's folder. We start Git
/// ourselves in the folder the command names and pass it none of the command's
/// words: this runs before any permission check. Anything but `-C`, and an answer
/// Git cannot give, counts as no.
fn adds_to_project(intent: &WorktreeIntent, root: &Path) -> bool {
    let common_dir = |directory: &Path| -> Option<PathBuf> {
        let output = git_command()
            .args(["rev-parse", "--path-format=absolute", "--git-common-dir"])
            .current_dir(directory)
            .output()
            .ok()
            .filter(|output| output.status.success())?;
        Path::new(String::from_utf8_lossy(&output.stdout).trim_end())
            .canonicalize()
            .ok()
    };
    // The agent's own Git obeys these and may be adding to another repository.
    if ["GIT_DIR", "GIT_COMMON_DIR"]
        .iter()
        .any(|variable| std::env::var_os(variable).is_some())
    {
        return false;
    }
    if intent.git_directories().is_none() {
        return false;
    }
    common_dir(&start_directory(intent))
        .is_some_and(|asked| common_dir(root).is_some_and(|project| asked == project))
}

/// Git for the hook's own questions, which are about the folders we name and not
/// whatever the agent's environment points at.
fn git_command() -> Command {
    let mut command = Command::new("git");
    crate::git::clear_repository_variables(&mut command);
    command.stdin(Stdio::null()).stderr(Stdio::null());
    command
}

/// Where the agent's command starts Git, past any `-C`, which decides the
/// repository and so the project.
fn start_directory(intent: &WorktreeIntent) -> PathBuf {
    let mut start = intent
        .cwd
        .clone()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    for directory in intent.git_directories().unwrap_or_default() {
        start.push(directory);
    }
    start
}

/// Whether Git would refuse to make a worktree at `path`. An empty folder it accepts.
fn is_taken(path: &Path) -> bool {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => {
            std::fs::read_dir(path).map_or(true, |mut entries| entries.next().is_some())
        }
        Ok(_) => true,
        Err(_) => false,
    }
}

/// The file that says a call of ours has a command on its way to making
/// `worktree`. It is what lets `finish` tell that worktree from one made elsewhere:
/// Codex sends `PostToolUse` for a command that failed too and names no status, so
/// a `git worktree add` repeated over a worktree that exists looks like one that
/// made it, and without this the person's bootstrap would run in it again. It stays
/// when the call that made it never hears back, so the agent's next try can still
/// set the worktree up.
fn awaited_mark(state_dir: &Path, worktree: &Path) -> PathBuf {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    worktree.hash(&mut hasher);
    state_dir
        .parent()
        .unwrap_or(state_dir)
        .join(AWAITED_DIRECTORY)
        .join(format!("{:016x}", hasher.finish()))
}

/// Best effort: without the mark the worktree only goes without its setup.
fn await_worktree(state_dir: &Path, worktree: &Path) {
    let mark = awaited_mark(state_dir, worktree);
    if let Some(parent) = mark.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(mark, b"");
}

/// Takes the mark for this call, so of two calls that finish together one runs
/// the setup. By rename: two processes removing one file on APFS can both be told
/// they did, and a rename goes to one. A mark older than `AWAITED_FOR` is from a
/// command the person refused or that failed, and says nothing about a worktree
/// made since. Taken before the wait for the checkout, so a crashed
/// `git worktree add` costs that wait once.
fn take_awaited(state_dir: &Path, worktree: &Path) -> bool {
    let mark = awaited_mark(state_dir, worktree);
    let taken = mark.with_extension(format!("taken-{}", std::process::id()));
    if std::fs::rename(&mark, &taken).is_err() {
        return false;
    }
    let is_fresh = std::fs::metadata(&taken)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age < AWAITED_FOR);
    let _ = std::fs::remove_file(&taken);
    is_fresh
}

/// Waits while `git worktree add` is still checking files out, which it holds the
/// worktree locked for. A provider can send `PostToolUse`
/// for a command it moved to the background, and a bootstrap must not start in a
/// half-filled folder. `false` when it does not finish in time. A `--no-checkout`
/// command has none to wait for, and no index ever says so.
fn wait_for_checkout(intent: &WorktreeIntent, root: &Path, worktree: &Path) -> bool {
    let branch = &intent.branch;
    let started = Instant::now();
    while let Some(entry) = listed_worktree(root, worktree, branch) {
        if !entry.is_checking_out || intent.skips_checkout() {
            return true;
        }
        if started.elapsed() >= CHECKOUT_WAIT {
            return false;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    false
}

/// The project that owns the intent and the folder its rules give the branch.
fn routed(
    intent: &WorktreeIntent,
    provider_id: &str,
    state_dir: &Path,
) -> Option<(ProjectRules, PathBuf)> {
    let support = state_dir.parent()?;
    let project = project_for(support, &start_directory(intent), provider_id)?;
    let worktree = project.worktree_path(&intent.branch)?;
    Some((project, worktree))
}

/// Whether `command` has `quoted` as a word of its own, so `/a/repo-x` is not
/// found in `/a/repo-x2`.
fn names_folder(command: &str, quoted: &str) -> bool {
    command.match_indices(quoted).any(|(start, _)| {
        let before = command[..start].chars().next_back();
        let after = command[start + quoted.len()..].chars().next();
        before.is_none_or(char::is_whitespace) && after.is_none_or(char::is_whitespace)
    })
}

/// `path` as one word for a shell.
fn shell_quoted(path: &Path) -> String {
    let path = path.to_string_lossy();
    let is_plain = path
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "/._-+=:,@%".contains(character));
    if is_plain {
        path.into_owned()
    } else {
        format!("'{}'", path.replace('\'', "'\\''"))
    }
}

/// A worktree Git lists.
struct ListedWorktree {
    is_checking_out: bool,
}

/// The worktree of `root` that Git lists at `path` on `branch`. Compared by
/// real path: a listed path has its links resolved. A Git that cannot answer
/// lists nothing, and then we set nothing up.
fn listed_worktree(root: &Path, path: &Path, branch: &str) -> Option<ListedWorktree> {
    let wanted = path.canonicalize().ok()?;
    let listing = git_command()
        .arg("-C")
        .arg(root)
        .args(["worktree", "list", "--porcelain"])
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let listing = String::from_utf8_lossy(&listing.stdout);
    let wanted_branch = format!("branch refs/heads/{branch}");
    listing.split("\n\n").find_map(|entry| {
        let mut lines = entry.lines();
        let listed = lines.next()?.strip_prefix("worktree ")?;
        if Path::new(listed).canonicalize().ok()? != wanted {
            return None;
        }
        let rest: Vec<&str> = lines.collect();
        // A prunable one has lost its folder or its `.git`, and Git run inside
        // would answer for whatever repository is around it. A locked one is never
        // called prunable, so we look for the `.git` ourselves.
        let is_prunable =
            rest.iter().any(|line| line.starts_with("prunable")) || !path.join(".git").exists();
        // Git holds the worktree locked through the checkout, under `initializing`
        // or the reason `--lock` gives, which may be a person's own or translated.
        // Only the index it writes at the end tells the checkout has finished.
        let is_locked = rest.iter().any(|line| line.starts_with("locked"));
        (rest.contains(&wanted_branch.as_str()) && !is_prunable).then(|| ListedWorktree {
            is_checking_out: is_locked && !has_index(path),
        })
    })
}

/// Whether Git has written the worktree's index, which it does when the checkout
/// ends.
fn has_index(worktree: &Path) -> bool {
    git_command()
        .arg("-C")
        .arg(worktree)
        .args(["rev-parse", "--path-format=absolute", "--git-path", "index"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .is_some_and(|output| {
            Path::new(String::from_utf8_lossy(&output.stdout).trim_end()).exists()
        })
}

/// How deep `folder` owns `cwd`, for choosing the deepest owner, or `None` when it
/// does not. By real path: an agent reports `/private/tmp/x` for a project recorded
/// as `/tmp/x`. A folder that no longer resolves is compared as written.
fn owning_depth(cwd: &Path, folder: &str) -> Option<usize> {
    let folder = Path::new(folder);
    let folder = folder
        .canonicalize()
        .unwrap_or_else(|_| folder.to_path_buf());
    cwd.starts_with(&folder).then(|| folder.as_os_str().len())
}

/// How deep `project` owns `cwd`, through its root or one of its worktrees, which
/// can sit outside the root.
fn project_depth(cwd: &Path, project: &Value) -> Option<usize> {
    let root = project.get("root").and_then(Value::as_str);
    let worktrees = project
        .get("worktrees")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    root.into_iter()
        .chain(worktrees)
        .filter_map(|folder| owning_depth(cwd, folder))
        .max()
}

/// `cwd` as `owning_depth` compares it.
fn real_cwd(cwd: &Path) -> PathBuf {
    cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf())
}

/// Finds the project whose root contains `cwd` and whose routing is on for
/// this provider. The deepest root decides, so a project at the home folder does
/// not take the projects inside it, whichever came first in the file.
///
/// Read from `worktree-routing.json`, which the application writes in the same
/// operation as the session itself so the two cannot drift. A version this
/// build does not know is left alone rather than guessed at: passing the
/// command through puts the worktree where the agent asked, which is
/// recoverable, where guessing at a shape could put it anywhere.
fn project_for(support: &Path, cwd: &Path, provider_id: &str) -> Option<ProjectRules> {
    let routing: Value =
        serde_json::from_slice(&std::fs::read(support.join(WORKTREE_ROUTING_FILE)).ok()?).ok()?;
    if routing.get("schemaVersion").and_then(Value::as_u64) != Some(ROUTING_SCHEMA_VERSION) {
        return None;
    }
    let cwd = real_cwd(cwd);
    // Absent means routed; only an explicit opt-out turns it off, so a
    // provider the application did not know about still gets the rules.
    let is_opted_out = |project: &Value| {
        project
            .get("routing")
            .and_then(|routing| routing.get(provider_id))
            .and_then(Value::as_bool)
            == Some(false)
    };
    // Only entries with a root have rules to give.
    let owners: Vec<(usize, &Value, &str)> = routing
        .get("projects")?
        .as_array()?
        .iter()
        .filter_map(|project| {
            let root = project.get("root").and_then(Value::as_str)?;
            Some((project_depth(&cwd, project)?, project, root))
        })
        .collect();
    let deepest = owners.iter().map(|(depth, _, _)| *depth).max()?;
    // An entry we cannot read is skipped rather than fatal: one project whose
    // placement this build does not recognize must not stop every other
    // project from routing, which is what returning here would do. It still owns
    // its folder, though, so the rules of a project around it do not apply there.
    let (_, project, root) = owners.into_iter().find(|(depth, project, _)| {
        *depth == deepest
            && (is_opted_out(project) || project.get("placement").and_then(placement).is_some())
    })?;
    if is_opted_out(project) {
        return None;
    }
    Some(ProjectRules {
        root: PathBuf::from(root),
        placement: project.get("placement").and_then(placement)?,
        bootstrap: project
            .get("bootstrap")
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(bootstrap_step).collect())
            .unwrap_or_default(),
    })
}

/// The check commands of the project that owns `cwd`: its own list
/// when it set one, `None` when it did not or no project owns `cwd`, and the
/// caller uses the defaults. A worktree of the project counts as the project
/// (`worktrees` in the routing entry). Read from the same file as the
/// worktree routing, with the same rule for a version this build does not
/// know: it is not guessed at, and the defaults apply.
pub(crate) fn check_patterns(support: &Path, cwd: &Path) -> Option<Vec<String>> {
    let routing: Value =
        serde_json::from_slice(&std::fs::read(support.join(WORKTREE_ROUTING_FILE)).ok()?).ok()?;
    if routing.get("schemaVersion").and_then(Value::as_u64) != Some(ROUTING_SCHEMA_VERSION) {
        return None;
    }
    let cwd = real_cwd(cwd);
    // The deepest directory that owns `cwd` decides, so a project nested in
    // another keeps its own checks.
    let (_, project) = routing
        .get("projects")?
        .as_array()?
        .iter()
        .filter_map(|project| Some((project_depth(&cwd, project)?, project)))
        .max_by_key(|(depth, _)| *depth)?;
    project.get("checks")?.as_array().map(|items| {
        items
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    })
}

fn placement(value: &Value) -> Option<Placement> {
    match value.get("kind")?.as_str()? {
        "siblingPrefixed" => Some(Placement::SiblingPrefixed),
        "insideHidden" => Some(Placement::InsideHidden),
        "custom" => Some(Placement::Custom(PathBuf::from(
            value.get("parent")?.as_str()?,
        ))),
        _ => None,
    }
}

impl ProjectRules {
    /// Mirrors `Project.resolvedWorktreeURL(branchLeaf:)` given
    /// `BranchNameSuggester.folderLeaf(of:)`. The two sides check the result
    /// against `rust/fixtures/contract/shared-values.json`. The whole branch
    /// names the folder, so `feature/alpha` and `fix/alpha` get one each.
    fn worktree_path(&self, branch: &str) -> Option<PathBuf> {
        if branch.is_empty() {
            return None;
        }
        let leaf = branch.replace('/', "-");
        match &self.placement {
            Placement::SiblingPrefixed => {
                let name = self.root.file_name()?.to_string_lossy();
                Some(self.root.parent()?.join(format!("{name}-{leaf}")))
            }
            Placement::InsideHidden => Some(self.root.join(".worktrees").join(leaf)),
            Placement::Custom(parent) => Some(parent.join(leaf)),
        }
    }
}

fn bootstrap_step(item: &Value) -> Option<BootstrapStep> {
    Some(BootstrapStep {
        command: item.get("command")?.as_str()?.to_owned(),
        cwd: item
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
    })
}

/// Runs each bootstrap step through `/bin/sh -c` in the worktree, as the
/// shell's `eval` did. Failures are diagnostic: they go to stderr and the
/// next step still runs. A step's `cwd` must stay inside the worktree.
fn run_bootstrap(steps: &[BootstrapStep], worktree: &Path) {
    for step in steps {
        if step.cwd.as_deref().is_some_and(escapes_worktree) {
            eprintln!(
                "weir-agent-hook: skipping step, unsafe cwd '{}'",
                step.cwd.as_deref().unwrap_or_default()
            );
            continue;
        }
        let directory = match step_directory(step.cwd.as_deref(), worktree) {
            StepDirectory::Inside(directory) => directory,
            StepDirectory::Outside(resolved) => {
                eprintln!(
                    "weir-agent-hook: skipping step, cwd '{}' resolves to {} outside the worktree",
                    step.cwd.as_deref().unwrap_or_default(),
                    resolved.display()
                );
                continue;
            }
            StepDirectory::Unresolved(path, error) => {
                eprintln!(
                    "weir-agent-hook: bootstrap step could not start in {}: {error}",
                    path.display()
                );
                continue;
            }
        };
        // Both streams go directly to stderr as the shell's `>&2` did.
        // Avoiding a captured stdout preserves output as it is produced and
        // avoids retaining an unbounded bootstrap log in memory.
        match bootstrap_command(step, &directory).status() {
            Ok(_) => {}
            Err(error) => eprintln!(
                "weir-agent-hook: bootstrap step could not start in {}: {error}",
                directory.display()
            ),
        }
    }
}

/// Where a step's directory really is, symlinks resolved.
#[derive(Debug)]
enum StepDirectory {
    /// The directory's real path, inside the worktree's.
    Inside(PathBuf),
    /// The directory's real path, which is not inside the worktree's.
    Outside(PathBuf),
    /// The worktree or the directory has no real path: it does not exist,
    /// or a link in it leads nowhere.
    Unresolved(PathBuf, std::io::Error),
}

/// The real path of the step's directory, checked to lie inside the real
/// path of the worktree, just before the step runs. `escapes_worktree`
/// cannot see a link: the branch just checked out decides what the worktree
/// holds, and a `frontend` there that is a symlink to another project, or a
/// `packages` link that `cwd: "packages/web"` passes through, would run the
/// person's own command in that other project. `canonicalize` is
/// `realpath(3)` and resolves a link in any component. The app's own setup
/// (`WorktreeSetup.stepDirectory`) makes the same check.
///
/// The step is started in the resolved path, so `chdir(2)` follows no link
/// this check did not see. What is left is a component of that path being
/// swapped for a link between this check and the start. We leave that open,
/// as the app does: whatever could make that swap in the window is already
/// running in the person's account in the worktree (an earlier step, or code
/// it started), with no boundary left for the check to keep. It guards the
/// directory a step starts in, not what the step does there.
fn step_directory(cwd: Option<&str>, worktree: &Path) -> StepDirectory {
    let root = match worktree.canonicalize() {
        Ok(root) => root,
        Err(error) => return StepDirectory::Unresolved(worktree.to_path_buf(), error),
    };
    let Some(cwd) = cwd else {
        return StepDirectory::Inside(root);
    };
    let joined = worktree.join(cwd);
    match joined.canonicalize() {
        // Component-wise, so `/a/bc` is not inside `/a/b`.
        Ok(directory) if directory.starts_with(&root) => StepDirectory::Inside(directory),
        Ok(directory) => StepDirectory::Outside(directory),
        Err(error) => StepDirectory::Unresolved(joined, error),
    }
}

fn bootstrap_command(step: &BootstrapStep, directory: &Path) -> Command {
    let mut command = Command::new("/bin/sh");
    // A step's Git belongs to the new worktree, not to whatever the agent's
    // environment points at.
    crate::git::clear_repository_variables(&mut command);
    command
        .arg("-c")
        .arg(&step.command)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::from(std::io::stderr()))
        .stderr(Stdio::inherit());
    command
}

/// A step `cwd` may only point inside the worktree. The steps are
/// per-machine today, but the same shape may later be shared by a team, so a
/// step must not be able to name a path outside the tree it was created for.
fn escapes_worktree(cwd: &str) -> bool {
    cwd.starts_with('/')
        || cwd == ".."
        || cwd.starts_with("../")
        || cwd.contains("/../")
        || cwd.ends_with("/..")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn git_and_the_bootstrap_do_not_inherit_where_the_agent_points_git() {
        let step = BootstrapStep {
            command: String::new(),
            cwd: None,
        };
        for command in [git_command(), bootstrap_command(&step, Path::new("/"))] {
            for variable in [
                "GIT_DIR",
                "GIT_WORK_TREE",
                "GIT_INDEX_FILE",
                "GIT_COMMON_DIR",
            ] {
                assert!(
                    command
                        .get_envs()
                        .any(|(name, value)| name == variable && value.is_none()),
                    "{variable}"
                );
            }
        }
    }

    /// The app's `SharedValuesContractTests` check `resolvedWorktreeURL`
    /// against the same file, so the hook and the sheet agree on the folder.
    #[test]
    fn the_worktree_folders_are_the_ones_the_app_makes() {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/contract/shared-values.json");
        let shared: Value =
            serde_json::from_slice(&std::fs::read(path).expect("the shared values file"))
                .expect("the shared values decode");
        let folders = &shared["worktreeFolders"];
        let text = |value: &Value| value.as_str().expect("a string").to_owned();
        let rules = |placement| ProjectRules {
            root: PathBuf::from(text(&folders["projectRoot"])),
            placement,
            bootstrap: Vec::new(),
        };
        let custom_parent = PathBuf::from(text(&folders["customParent"]));
        let cases = folders["cases"].as_array().expect("the cases");
        assert!(!cases.is_empty());
        for case in cases {
            let branch = text(&case["branch"]);
            for (placement, key) in [
                (Placement::SiblingPrefixed, "siblingPrefixed"),
                (Placement::InsideHidden, "insideHidden"),
                (Placement::Custom(custom_parent.clone()), "custom"),
            ] {
                assert_eq!(
                    rules(placement).worktree_path(&branch),
                    Some(PathBuf::from(text(&case[key]))),
                    "{branch} {key}"
                );
            }
        }
    }

    #[test]
    fn a_folder_is_named_only_as_a_word_of_its_own() {
        for (command, expected) in [
            ("git worktree add -b x /a/repo-x", true),
            ("git worktree add /a/repo-x -b x", true),
            ("git worktree add -b x /a/repo-x2", false),
            ("git worktree add -b x /b/a/repo-x", false),
        ] {
            assert_eq!(names_folder(command, "/a/repo-x"), expected, "{command}");
        }
    }

    #[test]
    fn a_folder_is_one_word_for_a_shell() {
        assert_eq!(shell_quoted(Path::new("/a/repo-x")), "/a/repo-x");
        assert_eq!(shell_quoted(Path::new("/a/my repo")), "'/a/my repo'");
        assert_eq!(shell_quoted(Path::new("/a/it's")), "'/a/it'\\''s'");
    }

    #[test]
    fn an_empty_branch_has_no_worktree_folder() {
        let rules = ProjectRules {
            root: PathBuf::from("/projects/repo"),
            placement: Placement::InsideHidden,
            bootstrap: Vec::new(),
        };
        assert_eq!(rules.worktree_path(""), None);
    }

    #[test]
    fn a_step_cwd_may_not_leave_the_worktree() {
        for cwd in ["/etc", "..", "../x", "a/../../b", "a/.."] {
            assert!(escapes_worktree(cwd), "{cwd}");
        }
        for cwd in ["sub", "a/b", "./a", "a/..b"] {
            assert!(!escapes_worktree(cwd), "{cwd}");
        }
    }

    /// A worktree with an `inside` subdirectory, and a directory beside it
    /// that is not in it.
    #[cfg(unix)]
    fn worktree_and_outside() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let scratch = tempfile::tempdir().expect("scratch");
        let worktree = scratch.path().join("worktree");
        let outside = scratch.path().join("outside");
        std::fs::create_dir_all(worktree.join("inside")).expect("inside");
        std::fs::create_dir_all(outside.join("web")).expect("outside");
        (scratch, worktree, outside)
    }

    #[cfg(unix)]
    fn touch_in(cwd: &str) -> BootstrapStep {
        BootstrapStep {
            command: "touch ran".into(),
            cwd: Some(cwd.into()),
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_a_link_out_of_the_worktree_is_not_run() {
        let (_scratch, worktree, outside) = worktree_and_outside();
        std::os::unix::fs::symlink(&outside, worktree.join("frontend")).expect("link");

        assert!(matches!(
            step_directory(Some("frontend"), &worktree),
            StepDirectory::Outside(_)
        ));
        run_bootstrap(&[touch_in("frontend"), touch_in("inside")], &worktree);

        assert!(!outside.join("ran").exists(), "the step ran outside");
        assert!(
            worktree.join("inside/ran").exists(),
            "a skipped step does not stop later steps"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_through_a_linked_parent_out_of_the_worktree_is_not_run() {
        let (_scratch, worktree, outside) = worktree_and_outside();
        std::os::unix::fs::symlink(&outside, worktree.join("packages")).expect("link");

        assert!(matches!(
            step_directory(Some("packages/web"), &worktree),
            StepDirectory::Outside(_)
        ));
        run_bootstrap(&[touch_in("packages/web")], &worktree);

        assert!(!outside.join("web/ran").exists(), "the step ran outside");
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_a_link_inside_the_worktree_runs() {
        let (_scratch, worktree, _outside) = worktree_and_outside();
        std::os::unix::fs::symlink("inside", worktree.join("alias")).expect("link");

        run_bootstrap(&[touch_in("alias")], &worktree);

        assert!(worktree.join("inside/ran").exists(), "the step did not run");
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_missing_is_skipped_and_later_steps_run() {
        let (_scratch, worktree, _outside) = worktree_and_outside();
        std::os::unix::fs::symlink("nowhere", worktree.join("dangling")).expect("link");

        for cwd in ["missing", "dangling"] {
            assert!(matches!(
                step_directory(Some(cwd), &worktree),
                StepDirectory::Unresolved(..)
            ));
        }
        run_bootstrap(
            &[
                touch_in("missing"),
                touch_in("dangling"),
                touch_in("inside"),
            ],
            &worktree,
        );

        assert!(
            worktree.join("inside/ran").exists(),
            "later steps did not run"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_worktree_reached_through_a_link_still_holds_its_subdirectory() {
        let (scratch, worktree, outside) = worktree_and_outside();
        let link = scratch.path().join("link");
        std::os::unix::fs::symlink(&worktree, &link).expect("link");
        std::os::unix::fs::symlink(&outside, worktree.join("frontend")).expect("link");

        assert!(matches!(
            step_directory(Some("inside"), &link),
            StepDirectory::Inside(_)
        ));
        assert!(matches!(
            step_directory(Some("frontend"), &link),
            StepDirectory::Outside(_)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_a_subdirectory_runs() {
        let (_scratch, worktree, _outside) = worktree_and_outside();

        run_bootstrap(&[touch_in("inside")], &worktree);

        assert!(worktree.join("inside/ran").exists(), "the step did not run");
    }

    #[cfg(unix)]
    #[test]
    fn a_sibling_whose_name_starts_with_the_worktree_is_outside() {
        let (scratch, worktree, _outside) = worktree_and_outside();
        let sibling = scratch.path().join("worktree-other");
        std::fs::create_dir_all(&sibling).expect("sibling");
        std::os::unix::fs::symlink(&sibling, worktree.join("next")).expect("link");

        assert!(matches!(
            step_directory(Some("next"), &worktree),
            StepDirectory::Outside(_)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn bootstrap_continues_after_a_failed_step() {
        let worktree_scratch = tempfile::tempdir().expect("scratch");
        let worktree = worktree_scratch.path().to_path_buf();
        let marker = worktree.join("continued");
        let steps = [
            BootstrapStep {
                command: "exit 1".into(),
                cwd: None,
            },
            BootstrapStep {
                command: "touch continued".into(),
                cwd: None,
            },
        ];

        run_bootstrap(&steps, &worktree);

        assert!(marker.exists(), "a failed step does not stop later steps");
    }
}
