//! Writing one path through the swap without losing another writer's save.

use super::*;

/// One change of `path` to what HEAD holds there (a deletion when `kind`
/// says so), for driving the writer directly.
fn change_to_head(repo: &Repo, path: &str, kind: PathChangeKind) -> Change {
    let object = if kind == PathChangeKind::Delete {
        String::new()
    } else {
        repo.git(&["rev-parse", &format!("HEAD:{path}")])
    };
    Change {
        raw: path.as_bytes().to_vec(),
        display: path.to_owned(),
        kind,
        mode: "100644".to_owned(),
        object,
    }
}

/// A save that lands after git read a path and before the path is
/// swapped comes out of the swap, and goes back: nothing is written over
/// unseen. The same for a path the operation deletes.
#[test]
fn a_save_between_the_read_and_the_swap_is_put_back() {
    let repo = Repo::new("swap-race");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("race-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let save = |moment| {
        if moment == Moment::AfterRead {
            repo.write("a.txt", "the editor's, longer\n");
        }
    };

    let mut writer = Writer::new(&worktree, "RACE", &head, "target")
        .unwrap()
        .with_between(&save);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert!(writer.finish().is_empty());

    assert_eq!(results[0].1, Err(Unwritten::ChangedWhileWriting));
    assert_eq!(
        repo.read("a.txt").as_deref(),
        Some("the editor's, longer\n")
    );

    // Read again, unchanged since: written.
    let before = worktree.capture("race-before-2").unwrap();
    let mut writer = Writer::new(&worktree, "RACE2", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert!(writer.finish().is_empty());
    assert_eq!(results[0].1, Ok(()));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));

    // A deletion read, then saved over: the save stays.
    let before = worktree.capture("race-before-3").unwrap();
    let save_keep = |moment| {
        if moment == Moment::AfterRead {
            repo.write("keep.txt", "saved after the read\n");
        }
    };
    let mut writer = Writer::new(&worktree, "RACE3", &head, "target")
        .unwrap()
        .with_between(&save_keep);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "keep.txt", PathChangeKind::Delete)],
    );
    assert!(writer.finish().is_empty());
    assert_eq!(results[0].1, Err(Unwritten::ChangedWhileWriting));
    assert_eq!(
        repo.read("keep.txt").as_deref(),
        Some("saved after the read\n")
    );
    assert!(
        !worktree.staging("RACE3").exists(),
        "nothing left in the worktree"
    );
}

/// Substituting a link after staging is opened cannot change files outside
/// the worktree, whether the link replaces the generation or its parent.
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
#[test]
fn replacing_a_staging_directory_cannot_redirect_checkout() {
    for directory in ["target/gen-1", "target"] {
        let repo = Repo::new("staging-race");
        let worktree = repo.worktree();
        let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
        repo.write("a.txt", "changed\n");
        let before = worktree.capture("staging-before").unwrap();
        let area = worktree.staging("STAGING");
        let outside = repo.scratch.join("outside");
        let outside_generation = if directory == "target" {
            outside.join("gen-1")
        } else {
            outside.clone()
        };
        fs::create_dir_all(&outside_generation).unwrap();
        let protected = outside_generation.join("a.txt");
        fs::write(&protected, "outside\n").unwrap();
        let replace = |moment| {
            if moment == Moment::BeforeStageWrite {
                let original = if directory.is_empty() {
                    area.clone()
                } else {
                    area.join(directory)
                };
                fs::rename(&original, original.with_extension("moved")).unwrap();
                std::os::unix::fs::symlink(&outside, &original).unwrap();
            }
            if moment == Moment::AfterStageWrite {
                assert_eq!(
                    fs::read_to_string(&protected).unwrap(),
                    "outside\n",
                    "{directory} during staging"
                );
            }
        };

        let mut writer = Writer::new(&worktree, "STAGING", &head, "target")
            .unwrap()
            .with_between(&replace);
        let results = writer.write(
            &before,
            &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
        );

        assert_eq!(
            fs::read_to_string(&protected).unwrap(),
            "outside\n",
            "{directory}"
        );
        assert!(
            matches!(results[0].1, Err(Unwritten::Failed(_))),
            "{directory}"
        );
        assert_eq!(
            repo.read("a.txt").as_deref(),
            Some("changed\n"),
            "{directory}"
        );
        assert!(writer.finish().is_empty());
        assert!(!worktree.scratch().join("checkout-STAGING").exists());
    }
}

