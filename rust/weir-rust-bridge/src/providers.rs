//! The C ABI for provider translation and hook execution.
//!
//! Provider lookup is delegated to the hook runtime so all callers share one
//! registry.

use crate::transfer;
use serde_json::Value;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use weir_agent_hook::{
    GitSnapshots, HookEnv, HookLog, HookOutcome, HookRuntime, MAX_INVOCATION_BYTES, NoSnapshots,
    SnapshotRunner, adapter_for, run_hook, run_hook_invocation, run_worktree_hook,
};
use weir_agent_model::{
    ApprovalDecision, FailureWatch, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter,
    RawHookInput,
};

/// Status codes returned by the provider translation ABI functions,
/// reported as `int32_t` for the same reason as `weir_approval_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum weir_provider_result {
    /// The call succeeded and the output buffer holds the result.
    WEIR_PROVIDER_OK = 0,
    /// The payload is valid but is not a permission request; the output
    /// buffer is empty.
    WEIR_PROVIDER_NOT_APPROVAL = 1,
    /// A required pointer was null.
    WEIR_PROVIDER_NULL_POINTER = 2,
    /// The provider id is not registered in this build.
    WEIR_PROVIDER_UNKNOWN_PROVIDER = 3,
    /// The input exceeded the hook payload limit.
    WEIR_PROVIDER_INPUT_TOO_LARGE = 4,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    WEIR_PROVIDER_INVALID_INPUT = 5,
    /// The translation could not be serialized.
    WEIR_PROVIDER_INTERNAL = 6,
    /// Rust caught a panic at the FFI boundary.
    WEIR_PROVIDER_PANIC = 7,
    /// `weir_hook_log_line_v1` could not write the line: the log could not
    /// be opened (a symlink or no plain file at its path, a folder that is
    /// not there), set aside, or written.
    WEIR_PROVIDER_LOG_NOT_WRITTEN = 8,
}

const PROVIDER_OK: i32 = weir_provider_result::WEIR_PROVIDER_OK as i32;
const PROVIDER_NOT_APPROVAL: i32 = weir_provider_result::WEIR_PROVIDER_NOT_APPROVAL as i32;
const PROVIDER_NULL_POINTER: i32 = weir_provider_result::WEIR_PROVIDER_NULL_POINTER as i32;
const PROVIDER_UNKNOWN_PROVIDER: i32 = weir_provider_result::WEIR_PROVIDER_UNKNOWN_PROVIDER as i32;
const PROVIDER_INPUT_TOO_LARGE: i32 = weir_provider_result::WEIR_PROVIDER_INPUT_TOO_LARGE as i32;
const PROVIDER_INVALID_INPUT: i32 = weir_provider_result::WEIR_PROVIDER_INVALID_INPUT as i32;
const PROVIDER_INTERNAL: i32 = weir_provider_result::WEIR_PROVIDER_INTERNAL as i32;
const PROVIDER_PANIC: i32 = weir_provider_result::WEIR_PROVIDER_PANIC as i32;
const PROVIDER_LOG_NOT_WRITTEN: i32 = weir_provider_result::WEIR_PROVIDER_LOG_NOT_WRITTEN as i32;

/// The longest transcript line asked about: more than the watcher's reads can
/// hand over together with what they kept of the line before.
const MAX_TRANSCRIPT_LINE_BYTES: usize = 8 * 1024 * 1024;

/// Which hook entry point `weir_hook_run_v1` runs.
pub const WEIR_HOOK_KIND_LIFECYCLE: u32 = 0;
/// The worktree intercept the providers call on their shell tool.
pub const WEIR_HOOK_KIND_WORKTREE: u32 = 1;
/// An envelope containing helper arguments and the original provider payload.
pub const WEIR_HOOK_KIND_INVOCATION: u32 = 2;

