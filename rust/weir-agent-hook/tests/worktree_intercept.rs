//! The worktree route: where a worktree an agent asks for is made, when the hook
//! passes the request through, and that nothing happens before the command runs. Unix only: the hook runtime itself only
//! runs there.
#![cfg(unix)]

mod support;

use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use support::{PANE, Repo, git};
use weir_agent_hook::{
    HookEnv, HookOutcome, HookRuntime, InterceptResult, NoSnapshots, finish_worktree,
    plan_worktree, run_worktree_hook,
};
use weir_agent_model::{WORKTREE_EVENT_FILE_SUFFIX, WORKTREE_EVENTS_DIRECTORY, WorktreeIntent};

/// The routing file as the application writes it beside the session: plain
/// paths, a named placement, and a per-provider routing map.
fn routing(repo: &Repo, routing_map: &str) -> PathBuf {
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[{{"command":"mkdir sub"}},{{"command":"touch nested.txt","cwd":"sub"}},{{"command":"touch escaped.txt","cwd":".."}}],"routing":{{{routing_map}}}}}]}}"#,
            repo.path.display()
        ),
    )
    .expect("worktree-routing.json");
    states
}

/// The intent of `command` run from the repository.
fn intent(repo: &Repo, command: &str) -> WorktreeIntent {
    WorktreeIntent::parse(command, Some(repo.path.to_str().expect("path"))).expect("intent")
}

/// Runs `command` as the agent's shell tool would, in the repository.
fn shell(repo: &Repo, command: &str) -> bool {
    std::process::Command::new("/bin/sh")
        .args(["-c", command])
        .current_dir(&repo.path)
        .output()
        .expect("sh")
        .status
        .success()
}

/// The command `plan_worktree` has the provider run in place of `command`.
fn rerouted(repo: &Repo, states: &std::path::Path, command: &str) -> (PathBuf, String) {
    match plan_worktree(&intent(repo, command), "claude", states) {
        InterceptResult::Reroute { path, command } => (path, command),
        InterceptResult::Passthrough => panic!("not rerouted: {command}"),
    }
}

fn events(states: &std::path::Path) -> Vec<PathBuf> {
    fs::read_dir(states.join(WORKTREE_EVENTS_DIRECTORY))
        .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
        .unwrap_or_default()
}

fn runtime_env(repo: &Repo, states: &std::path::Path) -> HookEnv {
    HookEnv::from_pairs([
        ("WEIR_PANE_ID", PANE),
        ("WEIR_AGENT_STATES_DIR", states.to_str().expect("path")),
        (
            "WEIR_CODEX_AGENT_STATES_DIR",
            states.to_str().expect("path"),
        ),
        (
            "WEIR_SESSIONS_DIR",
            repo.root.join("support/sessions").to_str().expect("path"),
        ),
        (
            "WEIR_CODEX_SESSIONS_DIR",
            repo.root.join("support/sessions").to_str().expect("path"),
        ),
    ])
}

fn payload(event: &str, repo: &Repo, command: &str) -> Value {
    serde_json::json!({
        "hook_event_name": event,
        "tool_name": "Bash",
        "cwd": repo.path,
        "tool_input": {"command": command, "description": "add a worktree"},
    })
}

#[test]
fn route_passes_through_when_the_routing_file_cannot_be_read() {
    let repo = Repo::new("unreadable-routing");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    let asked = intent(&repo, "git worktree add -b demo ../demo");

    // No file at all: the application has not written one yet.
    assert_eq!(
        plan_worktree(&asked, "claude", &states),
        InterceptResult::Passthrough
    );

    // A version this build does not know. Guessing at the shape could put a
    // worktree anywhere; passing through only puts it where the agent asked.
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":99,"projects":[{{"root":"{}","placement":{{"kind":"insideHidden"}},"bootstrap":[],"routing":{{}}}}]}}"#,
            repo.path.display()
        ),
    )
    .expect("routing");
    assert_eq!(
        plan_worktree(&asked, "claude", &states),
        InterceptResult::Passthrough
    );
}

