//! Fixture driver shared by every provider crate.
//!
//! A provider crate's `tests/conformance.rs` calls these functions with its
//! adapter and the fixture directories under `rust/fixtures`. The driver
//! walks `<provider>/<schema-date>/<case>/`, feeds each recorded payload to
//! `normalize` (with the titles its title index gives, as the hook runtime
//! adds them) and `approval_request`, and compares the result with the
//! case's `expected.json` and `approval.expected.json`. The negative set is
//! shared by all providers: every adapter must reject oversized or
//! non-object input and preserve unknown events as one `Extension`.

use crate::{
    AgentEvent, ApprovalRequest, HookContext, MAX_HOOK_INPUT_BYTES, NormalizeError,
    ProviderAdapter, RawHookInput,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// One mismatch between an adapter and a fixture.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConformanceFailure {
    /// The case directory or negative file.
    pub case: PathBuf,
    /// The payload file within the case, when applicable.
    pub payload: Option<String>,
    pub expected: String,
    pub got: String,
}

impl fmt::Display for ConformanceFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.case.display())?;
        if let Some(payload) = &self.payload {
            write!(formatter, " / {payload}")?;
        }
        write!(
            formatter,
            "\n  expected: {}\n  got:      {}",
            self.expected, self.got
        )
    }
}

impl HookContext {
    /// The context every fixture is replayed under. Stable ids keep
    /// `expected.json` independent of the machine that runs the test.
    #[must_use]
    pub fn fixture() -> Self {
        Self {
            run_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0010),
            pane_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0020),
            tmux: None,
            pid: Some(4242),
            invocation_id: Some(Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0030)),
            provider_home: None,
            hook_directory: None,
        }
    }

    /// The fixture context for one provider: `fixture()` with the home the
    /// scrubbed payloads name, `/Users/example/.<provider id>`, which is the
    /// provider's default directory under the scrubbed home.
    #[must_use]
    pub fn fixture_for(descriptor: &crate::ProviderDescriptor) -> Self {
        Self {
            provider_home: Some(PathBuf::from(format!("/Users/example/.{}", descriptor.id))),
            ..Self::fixture()
        }
    }
}

/// Runs every case under `provider_root` through `normalize`.
///
/// # Panics
///
/// Panics when the fixture tree itself is malformed (unreadable directory or
/// `expected.json` that is not `Vec<Vec<AgentEvent>>`) or when no cases are
/// found or a case contains no payloads.
#[must_use]
pub fn run_normalize(
    adapter: &dyn ProviderAdapter,
    provider_root: &Path,
) -> Vec<ConformanceFailure> {
    let mut failures = Vec::new();
    for case in cases_under(provider_root) {
        let expected_path = case.join("expected.json");
        let expected: Vec<Vec<AgentEvent>> = read_json(&expected_path);
        let payloads = case_payloads(&case);
        if payloads.len() != expected.len() {
            failures.push(ConformanceFailure {
                case: case.clone(),
                payload: None,
                expected: format!("{} entries in expected.json", payloads.len()),
                got: format!("{} entries", expected.len()),
            });
        }
        for (index, payload) in payloads.iter().enumerate() {
            let bytes = fs::read(payload).expect("payload is readable");
            let transcript = transcript_for(payload);
            let context = HookContext::fixture_for(adapter.descriptor());
            let input = RawHookInput {
                bytes: &bytes,
                transcript: transcript.as_deref(),
            };
            let actual = adapter.normalize(input, &context).map(|mut events| {
                add_indexed_titles(adapter, input, &context, payload, &mut events);
                events
            });
            let wanted = expected.get(index);
            let matches = matches!((&actual, wanted), (Ok(events), Some(want)) if events == want);
            if !matches {
                failures.push(ConformanceFailure {
                    case: case.clone(),
                    payload: Some(file_name(payload)),
                    expected: wanted
                        .map_or_else(|| "<missing>".to_owned(), |want| format!("{want:?}")),
                    got: format!("{actual:?}"),
                });
            }
        }
    }
    failures
}

