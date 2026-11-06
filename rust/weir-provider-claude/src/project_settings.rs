//! Where Claude Code keeps a project's settings files, for the status line
//! relay, which must read the ones Claude Code reads.
//!
//! Claude Code reads the shared `.claude/settings.json` from the session's
//! starting folder, and since 2.1.211 the local `.claude/settings.local.json`
//! from the root of the Git repository around it, the main checkout's root
//! for a worktree (<https://code.claude.com/docs/en/settings>, "Where Claude
//! Code keeps the local file in a git repository"). The local file stays in
//! the starting folder outside a repository, when the root is the home
//! folder, on a platform with no user ids (Windows), and when the root, its
//! `.git`, or its `.claude` is not the person's. A local file an earlier
//! version left in the starting folder is still read, below the root's. No
//! project file is read from inside a `connector-downloads` folder, where
//! Claude Code saves what claude.ai's connectors download. The rules here are
//! those of Claude Code 2.1.319's own code (`findGitRoot`,
//! `findCanonicalGitRoot`, and the local settings store).

use std::path::{Component, Path, PathBuf};
use weir_agent_model::{FileKind, SettingsFiles};

/// The folder Claude Code saves claude.ai connector downloads in; it reads no
/// project settings from inside one that holds a `.gitignore`.
const CONNECTOR_DOWNLOADS: &str = "connector-downloads";

/// A project's settings files, highest precedence first.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct ProjectFiles {
    /// The local files: the repository root's, then the starting folder's
    /// from an earlier version, when the root is elsewhere.
    pub(crate) local: Vec<PathBuf>,
    /// The shared file.
    pub(crate) shared: Option<PathBuf>,
}

/// The settings files Claude Code reads for a session started in `start`.
pub(crate) fn project_files(start: &Path, files: &dyn SettingsFiles) -> ProjectFiles {
    let start = normalized(start);
    let in_downloads = is_in_connector_downloads(&start, files);
    let local_folder = local_settings_folder(&start, files);
    let mut local = Vec::new();
    if !(in_downloads && is_in_connector_downloads(&local_folder, files)) {
        local.push(local_file(&local_folder));
    }
    if local_folder != start && !in_downloads {
        local.push(local_file(&start));
    }
    ProjectFiles {
        local,
        shared: (!in_downloads).then(|| start.join(".claude").join("settings.json")),
    }
}

fn local_file(folder: &Path) -> PathBuf {
    folder.join(".claude").join("settings.local.json")
}

/// The folder Claude Code keeps the local file in for a session started in
/// `start`: the repository's canonical root, unless one of the exceptions
/// keeps it in `start`.
fn local_settings_folder(start: &Path, files: &dyn SettingsFiles) -> PathBuf {
    let Some(root) = git_root(start, files) else {
        return start.to_path_buf();
    };
    let canonical = canonical_git_root(&root, files);
    if canonical == start
        || files
            .home()
            .is_some_and(|home| normalized(&home) == canonical)
        || !is_owned_by_user(&canonical, files)
    {
        return start.to_path_buf();
    }
    canonical
}

/// The nearest folder at or above `start` with a `.git` entry that is a
/// folder or a file, or a link to one (`findGitRoot`).
fn git_root(start: &Path, files: &dyn SettingsFiles) -> Option<PathBuf> {
    start
        .ancestors()
        .find(|folder| {
            let entry = folder.join(".git");
            match files.entry(&entry).map(|found| found.kind) {
                Some(FileKind::Directory | FileKind::File) => true,
                Some(FileKind::Link) => files.target(&entry).is_some_and(|target| {
                    matches!(target.kind, FileKind::Directory | FileKind::File)
                }),
                _ => false,
            }
        })
        .map(Path::to_path_buf)
}

/// The main checkout's root for a worktree's `root`, else `root` itself
/// (`findCanonicalGitRoot`). A worktree's `.git` file names its folder under
/// the main repository's `worktrees/`, whose `commondir` names that
/// repository and whose `gitdir` names this `.git` back; anything else is
/// not a worktree Claude Code follows.
fn canonical_git_root(root: &Path, files: &dyn SettingsFiles) -> PathBuf {
    worktree_main_root(root, files).unwrap_or_else(|| root.to_path_buf())
}

