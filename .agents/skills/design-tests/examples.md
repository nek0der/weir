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

## A later operation hides an earlier failure

A persistence test loads a viewed position, advances it, then checks that an
older item is viewed. Advancing the position can satisfy that assertion even
if loading did nothing. Assert the loaded position before changing it, then
check the new position and the required disk result separately.

## Setup hides a missing save request

When testing whether an update schedules a save, first persist the initial
state and confirm it through a new reader. Before the update, also clear any
pending save or unflushed-change state left by setup. A completed automatic
save does not necessarily clear that state. Otherwise, a later flush can
write the updated state even when the update never schedules its own save.
For Weir stores using `DebouncedSave`, explicitly flush the initial state
to clear its scheduling state before applying the update.

After the update, observe the save through another reader. When checking
automatic saving, await its result without forcing a flush. Use an explicit
flush when checking the flush contract; it does not establish that automatic
saving is wired correctly.

## Repeated results can agree without the operation succeeding

An approval test sends the same decision twice and compares the responses.
Both responses can still be `Pending` if the decision is never applied.
First assert that the initial decision produces the specified resolved state.
Then repeat it and check that the result is unchanged. Verify that sequence
numbers do not advance and side effects do not repeat where the contract
requires it. If the contract forbids replacing a settled decision, submit a
different decision and verify that it is rejected and the first decision remains.
Equality between two calls establishes consistency, not successful execution.

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

## A parsed field disappears when the value is copied

A diff parser fills a hunk's line metadata, and a parser test confirms it.
The closed-file stack then constructs a new row with a shifted ID but omits
the metadata. Its optional default lets the code compile, and the accessible
label becomes a generic "Comment" instead of naming the line.

Exercise the copy through its caller and check both the changed identity and
the preserved metadata, including the label that uses it. When adding a field,
inspect places that reconstruct its value. Keep a focused boundary case for
the missing guarantee; repeating every parser input through the stack is not
necessary.

## A valid input number exceeds the destination's range

A usage response contains an unsigned epoch value that JSON can represent,
but adding it to the platform's epoch can panic. Tests with ordinary dates
and an assertion that the result exists do not check that conversion.

Include an unrepresentable value when reviewing this boundary. If the contract
treats the timestamp as optional, check that only the timestamp is omitted
and that valid usage windows or credit counts remain. Preserve an exact normal
timestamp as a positive control. An error returned through the FFI does not
show whether the valid parts of the response survived.

## Smaller tests still need sufficient assertions

For a failed move, checking only the error leaves data loss undetected.
Inspect the source bytes, the destination's prior data, and cleanup of files
owned by the failed operation. Parameterize input variants when the operation
and contract stay the same; retain separate cases for a concurrent writer
whose files must survive cleanup.

## Expected data can be independent without being duplicated

A migration writes a required ordering field, but the decoder can reconstruct
that order when the field is missing. Reading the migrated data through that
decoder cannot establish that the migration wrote the field. Check the raw
output against independently specified keys and values when those bytes are
part of the migration contract. Keep the decoded-model check to establish
that the reader can consume the migrated output. If fallback behavior is
also part of the contract, check it separately with input that deliberately
omits the field. Likewise, a current encoder and decoder can share a mistake;
use independently authored historical input to establish compatibility.

A shared Swift/Rust fixture can specify a wire value once and verify both
implementations. That is different from asking the Swift implementation to
generate Rust's expected value at test time. Validate that the required corpus
is nonempty and that each expected entry has an input. Review changes to
expected output against the contract instead of accepting regenerated output
only because the new implementation produced it.