/// Runs one lifecycle or worktree hook call and reports the outcome as JSON:
/// `{"outcome":"applied","exit_code":0}` or, after a worktree intercept,
/// `{"outcome":"intercepted","exit_code":2,"message":"..."}`. Every other
/// outcome (`not_in_weir`, `rejected`, `unknown_provider`) carries exit
/// code zero so the agent is never blocked. `env_json` is a JSON object of
/// the process environment; the runtime reads the shim's variables from it
/// rather than from the process so the host controls what the hook sees.
/// The working directory, which no variable says, is read from the process:
/// the Hook Helper makes this call in the process the provider started for
/// the hook, in the directory it started it in
/// (`HookContext::hook_directory`).
/// `WEIR_HOOK_KIND_INVOCATION` takes an object with `arguments` (string array)
/// and `payload` (the original UTF-8 JSON text). Its envelope is bounded at
/// 8 MiB to allow JSON escaping; the runtime bounds the original and completed
/// payloads at 1 MiB. Other kinds take the provider payload directly.
/// This call opens no approval service connection. On success, ownership
/// of `*out` transfers to the caller, which must release it with
/// `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`, with `env_json`
/// readable for `env_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_hook_run_v1(
    provider: *const u8,
    provider_len: usize,
    kind: u32,
    input: *const u8,
    input_len: usize,
    env_json: *const u8,
    env_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let provider = unsafe { input_bytes(provider, provider_len) }?;
        let provider = std::str::from_utf8(provider).map_err(|_| PROVIDER_INVALID_INPUT)?;
        let input_limit = if kind == WEIR_HOOK_KIND_INVOCATION {
            MAX_INVOCATION_BYTES
        } else {
            MAX_HOOK_INPUT_BYTES
        };
        let input = unsafe { bounded_input_bytes(input, input_len, input_limit) }?;
        let env_json = unsafe { input_bytes(env_json, env_len) }?;
        let variables: std::collections::BTreeMap<String, String> =
            serde_json::from_slice(env_json).map_err(|_| PROVIDER_INVALID_INPUT)?;
        let env = HookEnv::from_pairs(variables);
        let env = match std::env::current_dir() {
            Ok(directory) => env.in_directory(directory),
            Err(_) => env,
        };
        let git = GitSnapshots;
        let none = NoSnapshots;
        let snapshots: &dyn SnapshotRunner = if env.turn_snapshots_disabled() {
            &none
        } else {
            &git
        };
        let runtime = HookRuntime::new(&env, snapshots);
        let outcome = match kind {
            WEIR_HOOK_KIND_LIFECYCLE => run_hook(provider, input, &runtime),
            WEIR_HOOK_KIND_WORKTREE => run_worktree_hook(provider, input, &runtime),
            WEIR_HOOK_KIND_INVOCATION => run_hook_invocation(provider, input, &runtime),
            _ => return Err(PROVIDER_INVALID_INPUT),
        };
        let body = serde_json::to_vec(&outcome_json(&outcome)).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Appends `message` to the hook log at `path`, labeled `weir-hook-helper`,