/// Runs every payload under `provider_root` through `approval_request`.
///
/// Cases with an `approval.expected.json` map payload file names to the
/// request the adapter must derive (`null` for "not an approval"). Every
/// payload not listed must yield `Ok(None)`.
///
/// # Panics
///
/// Panics when the fixture tree itself is malformed, no cases are found, or a
/// case contains no payloads.
#[must_use]
pub fn run_approval(
    adapter: &dyn ProviderAdapter,
    provider_root: &Path,
) -> Vec<ConformanceFailure> {
    let mut failures = Vec::new();
    for case in cases_under(provider_root) {
        let expected_path = case.join("approval.expected.json");
        let mut expected: BTreeMap<String, Option<ApprovalRequest>> = if expected_path.exists() {
            read_json(&expected_path)
        } else {
            BTreeMap::new()
        };
        for payload in case_payloads(&case) {
            let bytes = fs::read(&payload).expect("payload is readable");
            let actual = adapter.approval_request(RawHookInput {
                bytes: &bytes,
                transcript: None,
            });
            let name = file_name(&payload);
            let wanted = expected.remove(&name).flatten();
            let matches = matches!(&actual, Ok(request) if *request == wanted);
            if !matches {
                failures.push(ConformanceFailure {
                    case: case.clone(),
                    payload: Some(name),
                    expected: format!("{wanted:?}"),
                    got: format!("{actual:?}"),
                });
            }
        }
        failures.extend(expected.into_keys().map(|name| ConformanceFailure {
            case: case.clone(),
            payload: Some(name),
            expected: "a payload listed in approval.expected.json".to_owned(),
            got: "no matching payload file".to_owned(),
        }));
    }
    failures
}

/// Runs the shared negative set plus a synthesized oversized payload.
///
/// Oversized input must produce `TooLarge` with the hook input limit.
/// Malformed JSON and non-object roots must produce `NotAnObject`.
/// Unknown events must produce one `Extension` with the original name and
/// payload. The oversized payload is generated to keep padding out of the
/// repository.
///
/// # Panics
///
/// Panics when a directory or fixture cannot be read, or when a negative
/// fixture contains a JSON object without an event name.
#[must_use]
pub fn run_negative(
    adapter: &dyn ProviderAdapter,
    negative_root: &Path,
) -> Vec<ConformanceFailure> {
    let payloads = payloads_in(negative_root);
    let mut failures: Vec<_> = [
        "array-root.json",
        "string-root.json",
        "truncated.json",
        "unknown-event.json",
    ]
    .into_iter()
    .map(|name| negative_root.join(name))
    .filter(|path| !payloads.contains(path))
    .map(|case| ConformanceFailure {
        case,
        payload: None,
        expected: "required negative fixture".to_owned(),
        got: "no matching payload file".to_owned(),
    })
    .collect();
    let inputs = payloads.into_iter().map(|path| {
        let bytes =
            fs::read(&path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
        (path, bytes)
    });
    let mut oversized = br#"{"hook_event_name":"Stop","padding":""#.to_vec();
    let suffix = b"\"}";
    oversized.resize(MAX_HOOK_INPUT_BYTES + 1 - suffix.len(), b'x');
    oversized.extend_from_slice(suffix);
    let oversized_input = (
        negative_root.join("<synthesized oversized payload>"),
        oversized,
    );

    let context = HookContext::fixture_for(adapter.descriptor());
    for (path, bytes) in inputs.chain([oversized_input]) {
        let wanted = if bytes.len() > MAX_HOOK_INPUT_BYTES {
            Err(NormalizeError::TooLarge {
                limit: MAX_HOOK_INPUT_BYTES,
            })
        } else if let Ok(payload @ Value::Object(_)) = serde_json::from_slice::<Value>(&bytes) {
            let name = payload["hook_event_name"]
                .as_str()
                .unwrap_or_else(|| panic!("missing event name in {}", path.display()))
                .to_owned();
            Ok(vec![AgentEvent::Extension { name, payload }])
        } else {
            Err(NormalizeError::NotAnObject)
        };
        let actual = adapter.normalize(
            RawHookInput {
                bytes: &bytes,
                transcript: None,
            },
            &context,
        );
        if actual != wanted {
            failures.push(ConformanceFailure {
                case: path,
                payload: None,
                expected: format!("{wanted:?}"),
                got: format!("{actual:?}"),
            });
        }
    }
    failures
}

/// Every `<schema-date>/<case>` directory under a provider's fixture root,
/// sorted so failures are reported in a stable order.
fn cases_under(provider_root: &Path) -> Vec<PathBuf> {
    let mut cases = Vec::new();
    for date in sorted_entries(provider_root) {
        if !date.is_dir() {
            continue;
        }
        for case in sorted_entries(&date) {
            if case.is_dir() {
                cases.push(case);
            }
        }
    }
    assert!(
        !cases.is_empty(),
        "no fixture cases under {}",
        provider_root.display()
    );
    cases
}

/// Payload files in a case: `NNNN-<Event>.json`, sorted by name so the
/// recorder's sequence number orders them.
fn payloads_in(case: &Path) -> Vec<PathBuf> {
    sorted_entries(case)
        .into_iter()
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
                && !file_name(path).ends_with("expected.json")
        })
        .collect()
}