/// The whole point: `PreToolUse` runs ahead of the person's prompt, so a
/// "No" there must leave nothing behind.
#[test]
fn planning_a_route_makes_no_worktree_and_no_branch() {
    let repo = Repo::new("plans-only");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b feature/demo ../demo");

    assert_eq!(path, repo.root.join("repo-feature-demo"));
    assert_eq!(
        command,
        format!(
            "git worktree add -b feature/demo {}",
            repo.root.join("repo-feature-demo").display()
        )
    );
    assert!(!path.exists(), "the worktree was made before the decision");
    assert_eq!(
        git(&repo.path, &["branch", "--list", "feature/demo"]).as_deref(),
        Some(""),
        "the branch was made before the decision"
    );
    assert!(events(&states).is_empty());
}

#[test]
fn a_route_keeps_the_start_point_the_agent_named() {
    let repo = Repo::new("start-point");
    let states = routing(&repo, "");
    git(&repo.path, &["branch", "base"]);
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo base");

    assert!(
        command.ends_with(&format!("{} base", path.display())),
        "{command}"
    );
    assert!(shell(&repo, &command));
    assert!(path.join("README.md").exists());
}

#[test]
fn finishing_a_route_runs_the_bootstrap_and_notifies() {
    let repo = Repo::new("finish");
    let states = routing(&repo, "");
    let (expected, command) = rerouted(&repo, &states, "git worktree add -b feature/demo ../demo");
    assert!(shell(&repo, &command));

    let created = finish_worktree(&intent(&repo, &command), "claude", &states).expect("created");

    assert_eq!(created.path, expected);
    assert_eq!(created.repo_root, repo.path);
    assert_eq!(created.branch, "feature/demo");
    assert_eq!(
        git(&expected, &["branch", "--show-current"]).as_deref(),
        Some("feature/demo")
    );
    assert!(
        expected.join("sub").join("nested.txt").exists(),
        "string steps run in the worktree and a relative cwd resolves inside it"
    );
    // `..` of the worktree is a directory that exists, so this proves the
    // guard and not a failed `chdir`.
    assert!(
        !repo.root.join("escaped.txt").exists(),
        "an escaping cwd is skipped"
    );
}

#[test]
fn a_command_that_failed_runs_no_bootstrap() {
    let repo = Repo::new("failed");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    fs::create_dir_all(&path).expect("folder");
    fs::write(path.join("in-the-way"), "x").expect("file");

    // Codex sends `PostToolUse` for a failed command too.
    assert!(!shell(&repo, &command), "git refuses a folder in use");
    assert_eq!(
        finish_worktree(&intent(&repo, &command), "claude", &states),
        None
    );
    assert!(!path.join("sub").exists());
}

#[test]
fn a_repeated_command_does_not_run_the_bootstrap_again() {
    let repo = Repo::new("repeated");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command));
    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());
    fs::remove_dir_all(path.join("sub")).expect("the person's change");

    assert_eq!(
        plan_worktree(&intent(&repo, &command), "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(!shell(&repo, &command), "git refuses a folder in use");
    assert_eq!(
        finish_worktree(&intent(&repo, &command), "claude", &states),
        None
    );
    assert!(!path.join("sub").exists(), "the bootstrap ran again");
}

/// The sheet's worktree was set up by the app. An agent's command over it fails,
/// and that must not run the steps a second time.
#[test]
fn a_worktree_made_elsewhere_is_not_set_up() {
    let repo = Repo::new("made-elsewhere");
    let states = routing(&repo, "");
    let path = repo.root.join("repo-demo");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-b",
            "demo",
            path.to_str().expect("path"),
        ],
    );
    let command = format!("git worktree add -b demo {}", path.display());

    assert_eq!(
        plan_worktree(&intent(&repo, &command), "claude", &states),
        InterceptResult::Passthrough
    );
    assert_eq!(
        finish_worktree(&intent(&repo, &command), "claude", &states),
        None
    );
    assert!(!path.join("sub").exists());
}

#[test]
fn a_command_that_went_elsewhere_is_not_set_up() {
    let repo = Repo::new("went-elsewhere");
    let states = routing(&repo, "");
    let command = "git worktree add -b demo ../repo-demo2";
    assert!(!repo.root.join("repo-demo").exists());
    assert!(shell(&repo, command));
    assert_eq!(
        finish_worktree(&intent(&repo, command), "claude", &states),
        None
    );
}

