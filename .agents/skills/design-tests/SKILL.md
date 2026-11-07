---
name: design-tests
description: Designs tests for Weir when adding or changing behavior, fixing a bug, or reviewing and consolidating existing tests. Checks which cases are needed, whether assertions detect the intended regression, and whether fixtures, asynchronous waits, and test boundaries preserve that guarantee.
---

# Design and review tests

Use this when choosing, writing, or reviewing tests in Weir's Swift suites,
Rust crates, OpenCode plugin, or script self-tests. It also applies when
combining or removing existing cases. A review request remains read-only;
finding a weak test does not authorize changing it.

The result is a set of tests that detects specific incorrect behavior with
understandable failures. An existing test may already provide that guarantee;
adding a test is not required merely because code changed. This procedure
does not replace the repository's required checks or verification in the app.

## Steps

1. Read the behavior's specification, implementation, and callers. State the
   input or starting state, the operation, and the expected result or effect.
   Investigate discrepancies between the specification and implementation
   before copying the current result into an expectation. If the intended
   behavior remains unclear, report the conflict and defer assertions that
   would settle it; continue reviewing cases whose contracts are established.
2. Search for existing cases and shared fixtures. Trace what each relevant
   test actually executes, including its enabled conditions. Read
   [Weir test boundaries and fixtures](weir.md) when choosing a
   fixture or a test layer. Identify the guarantee missing from the existing
   tests before adding another case.
3. Name a plausible incorrect implementation the test should reject: a call
   omitted or repeated, an old result accepted, a boundary crossed, or a
   failed write that replaces valid data. Check that the proposed assertions
   distinguish it from the intended behavior. For examples of misleading
   assertions and valid overlap, read [Design examples](examples.md).
4. Choose the smallest test boundary that can observe the contract. Test a
   pure rule with values; test wiring through its caller; test a process or
   FFI contract across that boundary. A flag changed before sending an event
   does not establish that the recipient received it. Use app verification
   when the behavior depends on interaction the automated test cannot reach.
5. Select cases for the behavior's risks. Consider boundaries, failure,
   cancellation, ordering, and cleanup where they affect the contract; do
   not add every category to every test. Set up the condition the test's name
   describes, checking fixture defaults and any setup that may repair or
   replace that condition before the operation. Then observe required and
   forbidden effects. Use the test runner's skip mechanism for unsupported
   environments and limit the condition to affected tests. In Swift Testing,
   use the test's or suite's `.enabled` or `.disabled` traits. Within an
   enabled test, make unmet prerequisites fail explicitly instead of
   returning early and reporting success.
6. Decide how the cases belong together:

   | Relationship | Action |
   | --- | --- |
   | Same setup, operation, and contract; only inputs and expected values differ. | Parameterize the cases and keep each failure identifiable. |
   | Shared setup, but different operations, contracts, or observations. | Keep separate cases; share only preparation that remains easy to understand. |
   | Same contract, input, execution path, and enabled conditions. | Consider consolidating; name the remaining case that preserves the guarantee. |
   | Same output, but one case crosses a process, persistence, or FFI boundary. | Preserve the boundary check when it detects a wiring failure the other case cannot. |

   Different inputs may exercise different branches of the same contract;
   that alone does not require separate test functions. Preserve each input's
   distinct guarantee when parameterizing.

   Remove unrelated fixture data. Keep expected values independent of the
   code being tested; do not compute them with the same transformation.
   A small amount of repeated setup is preferable to a helper that hides
   the operation or chooses the assertion through conditional branches.
7. Control asynchronous ordering. Observe that work started, hold it when
   the case needs an operation in flight, then release it and await the
   result. Use a controllable clock for time-based rules when supported.
   Bound waits with a mechanism that can actually end them. In Swift Testing,
   a test or suite time limit relies on cooperative cancellation; it cannot
   interrupt a wait that ignores cancellation.
   Require the awaited condition before a dependent step. Elapsed time alone
   does not establish completion. Include cleanup for work and resources
   the test owns.
8. Check detection as well as success. For a bug fix, run the case against
   the broken behavior when feasible and verify that it fails for the
   intended reason. For contracts with a history of regressions or a risk of
   data loss, a small deliberate fault in an isolated checkout can check
   whether assertions detect it. Do not mutate
   another contributor's working changes or require mutation testing for
   every edit. Distinguish a demonstrated failure from a static prediction.

## Pitfalls

- Counts, coverage, and source similarity identify places to inspect; none
  proves that a test is useful or redundant. Do not set a deletion quota.
- A successful return or an internal flag may omit the contract's output,
  side effects, ordering, or exactly-once requirement. Inspect the recipient
  or persisted result when that is what the contract describes.
- Error cases that accept any error can pass for the wrong reason. Assert
  the error and preserved state that matter to the caller, without pinning
  incidental wording.
- A test named for stalled work must actually stall that work. A notification
  test must distinguish notification from the ordinary timeout response.
- A source-text check can pass for a comment or unreachable code. Use one
  only when the source structure is itself the intended constraint; it does
  not replace an execution test.
- Fixture runners must detect missing required inputs and unmatched expected
  entries. Empty discovery and skipped cases do not establish coverage.
- Retries, longer sleeps, and serial execution can conceal a synchronization
  or isolation defect. Diagnose it before changing those settings.
- Existing tests can reflect older conventions. Preserve their regression
  guarantees without copying incidental structure or obsolete assumptions.

## References

These official guides inform the choices above. The steps are adapted for
Weir; the links do not impose additional rules or need to be read on every use.

- [Chromium web test tips](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/testing/web_tests_tips.md):
  concise tests, event-based synchronization, and consistent results.
- [LLVM regression test guidance](https://llvm.org/docs/TestingGuide.html#best-practices-for-regression-tests):
  minimized reproductions and a minimal set of compiler passes.
- [Rust compiler test guidance](https://rustc-dev-guide.rust-lang.org/tests/best-practices.html):
  test intent, meaningful names, and explanations of special conditions.
- [Kubernetes testing guide](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-testing/testing.md):
  hermetic unit tests, table-driven cases, and concurrent execution.
- [Playwright best practices](https://playwright.dev/docs/best-practices):
  observable behavior and allowing limited duplication for clarity.

## Check it worked

- Run the affected cases and confirm they were selected and executed. After
  consolidation, confirm that the remaining cases retain the removed cases'
  distinct guarantees and required execution environments.
- After a broad review, compare related cases in the resulting suite.
  Check that fixture identities, case names, comments, and assertions describe
  the same contract, and that equivalent cases agree on waits, cleanup, and
  environment conditions. Preserve justified differences between test layers.
  A passing run alone does not establish this consistency.
- Complete the applicable checks in the contributor guide's
  [verification requirements](../../../CONTRIBUTING.md#before-opening-the-pr),
  [running the checks](../../../CONTRIBUTING.md#running-the-checks), and
  [test rules](../../../CONTRIBUTING.md#tests).
  A review-only task reports unexecuted checks instead of changing scope.
- Report the behavior protected, the reason for adding, retaining, or
  removing cases, the checks performed, and remaining limits. Keep the
  explanation proportional to the change. Do not claim a reproduced
  regression when only the corrected implementation was run.
