# ADR 0002: Portable agent integration core

- Status: Accepted.
- Date: 2026-09-13.
- Amends: [ADR 0001](0001-agent-integration-service.md), by saying which
  language owns the domain and the protocol.
- Amended by: [ADR 0004](0004-provider-adapter-contract.md), which defines
  the provider adapter and which rules run where.
- Amended: 2026-11-03. Rewritten as a record of the decision. A second
  operating system is not planned, so portability is a constraint on the
  crates' dependencies rather than a roadmap. The Hook CLI this ADR called
  `weir-agent` shipped as the Hook Helper's `hook <provider>` command. The
  rest of the decision is unchanged.

## Context

The macOS integration needs XPC, Service Management, code-signing checks,
Keychain access, notifications, and SwiftUI. Approval state, protocol
validation, idempotency, and provider normalization do not depend on macOS.
In a Swift XPC service, those rules would need another implementation for
any other platform.

## Decision

- **Provider-neutral agent logic is Rust.** The Rust workspace owns the
  versioned wire format, its limits and framing, the approval request's
  identity, state transitions, deadlines, and idempotency, provider input
  normalization and output models, and the provider-neutral event and
  projection rules.
- **The core imports no platform.** It uses no XPC, Service Management,
  Keychain, IPC, notification, or UI API. Time, transport, authenticated peer
  identity, storage, and process lifetime come from the platform host.
- **The platform boundary is native.** On macOS, Swift owns `SMAppService`,
  XPC, code-signing requirements, Keychain, notifications, and SwiftUI.
- **A narrow, versioned C ABI links the two.** C is the interoperability ABI,
  not an implementation language. Panics, native object layouts, and
  language-owned errors do not cross it.
- **The hook never gains controller authority.** The protocol accepts a
  `Principal` injected by the authenticated platform host and has no wire
  operation that turns a requester into a controller. Same-user file
  permissions or peer credentials separate users, not a hook from the
  approving app.
- **Approval identity is `(ServiceEpoch, RunID, RequestID)`.** Provider
  session IDs, pane IDs, process IDs, titles, and tool inputs are correlation
  or display data, never credentials.

## Consequences

- Debugging on macOS crosses a Swift and Rust boundary, and every wire change
  needs compatibility tests.
- The state machine that correctness depends on has one implementation, and
  its reducer and codec tests run on macOS, Windows, and Linux CI. That keeps
  the crates free of macOS dependencies, even with no second platform
  planned.
- A requester cannot resolve its own request or reach another run. A stale
  epoch, a conflicting retry, a late decision, and an oversized or truncated
  frame cannot produce an allow decision. Tests hold each of these.
- The XPC adapter passes one bounded JSON message per call, because XPC
  already keeps message boundaries. The length-prefixed stream framing stays
  for transports that need it. Swift chooses the authenticated role and
  injects the requester's run ID before Rust decodes sensitive request
  content.

## References

- [ADR 0001](0001-agent-integration-service.md).
- [ADR 0004](0004-provider-adapter-contract.md).
- [`docs/agent-integration-protocol.md`](../agent-integration-protocol.md).