#[test]
fn a_command_with_more_after_it_runs_as_written() {
    let repo = Repo::new("chained");
    let states = routing(&repo, "");
    // The `cd` names the folder too, and would go to the wrong place.
    assert_eq!(
        plan_worktree(
            &intent(&repo, "git worktree add -b demo ../demo && cd ../demo"),
            "claude",
            &states
        ),
        InterceptResult::Passthrough
    );
}

/// Another call for the folder, between the command that made it and that
/// command's `PostToolUse`, must not take the setup away from it.
#[test]
fn an_overlapping_call_leaves_the_setup_to_the_call_that_made_the_worktree() {
    let repo = Repo::new("overlapping");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command));

    assert_eq!(
        plan_worktree(&intent(&repo, &command), "claude", &states),
        InterceptResult::Passthrough
    );

    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());
    assert!(path.join("sub").exists());
}

/// A turn stopped between the command and its `PostToolUse` is the likelier
/// way to meet this: the agent's next try picks the setup up, on a provider that
/// calls the hook for a failed command. That is Codex: Claude Code sends
/// `PostToolUseFailure`, which has no worktree hook.
#[test]
fn a_retry_after_a_lost_post_tool_use_runs_the_setup() {
    let repo = Repo::new("lost-post");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command));

    assert_eq!(
        plan_worktree(&intent(&repo, &command), "codex", &states),
        InterceptResult::Passthrough
    );
    assert!(!shell(&repo, &command), "git refuses a folder in use");

    assert!(finish_worktree(&intent(&repo, &command), "codex", &states).is_some());
    assert!(path.join("sub").exists());
}

/// The old intercept ran Git in the project itself. A command keeps its own
/// `-C` now, and another repository's worktree has no place in this folder.
#[test]
fn a_command_for_another_repository_runs_as_written() {
    let repo = Repo::new("other-repository");
    let other = repo.root.join("other");
    fs::create_dir_all(&other).expect("other");
    git(&other, &["init", "-q"]);
    let states = routing(&repo, "");
    for command in [
        "git -C ../other worktree add -b demo ../demo",
        "git --git-dir=../other/.git worktree add -b demo ../demo",
    ] {
        assert_eq!(
            plan_worktree(&intent(&repo, command), "claude", &states),
            InterceptResult::Passthrough,
            "{command}"
        );
    }
    let same = format!(
        "git -C {} worktree add -b demo ../demo",
        repo.path.display()
    );
    assert!(matches!(
        plan_worktree(&intent(&repo, &same), "claude", &states),
        InterceptResult::Reroute { .. }
    ));
}

/// A repository of its own inside the project's folder is another repository
/// too, whichever folder the agent's call says it runs in.
#[test]
fn a_command_from_a_repository_inside_the_project_runs_as_written() {
    let repo = Repo::new("nested-repository");
    let inner = repo.path.join("inner");
    fs::create_dir_all(&inner).expect("inner");
    git(&inner, &["init", "-q"]);
    let states = routing(&repo, "");
    let asked = WorktreeIntent::parse(
        "git worktree add -b demo ../demo",
        Some(inner.to_str().expect("path")),
    )
    .expect("intent");
    assert_eq!(
        plan_worktree(&asked, "claude", &states),
        InterceptResult::Passthrough
    );
}