/// as the hook runtime appends its own lines (`HookLog`): one writer, so the file is created and set
/// aside private to the user whatever its earlier mode or the umask, a
/// symlink at `path` is refused, and the log is kept to one earlier
/// generation. Both are UTF-8. A line that could not be written returns
/// `WEIR_PROVIDER_LOG_NOT_WRITTEN`, so the caller can print it where it
/// still can.
///
/// # Safety
///
/// `path` must be readable for `path_len` bytes and `message` for
/// `message_len` bytes (either may be null with a zero length).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_hook_log_line_v1(
    path: *const u8,
    path_len: usize,
    message: *const u8,
    message_len: usize,
) -> i32 {
    let status = provider_boundary(|| {
        let path = unsafe { input_bytes(path, path_len) }?;
        let path = std::str::from_utf8(path).map_err(|_| PROVIDER_INVALID_INPUT)?;
        if path.is_empty() {
            return Err(PROVIDER_INVALID_INPUT);
        }
        let message = unsafe { input_bytes(message, message_len) }?;
        let message = std::str::from_utf8(message).map_err(|_| PROVIDER_INVALID_INPUT)?;
        HookLog::at(std::path::PathBuf::from(path))
            .write_line(HOOK_HELPER_LOG_SOURCE, message)
            .map_err(|_| PROVIDER_LOG_NOT_WRITTEN)?;
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// The label `weir_hook_log_line_v1` gives the Hook Helper's lines, beside
/// the runtime's own `weir-agent-hook`.
const HOOK_HELPER_LOG_SOURCE: &str = "weir-hook-helper";

fn outcome_json(outcome: &HookOutcome) -> serde_json::Value {
    let (name, message, stdout) = match outcome {
        HookOutcome::Applied => ("applied", None, None),
        HookOutcome::NotInWeir => ("not_in_weir", None, None),
        HookOutcome::Rejected(reason) => ("rejected", Some(reason.clone()), None),
        HookOutcome::UnknownProvider => ("unknown_provider", None, None),
        HookOutcome::NotRecorded(reason) => ("not_recorded", Some(reason.clone()), None),
        HookOutcome::Intercepted {
            message, stdout, ..
        } => ("intercepted", Some(message.clone()), stdout.as_deref()),
    };
    let mut body = serde_json::json!({
        "outcome": name,
        "exit_code": outcome.exit_code(),
    });
    if let Some(message) = message {
        body["message"] = serde_json::Value::String(message);
    }
    if let Some(stdout) = stdout {
        body["stdout"] = serde_json::Value::String(String::from_utf8_lossy(stdout).into_owned());
    }
    body
}

/// Translates a provider's `PermissionRequest` payload into the neutral
/// approval request as JSON.
///
/// Returns `WEIR_PROVIDER_OK` with a JSON body, `WEIR_PROVIDER_NOT_APPROVAL`
/// with an empty body when the payload is not a permission request, or an
/// error code with an empty body. On success, ownership of `*out` transfers to
/// the caller, which must release it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// `out` and `out_len` must be writable. `provider` must be readable for
/// `provider_len` bytes and `input` for `input_len` bytes; either may be null
/// only when its length is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_approval_request_v1(
    provider: *const u8,
    provider_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        let input = unsafe { input_bytes(input, input_len) }?;
        let request = adapter
            .approval_request(RawHookInput {
                bytes: input,
                transcript: None,
            })
            .map_err(|error| normalize_status(&error))?;
        let Some(request) = request else {
            return Ok(PROVIDER_NOT_APPROVAL);
        };
        let body = serde_json::to_vec(&request).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Renders a neutral decision as the provider's hook output.
///
/// `decision_json` is an `ApprovalDecision` document such as
/// `{"decision":"allow_once"}` or `{"decision":"deny","message":"..."}`.
/// An `answer` decision always delegates through this entry point, because it
/// has no request to echo; callers that need it rendered use
/// `weir_provider_approval_output_v2` with the request document.
/// Returns `WEIR_PROVIDER_OK` with the bytes to write to the hook's standard
/// output; an empty body means the provider's native flow decides. On
/// success, ownership of `*out` transfers to the caller, which must release
/// it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_approval_output_v1(
    provider: *const u8,
    provider_len: usize,
    decision_json: *const u8,
    decision_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        let decision = unsafe { input_bytes(decision_json, decision_len) }?;
        let decision: ApprovalDecision =
            serde_json::from_slice(decision).map_err(|_| PROVIDER_INVALID_INPUT)?;
        if let Some(body) = adapter.approval_output(&decision, &Value::Null).stdout {
            // SAFETY: The caller guarantees both output pointers are writable,
            // and the bytes are owned by the caller until it frees them.
            unsafe { transfer(body, out, out_len) };
        }
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Same as `weir_provider_approval_output_v1`, with the `ApprovalRequest`
/// JSON that `weir_provider_approval_request_v1` produced. An answer needs
/// the request's `tool_name` and `input`; the other decisions ignore it.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_approval_output_v2(
    provider: *const u8,
    provider_len: usize,
    request_json: *const u8,
    request_len: usize,
    decision_json: *const u8,
    decision_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        let request = unsafe { input_bytes(request_json, request_len) }?;
        let request: Value = serde_json::from_slice(request).map_err(|_| PROVIDER_INVALID_INPUT)?;
        let decision = unsafe { input_bytes(decision_json, decision_len) }?;
        let decision: ApprovalDecision =
            serde_json::from_slice(decision).map_err(|_| PROVIDER_INVALID_INPUT)?;
        if let Some(body) = adapter.approval_output(&decision, &request).stdout {
            // SAFETY: The caller guarantees both output pointers are writable,
            // and the bytes are owned by the caller until it frees them.
            unsafe { transfer(body, out, out_len) };
        }
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Asks `provider` about one line of a transcript a watcher reads. Reports the
/// `FailureReport` as JSON when the line is a turn that failed, and `null` for
/// any other line. On success, ownership of `*out` transfers to the caller,
/// which must release it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`, with `line` readable
/// for `line_len` bytes, and `transcript_path` and `session_id` readable for
/// their lengths.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn weir_provider_turn_failure_report_v1(
    provider: *const u8,
    provider_len: usize,
    line: *const u8,
    line_len: usize,
    transcript_path: *const u8,
    transcript_path_len: usize,
    session_id: *const u8,
    session_id_len: usize,
    read_at: u64,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        // A line is not a hook payload: a turn's end can carry a long answer,
        // and one refused here is a failure never reported.
        if line_len > MAX_TRANSCRIPT_LINE_BYTES {
            return Err(PROVIDER_INPUT_TOO_LARGE);
        }
        if line.is_null() && line_len > 0 {
            return Err(PROVIDER_NULL_POINTER);
        }
        // SAFETY: The caller guarantees a readable line of this length.
        let line = if line_len == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(line, line_len) }
        };
        let text = |pointer, length| {
            let bytes = unsafe { input_bytes(pointer, length) }?;
            std::str::from_utf8(bytes).map_err(|_| PROVIDER_INVALID_INPUT)
        };
        let watch = FailureWatch {
            transcript_path: text(transcript_path, transcript_path_len)?,
            session_id: text(session_id, session_id_len)?,
            read_at,
        };
        let report = adapter.turn_failure_report(line, &watch);
        let body = serde_json::to_vec(&report).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

/// Reports the question turn a hook payload names as JSON, or `null` when it
/// names none. On success, ownership of `*out` transfers to the caller, which
/// must release it with `weir_approval_bytes_free_v1`.
///
/// # Safety
///
/// Same contract as `weir_provider_approval_request_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_provider_question_turn_v1(
    provider: *const u8,
    provider_len: usize,
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        return PROVIDER_NULL_POINTER;
    }
    // SAFETY: The caller guarantees both output pointers are writable.
    unsafe {
        ptr::write(out, ptr::null_mut());
        ptr::write(out_len, 0);
    }
    let status = provider_boundary(|| {
        let adapter = unsafe { resolve_adapter(provider, provider_len) }?;
        let input = unsafe { input_bytes(input, input_len) }?;
        let turn = adapter
            .question_turn(input)
            .map_err(|error| normalize_status(&error))?;
        let body = serde_json::to_vec(&turn).map_err(|_| PROVIDER_INTERNAL)?;
        // SAFETY: The caller guarantees both output pointers are writable, and
        // the bytes are owned by the caller until it frees them.
        unsafe { transfer(body, out, out_len) };
        Ok(PROVIDER_OK)
    });
    status.unwrap_or_else(|code| code)
}

