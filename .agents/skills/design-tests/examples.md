# Design examples

These examples illustrate decisions, not a list of outstanding defects.
Choose the example relevant to the contract under review.

## A value comparison hides the property being tested

A Unicode normalization test compares a decomposed string with a composed
string using Swift's `String` equality. Canonically equivalent strings compare
equal even when their scalar sequences differ. If the contract requires NFC,
compare the resulting Unicode scalars or bytes with an explicit composed
sequence. If the contract only concerns displayed text, byte identity may be
an unnecessary restriction.

## A notification test passes without notification

A subscriber waits for a change, and the test checks the returned snapshot.
If the service also returns the snapshot on timeout, deleting the notification
can leave the assertion passing. Establish that the subscriber entered its
wait, trigger the change, and observe completion before the fallback timeout.
Prefer a controllable wait boundary; retain a focused real synchronization
check when that mechanism is part of the contract. Avoid a tight elapsed-time
threshold that fails merely because CI is busy.

## A negative assertion permits no work at all

A queue test expects no more than two reads after removing files from view.
Zero reads satisfies that assertion, including when the queue is broken.
Hold the first read, change the visible files, release the read, and observe
completion. Assert which required files were read and which excluded files
were not. Keep an upper-bound assertion when the bound itself is a contract.

## A fixture does not establish the scenario

A shutdown test claims to bypass a stalled hook, but its hook fake resolves
immediately. Hold a hook invocation with an explicit gate and confirm that
it reached the gate before shutting down. Observe the terminal report while
that hook remains held, then release the hook during cleanup. A separate
ordinary shutdown case does not establish this ordering guarantee.

## Fault injection also prevents the forbidden effect

A persistence test removes write permission from a temporary directory so
initialization cannot move aside an unreadable file. It then flushes the
store and checks that the original bytes remain. If the directory is still
unwritable, an atomic write cannot create its temporary file even when the
store incorrectly allows saving. The assertion cannot distinguish saving
suspension from a failed write.

Establish the initialization failure through observable results: the original
file remains in place and no set-aside copy was created. Restore write
permission, make a change that would normally require saving, then flush and
check that the protected file remains unchanged. Do not add an accessor for
private suspension state merely to establish the scenario.

For the positive control, put the same unreadable data in a separate temporary
directory and leave that directory writable throughout initialization. Check
that initialization moves the original data aside and that the same change
and flush save the new data while preserving the set-aside copy. The control
differs from the test only in whether directory permissions prevent moving
the file aside. A control that starts without the unreadable file would not
detect a store that suspends saving even after moving the file aside. Reuse
an existing case that establishes this control rather than adding a duplicate.

A probe file can additionally confirm that the directory is writable, but
cannot establish that the store has a pending save. Restore permissions
during cleanup as well. An injected failure should trigger the state under test
without also preventing the later effect the test is meant to detect.

## Similar cases protect different boundaries

A pure test checks how a branch becomes a directory name. A process test
starts the hook and observes the created worktree. Both may expect the same
path, but the process test also checks argument handling and filesystem
effects. Keep it if those failures are otherwise untested. Two pure cases
with the same inputs and expectations can be consolidated only after checking
that their replacements run in the same required environments.

## Smaller tests still need sufficient assertions

For a failed move, checking only the error leaves data loss undetected.
Inspect the source bytes, the destination's prior data, and cleanup of files
owned by the failed operation. Parameterize input variants when the operation
and contract stay the same; retain separate cases for a concurrent writer
whose files must survive cleanup.

## Expected data can be independent without being duplicated

A shared Swift/Rust fixture can specify a wire value once and verify both
implementations. That is different from asking the Swift implementation to
generate Rust's expected value at test time. Validate that the required corpus
is nonempty and that each expected entry has an input. Review changes to
expected output against the contract instead of accepting regenerated output
only because the new implementation produced it.
