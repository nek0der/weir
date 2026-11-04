# ADR 0003: Agent integration service reconciliation

- Status: Accepted.
- Date: 2026-09-13.
- Amends: [ADR 0001](0001-agent-integration-service.md), by saying how the
  service is kept or replaced when the app starts.
- Amended by: [ADR 0007](0007-unreachable-service-and-temporary-locations.md),
  which bounds the retry for an unreachable service and refuses to register
  from a temporary location.
- Amended: 2026-10-23. `.notFound` before a registration call now registers.
  The first revision treated every `.notFound` as an error, which blocked the
  first registration on a machine that had never had the service. The rest
  of the decision is unchanged.
- Amended: 2026-11-03. Rewritten for readability; the decision is unchanged.

## Context

The approval service outlives the Weir app. An ordinary quit and relaunch must
keep its process, its epoch, and its pending requests. A Sparkle update, a
rollback, or an interrupted replacement can instead leave an `SMAppService`
registration, or a running process, that belongs to a different bundled
executable.

`SMAppService.Status` reports eligibility and approval, not the version, path,
or process identity of what is registered. `BundleProgram` lets the app move,
so an absolute bundle path is the wrong identity too. Apple requires a changed
property list or executable to be registered again, and recommends
unregistering a changed executable first. The asynchronous unregister
completion is the point after which the old process is gone and registering
again is safe.

## Decision

- **The artifact's identity is its content.** Weir fingerprints the SHA-256
  of its bundled service executable and LaunchAgent property list. The
  service computes the same identity when it starts and returns it in the
  controller session's bootstrap, after XPC has authenticated the service's
  Team ID and signing identifier. Before registering, the app separately checks
  the bundled service's and Hook Helper's signatures against its own Team ID
  and their expected signing identifiers.
- **A marker records what this app last started.** An atomic `0600` file
  under the build's Application Support folder holds `replacing`,
  `registered`, or `ready`, the artifact identity, and the app's build
  version. It proves only that this app started a registration attempt; it is
  never a credential.
- **A healthy registration is kept only on full agreement.** The status is
  `.enabled`, the authenticated running artifact matches the bundle, and the
  marker names that artifact. A matching `registered` marker is completed as
  `ready` after authentication, which covers a process that exited right after
  registering. A `replacing`, missing, corrupt, or mismatched marker causes one
  deliberate repair.

| Status and evidence | Action |
| --- | --- |
| `.notRegistered`, or `.notFound` before a registration call | Write `replacing`, register, write `registered`, authenticate the running artifact, then write `ready`. Background Task Management reports `.notFound` for a label it has no record of, which is every machine's state before the first registration. |
| `.enabled` with matching running artifact and `registered` or `ready` marker | Keep the service process, PID, epoch, and pending requests; complete the marker as `ready`. |
| `.enabled` with any artifact or marker mismatch | Write `replacing`, await asynchronous unregister completion, register, write `registered`, authenticate, then write `ready`. |
| `.enabled` with an unreachable controller and current `registered` or `ready` marker | Keep the service and pending requests, disable controller observation, and retry. A marker mismatch remains explicit replacement evidence. |
| `.requiresApproval` | Keep the registration, disable native routing, and direct the person to Login Items. Retry when the app becomes active. |
| `.notFound` after a registration call | Disable native routing and expose a recoverable error. Do not register again in the same pass. |
| Unknown status | Disable native routing and expose a recoverable error. Do not treat it as unregistered. |

The same comparison handles upgrades, downgrades, and rollbacks. Moving an
unchanged app does not replace the service, because paths are not part of the
identity. Each place an attempt can stop is covered:

- Before the unregister, `replacing` forces a repair, even when launchd has
  lazily started a current executable against an older registered property
  list.
- After the unregister and before the register, the next launch sees
  `.notRegistered`.
- After `registered` and before `ready`, the matching authenticated artifact
  completes the attempt without resetting a pending Login Items approval.
- A slow unregister keeps reconciliation waiting. It never registers before
  the system's completion callback.

Controller observation starts only after the replacement has been
authenticated, and stops on a later reconciliation failure. The Hook Helper
checks too: on every request it compares the authenticated service artifact
with its own bundle. When it emits no approval decision, Codex gets its
lifecycle fallback, and Claude keeps its own permission prompt. Restarting
the service changes the Rust-owned epoch, so requests and controller actions
from the earlier epoch cannot authorize the new process.

## Consequences

- An update that changes the service loses its in-memory pending requests.
  Every requester fails closed, and no old decision crosses the epoch
  boundary. Ordinary launches do not restart a healthy service.
- Corrupting or deleting the marker can cause one safe extra restart. It
  cannot establish trust.
- Debug and Release use separate identifiers, endpoints, property lists,
  markers, and Application Support folders. Several running copies of the
  same production identity are unsupported, because macOS keeps one
  registration per per-user label. Checking an update uses one disposable
  production copy at a time, and the person checking restores the earlier
  registration and data exactly afterwards.

## References

- [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [Apple `SMAppService.unregister(completionHandler:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister(completionhandler:)).
- [Apple Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software).
- [ADR 0001](0001-agent-integration-service.md).
- [ADR 0002](0002-portable-agent-integration-core.md).