fn worktree_main_root(root: &Path, files: &dyn SettingsFiles) -> Option<PathBuf> {
    let dot_git = root.join(".git");
    if files.entry(&dot_git)?.kind != FileKind::File {
        return None;
    }
    let gitdir = files.read_text(&dot_git)?;
    let gitdir = gitdir.trim().strip_prefix("gitdir:")?.trim();
    let worktree = normalized(&root.join(gitdir));
    let common = regular_text(&worktree.join("commondir"), files)?;
    let common = normalized(&worktree.join(common.trim()));
    if worktree.parent()? != common.join("worktrees") {
        return None;
    }
    // Compared with every link resolved, as Claude Code compares them: Git
    // writes the paths it resolved itself.
    let back = regular_text(&worktree.join("gitdir"), files)?;
    let back = files.real_path(&normalized(&worktree.join(back.trim())))?;
    if back != files.real_path(root)?.join(".git") {
        return None;
    }
    if common.file_name()? != ".git" {
        // A bare repository's worktree: its root is the repository, unless
        // that holds a `.git` of its own.
        return files
            .entry(&common.join(".git"))
            .is_none()
            .then_some(common);
    }
    common.parent().map(Path::to_path_buf)
}

fn regular_text(path: &Path, files: &dyn SettingsFiles) -> Option<String> {
    (files.entry(path)?.kind == FileKind::File)
        .then(|| files.read_text(path))
        .flatten()
}

/// Whether `folder`, its `.git`, and its `.claude` when there is one belong
/// to the user the runtime runs as. False where there are no user ids.
fn is_owned_by_user(folder: &Path, files: &dyn SettingsFiles) -> bool {
    let Some(user) = files.user_id() else {
        return false;
    };
    let owned = |entry: Option<weir_agent_model::FileEntry>| {
        entry.is_some_and(|entry| entry.owner == Some(user))
    };
    owned(files.target(folder))
        && owned(files.entry(&folder.join(".git")))
        && files
            .entry(&folder.join(".claude"))
            .is_none_or(|claude| claude.owner == Some(user))
}

/// Whether `folder` lies in a `connector-downloads` folder that holds a
/// `.gitignore`, the way Claude Code marks the one it makes.
fn is_in_connector_downloads(folder: &Path, files: &dyn SettingsFiles) -> bool {
    folder.ancestors().any(|ancestor| {
        ancestor
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.to_lowercase() == CONNECTOR_DOWNLOADS)
            && files.entry(&ancestor.join(".gitignore")).is_some()
    })
}