/// This hook runs ahead of the person's prompt. Handing the command's own words
/// to Git to ask which repository they mean would run this alias before anyone
/// has said yes to it.
#[test]
fn nothing_the_command_says_runs_before_its_permission_check() {
    let repo = Repo::new("alias");
    let states = routing(&repo, "");
    let sentinel = repo.root.join("ran");
    let command = format!(
        "git -c alias.x=!touch${{IFS}}{} x worktree add -b demo ../demo",
        sentinel.display()
    );
    assert_eq!(
        plan_worktree(&intent(&repo, &command), "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(!sentinel.exists(), "the command's alias ran in the hook");
}

/// Removing one file from two threads on APFS can succeed in both, which ran the
/// bootstrap twice under a stress run.
#[test]
fn of_calls_that_finish_together_one_runs_the_setup() {
    for round in 0..20 {
        let repo = Repo::new(&format!("together-{round}"));
        let states = routing(&repo, "");
        let (_, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
        assert!(shell(&repo, &command));
        let asked = intent(&repo, &command);
        let barrier = std::sync::Barrier::new(4);
        let finished = std::thread::scope(|scope| {
            let calls: Vec<_> = (0..4)
                .map(|_| {
                    scope.spawn(|| {
                        barrier.wait();
                        finish_worktree(&asked, "codex", &states).is_some()
                    })
                })
                .collect();
            calls
                .into_iter()
                .map(|call| call.join().expect("call"))
                .filter(|finished| *finished)
                .count()
        });
        assert_eq!(finished, 1, "round {round}");
    }
}

/// Two providers can reach one worktree, and each has its own state folder.
#[test]
fn a_call_from_another_provider_leaves_the_setup_to_the_one_that_made_it() {
    let repo = Repo::new("two-providers");
    let states = routing(&repo, "");
    let codex_states = repo.root.join("support").join("codex-agent-states");
    fs::create_dir_all(&codex_states).expect("states");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command));

    assert_eq!(
        plan_worktree(&intent(&repo, &command), "codex", &codex_states),
        InterceptResult::Passthrough
    );

    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());
    assert!(path.join("sub").exists());
}

/// A person who refused has gone on to other things. A worktree the sheet makes
/// much later is not the one that command was going to make.
#[test]
fn a_mark_from_long_ago_sets_nothing_up() {
    let repo = Repo::new("old-mark");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    let marks: Vec<PathBuf> = fs::read_dir(repo.root.join("support/worktrees-awaited"))
        .expect("marks")
        .flatten()
        .map(|entry| entry.path())
        .collect();
    assert_eq!(marks.len(), 1);
    let long_ago = std::time::SystemTime::now() - std::time::Duration::from_hours(2);
    fs::File::options()
        .write(true)
        .open(&marks[0])
        .expect("mark")
        .set_modified(long_ago)
        .expect("age");
    assert!(shell(&repo, &command));

    assert_eq!(
        finish_worktree(&intent(&repo, &command), "claude", &states),
        None
    );
    assert!(!path.join("sub").exists());
}

