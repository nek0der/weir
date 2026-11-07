//! This is the git runner the hook's fixtures share, for the integration tests'
//! `support` module and the restore unit tests alike (which include this
//! file by path, as a unit test cannot reach `tests/`).

use std::path::Path;
use std::process::{Command, Output};

/// Prepares Git for a scratch repository. Keeping only PATH prevents
/// inherited Git variables from selecting a different repository or index.
pub fn command(cwd: &Path, args: &[&str]) -> Command {
    let mut git = Command::new("git");
    git.env_clear();
    if let Some(path) = std::env::var_os("PATH") {
        git.env("PATH", path);
    }
    git.env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .arg("-C")
        .arg(cwd)
        .args(args);
    git
}

/// Runs Git and leaves the exit status for the caller to interpret.
pub fn run(cwd: &Path, args: &[&str]) -> std::io::Result<Output> {
    command(cwd, args).output()
}

/// Does what `run` does, for a step the fixture needs: a git that cannot
/// start, or exits with a failure, fails the test there, and otherwise the
/// trimmed output is returned.
pub fn required(cwd: &Path, args: &[&str]) -> String {
    let output = run(cwd, args).expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    stdout(&output)
}

/// Does what `run` does, for a step whose failed exit is an answer (a ref
/// that is not there), and returns `None` for that exit. A git that cannot
/// start still fails the test.
pub fn optional(cwd: &Path, args: &[&str]) -> Option<String> {
    let output = run(cwd, args).expect("git runs");
    output.status.success().then(|| stdout(&output))
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}
