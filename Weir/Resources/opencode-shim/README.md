# opencode-shim

Two POSIX-shell scripts, and a plugin beside them, that let Weir track OpenCode
sessions and badge agent state. These facts are from OpenCode 2.2.5.

OpenCode runs its sessions on a background service that every terminal on the Mac
shares, so a hook in the service could not tell which pane a session belongs to. Only
the terminal interface in the pane can, so the report comes from a plugin there.
OpenCode reads its interface plugins from its own folder, so the shim places ours
there, and the plugin reports only for a launch through the shim.
`docs/provider-adapters.md`, "OpenCode", says why the other ways did not work.

## Files

- `opencode` — a transparent wrapper installed at
  `Weir.app/Contents/Resources/opencode-shim/opencode`. Weir prepends this directory to
  `PATH` for every pty it spawns. For a launch of the interface it places the plugin,
  says what the launch names, and keeps the pane's `WEIR_*` for the plugin while taking them
  out of the environment. It execs the real binary in its place.
- `weir-hook` — a wrapper that execs the Hook Helper's `hook opencode` subcommand.
- `../opencode-plugin/` — the plugin (`tui.js`), copied to
  `~/.config/opencode/plugins/weir`, or under `XDG_CONFIG_HOME` when that is set. When
  `OPENCODE_CONFIG_DIR` is set it goes to `plugins/weir` there, the only folder OpenCode
  then loads plugins from.

## The plugin

Each session the pane has to do with gets a run: the launch's run goes to the first, and the
plugin sets `WEIR_AGENT_RUN_ID` on each hook of another. The launch's run also holds which run
is on screen (`weir.shown`), reported past the other reports as the screen changes. It
reads the screen every 500 ms, as moving between tabs sends no event, and says what it shows until
the hook has written it: exit 75 says it could not, a limited number of times. Every 100 ms it looks for
`<sessions dir>/../tab-focus/<RUN>.json`, named for the process by its launch's run (several
OpenCodes can run from one pane under tmux), which Weir writes (0600,
atomically) to bring a session forward. The plugin takes it by rename. It can only say
`{"sessionId":"ses_...","nonce":"...","at":<ms>}`, only one of this pane's sessions is obeyed, and one
older than three seconds is ignored. One with a nonce is answered in `<RUN>.json.<nonce>.answer` with the
route read at that moment and its root.

The shim copies the plugin when it is missing or its `.weir-managed` is lower than the
bundle's, never when higher: the Debug and release apps share the folder, and overwriting
each other would reload the plugin in every running pane. Only a folder that carries that mark is ours to replace: a folder named the
same without it is the person's, and a link is left alone. A failure leaves the old
version or none, and `opencode` starts either way, unwatched. A demo run, whose record
directories are blank, places nothing.

Placement uses the shared `agent-shim/runtime-common.sh` helpers and a persistent
`.weir-placement.lock` in the config root (`${target%/plugins/weir}`, including
when `OPENCODE_CONFIG_DIR` is set). macOS `lockf` holds an exclusive
kernel lock while the shim re-reads ownership and version, stages files in that
root, renames them into place, and writes the completed mark last. It waits at
most one second; a timeout skips placement and starts the agent. A `placing:<version>` mark lets a later
launch finish an interrupted update without allowing an older build to overwrite
it. The kernel releases the lock when its holders exit, including after termination.

The lock and temporary staging folders and files stay outside `plugins/` so no
plugin loader can see them. Marks only increase: running an older Weir does not
downgrade the shared plugin. To reinstall an older bundled plugin on purpose,
quit every Weir build, remove the configured `plugins/weir` folder only if it
carries `.weir-managed`, then launch the older Weir and run `opencode` in a pane.

Outside a Weir pane `WEIR_OPENCODE_HOOK_DIR` is unset, and the plugin does nothing. The
folder holds only `tui.js`: the service's plugin loader looks for `server` and `index`,
and no pane's environment reaches it there.

Bump `.weir-managed` with every change to `tui.js`, or panes keep the old file. The
tests are in `scripts/opencode-plugin-tests/`, and `make plugin-test` runs them.

## What goes through untouched

A subcommand (`run`, `serve`, `session`, …), `--help`, and `--version` start no interface
of a pane's, so the shim places no plugin and keeps nothing for one; their arguments pass
through, with the pane's variables taken out as for every launch. A launch with `--server`
goes the same way, unwatched: that server's folders are not this Mac's to snapshot.

## The pane's environment

OpenCode hands its interface's environment to each session it shows, and that session's
commands run with it in preference to the service's (`Env.session`, `session.environment`,
`packages/core/src/shell.ts` at v2.2.5). A plugin cannot change what it hands over. So
`WEIR_*`, a `ZDOTDIR` of Weir's, and the shims on the `PATH` would reach every command the agent runs,
and a `claude` there would report as this pane's, and a service the interface starts would
keep them after the pane is gone.