fn case_payloads(case: &Path) -> Vec<PathBuf> {
    let payloads = payloads_in(case);
    assert!(
        !payloads.is_empty(),
        "no payloads in fixture case {}",
        case.display()
    );
    payloads
}

fn transcript_for(payload: &Path) -> Option<Vec<u8>> {
    let name = file_name(payload);
    let stem = name.strip_suffix(".json")?;
    let transcript = payload.with_file_name(format!("{stem}.transcript.jsonl"));
    fs::read(transcript).ok()
}

/// Adds the titles the payload's title index gives, as the hook runtime does:
/// only for a payload the adapter names an index for, read from the case's
/// `NNNN-<Event>.title-index.jsonl`, which holds the index as it was at that
/// call.
fn add_indexed_titles(
    adapter: &dyn ProviderAdapter,
    input: RawHookInput<'_>,
    context: &HookContext,
    payload: &Path,
    events: &mut [AgentEvent],
) {
    if !matches!(adapter.title_index_path(input, context), Ok(Some(_))) {
        return;
    }
    let name = file_name(payload);
    let Some(stem) = name.strip_suffix(".json") else {
        return;
    };
    let Ok(index) = fs::read(payload.with_file_name(format!("{stem}.title-index.jsonl"))) else {
        return;
    };
    if let Some(titles) = adapter.indexed_titles(input, &index) {
        for event in events {
            event.add_titles(&titles);
        }
    }
}