/// A model that writes the project's folder itself, as `agy`'s does when told
/// to, needs no rerouting and still gets its setup.
#[test]
fn a_command_that_already_names_the_folder_is_set_up() {
    let repo = Repo::new("named");
    let states = routing(&repo, "");
    let path = repo.root.join("repo-demo");
    let command = format!("git worktree add -b demo {}", path.display());
    assert_eq!(
        plan_worktree(&intent(&repo, &command), "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(shell(&repo, &command));
    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());
    assert!(path.join("sub").exists());
}

/// What Git lists decides. `agy`'s model writes out the command it is told to
/// run, and may quote the folder its own way.
#[test]
fn a_worktree_in_the_right_folder_is_set_up_however_the_command_spelled_it() {
    let repo = Repo::new("spelling");
    let states = routing(&repo, "");
    let folder = repo.root.join("repo-demo");
    let command = format!("git worktree add -b demo \"{}\" && cd ..", folder.display());
    assert_eq!(
        plan_worktree(&intent(&repo, &command), "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(shell(&repo, &command));

    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());
    assert!(folder.join("sub").exists());
}

/// `git worktree add` lists a worktree before it has checked its files out, and
/// `--lock` holds it under its own reason, which stays once the checkout is done.
/// A filter holds the checkout open until we let it go, with a limit of its own so
/// a failure here cannot leave Git running.
#[test]
fn the_bootstrap_waits_for_the_checkout() {
    for (name, option) in [("plain", ""), ("locked", "--lock ")] {
        let repo = Repo::new(&format!("checkout-{name}"));
        let states = routing(&repo, "");
        let gate = repo.root.join("gate");
        let filter = format!(
            "i=0; while [ ! -e '{}' ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done; cat",
            gate.display()
        );
        git(&repo.path, &["config", "filter.held.smudge", &filter]);
        git(&repo.path, &["config", "filter.held.clean", "cat"]);
        fs::write(repo.path.join(".gitattributes"), "*.held filter=held\n").expect("attributes");
        fs::write(repo.path.join("a.held"), "a").expect("file");
        git(&repo.path, &["add", "."]);
        git(&repo.path, &["commit", "-qm", "held file"]);
        let (path, command) = rerouted(
            &repo,
            &states,
            &format!("git worktree add {option}-b demo ../demo"),
        );
        let asked = intent(&repo, &command);

        // Started here and not on a thread beside our polling: on macOS a child
        // forked during another's `output()` can inherit its pipe, and that call
        // then blocks until this command ends.
        let mut adding = std::process::Command::new("/bin/sh")
            .args(["-c", &command])
            .current_dir(&repo.path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("sh");
        std::thread::scope(|scope| {
            let started = std::time::Instant::now();
            while !git(&repo.path, &["worktree", "list", "--porcelain"])
                .is_some_and(|listing| listing.contains("refs/heads/demo"))
            {
                assert!(started.elapsed().as_secs() < 25, "{name}: never listed");
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            let finishing = scope.spawn(|| finish_worktree(&asked, "claude", &states));
            std::thread::sleep(std::time::Duration::from_millis(600));
            assert!(!finishing.is_finished(), "{name}: did not wait");
            assert!(
                !path.join("sub").exists(),
                "{name}: the bootstrap ran early"
            );

            fs::write(&gate, "").expect("gate");

            assert!(finishing.join().expect("finish").is_some(), "{name}");
            assert!(path.join("a.held").exists(), "{name}");
            assert!(path.join("sub").exists(), "{name}");
            assert!(adding.wait().expect("add").success(), "{name}");
        });
    }
}

/// A worktree without files has nothing to wait for, and with `--lock` no index
/// would ever end the wait.
#[test]
fn a_locked_worktree_without_a_checkout_is_not_waited_for() {
    let repo = Repo::new("locked-no-checkout");
    let states = routing(&repo, "");
    let (_, command) = rerouted(
        &repo,
        &states,
        "git worktree add --lock --no-checkout -b demo ../demo",
    );
    assert!(shell(&repo, &command));
    let started = std::time::Instant::now();

    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());

    assert!(started.elapsed().as_secs() < 30);
}

/// Git only says `initializing` while it checks out, but a person can write it too.
#[test]
fn a_lock_a_person_called_initializing_does_not_hold_the_setup() {
    let repo = Repo::new("lock-reason");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command));
    let lock = ["worktree", "lock", "--reason", "initializing"];
    git(
        &repo.path,
        &[lock.as_slice(), &[path.to_str().expect("path")]].concat(),
    );
    let started = std::time::Instant::now();

    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());

    assert!(started.elapsed().as_secs() < 30);
}

/// `feature/alpha` and `feature-alpha` share a folder. The second is rerouted
/// too, and Git's refusal tells the agent, rather than it landing elsewhere.
#[test]
fn a_branch_that_shares_another_branchs_folder_runs_as_written() {
    let repo = Repo::new("shared-folder");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b feature/alpha ../x");
    assert!(shell(&repo, &command));

    let other = "git worktree add -b feature-alpha ../y";
    assert!(path.exists());
    assert_eq!(
        plan_worktree(&intent(&repo, other), "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(shell(&repo, other));
    assert_eq!(
        finish_worktree(&intent(&repo, other), "claude", &states),
        None
    );
}

#[test]
fn route_gives_branches_with_one_last_part_their_own_folders() {
    let repo = Repo::new("one-last-part");
    let states = routing(&repo, "");
    for (branch, folder) in [
        ("feature/alpha", "repo-feature-alpha"),
        ("fix/alpha", "repo-fix-alpha"),
    ] {
        let (path, _) = rerouted(
            &repo,
            &states,
            &format!("git worktree add -b {branch} ../elsewhere"),
        );
        assert_eq!(path, repo.root.join(folder), "{branch}");
    }
}

#[test]
fn route_honors_a_custom_placement_with_spaces_in_its_folder() {
    let repo = Repo::at("custom", "My 開発");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    let parent = repo.root.join("wt dir");
    // Plain paths: spaces and non-ASCII names need no decoding here, which is
    // the point of the application normalizing them before writing.
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{root}/My 開発","placement":{{"kind":"custom","parent":"{root}/wt dir"}},"bootstrap":[],"routing":{{}}}}]}}"#,
            root = repo.root.display()
        ),
    )
    .expect("routing");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert_eq!(path, parent.join("demo"));

    assert!(shell(&repo, &command), "{command}");
    assert!(path.join("README.md").exists());
    assert!(finish_worktree(&intent(&repo, &command), "claude", &states).is_some());
}