The shim therefore takes them out for every launch. For a launch the plugin will watch, it
first writes the `WEIR_*` to a uniquely named file in `pane-env/` under the state directory, as `NAME=value`
entries each ended by a NUL, 0600, and names the file in `WEIR_OPENCODE_PANE_ENV`. The plugin
reads and removes it, and passes the values to the hooks it runs. A nested OpenCode inherits
only the name, finds no file, and does nothing. One the plugin never read is swept after a day.

## Environment contract

Set by Weir before spawning the pty, except the rows that say the shim sets them.
`PaneShellEnvironment` and `AgentShimLocator` are the source of truth for the values
Weir sets.

| Variable | Meaning |
|---|---|
| `PATH` | Original `PATH` with this directory prepended. Looking for the real `opencode`, the shim passes over any entry holding a `weir-hook` (a shim folder, however it is spelled, this Weir's or another's) or a link to the shim itself, and keeps every other entry where it was, an empty one (the current folder) included (`weir_filter_path` in `agent-shim/runtime-common.sh`). Without that file the shim does not search the `PATH` |
| `WEIR_OPENCODE_SHIM_DIR` | This directory, so `claude-shim/zdotdir/.zshrc` can re-prepend it |
| `WEIR_OPENCODE_SESSIONS_DIR` | Directory to write session records into |
| `WEIR_OPENCODE_AGENT_STATES_DIR` | Directory to write agent-state records into; blank in a demo |
| `WEIR_OPENCODE_PANE_ENV` | Set by the shim, and the only one of these left in OpenCode's environment: the file that holds the others |
| `WEIR_OPENCODE_HOOK_DIR` | Set by the shim, in that file: this directory, which tells the plugin the launch is ours |
| `WEIR_OPENCODE_LAUNCH_SESSION` | Set by the shim: the session `--session` names, so the run rests with it from the launch |
| `WEIR_OPENCODE_LAUNCH_PROMPT` | Set by the shim: `1` when `--prompt` sends an input with no key press to tell whose it is |
| `WEIR_OPENCODE_LAUNCH_PREPARATION` | Set by the shim when `--prompt` carries an input: the generation of the turn start it saved before OpenCode ran, since no Enter comes for the plugin to save one. Absent when the save failed or took over ten seconds |
| `WEIR_OPENCODE_PID` | Set by the shim: its own PID, which becomes the agent's at the exec |
| `WEIR_REAL_OPENCODE` | Optional override path to the real `opencode`, taken before any search (a test's stub); outside an app bundle only |
| `WEIR_FOUND_OPENCODE` | The `opencode` the new worktree sheet found, as `WEIR_FOUND_CODEX` in [`codex-shim/README.md`](../codex-shim/README.md) |
| `WEIR_OPENCODE_KNOWN_LOCATIONS` | Newline-separated places to look when the `PATH` has no `opencode`, as `WEIR_CODEX_KNOWN_LOCATIONS` |

## Worktrees

The interface can neither stop nor change a tool, so an agent's `git worktree add` runs as
written. On `session.tool.success` of a shell command that names a worktree, the plugin runs
`weir-hook worktree`, apart from its other reports, as a bootstrap can take minutes. If the
command exited 0, is whole (the plugin cut nothing of it), and is exactly
`git worktree add -b <branch> <folder>` with single spaces and no quoting, comment,
variable, or other option, and its folder resolves to the one the project's placement gives
the branch, where Git lists the worktree, the runtime runs the bootstrap and writes the event
that refreshes the sidebar. Anywhere else nothing happens; the sidebar lists the worktree
the next time Weir refreshes the project's worktrees, for instance when Weir comes back to
the front. A subagent's `git worktree add` gets no bootstrap either, as the plugin forwards
only the root session's tools.

## tmux

Weir never hosts `opencode` in tmux: the plugin's reports need no help from it, and the
host's pid sweep watches the process it can see.

## Failure policy

Nothing the plugin does may reach OpenCode as an exception. It does nothing when the
interface lacks part of the API it needs, every report is caught, and Enter sends the
input whatever became of the save before it. The shim likewise starts `opencode` within ten
seconds, whatever became of a `--prompt` input's save. It exits `127` with a
diagnostic when it cannot find a real `opencode` to hand over to.

Launch preparation calls `weir-hook report weir.prepare` with `--string`
arguments for `preparation` and `cwd`, and `--empty-object data`. The Rust hook
runtime builds the JSON with serde. Folder names retain control characters
and trailing newlines, including when a launch selects another directory.