/// `path` with `.` and `..` resolved by name, as Node's `path.resolve` does,
/// without touching the file system.
fn normalized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use weir_agent_model::FileEntry;

    const ME: u32 = 501;

    /// A file system in memory: each path's kind, owner, and text.
    #[derive(Default)]
    struct Fake {
        entries: BTreeMap<PathBuf, (FileKind, u32, String)>,
        home: Option<PathBuf>,
        user: Option<u32>,
    }

    impl Fake {
        fn new() -> Self {
            Self {
                user: Some(ME),
                home: Some(PathBuf::from("/Users/me")),
                ..Self::default()
            }
        }
        fn dir(mut self, path: &str) -> Self {
            self.entries.insert(
                PathBuf::from(path),
                (FileKind::Directory, ME, String::new()),
            );
            self
        }
        fn file(mut self, path: &str, text: &str) -> Self {
            self.entries
                .insert(PathBuf::from(path), (FileKind::File, ME, text.to_owned()));
            self
        }
        fn owned_by(mut self, path: &str, owner: u32) -> Self {
            self.entries.get_mut(Path::new(path)).expect("entry").1 = owner;
            self
        }
        /// A repository at `/r` with a worktree at `/w`.
        fn repository_with_worktree() -> Self {
            Self::new()
                .dir("/r")
                .dir("/r/.git")
                .dir("/r/.git/worktrees/w")
                .file("/r/.git/worktrees/w/commondir", "../..\n")
                .file("/r/.git/worktrees/w/gitdir", "/w/.git\n")
                .dir("/w")
                .file("/w/.git", "gitdir: /r/.git/worktrees/w\n")
        }
    }

    impl SettingsFiles for Fake {
        fn entry(&self, path: &Path) -> Option<FileEntry> {
            self.entries.get(path).map(|(kind, owner, _)| FileEntry {
                kind: *kind,
                owner: Some(*owner),
            })
        }
        fn target(&self, path: &Path) -> Option<FileEntry> {
            self.entry(path)
        }
        fn real_path(&self, path: &Path) -> Option<PathBuf> {
            self.entries.contains_key(path).then(|| path.to_path_buf())
        }
        fn read_text(&self, path: &Path) -> Option<String> {
            self.entries
                .get(path)
                .filter(|(kind, _, _)| *kind == FileKind::File)
                .map(|(_, _, text)| text.clone())
        }
        fn user_id(&self) -> Option<u32> {
            self.user
        }
        fn home(&self) -> Option<PathBuf> {
            self.home.clone()
        }
    }

    fn paths(list: &[&str]) -> Vec<PathBuf> {
        list.iter().map(PathBuf::from).collect()
    }

    #[test]
    fn outside_a_repository_both_files_are_in_the_starting_folder() {
        let files = project_files(Path::new("/p"), &Fake::new().dir("/p"));
        assert_eq!(files.local, paths(&["/p/.claude/settings.local.json"]));
        assert_eq!(
            files.shared,
            Some(PathBuf::from("/p/.claude/settings.json"))
        );
    }

    #[test]
    fn in_a_subfolder_the_local_file_is_the_root_s_then_the_starting_folder_s() {
        let fake = Fake::new().dir("/r").dir("/r/.git").dir("/r/sub");
        let files = project_files(Path::new("/r/sub"), &fake);
        assert_eq!(
            files.local,
            paths(&[
                "/r/.claude/settings.local.json",
                "/r/sub/.claude/settings.local.json"
            ])
        );
        assert_eq!(
            files.shared,
            Some(PathBuf::from("/r/sub/.claude/settings.json"))
        );
        let at_root = project_files(Path::new("/r"), &fake);
        assert_eq!(at_root.local, paths(&["/r/.claude/settings.local.json"]));
    }

    #[test]
    fn in_a_worktree_the_local_file_is_the_main_checkout_s() {
        let files = project_files(Path::new("/w"), &Fake::repository_with_worktree());
        assert_eq!(
            files.local,
            paths(&[
                "/r/.claude/settings.local.json",
                "/w/.claude/settings.local.json"
            ])
        );
        assert_eq!(
            files.shared,
            Some(PathBuf::from("/w/.claude/settings.json"))
        );
    }

    #[test]
    fn a_gitdir_that_is_not_a_worktree_of_its_repository_keeps_the_worktree_root() {
        for fake in [
            // `gitdir` names another worktree's `.git`.
            Fake::repository_with_worktree().file("/r/.git/worktrees/w/gitdir", "/x/.git\n"),
            // `commondir` names a repository the folder is not under.
            Fake::repository_with_worktree().file("/r/.git/worktrees/w/commondir", "/elsewhere\n"),
            // Not a `gitdir:` line.
            Fake::repository_with_worktree().file("/w/.git", "nonsense\n"),
        ] {
            let files = project_files(Path::new("/w"), &fake);
            assert_eq!(files.local, paths(&["/w/.claude/settings.local.json"]));
        }
    }

    #[test]
    fn the_local_file_stays_in_the_starting_folder_when_the_root_is_not_the_person_s() {
        let base = || Fake::new().dir("/r").dir("/r/.git").dir("/r/sub");
        for fake in [
            base().owned_by("/r", 0),
            base().owned_by("/r/.git", 0),
            base().dir("/r/.claude").owned_by("/r/.claude", 0),
            Fake {
                user: None,
                ..base()
            },
        ] {
            let files = project_files(Path::new("/r/sub"), &fake);
            assert_eq!(files.local, paths(&["/r/sub/.claude/settings.local.json"]));
        }
    }

    #[test]
    fn the_local_file_stays_in_the_starting_folder_when_the_root_is_the_home_folder() {
        let fake = Fake::new()
            .dir("/Users/me")
            .dir("/Users/me/.git")
            .dir("/Users/me/p");
        let files = project_files(Path::new("/Users/me/p"), &fake);
        assert_eq!(
            files.local,
            paths(&["/Users/me/p/.claude/settings.local.json"])
        );
    }

    #[test]
    fn no_project_file_is_read_inside_a_connector_downloads_folder() {
        let fake = Fake::new()
            .dir("/d/Connector-Downloads")
            .file("/d/Connector-Downloads/.gitignore", "*\n")
            .dir("/d/Connector-Downloads/repo");
        let files = project_files(Path::new("/d/Connector-Downloads/repo"), &fake);
        assert_eq!(files, ProjectFiles::default());
        // Without the `.gitignore` Claude Code writes there, it is any folder.
        let plain = Fake::new().dir("/d/connector-downloads/repo");
        let files = project_files(Path::new("/d/connector-downloads/repo"), &plain);
        assert!(files.shared.is_some());
    }

    #[test]
    fn a_relative_or_dotted_start_is_resolved_by_name() {
        assert_eq!(normalized(Path::new("/a/./b/../c")), PathBuf::from("/a/c"));
    }
}