/// Finishing an interrupted stage does not remove entries through a
/// replacement link, even when the destination contains only empty folders.
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
#[test]
fn staging_cleanup_leaves_replaced_folders_untouched() {
    for directory in ["", "target"] {
        let repo = Repo::new("staging-cleanup");
        let worktree = repo.worktree();
        let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
        repo.write("a.txt", "changed\n");
        let before = worktree.capture("cleanup-before").unwrap();
        let area = worktree.staging("CLEANUP");
        let outside = repo.scratch.join("outside");
        let empty = outside.join("target/empty");
        fs::create_dir_all(&empty).unwrap();
        let ignore = outside.join(".gitignore");
        fs::write(&ignore, "outside\n").unwrap();
        let replace = |moment| {
            if moment == Moment::BeforeStageWrite {
                let original = if directory.is_empty() {
                    area.clone()
                } else {
                    area.join(directory)
                };
                fs::rename(&original, original.with_extension("moved")).unwrap();
                std::os::unix::fs::symlink(&outside, &original).unwrap();
            }
        };
        let mut writer = Writer::new(&worktree, "CLEANUP", &head, "target")
            .unwrap()
            .with_between(&replace);
        let results = writer.write(
            &before,
            &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
        );
        assert!(matches!(results[0].1, Err(Unwritten::Failed(_))));
        writer.finish();

        assert!(empty.is_dir(), "{directory}: the outside folder remains");
        assert_eq!(fs::read_to_string(&ignore).unwrap(), "outside\n");
        assert_eq!(repo.read("a.txt").as_deref(), Some("changed\n"));
    }
}

/// Publishing a generation keeps the opened parent even when another
/// directory takes its former name.
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
#[test]
fn staging_publish_leaves_a_replacement_parent_unchanged() {
    let repo = Repo::new("staging-publish");
    let worktree = repo.worktree();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    repo.write("a.txt", "changed\n");
    let before = worktree.capture("publish-before").unwrap();
    let side = worktree.staging("PUBLISH").join("target");
    let replacement = side.join("gen-1/keep.txt");
    let replace = |moment| {
        if moment == Moment::AfterStageWrite {
            fs::rename(&side, side.with_extension("moved")).unwrap();
            fs::create_dir_all(replacement.parent().unwrap()).unwrap();
            fs::write(&replacement, "replacement\n").unwrap();
        }
    };
    let mut writer = Writer::new(&worktree, "PUBLISH", &head, "target")
        .unwrap()
        .with_between(&replace);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert!(matches!(results[0].1, Err(Unwritten::Failed(_))));
    writer.finish();
    assert_eq!(fs::read_to_string(replacement).unwrap(), "replacement\n");
    assert_eq!(repo.read("a.txt").as_deref(), Some("changed\n"));
}

/// A saved file's matching identity does not authorize removing an entry
/// reached through a staging folder that has become a link.
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
#[test]
fn finishing_keeps_external_links_to_displaced_files() {
    let repo = Repo::new("displaced-cleanup");
    let worktree = repo.worktree();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    repo.write("a.txt", "changed\n");
    let before = worktree.capture("displaced-before").unwrap();
    let outside = repo.scratch.join("outside");
    fs::create_dir(&outside).unwrap();
    let protected = outside.join("a.txt");
    fs::hard_link(repo.path.join("a.txt"), &protected).unwrap();
    let ready = worktree.staging("DISPLACED").join("target/ready-1");
    let replace = |moment| {
        if moment == Moment::AtFinish {
            fs::rename(&ready, ready.with_extension("moved")).unwrap();
            std::os::unix::fs::symlink(&outside, &ready).unwrap();
        }
    };
    let mut writer = Writer::new(&worktree, "DISPLACED", &head, "target")
        .unwrap()
        .with_between(&replace);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert_eq!(results[0].1, Ok(()));
    let kept = writer.finish();
    assert_eq!(fs::read_to_string(protected).unwrap(), "changed\n");
    assert_eq!(kept.len(), 1);
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
}