unsafe fn resolve_adapter<'a>(
    provider: *const u8,
    provider_len: usize,
) -> Result<&'a dyn ProviderAdapter, i32> {
    let bytes = unsafe { input_bytes(provider, provider_len) }?;
    let id = std::str::from_utf8(bytes).map_err(|_| PROVIDER_INVALID_INPUT)?;
    adapter_for(id).ok_or(PROVIDER_UNKNOWN_PROVIDER)
}

unsafe fn input_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    // SAFETY: The caller supplies the same readable region to the bounded reader.
    unsafe { bounded_input_bytes(pointer, length, MAX_HOOK_INPUT_BYTES) }
}

unsafe fn bounded_input_bytes<'a>(
    pointer: *const u8,
    length: usize,
    limit: usize,
) -> Result<&'a [u8], i32> {
    if length == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(PROVIDER_NULL_POINTER);
    }
    if length > limit {
        return Err(PROVIDER_INPUT_TOO_LARGE);
    }
    // SAFETY: The caller guarantees a readable input region of this length.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

fn normalize_status(error: &NormalizeError) -> i32 {
    match error {
        NormalizeError::TooLarge { .. } => PROVIDER_INPUT_TOO_LARGE,
        NormalizeError::NotAnObject => PROVIDER_INVALID_INPUT,
    }
}

