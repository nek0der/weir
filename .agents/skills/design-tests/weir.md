# Weir test boundaries and fixtures

Use repository-relative paths below to inspect the current helpers and their
callers before selecting one. The contributor guide owns test commands and
required checks; this file describes how to choose the test boundary.

## Choose the boundary

| Contract | Starting point |
| --- | --- |
| A pure state or formatting rule. | The relevant Swift suite in `WeirTests/` or the relevant Rust crate's unit tests. |
| State-store transitions and persistence. | A fixture with an injected directory; inspect both state and stored output when required. |
| Git behavior and filesystem effects. | `TempGitRepo` or the repository fixtures, with actual Git operations for Git contracts. |
| Swift/Rust wire values and calls. | Shared contract fixtures plus a test through the Swift caller for a changed FFI contract. |
| Agent hook and process behavior. | `ShimHarness`, `HookScriptHarness`, `TestProcess`, or socket fixtures that observe the actual boundary. |
| OpenCode plugin lifecycle. | `scripts/opencode-plugin-tests/tui.test.mjs`; inspect whether the harness reproduces the lifecycle condition. |
| Script decisions and failures. | The relevant `scripts/test-*.sh` and the workflow that invokes it. |
| App interaction or appearance. | The repository's `verify-in-app` procedure for behavior that unit tests cannot establish. |

Keep pure rule tests independent of AppKit or libghostty when those are not
part of the contract. Conversely, a pure helper's result does not establish
that an app caller uses it or that a terminal receives its output.

## Reuse preparation without hiding the behavior

Look in `WeirTests/Support/` before adding a helper:

- `WithTempDir` and `TempGitRepo` provide isolated directories and Git
  repositories. `RepoFixture` also describes whether source-tree fixtures
  are available; preserve that distinction when consolidating tests.
- `WorkspaceSessionFixture` and `FakeGit` support session tests whose
  contract does not require an actual Git process.
- `Gate` holds an asynchronous operation until the test releases it. Its
  `requests` count and `waitUntilRequested` establish that the operation
  reached the gate.
  `waitUntilRequested` throws on timeout or cancellation. It waits for at
  least the requested count; assert an exact count separately when duplicate
  calls would violate the contract. The held operation's `wait()` does not
  end on cancellation. Arrange cleanup to release it even if observing the
  request fails.
- `ManualTimer` supplies a controllable `HoverDelayTimer`. Use it where the
  production API accepts that timer; it is not a replacement for every clock.
- `Polling` waits for conditions that cannot be awaited directly. Its
  `pollUntil` helpers do not assert on timeout, so assert the required
  condition afterward or require it before a dependent step.
  For `@Observable` state on the main actor, consider `untilObserved` in the
  same file: it waits for observed changes rather than polling. It has no
  deadline, so give the test or suite a `.timeLimit` and assert the condition
  after the wait, because cancellation also ends the wait.

Inspect `AgentPassCoalescerTests.swift` for manually controlled scheduling
with a separate real-timer check, and `UncommittedChangesCarrierTests+Rollback.swift`
for assertions about preserved bytes and concurrent filesystem changes.
These are examples of the contracts to preserve, not templates to copy in full.

## Preserve execution and isolation

Use Swift Testing and the existing suite conventions. Report unsupported
environments through enabled or disabled traits, following the existing
availability checks. Within an enabled test, use `#require` for required
optional values rather than silently skipping the operation. Give
parameterized cases enough input context to identify a failure.

Inject temporary storage as the contributor guide requires. Use
`SecureFileWrite` for Weir data files so `TestWriteGuard` can reject writes to
real user data. A rejected write means the intended write was not tested.
Check inherited process state as well as paths. A temporary working directory
does not stop `GIT_DIR`, `GIT_WORK_TREE`, or `GIT_INDEX_FILE` from selecting
another repository or index; use the fixture's isolated Git runner.
Own and clean up child processes, sockets, timers, and pending operations.

Check enabled conditions before removing a case in favor of another. Tests
requiring libghostty, tmux, or source-tree fixtures may not run in every
environment. A successful filtered command with no executed cases is not
evidence that a contract holds.

`make test` does not include `make review-core`, app verification, or timing
measurements. Measurements without assertions are useful observations, but
do not establish a performance regression threshold. Follow the contributor
guide for the checks required by the files and behavior changed.