/// Distinct index paths retain their bytes when the checkout volume
/// folds case or normalizes their names.
#[test]
fn private_checkout_keeps_distinct_bytes_for_aliasing_names() {
    use super::super::write::Checkout;
    use std::ffi::OsStr;
    use std::io::Read;

    for names in [["A.txt", "a.txt"], ["e\u{301}.txt", "é.txt"]] {
        let repo = Repo::new("checkout-aliases");
        let first = repo.git(&["rev-parse", "HEAD:a.txt"]);
        let second = repo.git(&["rev-parse", "HEAD:keep.txt"]);
        repo.git_with_input(
            &["update-index", "--index-info"],
            format!(
                "100644 {first}\t{}\n100644 {second}\t{}\n",
                names[0], names[1]
            )
            .as_bytes(),
        );
        let tree = repo.git(&["write-tree"]);
        let worktree = repo.worktree();
        fs::create_dir_all(worktree.scratch()).unwrap();
        let index = worktree.index("ALIASES");
        GitSnapshots::run(&repo.path, &["read-tree", &tree], Some(&index)).unwrap();
        let changes: Vec<_> = names
            .iter()
            .zip([first, second])
            .map(|(name, object)| Change {
                raw: name.as_bytes().to_vec(),
                display: (*name).to_owned(),
                kind: PathChangeKind::Modify,
                mode: "100644".to_owned(),
                object,
            })
            .collect();
        let mut checkout = Checkout::new(&worktree, "ALIASES", OsStr::new("target"), 1).unwrap();
        let entries = checkout.materialize(&repo.path, &index, &changes.iter().collect::<Vec<_>>());
        assert_eq!(entries.len(), 2);
        for (entry, expected) in entries.iter().zip(["a\n", "keep\n"]) {
            let path = path_from_bytes(&entry.change.raw).unwrap();
            let mut file = entry.directory.read_file(path.as_os_str()).unwrap();
            let mut bytes = String::new();
            file.read_to_string(&mut bytes).unwrap();
            assert_eq!(bytes, expected);
        }
        drop(checkout);
        assert!(!worktree.scratch().join("checkout-ALIASES").exists());
    }
}

/// Checkout reads attributes from the target index when the worktree
/// has no attributes file, and applies the target's executable mode.
#[cfg(unix)]
#[test]
fn staging_preserves_checkout_attributes_and_executable_mode() {
    use std::os::unix::fs::PermissionsExt;

    let repo = Repo::new("stage-attrs");
    repo.write(
        ".gitattributes",
        "a.txt text eol=crlf ident filter=prefix\n",
    );
    repo.write("a.txt", "$Id$\n");
    repo.git(&["add", ".gitattributes", "a.txt"]);
    repo.git(&["update-index", "--chmod=+x", "a.txt"]);
    repo.commit("checkout attributes");
    repo.git(&["config", "filter.prefix.smudge", "sed 's/^/smudged: /'"]);
    repo.git(&["rm", "--cached", ".gitattributes"]);
    fs::remove_file(repo.path.join(".gitattributes")).unwrap();
    repo.write("a.txt", "before\n");

    let worktree = repo.worktree();
    let before = worktree.capture("attrs-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let changes: Vec<_> = worktree
        .changes(&before, &head)
        .unwrap()
        .into_iter()
        .filter(|change| change.raw == b"a.txt")
        .collect();

    let mut writer = Writer::new(&worktree, "ATTRS", &head, "target").unwrap();
    let results = writer.write(&before, &changes);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].1, Ok(()));
    assert!(writer.finish().is_empty());

    let object = repo.git(&["rev-parse", "HEAD:a.txt"]);
    assert_eq!(
        fs::read(repo.path.join("a.txt")).unwrap(),
        format!("smudged: $Id: {object} $\r\n").as_bytes()
    );
    let metadata = fs::metadata(repo.path.join("a.txt")).unwrap();
    assert_ne!(metadata.permissions().mode() & 0o100, 0);
}

/// A required filter failure leaves its path untouched. Another path
/// in the batch can still be staged and written.
#[test]
fn a_required_checkout_filter_failure_does_not_publish_the_file() {
    let repo = Repo::new("stage-failed-filter");
    repo.write(".gitattributes", "a.txt filter=refuse\n");
    repo.git(&["add", ".gitattributes"]);
    repo.commit("checkout filter");
    repo.git(&["config", "filter.refuse.clean", "cat"]);
    repo.git(&["config", "filter.refuse.smudge", "printf 'partial'; exit 1"]);
    repo.git(&["config", "filter.refuse.required", "true"]);
    repo.write("a.txt", "a before\n");
    repo.write("keep.txt", "keep before\n");

    let worktree = repo.worktree();
    let before = worktree.capture("filter-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let mut writer = Writer::new(&worktree, "FILTER", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[
            change_to_head(&repo, "a.txt", PathChangeKind::Modify),
            change_to_head(&repo, "keep.txt", PathChangeKind::Modify),
        ],
    );

    assert!(matches!(results[0].1, Err(Unwritten::Failed(_))));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a before\n"));
    assert!(
        !worktree
            .staging("FILTER")
            .join("target/ready-1/a.txt")
            .exists()
    );
    assert_eq!(results[1].1, Ok(()));
    assert_eq!(repo.read("keep.txt").as_deref(), Some("keep\n"));
    assert!(writer.finish().is_empty());
}

