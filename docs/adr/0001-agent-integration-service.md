# ADR 0001: Agent integration service

- Status: Accepted.
- Date: 2026-09-13.
- Amended by: [ADR 0002](0002-portable-agent-integration-core.md), which gives
  the portable rules to Rust, and
  [ADR 0003](0003-agent-integration-service-reconciliation.md), which says how
  the service is replaced on update.
- Amended: 2026-11-03. Rewritten as a record of the decision. The rollout
  section is gone now that the rollout is over. The tabs and Waiting UI this
  ADR named were replaced by the supervision window's approval card and Needs
  Attention list (`ARCHITECTURE.md`, "Attention, turns, and approvals"). The
  decision is unchanged.

## Context

Weir observed Claude Code and Codex through per-run JSON records that their
hooks wrote and the app watched. That path was for delayed observation, not
for a request and its reply.

Approval needs a live request, cancellation, one accepted decision, a bounded
wait, and an explicit fallback when Weir cannot answer. Response files beside
the records would bring polling, stale replies, cleanup races, and a two-way
protocol into a store designed for observation.

An agent may also go on running inside tmux after Weir quits. A service hosted
by the app's process would therefore have the wrong lifetime.

## Decision

- **A per-user service outside the app.** On macOS, `launchd` manages it
  after the app registers its bundled executable through
  `SMAppService.agent`. Quitting Weir does not unregister it.
- **A signed Hook Helper between the agent and the service.** Provider hooks
  run the helper. It translates the provider's input into Weir's versioned
  protocol, holds a live request while a decision is pending, and translates
  the result back into the provider's output. It uses a connection of its own,
  never the lifecycle records.
- **Trust comes from the transport, not from the message.** The macOS
  transport is role-specific XPC Mach services, one for the app and one for
  hooks. The platform authenticates each peer and hands a trusted principal
  to the protocol; a role claimed in JSON grants nothing. A Unix domain
  socket or any other transport is not a drop-in replacement and needs an
  authentication design of its own.
- **The service holds approval authority, in memory only.** Pending requests,
  tool inputs, and decisions are never written to disk. A restart changes the
  service's epoch, which makes every earlier decision unusable.
- **Every failure falls back to the provider, never to allow.** A connection,
  decoding, timeout, or service failure produces no allow decision. The
  adapter hands the request back to the provider's own approval prompt where
  the provider has one.

Lifecycle observation stays on the per-run records. Only approval uses the
service.

## Consequences

- The service adds signed executables, update coordination, protocol
  compatibility, and a lifecycle outside the app.
  [ADR 0003](0003-agent-integration-service-reconciliation.md) says how an
  update replaces it.
- In return, a decision has one explicit authority, and it can still be made
  while the agent outlives the app.
- Debug builds are ad-hoc signed, so the service never becomes ready in them
  and agents use their own prompts. A signed Debug build (`CONTRIBUTING.md`)
  exercises native approvals.

## References

- [Apple XPC](https://developer.apple.com/documentation/xpc).
- [Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice).
- [Claude Code hooks](https://code.claude.com/docs/en/hooks).
- [OpenAI Codex hook schemas](https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated).
