//! Which files the turns since a restored one made, read before the
//! restore takes the worktree lock. A long history means thousands of turn
//! records and a diff of each turn's trees, which can take seconds, and a
//! hook that waits for the lock past `Limits::HOOK.snapshot` gives up the
//! begin snapshot of its turn. So the records are read, and the trees
//! diffed, first; under the lock only a record that changed since is read
//! again, and only a pair of trees not diffed yet is diffed.

use super::{StateDirectory, Worktree, file_identity, same_path};
use crate::git::{GitSnapshots, is_object_id};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;
use std::time::SystemTime;
use weir_agent_model::{
    ConversationKey, SnapshotStatus, TURN_RECORD_FILE_SUFFIX, TURNS_DIRECTORY, TurnRecord,
};

/// A turn's begin tree and end tree, which never change once written.
type Trees = (String, String);

/// The most pairs of trees handed to one git call.
const PAIRS_PER_CALL: usize = 500;

/// One turn record file as it was read: a record written again is a new
/// file renamed into place (`records::atomic_write`), so it has another
/// identity, and another time, size, or both.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Stamp {
    identity: Option<(u64, u64)>,
    len: u64,
    modified: Option<SystemTime>,
}

/// What a turn of the record says that the restore asks: when it ran, and
/// what it changed, as its two trees.
#[derive(Clone, Debug)]
struct Turn {
    conversation: ConversationKey,
    display_number: u32,
    started_at: String,
    begin_root: String,
    trees: Trees,
}

impl Turn {
    /// A record whose begin and end were both captured; `None` for any
    /// other, which made nothing a restore can see.
    fn of(record: TurnRecord) -> Option<Self> {
        let (
            SnapshotStatus::Captured {
                tree: begin,
                root: begin_root,
            },
            SnapshotStatus::Captured { tree: end, .. },
        ) = (record.begin, record.end)
        else {
            return None;
        };
        Some(Self {
            conversation: record.conversation,
            display_number: record.display_number,
            started_at: record.started_at,
            begin_root,
            trees: (begin, end),
        })
    }

    /// Whether it ran from `since` on. Within a conversation the number
    /// orders turns that started in the same second; across conversations
    /// only the time can.
    fn is_from(&self, since: &TurnRecord) -> bool {
        if self.conversation == since.conversation {
            self.display_number >= since.display_number
        } else {
            self.started_at >= since.started_at
        }
    }
}

/// The turn records of the state directories, and the files each turn
/// made, as far as they have been read.
#[derive(Default)]
pub(super) struct MadeByTurns {
    /// Each record file by its path, with what it was when read: `None`
    /// for one that could not be read or decoded, or made nothing a
    /// restore can see.
    records: HashMap<PathBuf, (Stamp, Option<Turn>)>,
    /// The files each pair of trees adds.
    added: HashMap<Trees, Vec<Vec<u8>>>,
    /// Whether each root a turn began in is this worktree's.
    is_here: HashMap<String, bool>,
    /// How many pairs of trees the last `since` diffed, for the tests.
    pub(super) diffed: usize,
}

impl MadeByTurns {
    /// Reads every turn record, and diffs the trees of the turns of
    /// `worktree` from `since` on: the work done before the lock.
    pub(super) fn read(
        directories: &[StateDirectory],
        worktree: &Worktree,
        since: Option<&TurnRecord>,
    ) -> Self {
        let mut made = Self::default();
        made.refresh(directories);
        if let Some(since) = since {
            made.diff(worktree, since);
        }
        made
    }

    /// The paths turns of this worktree made, from `since` on: absent from
    /// a turn's start and present at its end. A file made by hand between
    /// turns is in no such list, though a later turn's start holds it.
    /// Reads again only the records written since `read`, and diffs only
    /// the trees not diffed yet, so a turn that began or ended in between
    /// counts as if all were read now.
    pub(super) fn since(
        &mut self,
        directories: &[StateDirectory],
        worktree: &Worktree,
        since: &TurnRecord,
    ) -> HashSet<Vec<u8>> {
        self.refresh(directories);
        self.diffed = self.diff(worktree, since);
        self.trees_from(worktree, since)
            .iter()
            .filter_map(|trees| self.added.get(trees))
            .flatten()
            .cloned()
            .collect()
    }

    /// Lists the record files again, reading the ones new or written since
    /// they were read, and forgetting the ones gone.
    fn refresh(&mut self, directories: &[StateDirectory]) {
        let mut records = HashMap::new();
        for state in directories {
            let Ok(entries) = fs::read_dir(state.directory.join(TURNS_DIRECTORY)) else {
                continue;
            };
            for entry in entries.flatten() {
                // A conversation's counter, a record's lock, and one set
                // aside to be deleted are no records.
                if !entry
                    .file_name()
                    .to_string_lossy()
                    .ends_with(TURN_RECORD_FILE_SUFFIX)
                {
                    continue;
                }
                let path = entry.path();
                // Looked at before it is read: a record written again
                // after that has another stamp, and the next refresh
                // reads it again.
                let Ok(metadata) = fs::symlink_metadata(&path) else {
                    continue;
                };
                let stamp = Stamp {
                    identity: file_identity(&path),
                    len: metadata.len(),
                    modified: metadata.modified().ok(),
                };
                let turn = match self.records.remove(&path) {
                    Some((read, turn)) if read == stamp => turn,
                    _ => fs::read(&path)
                        .ok()
                        .and_then(|bytes| TurnRecord::decode(&bytes).ok())
                        .and_then(Turn::of),
                };
                records.insert(path, (stamp, turn));
            }
        }
        self.records = records;
    }