/// When Git is configured without symlink support, the link's target
/// becomes the contents of an ordinary file.
#[cfg(unix)]
#[test]
fn staging_respects_core_symlinks() {
    let repo = Repo::new("stage-symlink-config");
    let link = repo.path.join("link");
    std::os::unix::fs::symlink("keep.txt", &link).unwrap();
    repo.git(&["add", "link"]);
    repo.commit("symlink");
    fs::remove_file(&link).unwrap();
    repo.git(&["config", "core.symlinks", "false"]);

    let worktree = repo.worktree();
    let before = worktree.capture("symlink-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let changes = worktree.changes(&before, &head).unwrap();
    let mut writer = Writer::new(&worktree, "LINK", &head, "target").unwrap();
    let results = writer.write(&before, &changes);

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].1, Ok(()));
    assert!(fs::symlink_metadata(&link).unwrap().is_file());
    assert_eq!(fs::read(link).unwrap(), b"keep.txt");
    assert!(writer.finish().is_empty());
}

/// A write through a descriptor opened before the swap lands in the file
/// that came out; it is kept aside, not deleted, and the journal says
/// where.
#[test]
fn a_write_to_the_file_that_came_out_is_kept_aside() {
    let repo = Repo::new("swap-late");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("late-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);

    let mut writer = Writer::new(&worktree, "LATE", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert_eq!(results[0].1, Ok(()));
    let came_out = worktree.staging("LATE").join("target/ready-1/a.txt");
    fs::write(&came_out, "written late through an old descriptor\n").unwrap();
    let kept = writer.finish();

    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].path, "a.txt");
    assert_eq!(kept[0].kept_at(), Some(".weir-LATE/target/ready-1/a.txt"));
    assert_eq!(
        fs::read_to_string(&came_out).unwrap(),
        "written late through an old descriptor\n"
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
}

/// A save after the read comes out of the swap; one more save on top of
/// what was swapped in, before it goes back, is not written over either:
/// the first is kept aside, and the path keeps the last.
#[test]
fn a_save_on_top_of_the_swap_keeps_the_earlier_save_aside() {
    let repo = Repo::new("swap-twice");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("twice-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let saves = |moment| match moment {
        Moment::AfterRead => repo.write("a.txt", "first save\n"),
        Moment::AfterSwap => repo.write("a.txt", "second save, longer\n"),
        Moment::BeforeStageWrite | Moment::AfterStageWrite | Moment::AtFinish => {}
    };

    let mut writer = Writer::new(&worktree, "TWICE", &head, "target")
        .unwrap()
        .with_between(&saves);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    let kept = writer.finish();

    let aside = ".weir-TWICE/target/ready-1/a.txt";
    assert_eq!(results[0].1, Err(Unwritten::KeptAside(aside.to_owned())));
    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].path, "a.txt");
    assert_eq!(kept[0].kept_at(), Some(aside));
    assert_eq!(repo.read("a.txt").as_deref(), Some("second save, longer\n"));
    assert_eq!(repo.read(aside).as_deref(), Some("first save\n"));
    // Git does not see what the staging area keeps.
    assert_eq!(
        repo.git(&["status", "--porcelain", "--", ".weir-TWICE"]),
        ""
    );
}

