# ADR 0006: Keys posted to a background run

- Status: Accepted.
- Date: 2026-11-04.
- Amends: [ADR 0005](0005-agent-verification-surface.md), by letting a check
  post named keys to a background run instead of taking the person's display.

## Context

ADR 0005 left real key input to a check in front, a manual check, or a
virtual machine. So agents took the person's whole display to press a key:
Esc, ↑, ↓, and Return in Weir's own dropdowns (the project menu, Open Tabs,
the "+" menu), which are floating panels inside the app rather than standard
menus. They also took it for ⌘⏎ on the decision bar and Return on the restore
strip.

The spike behind ADR 0005 showed that keys posted with `CGEventPostToPid`
reach a background run whose window is covered. `scripts/check-automation.py
--keys` already sends them that way. ADR 0005 rejected posted events as the
channel's way to type text: each letter is a key code of one keyboard layout,
an input method can hold it as marked text, and nothing reports whether it
arrived. None of that applies to a named key such as Esc or Return, which has
the same key code on every layout, produces no text for an input method, and
whose effect the check can read back.

## Decision

- **A check about a key may post it.** The client gains a way to post named
  keys and their modifiers (Esc, Return, Tab, the arrows, and shortcuts such
  as ⌘⏎) to a background run with `CGEventPostToPid`. The `verify-in-app`
  skill offers it before full-screen control.
- **Keys, never text.** Text still goes through `typeLine` and `paste`, whose
  checks for the agent, the session, and the person's draft a posted key would
  bypass.
- **Only where `focus` put the keyboard, and never into a terminal pane.** A
  key reaches whatever holds the keyboard, and Return in a terminal pane runs
  code there. The client posts only after `state` shows the keyboard on one of
  Weir's own controls, not on a pane. Sending Return to a pane stays `submit`.
- **The check reads the result back.** A posted key reports nothing, so the
  check confirms what it did with `state` or `capture`, as with any other
  action.
- **What stays manual.** Input methods, standard macOS menus, and the active
  window's look still need a check in front, a manual check, or a virtual
  machine.

## Consequences

- Checks of Weir's own dropdowns, the decision bar's shortcut, and the
  restore strip no longer take the person's display.
- The terminal that runs the client needs the Accessibility grant, as
  `check-automation.py --keys` already does.
- A key posted while the keyboard moves can land somewhere else. Reading
  `state` just before is the guard, and reading the result after catches what
  that guard misses.

## Alternatives considered

- **Keep keys in front.** This is safe and needs no grant, but it takes the
  display for every key a check presses.
- **A channel operation that presses a key inside the app.** It could check
  the target itself, but a key synthesized inside the app would skip the event
  path the check is about, so it would not prove that the key works.

## References

- [ADR 0005](0005-agent-verification-surface.md).
- [`docs/verification-channel.md`](../verification-channel.md).