#[test]
fn route_passes_through_when_routing_is_off_or_the_project_is_unknown() {
    let repo = Repo::new("passthrough");
    let asked = intent(&repo, "git worktree add -b demo ../demo");
    let states = routing(&repo, r#""claude":false"#);
    assert_eq!(
        plan_worktree(&asked, "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(matches!(
        plan_worktree(&asked, "codex", &states),
        InterceptResult::Reroute { .. }
    ));
    let elsewhere = repo.root.join("elsewhere");
    fs::create_dir_all(&elsewhere).expect("dir");
    let outside = WorktreeIntent::parse(
        "git worktree add -b other ../x",
        Some(elsewhere.to_str().expect("path")),
    )
    .expect("intent");
    assert_eq!(
        plan_worktree(&outside, "claude", &states),
        InterceptResult::Passthrough
    );
}

/// Claude Code goes on to its own checks only when no decision is given, and
/// Codex ignores a new input without `allow`. Both measured on real builds.
#[test]
fn the_pre_tool_use_reply_is_the_one_each_provider_needs() {
    let repo = Repo::new("hook");
    let states = routing(&repo, "");
    let env = runtime_env(&repo, &states);
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    let asked = payload("PreToolUse", &repo, "git worktree add -b demo ../demo");
    let expected = format!(
        "git worktree add -b demo {}",
        repo.root.join("repo-demo").display()
    );
    for (provider, decision) in [("claude", Value::Null), ("codex", Value::from("allow"))] {
        let outcome = run_worktree_hook(provider, asked.to_string().as_bytes(), &runtime);
        assert_eq!(outcome.exit_code(), 0, "{provider}");
        let HookOutcome::Intercepted {
            stdout: Some(stdout),
            ..
        } = outcome
        else {
            panic!("{provider}: {outcome:?}");
        };
        let reply: Value = serde_json::from_slice(&stdout).expect("json");
        let inner = &reply["hookSpecificOutput"];
        assert_eq!(inner["hookEventName"], "PreToolUse");
        assert_eq!(inner["updatedInput"]["command"], expected.as_str());
        assert_eq!(inner["updatedInput"]["description"], "add a worktree");
        assert_eq!(inner["permissionDecision"], decision, "{provider}");
    }
    assert!(!repo.root.join("repo-demo").exists());
    let other =
        r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#;
    assert_eq!(
        run_worktree_hook("claude", other.as_bytes(), &runtime),
        HookOutcome::Applied
    );
}

#[test]
fn the_post_tool_use_reply_tells_the_model_the_folder_and_the_host_hears() {
    let repo = Repo::new("post-hook");
    let states = routing(&repo, "");
    let env = runtime_env(&repo, &states);
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    let path = repo.root.join("repo-feature-demo");
    let command = format!("git worktree add -b feature/demo {}", path.display());
    let asked = payload("PreToolUse", &repo, &command);
    assert_eq!(
        run_worktree_hook("claude", asked.to_string().as_bytes(), &runtime),
        HookOutcome::Applied
    );
    assert!(shell(&repo, &command));

    let finished = payload("PostToolUse", &repo, &command);
    let outcome = run_worktree_hook("claude", finished.to_string().as_bytes(), &runtime);

    assert_eq!(outcome.exit_code(), 0);
    let HookOutcome::Intercepted {
        stdout: Some(stdout),
        ..
    } = outcome
    else {
        panic!("{outcome:?}");
    };
    let reply: Value = serde_json::from_slice(&stdout).expect("json");
    assert_eq!(reply["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    assert!(
        reply["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .expect("context")
            .contains("repo-feature-demo")
    );
    let events = events(&states);
    assert_eq!(events.len(), 1);
    // The host lists events by this suffix, so a name without it is an
    // event nothing reads.
    assert!(
        events[0]
            .to_string_lossy()
            .ends_with(WORKTREE_EVENT_FILE_SUFFIX)
    );
    let event: Value = serde_json::from_slice(&fs::read(&events[0]).expect("event")).expect("json");
    assert_eq!(event["event"], "WorktreeCreate");
    assert_eq!(event["branch"], "feature/demo");
    assert_eq!(event["worktreePath"], path.to_string_lossy().as_ref());
}

/// A routing file whose first entry this build cannot interpret, followed by
/// the entry that owns `cwd`.
#[test]
fn route_skips_an_unreadable_entry_and_keeps_routing_the_rest() {
    let repo = Repo::new("mixed-routing");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{root}","placement":{{"kind":"fromTheFuture"}},"bootstrap":[],"routing":{{}}}},{{"placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{}}}},{{"root":"{root}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{}}}}]}}"#,
            root = repo.path.display()
        ),
    )
    .expect("worktree-routing.json");
    // A placement a later version adds, or an entry missing its root, must not
    // turn every other project's routing off.
    assert!(matches!(
        plan_worktree(
            &intent(&repo, "git worktree add -b demo ../demo"),
            "claude",
            &states
        ),
        InterceptResult::Reroute { .. }
    ));
}

