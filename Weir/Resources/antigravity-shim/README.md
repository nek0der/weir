# antigravity-shim

Two POSIX-shell scripts, and a plugin beside them, that let Weir track
Antigravity CLI (`agy`) sessions, badge agent state, and re-route
`git worktree add`. These facts are from `agy` 1.4.12.

`agy` takes no hooks on its command line, unlike `claude` and `codex`. Its
hooks come from plugins in its own folder, which every `agy` reads. So the shim
places our plugin there, and the plugin reports only for a launch through the
shim. This is the one place Weir writes into an agent's own folder.

## Files

- `agy` — a transparent wrapper installed at
  `Weir.app/Contents/Resources/antigravity-shim/agy`. Weir prepends this
  directory to `PATH` for every pty it spawns. It locates the real binary,
  places the plugin, names this launch's run, reports the launch, adds `--settings` for the status
  line relay, and execs the real binary in its place.
- `weir-hook` — a wrapper that execs the Hook Helper's `hook antigravity`
  subcommand, forwarding event and report arguments to the Rust runtime.
- `../antigravity-plugin/` — the plugin (`plugin.json`, `hooks.json`,
  `scripts/weir-dispatch`), copied to `~/.gemini/config/plugins/weir`.

## The plugin

The shim copies the plugin when it is missing or its `.weir-managed` differs
from the bundle's, through a staged folder and a rename. Only a folder that
carries that mark is ours to replace: a folder named the same without it is the
person's, and a link is left alone. A failure leaves the old version or none,
and `agy` starts either way, unwatched. A demo run, whose record directories
are blank, places nothing.

`scripts/weir-dispatch` is what each hook runs. Outside a Weir pane
`WEIR_ANTIGRAVITY_HOOK_DIR` is unset, and it only gives the default reply.
`agy`'s payloads name no event, so the dispatch passes the event name separately
with `event <name> [worktree]`. The Rust runtime parses the bounded payload as
a JSON object and sets `hook_event_name` with serde. Empty objects and leading
whitespace do not change this behavior.

`agy plugin disable weir` or removing the folder stops the reporting. A removed
folder returns on the next launch through the shim.

## The launch report

`agy` sends `SessionStart` only with the first prompt, and none for
`--conversation`. So the shim calls `weir-hook report WeirLaunch` before
`agy` starts, passing the conversation as `--string conversationId` and the
folder as `--string-array workspacePaths`. The Rust runtime serializes these
named values with serde, preserving control characters and trailing newlines. A run then shows from the
start, and a failure before any hook has a record to show on. It sends none for
a subcommand, help or version, in a demo, or while the plugin folder is not
ours. `--continue` names no conversation, so the first request supplies it.

## Environment contract

Set by Weir before spawning the pty, except the rows that say the shim sets
them. `PaneShellEnvironment` and `AgentShimLocator` are the source of
truth for the values Weir sets.

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended. Looking for the real `agy`, the shim passes over any entry holding a `weir-hook` (a shim folder, however it is spelled, this Weir's or another's) or a link to the shim itself, and keeps every other entry where it was, an empty one (the current folder) included (`weir_filter_path` in `agent-shim/runtime-common.sh`). Without that file the shim does not search the `PATH` |
| `WEIR_ANTIGRAVITY_SHIM_DIR` | This directory, so `claude-shim/zdotdir/.zshrc` can re-prepend it |
| `WEIR_ANTIGRAVITY_SESSIONS_DIR` | Directory to write session records into |
| `WEIR_ANTIGRAVITY_AGENT_STATES_DIR` | Directory to write agent-state records into; blank in a demo |
| `WEIR_USAGE_DIR` | Directory to write the plan's usage into |
| `WEIR_ANTIGRAVITY_HOOK_DIR` | Set by the shim: this directory, which tells the plugin the launch is ours |
| `WEIR_ANTIGRAVITY_WORKSPACE` | Set by the shim: the launch's folder. Hooks run in the plugin's folder, so the dispatch script returns here |
| `WEIR_ANTIGRAVITY_PID` | Set by the shim: its own PID, which becomes the agent's at the exec |
| `WEIR_AGENT_TMUX_HOST_MODE` | Set by the shim to `manual` inside the person's own tmux |
| `WEIR_REAL_ANTIGRAVITY` | Optional override path to the real `agy`, taken before any search (a test's stub); outside an app bundle only |
| `WEIR_FOUND_ANTIGRAVITY` | The `agy` the new worktree sheet found, as `WEIR_FOUND_CODEX` in [`codex-shim/README.md`](../codex-shim/README.md) |
| `WEIR_ANTIGRAVITY_KNOWN_LOCATIONS` | Newline-separated places to look when the `PATH` has no `agy`, as `WEIR_CODEX_KNOWN_LOCATIONS` |

## Status line

The plan's usage reaches us only through the status line. As for Claude Code,
the shim asks the helper for a `--settings` value that puts our relay in the
slot of the person's own status line, and the relay runs theirs on the same
input. Without one of their own, the slot stays theirs. `agy` takes `--settings`
once, so a launch with its own keeps it, and shows no usage.

## tmux

Weir never hosts `agy` in tmux. `agy` reports its status over OSC 7501 only
outside tmux, and that report is our only sign of a permission wait or a stopped
turn. Inside the person's own tmux, permission waits do not show, and a stopped
generation or a canceled question stays at work until the next prompt.

## Failure policy

`weir-dispatch` always exits `0` with valid JSON on stdout. `agy` treats any
other result as the tool failing and its model retries the call, contrary to
its documentation, so a broken Weir must never reach it. A missing helper
makes `weir-hook` exit `1` as the other shims do, and the dispatch script turns
that into the default reply.

The installed plugin is shared by every Weir build that uses the same home
folder. Its `weir-dispatch` hands each call to the copy bundled with the pane's
own build, beside that build's helper, so a pane started by an older build still
gets the arguments its helper understands.

`agy` has no way we know of to change a tool's input, so a `git worktree add`
aimed at another folder gets a `deny` whose reason gives the command to run
instead (`ProviderAdapter::worktree_reroute_output`). Nothing is created until
the model runs that command, which meets `agy`'s own policy like any other.

The `agy` shim exits `127` with a diagnostic when it cannot find a real `agy`
to hand over to.
