# ADR 0007: Unreachable service and temporary locations

- Status: Accepted.
- Date: 2026-11-04.
- Amends: [ADR 0003](0003-agent-integration-service-reconciliation.md), by
  bounding the retry for a registered service that does not answer, and by
  refusing to register from a disk image or a translocated copy.

## Context

ADR 0003 keeps a registered service whose controller does not answer, when
the marker is current, and tries again. It assumed the failure passes: a
service restarting after a crash or a wake answers within seconds, and
replacing it would drop its pending requests. Some failures do not pass. A
service that exits as it starts never answers. A registration made from a
disk image, or from a copy macOS translocated, points at a path that is gone
once the image is ejected or the app is moved. launchd then cannot start the
service, and the marker still names the current artifact. So the app asked
every two seconds without end, and reinstalling the same build could not
repair it, because nothing differed.

`SMAppService.register()` also reports errors the app misread. It returns
`kSMErrorLaunchDeniedByUser` when the person has turned the service off in
Login Items, and `kSMErrorAlreadyRegistered` when nothing failed. The app
showed both as a generic failure, without the way to Login Items, and showed
a property list or executable missing from the bundle the same way.

## Decision

- **An unreachable service gets a bounded retry, then one replacement.** The
  app asks again after 2, 4, 8, 16, and 32 seconds. When the service has
  stayed unreachable for 60 seconds since the first failure, and the latest
  observation still fails, the app replaces it once: the unregister and
  register of ADR 0003's mismatch row, which points the registration at the
  running app. After that it sets no timer. The next activation or the
  person's Retry observes once more.
- **The window is measured on a clock.** Activating the app observes too,
  but counting observations would let quick activations bring the
  replacement forward, so the 60 seconds are time. The clock stops while
  the Mac sleeps, so a wake cannot use up the minute. A service that answers
  is kept, and the budget starts again.
- **Retry starts the budget again.** It is the person's explicit request. A
  Retry that arrives while a reconciliation runs follows that one instead of
  being dropped.
- **A replacement for other evidence is unchanged.** A marker or artifact
  mismatch, including a `replacing` marker that a failed replacement left,
  still repairs on the next activation, as ADR 0003 says. It never runs on a
  timer, so it cannot loop on its own.
- **No registration from a temporary location.** When the app runs from a
  mounted disk image or under App Translocation, it neither registers nor
  replaces the service. It tells the person to move Weir to the Applications
  folder. Keeping a healthy service that an installed copy registered still
  works from there. The check identifies a disk image and a translocated
  copy themselves, not a kind of volume, so an installed copy on an external
  or read-only disk is still registered.
- **A registration error is read for what it means**, so the person sees
  the step that fixes it. `kSMErrorAlreadyRegistered` continues to
  verification. `kSMErrorLaunchDeniedByUser`, or a refusal while the status
  is `.requiresApproval`, keeps the registration and directs the person to
  Login Items. A missing property list or executable reports the missing
  service. Any other error stays a generic failure.

| Status and evidence | Action |
| --- | --- |
| `.enabled`, current marker, controller unreachable for less than 60 seconds | Keep the service and its pending requests, and ask again on the backoff. |
| `.enabled`, current marker, controller unreachable for 60 seconds | Replace the service once, then set no timer; the next activation or the person's Retry observes again. |
| Any action that registers, while the app runs from a disk image or a translocated copy | Do not register. Ask the person to move Weir to the Applications folder. |

## Consequences

- A service that never answers costs about a minute of retries and one
  replacement, rather than a request every two seconds for as long as the
  app runs.
- A service that is merely slow for more than a minute is replaced once, and
  loses its pending requests. Each requester fails closed, as on any
  replacement.
- Opening Weir straight from its disk image, or from a translocated copy,
  keeps approvals in each agent's own prompt until Weir is moved and opened
  again, unless an installed copy already registered a service that answers.

## Alternatives considered

- **Counting observations instead of time.** Each activation of the app
  observes the service, so a few quick switches to Weir would use up the
  count and replace a service that was only restarting. A clock gives the
  service the same minute however often the person comes back.
- **Replacing at the first failure.** A service restarting after a crash, or
  slow after a wake, answers within seconds. Replacing it at once would drop
  its pending requests on every such moment, which ADR 0003 keeps the
  service to avoid.
- **Refusing any app under `/Volumes`.** That catches a mounted disk image,
  but it also refuses an install on an external disk, which registers and
  runs like one in `/Applications`.
- **`SecTranslocateIsTranslocatedURL`.** It answers the translocation
  question directly, but the macOS 26 SDK publishes no header for it, so it
  is not an interface the app can rely on.

## References

- [ADR 0003](0003-agent-integration-service-reconciliation.md).
- [Apple `SMAppService.register()`](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).