/// Writes a routing file with one plain sibling-placed project per root.
fn routing_for(repo: &Repo, roots: &[&std::path::Path]) -> PathBuf {
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    let projects: Vec<String> = roots
        .iter()
        .map(|root| {
            format!(
                r#"{{"root":"{}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{}}}}"#,
                root.display()
            )
        })
        .collect();
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{}]}}"#,
            projects.join(",")
        ),
    )
    .expect("worktree-routing.json");
    states
}

/// A project at the home folder must not take the projects inside it, whichever
/// the person added first.
#[test]
fn the_deepest_project_owns_a_folder_in_either_order() {
    let repo = Repo::new("nested-project");
    let outer = repo.path.parent().expect("parent").to_path_buf();
    for roots in [[outer.as_path(), &repo.path], [&repo.path, outer.as_path()]] {
        let states = routing_for(&repo, &roots);
        let (path, _) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
        assert_eq!(
            path,
            repo.path.with_file_name(format!(
                "{}-demo",
                repo.path.file_name().expect("name").to_string_lossy()
            ))
        );
    }
}

/// An opt-out belongs to the project that owns the folder, not to one around it.
#[test]
fn a_project_around_this_one_does_not_decide_its_routing() {
    let repo = Repo::new("nested-opt-out");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{"claude":false}}}},{{"root":"{}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{}}}}]}}"#,
            repo.path.parent().expect("parent").display(),
            repo.path.display()
        ),
    )
    .expect("worktree-routing.json");
    rerouted(&repo, &states, "git worktree add -b demo ../demo");
}

/// macOS reports `/private/tmp/x` for a folder Weir recorded as `/tmp/x`.
#[test]
fn a_project_recorded_through_a_link_owns_its_real_folder() {
    let repo = Repo::new("linked-root");
    let parent = repo.path.parent().expect("parent");
    let link = parent.join("link-to-repo");
    std::os::unix::fs::symlink(&repo.path, &link).expect("link");
    let states = routing_for(&repo, &[&link]);
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command), "{command}");
    assert!(path.join(".git").exists(), "{}", path.display());
}

/// Git makes a worktree in an empty folder and refuses anything else there.
#[test]
fn a_folder_with_something_in_it_keeps_the_command_as_written() {
    let repo = Repo::new("taken-folder");
    let states = routing(&repo, "");
    let path = repo.root.join("repo-demo");
    fs::create_dir(&path).expect("folder");
    rerouted(&repo, &states, "git worktree add -b demo ../demo");
    fs::write(path.join("kept.txt"), "").expect("file");
    assert_eq!(
        plan_worktree(
            &intent(&repo, "git worktree add -b demo ../demo"),
            "claude",
            &states
        ),
        InterceptResult::Passthrough
    );
}

