//! Sweeping the files no record needs any more: a lock sidecar whose file
//! is gone, a temporary file a writer that was killed left behind, and a
//! conversation's turn counter once no turn of the conversation is left.
//! Each is small, but each record ever written leaves one, and nothing
//! else removes them.
//!
//! A sidecar is removed under its own lock, and only while its file is
//! still missing. A writer that opened it before the removal finds, once it
//! holds the lock, that the path names another file now, and locks that one
//! instead (`records::with_record_lock_attempts`, and `AgentFileLock` on the
//! Swift side), so a lock is never held on a file nobody else can open.

use crate::records::{is_at_path, open_lock_file, try_lock, unlock};
use serde::Serialize;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime};
use weir_agent_model::{
    LOCK_FILE_SUFFIX, TURN_COUNTER_FILE_SUFFIX, TURN_RECORD_FILE_SUFFIX, TurnRecord,
};

/// How old a temporary file is before it is taken for one a killed writer
/// left. A writer renames its temporary into place within milliseconds.
pub const TEMPORARY_AGE: Duration = Duration::from_hours(1);

/// How long a counter with no turn left is kept. A prompt writes its
/// counter and then its turn record, so a counter just written may have no
/// turn yet; removed then, the next prompt would take the same number.
pub const COUNTER_AGE: Duration = Duration::from_hours(24);

/// What one sweep removed.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LeftoverSweep {
    pub sidecars: usize,
    pub temporaries: usize,
    pub counters: usize,
}

impl LeftoverSweep {
    fn add(&mut self, other: &Self) {
        self.sidecars += other.sidecars;
        self.temporaries += other.temporaries;
        self.counters += other.counters;
    }
}

/// Sweeps each of `directories` (not their subdirectories) as of `now`. A
/// directory that cannot be listed is skipped, and so is one that is a
/// symbolic link: the sweep removes by name and age alone, so it reaches
/// only the folders the records are written in, never one a link points at.
#[must_use]
pub fn sweep_leftovers(directories: &[&Path], now: SystemTime) -> LeftoverSweep {
    let mut swept = LeftoverSweep::default();
    for directory in directories {
        swept.add(&sweep_directory(directory, now));
    }
    swept
}

fn sweep_directory(directory: &Path, now: SystemTime) -> LeftoverSweep {
    let mut swept = LeftoverSweep::default();
    if !fs::symlink_metadata(directory).is_ok_and(|metadata| metadata.is_dir()) {
        return swept;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return swept;
    };
    let names: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    // Counters first, so a counter's sidecar goes in the same sweep.
    for name in counters_to_remove(directory, &names, now) {
        if remove_under_lock(directory, name, |path| is_older(path, now, COUNTER_AGE)) {
            swept.counters += 1;
        }
    }
    for name in &names {
        if let Some(file) = name.strip_suffix(LOCK_FILE_SUFFIX)
            && !file.is_empty()
            && remove_sidecar(directory, name, file)
        {
            swept.sidecars += 1;
        } else if is_temporary(name)
            && is_older(&directory.join(name), now, TEMPORARY_AGE)
            && fs::remove_file(directory.join(name)).is_ok()
        {
            swept.temporaries += 1;
        }
    }
    swept
}

/// Removes the sidecar `name` of `file` while holding its lock, if `file`
/// is still missing then. A sidecar someone holds is left for the next
/// sweep.
fn remove_sidecar(directory: &Path, name: &str, file: &str) -> bool {
    let file = directory.join(file);
    let sidecar = directory.join(name);
    // Opening the sidecar creates it, so one already gone is not opened.
    if fs::symlink_metadata(&file).is_ok() || fs::symlink_metadata(&sidecar).is_err() {
        return false;
    }
    let Some(lock) = open_lock_file(&sidecar) else {
        return false;
    };
    if try_lock(&lock).is_err() {
        return false;
    }
    let is_removed = is_at_path(&lock, &sidecar)
        && fs::symlink_metadata(&file).is_err()
        && fs::remove_file(&sidecar).is_ok();
    let _ = unlock(&lock);
    is_removed
}

/// Removes `name` under the lock its writer takes, if `should` still holds
/// for it then. Its sidecar goes too, still held, since its file is gone.
fn remove_under_lock(directory: &Path, name: &str, should: impl Fn(&Path) -> bool) -> bool {
    let path = directory.join(name);
    let sidecar = directory.join(format!("{name}{LOCK_FILE_SUFFIX}"));
    let Some(lock) = open_lock_file(&sidecar) else {
        return false;
    };
    if try_lock(&lock).is_err() {
        return false;
    }
    let is_removed = is_at_path(&lock, &sidecar) && should(&path) && fs::remove_file(&path).is_ok();
    if is_removed {
        let _ = fs::remove_file(&sidecar);
    }
    let _ = unlock(&lock);
    is_removed
}

