# ADR 0004: Provider adapter contract

- Status: Accepted.
- Date: 2026-09-14.
- Amends: [ADR 0002](0002-portable-agent-integration-core.md), by defining
  how a provider is added and which rules run where.
- Amended: 2026-11-03. Rewritten as a record of the decision. The adapter's
  methods, the capability table, the turn rules, and what each provider needed
  moved to [`docs/provider-adapters.md`](../provider-adapters.md). The
  decision is unchanged.
- Amended: 2026-11-04. Kiro joins the providers that changed the model
  crate's contract (Consequences). The decision is unchanged.
- Amended: 2026-11-12. An adapter reads no clock either, and the runtime
  hands it the host's facts. The decision is unchanged.

## Context

Weir observed Claude Code and Codex through provider hooks whose receivers
were two shell scripts, one per provider. Each mapped hook events to a
per-run state record, wrote resume hints and cwd events, captured turn
snapshots, and intercepted `git worktree add`. On the application side, four
Swift trackers merged the records into badges, notifications, and cleanup.
The real duplication was the event-to-state rule set, once per shell script,
and the provider-specific approval translation in Swift.

ADR 0002 gives provider normalization and the provider-neutral rules to the
Rust core. It does not say how a provider is added, which behavior
differences count as provider capabilities, or which rules run in the hook
process and which in the application. Adding a third agent meant editing both
shells, the Swift registry, and `Tab`. A change in a provider's hook schema
had no recorded contract to test against.

## Decision

- **One crate per provider.** A provider implements one adapter trait and
  publishes a descriptor (id, display name, capabilities, directory names,
  process names). It turns a raw hook payload into neutral events and renders
  the provider's approval output. An adapter never touches the file system
  or reads the clock; the runtime reads those facts of the host and hands
  them over, so a recorded payload normalizes the same way on any machine.
  It declares what the platform must install as a recipe.
- **The rules branch on capabilities, never on provider ids.** How a
  provider differs (whether it reports cwd changes, answers approvals by a
  hook, or reports its status over OSC 7501, and so on) is a named
  capability. The core, the Hook Helper, and the approval card all follow
  this rule. The app names an agent only where it is set up differently, not
  where it behaves differently.
- **A neutral event vocabulary that grows slowly.** A payload the adapter
  does not know becomes an `Extension` event carrying the original, so a
  provider's new event is visible before the core understands it. An
  extension becomes a named event only when two providers emit the same
  thing, or when it closes a state an existing event opened.
- **Rules describe effects and do not perform them.** `apply` runs in the
  hook process and returns the record writes. `project`, `on_launch`, and
  `on_terminate` run in the application and return commands. The commands
  carry their own preconditions, which the Swift host checks under the record
  lock. No rule owns a file, a timer, or a provider branch.
- **Records stay reduced, and only Rust reads them.** State files hold one
  record per run, not an event log. The hook writes them and the projection
  reads them, both in Rust; Swift compares only the fields a command names.
- **The hook has no fallback.** The hook wrappers exec only the signed Hook
  Helper. When it is missing, the hook call fails and says why. The shell
  receivers it replaced wrote no turn records, and a silent fallback to them
  emptied the Changes panel without a word.
- **Message-shaped calls cross a hand-written C ABI as JSON.** cbindgen
  generates the header, and CI diffs the committed file. Symbols carry a
  version suffix, and the bridge's ABI version moves only on an incompatible
  change. Typed records across the boundary would need a binding generator,
  which would be a decision of its own.
- **Real payloads are the contract.** Each provider's recorded and scrubbed
  payloads, with the events expected from them, run through one conformance
  driver, together with a shared negative set. A schema change adds a dated
  fixture directory and keeps the old one passing.

## Consequences

- A provider is added as one crate, its fixtures, a shim, and an `AgentKind`
  case. `ARCHITECTURE.md` lists every step. The goal is that adding a provider
  changes no source file in `weir-agent-model` or `weir-agent-core`.
  Antigravity, OpenCode, and Kiro did not meet it: each behaved in a way the
  vocabulary did not yet describe, and each changed the contract.
  The goal holds for a provider whose behavior the vocabulary already covers.
- Every hook event starts the signed Hook Helper and runs Rust in process.
  The accepted latency is a p95 of 50 ms or less per hook, measured over 200
  consecutive `PreToolUse` payloads (`scripts/measure-hook-latency.py`).
- The Xcode build runs Cargo on every build, so the size of the workspace is
  a build-time cost (`scripts/measure-build-time.sh`). Before the new crates,
  a clean `make build` took 25.0 s and an incremental one 4.9 s
  (2026-09-14, Apple silicon).
- Recorded fixtures carry the person's content until they are scrubbed.
  Scrubbing is mandatory, and the corpus is reviewed like code.
- Swift keeps file watching, PID sweeps, tmux presence, the locked command
  executor, the session model, notification delivery, XPC, signing,
  `SMAppService`, and all UI.

## Alternatives considered

- **Keep a shell receiver per provider.** Every rule exists once per shell
  and cannot be tested against recorded payloads. A third provider would
  have been a third copy.
- **Keep the rules in Swift trackers.** The hook, which writes the record,
  and the app, which reads it, would each hold their own copy of the event
  rules. ADR 0002 already gives these rules to Rust.
- **Branch on provider ids in the rules.** That is quicker for a second
  provider. But every later one then has to find each branch, and a
  provider's behavior is never named or tested apart from its id.

## References

- [`docs/provider-adapters.md`](../provider-adapters.md).
- [`docs/agent-integration-protocol.md`](../agent-integration-protocol.md).
- [ADR 0002](0002-portable-agent-integration-core.md).
- [cbindgen](https://github.com/mozilla/cbindgen).
- [Claude Code hooks](https://code.claude.com/docs/en/hooks).
- [OpenAI Codex hook schemas](https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated).