/// A save into a file the rollback took out keeps the restore from being
/// called aborted: the record says where the save went.
#[test]
fn a_save_kept_aside_in_the_rollback_leaves_the_restore_partial() {
    let repo = Repo::new("rollback-aside");
    let turn = repo.turn(|repo| {
        repo.write("a.txt", "a\nchanged\n");
        repo.write("keep.txt", "keep\nchanged\n");
    });
    let late = |moment| {
        if moment == Moment::AtFinish {
            // The file the rollback took out of keep.txt, wherever its
            // operation put it.
            for entry in fs::read_dir(&repo.path).unwrap().flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with(".weir-") {
                    let file = entry.path().join("back/ready-1/keep.txt");
                    if file.exists() {
                        fs::write(file, "written late\n").unwrap();
                    }
                }
            }
        }
    };
    let seams = Seams {
        before_lock: &nothing,
        after_journal: &nothing,
        after_write: &|| repo.write("a.txt", "editor\n"),
        in_write: &nothing_at,
        in_rollback: &late,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    let RestoreStage::PartiallyApplied { kept, failed, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    assert_eq!(kept, &["a.txt"]);
    let aside = failed
        .iter()
        .find(|failed| failed.path == "keep.txt")
        .and_then(FailedPath::kept_at)
        .unwrap_or_else(|| panic!("{failed:?}"));
    assert_eq!(repo.read(aside).as_deref(), Some("written late\n"));
    assert_eq!(repo.read("a.txt").as_deref(), Some("editor\n"));
    assert_eq!(repo.read("keep.txt").as_deref(), Some("keep\nchanged\n"));
}

/// A save found while writing stops the restore as one found after it
/// does: what the restore wrote elsewhere goes back, and nothing is left
/// half done.
#[test]
fn a_save_found_while_writing_takes_the_restore_back_whole() {
    let repo = Repo::new("found-while-writing");
    let turn = busy_turn(&repo);
    let save = |moment| {
        if moment == Moment::AfterRead && repo.read("a.txt").as_deref() == Some("a\nchanged\n") {
            repo.write("a.txt", "saved while writing\n");
        }
    };
    let seams = Seams {
        before_lock: &nothing,
        after_journal: &nothing,
        after_write: &nothing,
        in_write: &save,
        in_rollback: &nothing_at,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    assert_eq!(
        journal.stage,
        RestoreStage::Aborted {
            reason: StageReason::ExternalChangeDetected
        }
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("saved while writing\n"));
    assert_eq!(repo.read("keep.txt"), None);
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
}

/// An exchange the system refuses (a locked file) writes nothing and
/// leaves nothing: the path keeps its file, and no made file is taken for
/// another writer's save.
#[cfg(target_os = "macos")]
#[test]
fn a_refused_exchange_leaves_the_path_and_no_save_aside() {
    let repo = Repo::new("swap-refused");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("refused-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let lock = |flag: &str| {
        let status = Command::new("chflags")
            .args([flag, &repo.path.join("a.txt").to_string_lossy()])
            .status()
            .unwrap();
        assert!(status.success());
    };
    lock("uchg");

    let mut writer = Writer::new(&worktree, "REFUSED", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    let kept = writer.finish();
    lock("nouchg");

    assert!(
        results[0]
            .1
            .as_ref()
            .is_err_and(|unwritten| !matches!(unwritten, Unwritten::KeptAside(_))),
        "{results:?}"
    );
    assert!(kept.is_empty(), "{kept:?}");
    assert_eq!(repo.read("a.txt").as_deref(), Some("changed\n"));
    assert!(!worktree.staging("REFUSED").exists());
}

/// A save git reads the same as the restore's file (`ident` folds any
/// `$Id: ... $`) is still another writer's: when the rollback takes it
/// out, no tree gives its bytes back, so it is kept aside, not deleted.
#[test]
fn a_save_a_filter_reads_as_the_same_is_kept_aside() {
    let repo = Repo::new("ident");
    repo.write(".gitattributes", "a.txt ident\n");
    repo.write("a.txt", "$Id$\nline\n");
    repo.git(&["add", ".gitattributes", "a.txt"]);
    repo.commit("ident");
    let turn = repo.turn(|repo| {
        repo.write("a.txt", "$Id$\nchanged\n");
        repo.write("keep.txt", "keep\nchanged\n");
    });
    let seams = Seams {
        before_lock: &nothing,
        after_journal: &nothing,
        after_write: &|| {
            // Read by git as the restore's own file, and it is not.
            repo.write("a.txt", "$Id: the editor's own $\nline\n");
            repo.write("keep.txt", "editor\n");
        },
        in_write: &nothing_at,
        in_rollback: &nothing_at,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    let RestoreStage::PartiallyApplied { failed, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    let aside = failed
        .iter()
        .find(|failed| failed.path == "a.txt")
        .and_then(FailedPath::kept_at)
        .unwrap_or_else(|| panic!("{failed:?}"));
    assert_eq!(
        repo.read(aside).as_deref(),
        Some("$Id: the editor's own $\nline\n")
    );
}

/// A restore whole but for a save it kept aside is done; once undone, the
/// save stays where it went, and the undo's record names it.
#[test]
fn a_save_kept_aside_is_named_by_the_undo_too() {
    let repo = Repo::new("aside-undo");
    let turn = busy_turn(&repo);
    let late = |moment| {
        if moment == Moment::AtFinish {
            for entry in fs::read_dir(&repo.path).unwrap().flatten() {
                if entry.file_name().to_string_lossy().starts_with(".weir-") {
                    let file = entry.path().join("target/ready-1/a.txt");
                    if file.exists() {
                        fs::write(file, "written late\n").unwrap();
                    }
                }
            }
        }
    };
    let seams = Seams {
        before_lock: &nothing,
        after_journal: &nothing,
        after_write: &nothing,
        in_write: &late,
        in_rollback: &nothing_at,
    };
    let restored = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));
    let RestoreStage::PartiallyApplied { reason, failed, .. } = &restored.stage else {
        panic!("{:?}", restored.stage);
    };
    assert_eq!(*reason, StageReason::KeptAside);
    let place = failed[0].kept_at().unwrap().to_owned();
    assert_eq!(failed[0].path, "a.txt");
    assert_eq!(repo.read(&place).as_deref(), Some("written late\n"));

    let undo = finished(repo.undo(&restored.op_id));

    let RestoreStage::PartiallyApplied { reason, failed, .. } = &undo.stage else {
        panic!("{:?}", undo.stage);
    };
    assert_eq!(*reason, StageReason::KeptAside);
    assert!(
        failed.iter().any(|failed| failed.kept_at() == Some(&place)),
        "{failed:?}"
    );
    assert!(matches!(
        repo.worktree()
            .journal(&restored.op_id)
            .unwrap()
            .unwrap()
            .stage,
        RestoreStage::Undone { .. }
    ));

    // A crash after the undo's journal and before the marks: recovery
    // marks the restore, and the undo names the saves.
    let worktree = repo.worktree();
    let mut bare = undo.clone();
    bare.stage = RestoreStage::Applied;
    assert!(worktree.write_journal(&bare).is_ok());
    assert!(worktree.write_journal(&restored).is_ok());
    let _ = recover(&repo.path, NOW).unwrap();
    let undo = worktree.journal(&undo.op_id).unwrap().unwrap();
    let RestoreStage::PartiallyApplied { failed, .. } = &undo.stage else {
        panic!("{:?}", undo.stage);
    };
    assert_eq!(
        failed
            .iter()
            .filter(|failed| failed.kept_at() == Some(&place))
            .count(),
        1
    );
    assert_eq!(
        worktree.journal(&restored.op_id).unwrap().unwrap().stage,
        RestoreStage::Undone { by: undo.op_id }
    );
    assert_eq!(repo.read(&place).as_deref(), Some("written late\n"));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
}

/// The stage is what the planned paths hold: a write that failed where the
/// path still holds what was there before is no part of a partial restore.
/// A failure is said beside a stage only of a path the operation did not
/// leave as it writes it.
#[test]
fn a_failed_write_is_said_beside_the_stage_the_paths_decide() {
    let change = |path: &str| Change {
        raw: path.as_bytes().to_vec(),
        display: path.to_owned(),
        kind: PathChangeKind::Modify,
        mode: "100644".to_owned(),
        object: "0".repeat(40),
    };
    let reading = |states: &[(&str, PathState)]| Reading {
        paths: states
            .iter()
            .map(|(path, state)| PlannedPath {
                change: change(path),
                state: *state,
                now: None,
                back: change(path),
            })
            .collect(),
        current_tree: "c".repeat(40),
    };
    let failure = |path: &str| FailedPath {
        path: path.to_owned(),
        reason: FailedReason::WriteFailed,
        detail: Some("checkout-index".to_owned()),
    };

    let untouched = reading(&[("a", PathState::Before), ("b", PathState::Before)]);
    assert_eq!(
        settled_stage(&untouched, StageReason::WriteFailed, vec![failure("b")]),
        Some(RestoreStage::Aborted {
            reason: StageReason::WriteFailed
        })
    );

    let written = reading(&[("a", PathState::Target), ("b", PathState::Target)]);
    assert_eq!(
        settled_stage(&written, StageReason::WriteFailed, vec![failure("b")]),
        None
    );

    let half = reading(&[
        ("a", PathState::Target),
        ("b", PathState::Before),
        ("c", PathState::Other),
    ]);
    assert_eq!(
        settled_stage(
            &half,
            StageReason::WriteFailed,
            vec![failure("a"), failure("b")]
        ),
        Some(RestoreStage::PartiallyApplied {
            reason: StageReason::WriteFailed,
            current_tree: "c".repeat(40),
            kept: vec!["c".into()],
            failed: vec![failure("b")],
        })
    );
}