fn provider_boundary(operation: impl FnOnce() -> Result<i32, i32>) -> Result<i32, i32> {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => Err(PROVIDER_PANIC),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::take_bytes;
    use serde_json::json;

    const UNWRITTEN_LEN: usize = usize::MAX;

    // Reject an untouched output before treating it as an owned allocation.
    fn take_output(out: *mut u8, out_len: usize) -> Option<Vec<u8>> {
        assert_ne!(out, ptr::dangling_mut(), "output pointer was not written");
        assert_ne!(out_len, UNWRITTEN_LEN, "output length was not written");
        // SAFETY: These are the initialized outputs of the provider ABI call.
        unsafe { take_bytes(out, out_len) }
    }

    #[test]
    fn a_write_not_recorded_crosses_with_its_exit_status() {
        let body = outcome_json(&HookOutcome::NotRecorded("record lock busy".to_owned()));
        assert_eq!(body["outcome"], "not_recorded");
        assert_eq!(body["exit_code"], 75);
        assert_eq!(body["message"], "record lock busy");
    }

    /// The Hook Helper's lines go through the runtime's own log: the file is
    /// private even when the umask and an earlier build left it readable.
    #[cfg(unix)]
    #[test]
    fn a_helper_line_is_written_private_through_the_hook_log() {
        use std::os::unix::fs::PermissionsExt;
        let scratch = tempfile::tempdir().expect("scratch");
        let path = scratch.path().join("hook.log");
        std::fs::write(&path, b"").expect("earlier log");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).expect("chmod");
        let path_bytes = path.to_str().expect("path").as_bytes();
        let message = b"Weir hook helper: refused";
        // SAFETY: Both inputs are live locals of this test.
        let status = unsafe {
            weir_hook_log_line_v1(
                path_bytes.as_ptr(),
                path_bytes.len(),
                message.as_ptr(),
                message.len(),
            )
        };
        assert_eq!(status, PROVIDER_OK);
        let written = std::fs::read_to_string(&path).expect("log");
        assert!(
            written.ends_with("Weir hook helper: refused\n"),
            "{written}"
        );
        let mode = std::fs::metadata(&path).expect("log").permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        // SAFETY: A null path with no length is the call's empty input.
        let empty = unsafe { weir_hook_log_line_v1(ptr::null(), 0, message.as_ptr(), 1) };
        assert_eq!(empty, PROVIDER_INVALID_INPUT);
        // A log that cannot be opened says so, for the helper to print the
        // line to its standard error instead.
        let gone = scratch.path().join("gone/hook.log");
        let gone = gone.to_str().expect("path").as_bytes();
        // SAFETY: Both inputs are live locals of this test.
        let unwritten = unsafe {
            weir_hook_log_line_v1(gone.as_ptr(), gone.len(), message.as_ptr(), message.len())
        };
        assert_eq!(unwritten, PROVIDER_LOG_NOT_WRITTEN);
    }

    fn request(provider: &str, payload: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len = UNWRITTEN_LEN;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_provider_approval_request_v1(
                provider.as_ptr(),
                provider.len(),
                payload.as_ptr(),
                payload.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        (status, take(out, out_len))
    }

    fn output(provider: &str, decision: &[u8]) -> (i32, Option<Vec<u8>>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len = UNWRITTEN_LEN;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_provider_approval_output_v1(
                provider.as_ptr(),
                provider.len(),
                decision.as_ptr(),
                decision.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        (status, take_output(out, out_len))
    }

    fn output_v2(provider: &str, request: &[u8], decision: &[u8]) -> (i32, Option<Vec<u8>>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len = UNWRITTEN_LEN;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_provider_approval_output_v2(
                provider.as_ptr(),
                provider.len(),
                request.as_ptr(),
                request.len(),
                decision.as_ptr(),
                decision.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        (status, take_output(out, out_len))
    }

    fn take(out: *mut u8, out_len: usize) -> Option<Value> {
        take_output(out, out_len).map(|bytes| serde_json::from_slice(&bytes).expect("JSON body"))
    }

    const CODEX_PERMISSION: &[u8] = br#"{"hook_event_name":"PermissionRequest","session_id":"s","turn_id":"t","tool_name":"Bash","tool_input":{"command":"ls"}}"#;

    #[test]
    fn translates_a_permission_request_for_each_registered_provider() {
        let (status, body) = request("codex", CODEX_PERMISSION);
        assert_eq!(status, PROVIDER_OK);
        let body = body.expect("body");
        assert_eq!(body["provider"], "codex");
        assert_eq!(body["operation_id"], "t");
        assert_eq!(body["summary"], "ls");
        assert_eq!(body["timeout_ms"], 570_000);

        let (status, body) = request("claude", CODEX_PERMISSION);
        assert_eq!(status, PROVIDER_OK);
        let body = body.expect("body");
        assert_eq!(body["provider"], "claude");
        assert_eq!(body.get("operation_id"), None);

        let (status, body) = request(
            "opencode",
            br#"{"hook_event_name":"permission.asked","data":{"id":"p","sessionID":"s","action":"shell","resources":["ls"]}}"#,
        );
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(
            body,
            Some(json!({
                "provider": "opencode",
                "session_id": "s",
                "operation_id": "p",
                "tool_name": "Bash",
                "summary": "ls",
                "input": {"command": "ls"},
                "timeout_ms": 570_000,
            }))
        );

        assert_eq!(
            request("antigravity", CODEX_PERMISSION),
            (PROVIDER_NOT_APPROVAL, None)
        );
        assert_eq!(
            request("kiro", CODEX_PERMISSION),
            (PROVIDER_NOT_APPROVAL, None)
        );
    }

    #[test]
    fn non_approval_payloads_return_an_empty_body() {
        let (status, body) = request("claude", br#"{"hook_event_name":"Stop"}"#);
        assert_eq!(status, PROVIDER_NOT_APPROVAL);
        assert_eq!(body, None);
    }

    #[test]
    fn rejects_null_pointers_unknown_providers_and_bad_input() {
        let (status, body) = request("gemini", CODEX_PERMISSION);
        assert_eq!((status, body), (PROVIDER_UNKNOWN_PROVIDER, None));
        assert_eq!(
            request("", CODEX_PERMISSION),
            (PROVIDER_UNKNOWN_PROVIDER, None)
        );
        assert_eq!(request("claude", b"[1,2]"), (PROVIDER_INVALID_INPUT, None));
        assert_eq!(request("claude", b""), (PROVIDER_INVALID_INPUT, None));
        let oversized = vec![b'{'; MAX_HOOK_INPUT_BYTES + 1];
        assert_eq!(
            request("claude", &oversized),
            (PROVIDER_INPUT_TOO_LARGE, None)
        );

        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        // SAFETY: The non-null pointers are live locals of this test.
        unsafe {
            assert_eq!(
                weir_provider_approval_request_v1(
                    ptr::null(),
                    6,
                    CODEX_PERMISSION.as_ptr(),
                    CODEX_PERMISSION.len(),
                    &raw mut out,
                    &raw mut out_len,
                ),
                PROVIDER_NULL_POINTER
            );
            assert_eq!(
                weir_provider_approval_request_v1(
                    b"codex".as_ptr(),
                    5,
                    ptr::null(),
                    4,
                    &raw mut out,
                    &raw mut out_len,
                ),
                PROVIDER_NULL_POINTER
            );
            assert_eq!(
                weir_provider_approval_request_v1(
                    b"codex".as_ptr(),
                    5,
                    CODEX_PERMISSION.as_ptr(),
                    CODEX_PERMISSION.len(),
                    ptr::null_mut(),
                    &raw mut out_len,
                ),
                PROVIDER_NULL_POINTER
            );
        }
        assert!(out.is_null());
    }

    /// A decision comes back as the provider's hook output, and a delegated
    /// one with no body. The bytes themselves are each adapter's, tested
    /// with it (`decisions_render_the_hook_output_the_agent_reads`).
    #[test]
    fn renders_decisions_and_delegates_with_an_empty_body() {
        let (status, bytes) = output("claude", br#"{"decision":"allow_once"}"#);
        assert_eq!(status, PROVIDER_OK);
        assert!(bytes.is_some_and(|bytes| !bytes.is_empty()));
        // The message is decoded and handed to the adapter; its bytes are
        // the adapter's tests'.
        let (status, bytes) = output("codex", br#"{"decision":"deny","message":"Blocked"}"#);
        assert_eq!(status, PROVIDER_OK);
        let bytes = String::from_utf8(bytes.expect("bytes")).expect("utf8");
        assert!(bytes.contains(r#""message":"Blocked""#), "{bytes}");
        let (status, bytes) = output("codex", br#"{"decision":"delegate"}"#);
        assert_eq!((status, bytes), (PROVIDER_OK, None));
        let (status, bytes) = output("codex", br#"{"decision":"ask"}"#);
        assert_eq!((status, bytes), (PROVIDER_INVALID_INPUT, None));
        let (status, _) = output("nope", br#"{"decision":"delegate"}"#);
        assert_eq!(status, PROVIDER_UNKNOWN_PROVIDER);
    }

    #[test]
    fn answers_render_only_through_v2_with_the_request() {
        let request = br#"{"tool_name":"AskUserQuestion","input":{"questions":[{"question":"q","options":[{"label":"a"}]}]}}"#;
        let answer = br#"{"decision":"answer","answers":{"q":"a"}}"#;
        let (status, bytes) = output_v2("claude", request, answer);
        assert_eq!(status, PROVIDER_OK);
        let body: Value = serde_json::from_slice(&bytes.expect("bytes")).expect("JSON body");
        assert_eq!(
            body["hookSpecificOutput"]["decision"],
            json!({
                "behavior": "allow",
                "updatedInput": {
                    "questions": [{"question":"q","options":[{"label":"a"}]}],
                    "answers": {"q":"a"},
                },
            })
        );
        assert_eq!(
            output_v2("claude", b"[", answer),
            (PROVIDER_INVALID_INPUT, None)
        );
        let (status, bytes) = output("claude", answer);
        assert_eq!((status, bytes), (PROVIDER_OK, None));
    }

    fn hook(provider: &str, kind: u32, payload: &[u8], env: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len = UNWRITTEN_LEN;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_hook_run_v1(
                provider.as_ptr(),
                provider.len(),
                kind,
                payload.as_ptr(),
                payload.len(),
                env.as_ptr(),
                env.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        (status, take(out, out_len))
    }

    #[test]
    fn invocation_abi_preserves_launch_fields_in_the_session_hint() {
        for (provider, session) in [
            ("kiro", "session"),
            ("antigravity", "session"),
            ("kiro", "id\t\"\\\n"),
            ("antigravity", "id\t\"\\\n"),
        ] {
            let scratch = tempfile::tempdir().unwrap();
            let pane = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";
            let folder = "/tmp/tab\tquote\"backslash\\end\n";
            let prefix = provider.to_ascii_uppercase();
            let env = serde_json::to_vec(&serde_json::json!({
                "WEIR_PANE_ID": pane,
                "WEIR_AGENT_RUN_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",
                format!("WEIR_{prefix}_AGENT_STATES_DIR"): scratch.path().join("states"),
                format!("WEIR_{prefix}_SESSIONS_DIR"): scratch.path().join("sessions"),
                "WEIR_TURN_SNAPSHOT": "0",
            }))
            .unwrap();
            let arguments = if provider == "kiro" {
                vec![
                    "report",
                    "WeirLaunch",
                    "--string",
                    "session_id",
                    session,
                    "--string",
                    "cwd",
                    folder,
                    "--boolean",
                    "trust_all_tools",
                    "true",
                ]
            } else {
                vec![
                    "report",
                    "WeirLaunch",
                    "--string",
                    "conversationId",
                    session,
                    "--string-array",
                    "workspacePaths",
                    folder,
                ]
            };
            let input =
                serde_json::to_vec(&serde_json::json!({"arguments": arguments, "payload": ""}))
                    .unwrap();
            let (status, outcome) = hook(provider, WEIR_HOOK_KIND_INVOCATION, &input, &env);
            assert_eq!(status, PROVIDER_OK);
            assert_eq!(outcome.unwrap()["outcome"], "applied");
            if session == "session" {
                let hint: Value = serde_json::from_slice(
                    &std::fs::read(
                        scratch
                            .path()
                            .join("sessions")
                            .join(weir_agent_model::session_hint_file_name(pane)),
                    )
                    .unwrap(),
                )
                .unwrap();
                assert_eq!(hint["cwd"], folder);
                assert_eq!(hint["sessionId"], session);
            }
            let record = weir_agent_model::RunRecord::decode(
                &std::fs::read(scratch.path().join("states").join(
                    weir_agent_model::run_record_file_name("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"),
                ))
                .unwrap(),
            )
            .unwrap();
            assert_eq!(record.session_id.as_deref(), Some(session));
        }
    }

    #[test]
    fn invocation_abi_completes_empty_events_before_normalization() {
        for payload in ["{}", " \n\t{}"] {
            let scratch = tempfile::tempdir().unwrap();
            let run = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11";
            let env = serde_json::to_vec(&serde_json::json!({
                "WEIR_PANE_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10",
                "WEIR_AGENT_RUN_ID": run,
                "WEIR_ANTIGRAVITY_AGENT_STATES_DIR": scratch.path().join("states"),
                "WEIR_ANTIGRAVITY_SESSIONS_DIR": scratch.path().join("sessions"),
                "WEIR_TURN_SNAPSHOT": "0",
            }))
            .unwrap();
            let input = serde_json::to_vec(&serde_json::json!({
                "arguments": ["event", "SessionStart"], "payload": payload
            }))
            .unwrap();
            let (status, outcome) = hook("antigravity", WEIR_HOOK_KIND_INVOCATION, &input, &env);
            assert_eq!(status, PROVIDER_OK);
            assert_eq!(outcome.unwrap()["outcome"], "applied");
            let record = weir_agent_model::RunRecord::decode(
                &std::fs::read(
                    scratch
                        .path()
                        .join("states")
                        .join(weir_agent_model::run_record_file_name(run)),
                )
                .unwrap(),
            )
            .unwrap();
            assert_eq!(record.last_hook_event.as_deref(), Some("session_started"));
        }
    }

    #[test]
    fn invocation_abi_bounds_the_envelope_and_rejects_non_object_events() {
        for payload in ["{}", " \n\t{}", "[]"] {
            let input = serde_json::to_vec(&serde_json::json!({
                "arguments": ["event", "SessionStart"], "payload": payload
            }))
            .unwrap();
            let (status, outcome) = hook("antigravity", WEIR_HOOK_KIND_INVOCATION, &input, b"{}");
            assert_eq!(status, PROVIDER_OK);
            assert_eq!(
                outcome.unwrap()["outcome"],
                if payload == "[]" {
                    "rejected"
                } else {
                    "not_in_weir"
                }
            );
        }
        // A payload just under the payload limit makes an envelope over it,
        // since the envelope escapes the payload: the envelope's own limit
        // applies, not the payload's.
        let payload = format!("{}{{}}", "\t".repeat(MAX_HOOK_INPUT_BYTES - 2));
        let input = serde_json::to_vec(&serde_json::json!({
            "arguments": ["event", "SessionStart"], "payload": payload
        }))
        .unwrap();
        assert!(input.len() > MAX_HOOK_INPUT_BYTES);
        let (status, outcome) = hook("antigravity", WEIR_HOOK_KIND_INVOCATION, &input, b"{}");
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(outcome.unwrap()["outcome"], "not_in_weir");
        let (status, outcome) = hook(
            "antigravity",
            WEIR_HOOK_KIND_INVOCATION,
            &vec![b' '; MAX_INVOCATION_BYTES + 1],
            b"{}",
        );
        assert_eq!(status, PROVIDER_INPUT_TOO_LARGE);
        assert!(outcome.is_none());
    }

    #[test]
    fn hook_abi_reports_outcomes_and_writes_records() {
        let scratch_dir = tempfile::tempdir().expect("scratch");
        let scratch = scratch_dir.path().to_path_buf();
        let env = serde_json::json!({
            "WEIR_PANE_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10",
            "WEIR_AGENT_RUN_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11",
            "WEIR_AGENT_LAUNCH_ORDER": "18446744073709551615",
            "WEIR_AGENT_PARENT_RUN_ID": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "WEIR_HOOK_OBSERVED_ORDER": "100",
            "WEIR_AGENT_STATES_DIR": scratch.join("states"),
            "WEIR_SESSIONS_DIR": scratch.join("sessions"),
            "WEIR_TURN_SNAPSHOT": "0",
        })
        .to_string();
        let payload = br#"{"hook_event_name":"SessionStart","source":"startup","session_id":"s","cwd":"/tmp","model":"claude-opus-5-5"}"#;
        let (status, body) = hook("claude", WEIR_HOOK_KIND_LIFECYCLE, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_OK);
        let body = body.expect("body");
        assert_eq!(body["outcome"], "applied");
        assert_eq!(body["exit_code"], 0);
        let record = std::fs::read(scratch.join("states").join(
            weir_agent_model::run_record_file_name("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"),
        ))
        .expect("record written");
        assert!(String::from_utf8_lossy(&record).contains("\"schemaVersion\":3"));
        let decoded = weir_agent_model::RunRecord::decode(&record).expect("run record");
        assert_eq!(decoded.run_launch_order, Some(u64::MAX));
        assert_eq!(
            decoded.parent_run_id.as_deref(),
            Some("AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1")
        );
        assert_eq!(decoded.run_observed_order, Some(100));
        let mut subagent_env: Value = serde_json::from_str(&env).expect("environment");
        subagent_env["WEIR_HOOK_OBSERVED_ORDER"] = Value::String("200".into());
        let subagent_payload = br#"{"hook_event_name":"PreToolUse","session_id":"s","agent_id":"child","tool_name":"Bash","permission_mode":"default"}"#;
        let (status, _) = hook(
            "claude",
            WEIR_HOOK_KIND_LIFECYCLE,
            subagent_payload,
            subagent_env.to_string().as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        let after = std::fs::read(scratch.join("states").join(
            weir_agent_model::run_record_file_name("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11"),
        ))
        .expect("record after subagent hook");
        assert_eq!(
            weir_agent_model::RunRecord::decode(&after)
                .expect("record")
                .run_observed_order,
            Some(100)
        );

        let (status, body) = hook("claude", WEIR_HOOK_KIND_LIFECYCLE, payload, b"{}");
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "not_in_weir");
        let (status, body) = hook(
            "claude",
            WEIR_HOOK_KIND_WORKTREE,
            br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            env.as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "applied");
        assert_eq!(
            hook("claude", 7, payload, env.as_bytes()),
            (PROVIDER_INVALID_INPUT, None)
        );
        assert_eq!(
            hook("claude", WEIR_HOOK_KIND_LIFECYCLE, payload, b"[]"),
            (PROVIDER_INVALID_INPUT, None)
        );
        let (status, body) = hook("nope", WEIR_HOOK_KIND_LIFECYCLE, payload, env.as_bytes());
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "unknown_provider");
    }

    /// The thread is told by the directory the hook runs in, not by a tool's
    /// `cwd` (Codex 0.166): a tool of the person's run in Codex's memories
    /// directory is recorded, though the payload names that directory. The
    /// test runs in the crate's directory, which is not under the home.
    #[test]
    fn hook_abi_tells_the_thread_by_the_hooks_own_directory() {
        let scratch_dir = tempfile::tempdir().expect("scratch");
        let scratch = scratch_dir.path().to_path_buf();
        let home = scratch.join("codex-home");
        std::fs::create_dir_all(home.join("memories")).expect("memories directory");
        let run = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F21";
        let env = serde_json::json!({
            "WEIR_PANE_ID": "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F20",
            "WEIR_AGENT_RUN_ID": run,
            "WEIR_CODEX_AGENT_STATES_DIR": scratch.join("states"),
            "WEIR_CODEX_SESSIONS_DIR": scratch.join("sessions"),
            "WEIR_TURN_SNAPSHOT": "0",
            "CODEX_HOME": home,
        })
        .to_string();
        let payload = serde_json::json!({
            "hook_event_name": "PreToolUse",
            "session_id": "s",
            "turn_id": "t",
            "cwd": home.join("memories"),
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
            "tool_use_id": "exec-1",
        })
        .to_string();
        let (status, body) = hook(
            "codex",
            WEIR_HOOK_KIND_LIFECYCLE,
            payload.as_bytes(),
            env.as_bytes(),
        );
        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("body")["outcome"], "applied");
        let record = std::fs::read(
            scratch
                .join("states")
                .join(weir_agent_model::run_record_file_name(run)),
        )
        .expect("the tool's call is recorded");
        let decoded = weir_agent_model::RunRecord::decode(&record).expect("run record");
        assert_eq!(decoded.run_id.as_deref(), Some(run));
        assert_eq!(decoded.tool.as_deref(), Some("Bash"));
        assert_eq!(decoded.last_hook_event.as_deref(), Some("tool_started"));
    }

    #[test]
    fn a_session_end_removes_its_legacy_hint() {
        let scratch = tempfile::tempdir().expect("scratch");
        let pane = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";
        let run = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11";
        let state_dir = scratch.path().join("states");
        let sessions = scratch.path().join("sessions");
        let env = json!({
            "WEIR_PANE_ID": pane,
            "WEIR_AGENT_RUN_ID": run,
            "WEIR_AGENT_STATES_DIR": state_dir,
            "WEIR_SESSIONS_DIR": sessions,
            "WEIR_TURN_SNAPSHOT": "0",
        })
        .to_string();
        std::fs::create_dir_all(&sessions).expect("sessions directory");
        let hint = sessions.join(weir_agent_model::session_hint_file_name(pane));
        std::fs::write(
            &hint,
            json!({
                "schemaVersion": 1,
                "paneId": pane,
                "sessionId": "s",
                "updatedAt": "2026-09-14T00:00:10Z",
            })
            .to_string(),
        )
        .expect("legacy hint");

        let (status, body) = hook(
            "claude",
            WEIR_HOOK_KIND_LIFECYCLE,
            br#"{"hook_event_name":"SessionEnd","reason":"clear","session_id":"s"}"#,
            env.as_bytes(),
        );

        assert_eq!(status, PROVIDER_OK);
        assert_eq!(body.expect("outcome")["outcome"], "applied");
        let record = std::fs::read(state_dir.join(weir_agent_model::run_record_file_name(run)))
            .expect("run record");
        let record = weir_agent_model::RunRecord::decode(&record).expect("run record");
        assert_eq!(record.last_hook_event.as_deref(), Some("session_ended"));
        assert_eq!(record.session_id.as_deref(), Some("s"));
        assert!(
            !hint.exists(),
            "a run's own end record must not retain its hint"
        );
    }

    #[test]
    fn panics_become_a_closed_error() {
        assert_eq!(provider_boundary(|| panic!("boom")), Err(PROVIDER_PANIC));
    }
}