fn sorted_entries(directory: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<PathBuf> = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("read {}: {error}", directory.display()))
        .map(|entry| entry.expect("directory entry").path())
        .collect();
    entries.sort();
    entries
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> T {
    let bytes = fs::read(path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    serde_json::from_slice(&bytes)
        .unwrap_or_else(|error| panic!("parse {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        ApprovalDecision, Capability, InstallRecipe, ProviderDescriptor, ProviderOutput,
        parse_object,
    };

    type NormalizeFixture = fn(&[u8]) -> Result<Vec<AgentEvent>, NormalizeError>;

    /// Turns every object into one `Extension` named after its event, and
    /// treats a `PermissionRequest` as an approval for `tool_name`.
    struct PassThrough {
        descriptor: ProviderDescriptor,
        normalize_bytes: NormalizeFixture,
    }

    impl PassThrough {
        fn new() -> Self {
            Self {
                descriptor: ProviderDescriptor::fixture("fake", [Capability::ApprovalHook]),
                normalize_bytes: Self::preserve_payload,
            }
        }

        fn preserve_payload(bytes: &[u8]) -> Result<Vec<AgentEvent>, NormalizeError> {
            let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
            let name = object
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("unknown")
                .to_owned();
            Ok(vec![AgentEvent::Extension {
                name,
                payload: serde_json::Value::Object(object),
            }])
        }
    }

    impl ProviderAdapter for PassThrough {
        fn descriptor(&self) -> &ProviderDescriptor {
            &self.descriptor
        }

        fn install_recipe(&self) -> InstallRecipe {
            InstallRecipe::default()
        }

        fn normalize(
            &self,
            input: RawHookInput<'_>,
            _context: &HookContext,
        ) -> Result<Vec<AgentEvent>, NormalizeError> {
            (self.normalize_bytes)(input.bytes)
        }

        fn approval_request(
            &self,
            input: RawHookInput<'_>,
        ) -> Result<Option<ApprovalRequest>, NormalizeError> {
            let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
            if object
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                != Some("PermissionRequest")
            {
                return Ok(None);
            }
            Ok(Some(ApprovalRequest {
                provider: self.descriptor.id.clone(),
                session_id: None,
                operation_id: None,
                tool_name: object
                    .get("tool_name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                summary: None,
                input: serde_json::Value::Null,
                timeout_ms: 1,
                questions: Vec::new(),
            }))
        }

        fn approval_output(
            &self,
            _decision: &ApprovalDecision,
            _request: &serde_json::Value,
        ) -> ProviderOutput {
            ProviderOutput::default()
        }
    }

    /// A scratch fixture tree that removes itself.
    struct Tree(PathBuf);

    impl Tree {
        fn new(name: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("weir-conformance-{name}-{}", Uuid::new_v4()));
            fs::create_dir_all(&root).expect("create scratch tree");
            Self(root)
        }

        fn write(&self, relative: &str, contents: &str) {
            let path = self.0.join(relative);
            fs::create_dir_all(path.parent().expect("parent")).expect("create case");
            fs::write(path, contents).expect("write fixture");
        }

        fn negative() -> Self {
            let tree = Self::new("negative");
            tree.write("truncated.json", "{\"hook_event_name\":");
            tree.write("array-root.json", "[1]");
            tree.write("string-root.json", r#""text""#);
            tree.write(
                "unknown-event.json",
                r#"{"hook_event_name":"Whatever","payload":{"nested":[1,2,3]}}"#,
            );
            tree
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn matching_expectations_report_no_failures() {
        let tree = Tree::new("ok");
        tree.write(
            "2026-09/basic/0000-Stop.json",
            r#"{"hook_event_name":"Stop","x":1}"#,
        );
        tree.write(
            "2026-09/basic/expected.json",
            r#"[[{"type":"extension","name":"Stop","payload":{"hook_event_name":"Stop","x":1}}]]"#,
        );
        assert_eq!(run_normalize(&PassThrough::new(), &tree.0), Vec::new());
        assert_eq!(run_approval(&PassThrough::new(), &tree.0), Vec::new());
    }

    #[test]
    fn mismatches_and_missing_expectations_are_reported_per_payload() {
        let tree = Tree::new("mismatch");
        tree.write(
            "2026-09/basic/0000-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write(
            "2026-09/basic/0001-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write(
            "2026-09/basic/expected.json",
            r#"[[{"type":"compacting"}]]"#,
        );
        let failures = run_normalize(&PassThrough::new(), &tree.0);
        let payloads: Vec<Option<String>> = failures
            .iter()
            .map(|failure| failure.payload.clone())
            .collect();
        assert_eq!(
            payloads,
            vec![
                None,
                Some("0000-Stop.json".into()),
                Some("0001-Stop.json".into())
            ]
        );
        assert!(
            failures
                .iter()
                .all(|failure| failure.case == tree.0.join("2026-09/basic"))
        );
        assert_eq!(failures[0].expected, "2 entries in expected.json");
        assert_eq!(failures[0].got, "1 entries");
        assert_eq!(failures[1].expected, "[Compacting]");
        assert!(failures[1].got.contains("Extension"));
        assert_eq!(failures[2].expected, "<missing>");
        assert!(failures[2].got.contains("Extension"));
    }

    #[test]
    fn approval_expectations_cover_listed_and_unlisted_payloads() {
        let tree = Tree::new("approval");
        tree.write(
            "2026-09/ask/0000-PermissionRequest.json",
            r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#,
        );
        tree.write(
            "2026-09/ask/0001-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write("2026-09/ask/expected.json", "[[],[]]");
        tree.write(
            "2026-09/ask/approval.expected.json",
            r#"{"0000-PermissionRequest.json":{"provider":"fake","tool_name":"Bash","input":null,"timeout_ms":1}}"#,
        );
        assert_eq!(run_approval(&PassThrough::new(), &tree.0), Vec::new());

        tree.write(
            "2026-09/ask/approval.expected.json",
            r#"{"0000-PermissionRequest.json":null}"#,
        );
        let failures = run_approval(&PassThrough::new(), &tree.0);
        assert_eq!(failures.len(), 1);
        assert_eq!(
            failures[0].payload.as_deref(),
            Some("0000-PermissionRequest.json")
        );
    }

    #[test]
    fn approval_reports_unmatched_keys_even_when_their_value_is_null() {
        let tree = Tree::new("unmatched-approval");
        tree.write(
            "2026-09/ask/0000-Stop.json",
            r#"{"hook_event_name":"Stop"}"#,
        );
        tree.write(
            "2026-09/ask/approval.expected.json",
            r#"{"0000-Stop.json":null,"0001-Stop.json":null,"0002-PermissionRequest.json":{"provider":"fake","tool_name":"Bash","input":null,"timeout_ms":1}}"#,
        );
        let failures = run_approval(&PassThrough::new(), &tree.0);
        let names: Vec<_> = failures
            .iter()
            .map(|failure| failure.payload.as_deref())
            .collect();
        assert_eq!(
            names,
            [Some("0001-Stop.json"), Some("0002-PermissionRequest.json")]
        );
    }

    #[test]
    #[should_panic(expected = "no fixture cases under")]
    fn an_empty_provider_root_fails_discovery() {
        let tree = Tree::new("empty-provider");
        let _ = run_normalize(&PassThrough::new(), &tree.0);
    }

    #[test]
    #[should_panic(expected = "no payloads in fixture case")]
    fn an_empty_case_cannot_pass_normalization() {
        let tree = Tree::new("empty-normalize-case");
        tree.write("2026-09/empty/expected.json", "[]");
        let _ = run_normalize(&PassThrough::new(), &tree.0);
    }

    #[test]
    #[should_panic(expected = "no payloads in fixture case")]
    fn an_empty_case_cannot_pass_approval() {
        let tree = Tree::new("empty-approval-case");
        tree.write("2026-09/empty/approval.expected.json", "{}");
        let _ = run_approval(&PassThrough::new(), &tree.0);
    }

    #[test]
    fn a_missing_negative_fixture_is_reported_by_name() {
        let tree = Tree::negative();
        fs::remove_file(tree.0.join("string-root.json")).expect("remove fixture");
        let failures = run_negative(&PassThrough::new(), &tree.0);
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].case, tree.0.join("string-root.json"));
        assert_eq!(failures[0].payload, None);
        assert_eq!(failures[0].expected, "required negative fixture");
        assert_eq!(failures[0].got, "no matching payload file");
    }

    #[test]
    fn the_negative_set_rejects_wrong_errors_and_altered_extensions() {
        let tree = Tree::negative();
        let mut adapter = PassThrough::new();
        assert_eq!(run_negative(&adapter, &tree.0), Vec::new());

        let oversized = "<synthesized oversized payload>";
        let wrong_results: [(NormalizeFixture, &[&str]); 5] = [
            (
                |_| Ok(Vec::new()),
                &[
                    "array-root.json",
                    "string-root.json",
                    "truncated.json",
                    "unknown-event.json",
                    oversized,
                ],
            ),
            (
                |_| Err(NormalizeError::NotAnObject),
                &["unknown-event.json", oversized],
            ),
            (
                |bytes| {
                    PassThrough::preserve_payload(bytes)
                        .map_err(|_| NormalizeError::TooLarge { limit: 1 })
                },
                &[
                    "array-root.json",
                    "string-root.json",
                    "truncated.json",
                    oversized,
                ],
            ),
            (
                |bytes| {
                    let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
                    Ok(vec![AgentEvent::Extension {
                        name: "changed".to_owned(),
                        payload: Value::Object(object),
                    }])
                },
                &["unknown-event.json"],
            ),
            (
                |bytes| {
                    let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
                    let name = object["hook_event_name"]
                        .as_str()
                        .expect("event name")
                        .to_owned();
                    Ok(vec![AgentEvent::Extension {
                        name,
                        payload: Value::Null,
                    }])
                },
                &["unknown-event.json"],
            ),
        ];
        for (normalize_bytes, rejected) in wrong_results {
            adapter.normalize_bytes = normalize_bytes;
            let failures = run_negative(&adapter, &tree.0);
            let names: Vec<_> = failures
                .iter()
                .map(|failure| file_name(&failure.case))
                .collect();
            assert_eq!(names, rejected, "{failures:?}");
        }
    }
}
