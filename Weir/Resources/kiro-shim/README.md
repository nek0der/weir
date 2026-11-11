# kiro-shim

Two POSIX-shell scripts, and a hook file beside them, that let Weir track Kiro
CLI (`kiro-cli`) sessions, badge agent state, and re-route `git worktree add`.
These facts are from `kiro-cli` 2.37.1, and were checked again on 3.2.0.

Kiro takes no hooks on its command line, unlike `claude` and `codex`. It reads
hook files from its own folder, `~/.kiro/hooks/`, for every session, and from a
project's `.kiro/hooks/`. So the shim places our file there, and its hooks
report only for a launch through the shim. Hooks load only under Kiro's v3
engine, which a person who used Kiro 2 may not have chosen yet: Weir's own
launches pass `--v3`.

## Files

- `kiro-cli` — a transparent wrapper installed at
  `Weir.app/Contents/Resources/kiro-shim/kiro-cli`. Weir prepends this
  directory to `PATH` for every pty it spawns. It locates the real binary,
  places the hook file, reports the launch, and execs the real binary in its
  place.
- `weir-hook` — a wrapper that execs the Hook Helper's `hook kiro`
  subcommand, with `worktree` passed on for the intercept.
- `../kiro-hooks/weir.json` — the hook file, copied to
  `~/.kiro/hooks/weir.json`.

## The hook file

The shim copies the file when it is missing, or when it is one we wrote, left
as we wrote it, and differs from the bundle's. It keeps the `cksum` of what it
wrote in `~/.kiro/hooks/.weir.json.cksum` to tell the two apart: a file the
person wrote, or ours after they edited it (a hook set to `"enabled": false`, a
timeout), is theirs, and is left alone. A link is left alone too. A new file
goes in by a hard link to a staged copy, which fails if a file appeared
meanwhile; a replacement by a rename, after the file is read once more, so only
an edit saved in that instant could be lost. A failure leaves Kiro to start,
unwatched. A demo run, whose record directories are blank, places nothing.

Every hook's command runs `weir-hook` only when `WEIR_KIRO_HOOK_DIR` names it,
which the shim sets for its own launch. Outside a Weir pane the variable is
unset, and the hook exits 0 with no output, which Kiro ignores. Kiro runs each
command through `/bin/sh -c`, in the session's folder, with the agent's
environment.

The hooks: `SessionStart`, `PreToolUse` and `PostToolUse` for every tool, and
`Stop`, each with 30 seconds; and the worktree route, `PreToolUse` and
`PostToolUse` for the `shell` tools, the second with a day for the project's
setup. There is no prompt hook: Kiro adds a prompt hook's output, even an empty
one, to the model's context every turn. A turn's start and its words are read
from Kiro's session log instead (`docs/provider-adapters.md`, "Kiro").

Removing the file stops the reporting until the next launch through the shim,
which places it again. Setting a hook's `enabled` to `false` stops only that
hook, and the edited file stays as the person left it. A folder Kiro does not
trust runs no hooks at all, ours included.

We do not follow `KIRO_HOME`. Kiro refuses some values of it (a relative path,
the home folder or one above it) and falls back to `~/.kiro`, so the shim and
the hook use `~/.kiro` whatever it says.

## The launch report

Kiro sends `SessionStart` only with the first prompt, and none for
`--resume-id`. So the shim sends `weir-hook` a `WeirLaunch` payload before Kiro
starts, with the session a resume names and whether `--trust-all-tools` (`-a`)
was given. A run then shows from the start, and a failure before any hook has a
record to show on. It sends none for a subcommand other than `chat`, help,
version, or a list, a cloud session (`--cloud`), a folder whose name has a line
break, in a demo, for a launch that does not run the v3 engine, or while the
hook file is not exactly this build's. The engine is read as Kiro 3.2.0 chooses
it: `--v3` or `--agent-engine`, then `KIRO_AGENT_ENGINE`, then
`chat.agentEngine` in the folder's settings and the person's, and with none of
them v3 for an interactive chat and v2 for one without a terminal unless it
trusts every tool. `--resume` names no session, so the first hook supplies it.

## Environment contract

Set by Weir before spawning the pty, except the rows that say the shim sets
them. `PaneShellEnvironment` and `AgentShimLocator` are the source of
truth for the values Weir sets.

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended. Looking for the real `kiro-cli`, the shim passes over any entry holding a `weir-hook` (a shim folder, however it is spelled, this Weir's or another's) or a link to the shim itself |
| `WEIR_KIRO_SHIM_DIR` | This directory, so `claude-shim/zdotdir/.zshrc` can re-prepend it |
| `WEIR_KIRO_SESSIONS_DIR` | Directory to write session records into |
| `WEIR_KIRO_AGENT_STATES_DIR` | Directory to write agent-state records into; blank in a demo |
| `WEIR_KIRO_HOOK_DIR` | Set by the shim: this directory, which tells the hooks the launch is ours |
| `WEIR_KIRO_PID` | Set by the shim: its own PID, which becomes the agent's at the exec |
| `WEIR_AGENT_TMUX_HOST_MODE` | Set by the shim to `manual` inside the person's own tmux |
| `WEIR_REAL_KIRO` | Optional override path to the real `kiro-cli`, taken before any search (a test's stub); outside an app bundle only |
| `WEIR_FOUND_KIRO` | The `kiro-cli` the new worktree sheet found, as `WEIR_FOUND_CODEX` in [`codex-shim/README.md`](../codex-shim/README.md) |
| `WEIR_KIRO_KNOWN_LOCATIONS` | Newline-separated places to look when the `PATH` has no `kiro-cli`, as `WEIR_CODEX_KNOWN_LOCATIONS` |

## tmux

Weir never hosts Kiro in tmux. Kiro reports its status over OSC 7501, and that
report is our only sign of a permission wait, a stopped turn, or a failure with
no hook; it does not reach us through tmux. Inside the person's own tmux,
permission waits do not show, and a stopped turn stays at work until the next
one.

## Failure policy

Kiro continues a turn whose `Stop` hook exits 1, and refuses a tool whose
`PreToolUse` hook exits 2. A broken Weir must do neither, so every hook's
command ends with `exit 0` whatever `weir-hook` returned; a missing helper makes
`weir-hook` exit `1` as the other shims do. The one exit 2 that gets through is
the worktree route's refusal, on `PreToolUse`.

Kiro takes no rewritten tool input, and reads nothing from a `PreToolUse` hook's
standard output. So a `git worktree add` aimed at another folder is refused with
exit 2, and standard error, which Kiro hands the model, gives the command to run
instead (`ProviderAdapter::worktree_reroute_refusal`). Nothing is created until
the model runs that command, which meets Kiro's own prompt like any other.

The `kiro-cli` shim exits `127` with a diagnostic when it cannot find a real
`kiro-cli` to hand over to.
