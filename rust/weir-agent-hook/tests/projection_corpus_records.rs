//! The projection corpus's generated records are what the hook runtime writes
//! today. Each case's scenario is replayed into a scratch directory and
//! compared, file by file, with what is committed, so a runtime change that
//! leaves the records behind fails here instead of feeding the projection
//! goldens records no hook writes any more. Unix only: the hook runtime itself
//! only runs there.
#![cfg(unix)]

#[path = "../examples/derive-projection-corpus.rs"]
mod derive;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

/// Every file under `root`'s generated directories, by its path below
/// `root`, with its bytes. Lock sidecars are pruned by `derive`, and the
/// committed tree has none.
fn generated_files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    for directory in derive::GENERATED {
        let entries = match fs::read_dir(root.join(directory)) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => panic!("read {}: {error}", root.join(directory).display()),
        };
        for entry in entries {
            let entry = entry.expect("generated directory entry");
            let name = format!("{directory}/{}", entry.file_name().to_string_lossy());
            files.insert(name, fs::read(entry.path()).expect("read a record"));
        }
    }
    files
}

#[test]
fn the_committed_records_are_what_the_runtime_writes_now() {
    let fixtures = derive::fixtures();
    let scenarios = derive::cases(&fixtures).expect("projection scenarios");
    let cases: BTreeSet<_> = fs::read_dir(fixtures.join("projection"))
        .expect("projection cases")
        .map(|entry| entry.expect("projection directory entry").path())
        .filter(|path| path.is_dir())
        .collect();
    assert!(!cases.is_empty(), "no projection case to replay");
    let scenarios: BTreeSet<_> = scenarios.into_iter().collect();
    let missing: Vec<_> = cases.difference(&scenarios).collect();
    assert!(
        missing.is_empty(),
        "projection cases without scenario.json: {missing:?}"
    );
    let mut stale = Vec::new();
    for case in &cases {
        let scratch = tempfile::tempdir().expect("scratch");
        derive::derive(case, &fixtures, scratch.path()).expect("the scenario replays");
        let written = generated_files(scratch.path());
        let committed = generated_files(case);
        let name = case.file_name().unwrap_or_default().to_string_lossy();
        for path in committed
            .keys()
            .chain(written.keys())
            .collect::<BTreeSet<_>>()
        {
            if committed.get(path) != written.get(path) {
                stale.push(format!("{name}/{path}"));
            }
        }
    }
    assert!(
        stale.is_empty(),
        "stale corpus records; run scripts/derive-projection-corpus.sh and \
         review the diff:\n{}",
        stale.join("\n")
    );
}