/// The counters in `names` no turn record in `directory` numbers from.
/// None when a record cannot be read: its conversation may be any of them.
fn counters_to_remove<'a>(
    directory: &Path,
    names: &'a [String],
    now: SystemTime,
) -> BTreeSet<&'a str> {
    let mut used = BTreeSet::new();
    for name in names.iter().filter(|name| is_turn_record(name)) {
        let Some(record) = fs::read(directory.join(name))
            .ok()
            .and_then(|bytes| TurnRecord::decode(&bytes).ok())
        else {
            return BTreeSet::new();
        };
        used.insert(record.conversation.counter_file_name());
    }
    names
        .iter()
        .filter(|name| is_counter(name) && !used.contains(name.as_str()))
        .filter(|name| is_older(&directory.join(name), now, COUNTER_AGE))
        .map(String::as_str)
        .collect()
}

fn is_counter(name: &str) -> bool {
    name.ends_with(TURN_COUNTER_FILE_SUFFIX) && !name.starts_with('.')
}

/// A turn record as the writer names it, or one a deletion moved aside
/// (`.<record>.deleting`, `turn_gc`): its turn is not gone yet, and git
/// refusing its refs puts it back with its number.
fn is_turn_record(name: &str) -> bool {
    let name = name.strip_suffix(".deleting").unwrap_or(name);
    name.ends_with(TURN_RECORD_FILE_SUFFIX) && !is_temporary(name)
}

/// A temporary file as the writers name one: `.<name>.tmp-<uuid>` from the
/// hook (`records::atomic_write`) and the app (`SecureFileWrite.writeAtomic`),
/// and `.<name>.tmp.<pid>` from a hook of an earlier build.
fn is_temporary(name: &str) -> bool {
    let Some(rest) = name.strip_prefix('.') else {
        return false;
    };
    if let Some((_, pid)) = rest.rsplit_once(".tmp.") {
        return !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit());
    }
    rest.rsplit_once(".tmp-")
        .is_some_and(|(_, id)| uuid::Uuid::parse_str(id).is_ok())
}