/// A mark from a command that never ran says nothing about one for another
/// repository, whatever Git lists in this one's folder.
#[test]
fn a_command_for_another_repository_does_not_set_up_this_one() {
    let repo = Repo::new("stale-mark");
    let states = routing(&repo, "");
    let (path, command) = rerouted(&repo, &states, "git worktree add -b demo ../demo");
    assert!(shell(&repo, &command));
    let other = repo.root.join("other");
    fs::create_dir(&other).expect("other");
    git(&other, &["init", "-q"]);
    git(
        &other,
        &[
            "-c",
            "user.name=a",
            "-c",
            "user.email=a@a",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "i",
        ],
    );
    let elsewhere = format!(
        "git -C {} worktree add -b demo {}",
        other.display(),
        repo.root.join("elsewhere").display()
    );
    assert!(shell(&repo, &elsewhere));
    assert_eq!(
        finish_worktree(&intent(&repo, &elsewhere), "claude", &states),
        None
    );
    assert!(!path.join("sub").exists());
}

/// A worktree beside the project has the project's rules, as it has its checks.
#[test]
fn a_command_from_a_worktree_beside_the_project_is_rerouted() {
    let repo = Repo::new("beside");
    let beside = repo.root.join("repo-beside");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "beside",
            beside.to_str().expect("path"),
        ],
    );
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{}","worktrees":["{}"],"placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{}}}}]}}"#,
            repo.path.display(),
            beside.display()
        ),
    )
    .expect("worktree-routing.json");
    let asked = WorktreeIntent::parse(
        "git worktree add -b demo ../demo",
        Some(beside.to_str().expect("path")),
    )
    .expect("intent");
    let InterceptResult::Reroute { path, .. } = plan_worktree(&asked, "claude", &states) else {
        panic!("not rerouted");
    };
    assert_eq!(path, repo.root.join("repo-demo"));
}

/// Writes two projects, the second a folder inside the repository's root.
fn nested_routing(repo: &Repo, inner: &str) -> PathBuf {
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::create_dir_all(repo.path.join("pkg")).expect("pkg");
    fs::write(
        repo.root.join("support").join("worktree-routing.json"),
        format!(
            r#"{{"schemaVersion":1,"projects":[{{"root":"{root}","placement":{{"kind":"siblingPrefixed"}},"bootstrap":[],"routing":{{}}}},{{"root":"{root}/pkg",{inner},"bootstrap":[]}}]}}"#,
            root = repo.path.display()
        ),
    )
    .expect("worktree-routing.json");
    states
}

/// `-C` says where Git runs, so it picks the project as the folder would.
#[test]
fn a_project_turned_off_stays_off_through_dash_c() {
    let repo = Repo::new("dash-c");
    let states = nested_routing(
        &repo,
        r#""placement":{"kind":"siblingPrefixed"},"routing":{"claude":false}"#,
    );
    assert_eq!(
        plan_worktree(
            &intent(&repo, "git -C pkg worktree add -b demo ../../demo"),
            "claude",
            &states
        ),
        InterceptResult::Passthrough
    );
}

/// The placement inside is unknown, and the one around it is not what that
/// project asked for.
#[test]
fn a_project_with_an_unknown_placement_does_not_take_the_rules_around_it() {
    let repo = Repo::new("unknown-inner");
    let states = nested_routing(
        &repo,
        r#""placement":{"kind":"fromTheFuture"},"routing":{}"#,
    );
    let asked = WorktreeIntent::parse(
        "git worktree add -b demo ../../demo",
        Some(repo.path.join("pkg").to_str().expect("path")),
    )
    .expect("intent");
    assert_eq!(
        plan_worktree(&asked, "claude", &states),
        InterceptResult::Passthrough
    );
}

#[test]
fn the_last_checkout_option_decides() {
    let repo = Repo::new("checkout-order");
    for (command, skips) in [
        ("git worktree add --no-checkout -b demo ../demo", true),
        (
            "git worktree add --checkout --no-checkout -b demo ../demo",
            true,
        ),
        (
            "git worktree add --no-checkout --checkout -b demo ../demo",
            false,
        ),
        ("git worktree add -b demo ../demo", false),
    ] {
        assert_eq!(intent(&repo, command).skips_checkout(), skips, "{command}");
    }
}