    /// The trees of the turns of `worktree` from `since` on.
    fn trees_from(&mut self, worktree: &Worktree, since: &TurnRecord) -> HashSet<Trees> {
        let mut trees = HashSet::new();
        for turn in self.records.values().filter_map(|(_, turn)| turn.as_ref()) {
            if !turn.is_from(since) {
                continue;
            }
            let is_here = *self
                .is_here
                .entry(turn.begin_root.clone())
                .or_insert_with(|| same_path(turn.begin_root.as_ref(), &worktree.root));
            if is_here {
                trees.insert(turn.trees.clone());
            }
        }
        trees
    }

    /// Diffs the trees of the turns of `worktree` from `since` on that are
    /// not diffed yet, `PAIRS_PER_CALL` to a git call: each call has the
    /// limit of one git command, and one that runs out of it stops every
    /// later git command of the operation (`GitScope`). Returns how many
    /// pairs it diffed.
    fn diff(&mut self, worktree: &Worktree, since: &TurnRecord) -> usize {
        let pending: Vec<Trees> = self
            .trees_from(worktree, since)
            .into_iter()
            .filter(|trees| !self.added.contains_key(trees))
            .collect();
        if pending.is_empty() {
            return 0;
        }
        let mut added = HashMap::new();
        for chunk in pending.chunks(PAIRS_PER_CALL) {
            let mut input = String::new();
            for (begin, end) in chunk {
                if is_object_id(begin) && is_object_id(end) {
                    let _ = writeln!(input, "{begin} {end}");
                }
            }
            added.extend(
                GitSnapshots::run_with_input(
                    &worktree.root,
                    &[
                        "diff-tree",
                        "--stdin",
                        "-r",
                        "-z",
                        "--no-renames",
                        "--diff-filter=A",
                    ],
                    input.as_bytes(),
                )
                .and_then(|raw| parse_added(&raw))
                .unwrap_or_default(),
            );
        }
        // A pair a call did not answer (git leaves out a tree it cannot
        // read, and a call that failed answers none) is diffed on its own,
        // and one that fails then adds nothing, as before the batch.
        for trees in &pending {
            if added.contains_key(trees) {
                continue;
            }
            let paths = worktree
                .changes(&trees.0, &trees.1)
                .unwrap_or_default()
                .into_iter()
                .filter(|change| change.kind == weir_agent_model::PathChangeKind::Add)
                .map(|change| change.raw)
                .collect();
            added.insert(trees.clone(), paths);
        }
        self.added.extend(added);
        pending.len()
    }
}

/// The paths each pair of trees adds, from `git diff-tree --stdin -z`:
/// each pair's line as given (`<begin> <end>\n`), then a
/// `:<old mode> <new mode> <old id> <new id> <status>\0<path>\0` for each
/// path. A pair's line starts with a hex digit and a path's header with a
/// colon, so a newline in a path cannot be read as a pair. Submodules are
/// left out: a restore does not touch them. `None` when the output is
/// not of that form.
fn parse_added(raw: &[u8]) -> Option<HashMap<Trees, Vec<Vec<u8>>>> {
    let mut added: HashMap<Trees, Vec<Vec<u8>>> = HashMap::new();
    let mut current: Option<Trees> = None;
    let mut rest = raw;
    while let Some(first) = rest.first() {
        if *first == b':' {
            let header_end = rest.iter().position(|byte| *byte == 0)?;
            let header = String::from_utf8_lossy(&rest[1..header_end]).into_owned();
            rest = &rest[header_end + 1..];
            let path_end = rest.iter().position(|byte| *byte == 0)?;
            let path = rest[..path_end].to_vec();
            rest = &rest[path_end + 1..];
            let trees = current.as_ref()?;
            let mut modes = header.split(' ');
            if modes.next() == Some("160000") || modes.next() == Some("160000") {
                continue;
            }
            added.entry(trees.clone()).or_default().push(path);
        } else {
            let line_end = rest.iter().position(|byte| *byte == b'\n')?;
            let line = std::str::from_utf8(&rest[..line_end]).ok()?;
            rest = &rest[line_end + 1..];
            let (begin, end) = line.split_once(' ')?;
            let trees = (begin.to_owned(), end.to_owned());
            added.entry(trees.clone()).or_default();
            current = Some(trees);
        }
    }
    Some(added)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_pair_gets_the_paths_it_adds_and_no_submodule() {
        let first = ("a".repeat(40), "b".repeat(40));
        let second = ("c".repeat(40), "d".repeat(40));
        let zero = "0".repeat(40);
        let id = "e".repeat(40);
        let mut raw = Vec::new();
        raw.extend(format!("{} {}\n", first.0, first.1).as_bytes());
        raw.extend(format!(":000000 100644 {zero} {id} A\0new\nline\0").as_bytes());
        raw.extend(format!(":000000 160000 {zero} {id} A\0module\0").as_bytes());
        raw.extend(format!("{} {}\n", second.0, second.1).as_bytes());

        let added = parse_added(&raw).unwrap();

        assert_eq!(added[&first], [b"new\nline".to_vec()]);
        assert!(added[&second].is_empty());
    }

    #[test]
    fn a_path_before_any_pair_is_no_answer() {
        assert!(parse_added(b":000000 100644 0 1 A\0x\0").is_none());
    }
}