/// Whether `path` was last written at least `age` before `now`. A time that
/// cannot be read, or one in the future, is not old.
fn is_older(path: &Path, now: SystemTime, age: Duration) -> bool {
    fs::symlink_metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| now.duration_since(modified).ok())
        .is_some_and(|elapsed| elapsed >= age)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::records::with_record_lock;
    use std::path::PathBuf;
    use weir_agent_model::ConversationKey;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "weir-hook-leftovers-{name}-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir_all(&root).expect("scratch");
            Self(root)
        }

        fn touch(&self, name: &str) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, b"{}").expect("write");
            path
        }

        fn exists(&self, name: &str) -> bool {
            self.0.join(name).exists()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn later(age: Duration) -> SystemTime {
        SystemTime::now() + age + Duration::from_secs(1)
    }

    #[test]
    fn a_sidecar_without_its_file_is_swept_and_one_with_it_is_kept() {
        let scratch = Scratch::new("sidecars");
        scratch.touch("kept.json");
        scratch.touch("kept.json.flock");
        scratch.touch("gone.json.flock");
        let swept = sweep_leftovers(&[&scratch.0], SystemTime::now());
        assert_eq!(swept.sidecars, 1);
        assert!(scratch.exists("kept.json.flock"));
        assert!(!scratch.exists("gone.json.flock"));
    }

    #[test]
    fn a_sidecar_someone_holds_is_left_for_the_next_sweep() {
        let scratch = Scratch::new("held");
        let file = scratch.0.join("gone.json");
        let swept = with_record_lock(&file, || sweep_leftovers(&[&scratch.0], SystemTime::now()))
            .expect("lock");
        assert_eq!(swept.sidecars, 0);
        assert!(scratch.exists("gone.json.flock"));
        assert_eq!(
            sweep_leftovers(&[&scratch.0], SystemTime::now()).sidecars,
            1
        );
    }

    #[test]
    fn a_writer_that_locks_a_swept_sidecar_takes_the_one_at_the_path_instead() {
        let scratch = Scratch::new("waiting-writer");
        let file = scratch.0.join("run.json");
        let sidecar = scratch.0.join("run.json.flock");
        // Held as the sweep holds it, while a writer opens it and waits.
        let swept = open_lock_file(&sidecar).expect("open");
        try_lock(&swept).expect("lock");
        let writer = {
            let file = file.clone();
            let sidecar = sidecar.clone();
            std::thread::spawn(move || {
                crate::records::with_record_lock_attempts(&file, 200, || {
                    // Ours is the sidecar at the path: another opener of it
                    // finds it held.
                    let next = open_lock_file(&sidecar).expect("open");
                    try_lock(&next).is_err()
                })
            })
        };
        // The sweep removes the sidecar only once the writer holds it open,
        // or the writer would open the new one first and prove nothing.
        wait_until_opened_again(&swept);
        fs::remove_file(&sidecar).expect("sweep");
        let _ = unlock(&swept);
        assert_eq!(writer.join().expect("writer"), Some(true));
    }

    /// Waits until a descriptor of this process other than `held` names the
    /// file `held` does.
    fn wait_until_opened_again(held: &fs::File) {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::MetadataExt;
        let opened = held.metadata().expect("held");
        let ours = held.as_raw_fd().to_string();
        for _ in 0..500 {
            let is_opened_again = fs::read_dir("/dev/fd").expect("fds").flatten().any(|entry| {
                entry.file_name() != ours.as_str()
                    // macOS reports the descriptor file system's device
                    // here, so only the inode is compared.
                    && fs::metadata(entry.path()).is_ok_and(|metadata| metadata.ino() == opened.ino())
            });
            if is_opened_again {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the writer never opened the sidecar");
    }

    #[test]
    fn a_directory_that_is_a_link_is_not_swept() {
        let scratch = Scratch::new("linked");
        scratch.touch("gone.json.flock");
        let link =
            std::env::temp_dir().join(format!("weir-hook-leftovers-link-{}", uuid::Uuid::new_v4()));
        std::os::unix::fs::symlink(&scratch.0, &link).expect("link");
        let swept = sweep_leftovers(&[&link], SystemTime::now());
        let _ = fs::remove_file(&link);
        assert_eq!(swept.sidecars, 0);
        assert!(scratch.exists("gone.json.flock"));
    }

    #[test]
    fn a_temporary_file_is_swept_only_once_it_is_old() {
        let scratch = Scratch::new("temporaries");
        scratch.touch(".run.json.tmp.4242");
        scratch.touch(".hint.json.tmp-6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10");
        scratch.touch(".not-a.tmp.file");
        let fresh = sweep_leftovers(&[&scratch.0], SystemTime::now());
        assert_eq!(fresh.temporaries, 0);
        let old = sweep_leftovers(&[&scratch.0], later(TEMPORARY_AGE));
        assert_eq!(old.temporaries, 2);
        assert!(scratch.exists(".not-a.tmp.file"));
    }

    fn turn_record(conversation: &ConversationKey, turn_id: &str) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "schemaVersion": weir_agent_model::TurnRecord::SCHEMA_VERSION,
            "turnId": turn_id,
            "provider": "claude",
            "conversation": conversation,
            "runId": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",
            "paneId": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10",
            "displayNumber": 1,
            "phase": "finished",
            "startedAt": "2026-11-03T00:00:00Z",
            "begin": {"status": "notGit"},
        }))
        .expect("json")
    }

    fn conversation(id: &str) -> ConversationKey {
        serde_json::from_value(serde_json::json!({
            "provider": "claude",
            "conversationId": id,
            "isFallback": false,
        }))
        .expect("key")
    }

    #[test]
    fn a_counter_outlives_its_last_turn_until_it_is_old() {
        let scratch = Scratch::new("counters");
        let used = conversation("used");
        let unused = conversation("unused");
        let turn_id = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F20";
        fs::write(
            scratch
                .0
                .join(weir_agent_model::turn_record_file_name(turn_id)),
            turn_record(&used, turn_id),
        )
        .expect("turn");
        scratch.touch(&used.counter_file_name());
        // A record a deletion moved aside still numbers from its counter.
        let aside = conversation("aside");
        let aside_id = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F21";
        fs::write(
            scratch.0.join(format!(
                ".{}.deleting",
                weir_agent_model::turn_record_file_name(aside_id)
            )),
            turn_record(&aside, aside_id),
        )
        .expect("aside");
        scratch.touch(&aside.counter_file_name());
        scratch.touch(&unused.counter_file_name());
        scratch.touch(&format!("{}.flock", unused.counter_file_name()));
        assert_eq!(
            sweep_leftovers(&[&scratch.0], SystemTime::now()).counters,
            0
        );
        let swept = sweep_leftovers(&[&scratch.0], later(COUNTER_AGE));
        assert_eq!(swept.counters, 1);
        assert!(scratch.exists(&used.counter_file_name()));
        assert!(scratch.exists(&aside.counter_file_name()));
        assert!(!scratch.exists(&unused.counter_file_name()));
        assert!(!scratch.exists(&format!("{}.flock", unused.counter_file_name())));
    }

    #[test]
    fn no_counter_is_swept_beside_a_turn_record_this_build_cannot_read() {
        let scratch = Scratch::new("unreadable-turn");
        fs::write(
            scratch.0.join(weir_agent_model::turn_record_file_name(
                "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F20",
            )),
            br#"{"schemaVersion":99}"#,
        )
        .expect("turn");
        scratch.touch(&conversation("any").counter_file_name());
        assert_eq!(
            sweep_leftovers(&[&scratch.0], later(COUNTER_AGE)).counters,
            0
        );
    }
}
