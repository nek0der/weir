---
name: verify-in-app
description: Checks a change to Weir in a real run of the Debug app without taking over the person's screen, through the verification channel (scripts/weir-automation.py, ADR 0005). Use when asked to verify, try, or see a change in the running app, to send a prompt to Claude Code, Codex, OpenCode, Antigravity, or Kiro in a pane and wait for its turn, to open a layer such as Needs Attention or review, to run a menu or palette command, to change a setting and see it, or to capture the window; to check an approval card's round trip in a signed build, which has no channel, through accessibility; and to run make check-automation after changing Weir/Automation.
---

# Verify a change in the running app

Use this when a change has to be seen in the app itself: what a pane shows,
what an agent does with a prompt, whether a layer opens, how a setting looks.
Unit tests come first; this is for what they cannot show.

A key a check is about (Esc, Return, Tab, the arrows, ⌘⏎ and the like)
can be posted to the run behind the person's windows with `keys` (ADR 0006),
as long as one of Weir's own controls holds the keyboard: a dropdown, a
sheet's field, the restore strip. Input methods, a standard macOS menu
opening on screen, and the active window's look still need full-screen
control or a manual check: ask the person for the first, or say which you
left to the second.

When a check needs something no operation or palette row reaches, add an
operation as ADR 0005's "Adding an operation" says, rather than reaching for
full-screen control. Every operation, its replies, and its limits are in
`docs/verification-channel.md`.

The run is a Debug build of this checkout, behind the person's windows, with
its own data. Several worktrees can each have one at once.

## Steps

1. Build: `make build`.
2. Launch a run and keep its short ID:

   ```bash
   scripts/weir-automation.py launch          # prints JSON; "folder" is the short ID
   ```

   With several runs live (other agents' worktrees), every later command
   needs `--run <short ID>`; without it the script refuses to guess.

   The run's data starts empty, and Open Folder… asks through a panel no
   request can answer, so hand it what the check needs at launch:

   - `launch --project /path/to/repo` (repeat for more) opens each folder
     as a project, in a window of its own; `state` names the window by its
     `project`. A scratch repository under `build/` keeps the person's
     repositories out of it.
   - `launch --demo` shows the demo's made-up projects, worktrees, turns,
     and review instead, with no agent running; `--layer approval-card`
     (or `needs-attention`, `all-projects`, `review`, `approval-list`) opens
     that layer at once, and `--appearance dark` / `--language ja` change the
     look. Use it to look at a state an agent would take a while to reach.

3. Find the pane: `scripts/weir-automation.py --run ID state`. A pane is
   named by a prefix of its `id`; `foregroundProcess` says what runs in it.
4. Act, then wait for the outcome, then look:

   ```bash
   A="scripts/weir-automation.py --run ID"
   $A type-line PANE "cd /path/to/repo && claude" --expect zsh
   $A state                                   # until foregroundProcess is claude
   $A wait turnEnded --pane PANE --timeout 30 &   # start the wait first
   $A type-line PANE "the prompt" --expect claude
   wait
   $A capture /tmp/after.png                  # then read the image
   ```

   - Several lines go with `paste`, then `submit`.
   - A layer: `$A open needsAttention`, then `$A wait layerOpen --layer needsAttention`.
   - A menu item or shortcut: `$A commands` lists them with whether each can
     run now; `$A command splitRight` runs one. `--new-window` commits a row
     as ⌘Return does, which opens another project's row in a new window.
   - Controls with no shortcut have palette rows too: `newTab.claude` (and
     `.codex`, `.antigravity`, `.opencode`, `.kiro`, for each agent the pane
     strip's "+" offers on this Mac) adds a tab as "+" does,
     `settings.section.keyboard` (any `SettingsSection`) opens Settings
     there, and `pane.moveToNewTab` and `view.toggleIconBars` are rows too.
   - What a check opened shows in `state`: each window's `dropdown` (the
     title bar's and the strip's), `hasSheet`, `isSidebarShown`,
     `areIconBarsHidden`, `isChangesPanelShown`, `review` with its scope,
     and `settings` with the section while Settings is open. Capture
     Settings with `$A capture /tmp/settings.png --settings`.
   - A key: open the control first, then `$A keys down return` (names:
     `escape`, `return`, `tab`, the arrows, `home`, `end`, with `cmd+`,
     `shift+`, `option+`, `ctrl+` before one), then read the result with
     `state` or `capture`. A key that arrives anywhere but a control of a
     project window is dropped by the app, so a dropped key shows as no
     change. The client posts nothing while a terminal pane holds the
     keyboard (`keyboard` in `state`: Return there is `submit`, text is
     `type-line`), while Settings is open, or while the run shows more than
     one window, since the key could land in another. It needs this
     terminal's Accessibility grant.
   - A setting: `$A setting font.family '"Menlo"'` (the value is JSON). It is
     refused where the Settings control would refuse or ask first: a
     binding another action holds, a quick terminal hotkey the recorder
     refuses, or a narrower turn retention, which deletes records.

5. Quit: `$A quit` (`--force` when agents still run in it).

Every reply has a `status`; only `done` is success. A `failed` reply says why,
and the reason is what to act on.

## Pitfalls

- `--expect` names the process that must be in front of the pane, or nothing
  is typed. That is the guard against typing into a shell; never set it to
  the shell to get past a refusal aimed at an agent.
- A wait for `turnEnded` must start before the prompt is sent, and the agent
  must be at rest when it starts; a wait begun while a turn is ending sees
  that turn end.
- Wait for a shell command to finish before the next paste, or the paste can
  arrive while the shell is between prompts and show its brackets as text.
- Keys sent from outside the channel go to the pane with the keyboard: give
  it with `$A focus PANE` first.
- What a Copy put on the clipboard can be read with `pbpaste`; the
  clipboard is the person's, so put back what was there.
- An agent's first start in a folder may ask whether to trust it. Do not
  answer yes on the person's behalf: it writes to their agent's settings. Ask.
- tmux needs no full-screen control. Start it with the channel, on a server
  and session of the run's own so the person's sessions are never touched:
  `$A type-line PANE "tmux -L weir-check new -s check" --expect zsh`.
  Inside it the channel refuses to type (`isInTmux` in `state`), since the
  process in front is tmux; send with tmux itself instead,
  `tmux -L weir-check send-keys -t check 'echo hi' Enter`, then `capture`.
  End it with `tmux -L weir-check kill-server`.
- A sheet or an alert a row opened (`hasSheet` in `state`: New Worktree…,
  Project Settings…, Close Project…) cannot be answered or closed through
  the channel yet, and it covers the window until the run quits. Open one
  only when the check is about it, and last.
- A paste into a program without bracketed paste raises the paste
  confirmation (`notObservable`), which only the person can answer; `quit`
  clears it by refusing the paste.
- The run's panes have the person's real `HOME`: an agent started there reads
  and writes the person's agent settings and history.
- The run is a copy of the build with a bundle identifier of its own, which
  `launch` prints as `bundleID`. Read the run's user defaults with
  `defaults read <bundleID>`. The build's own identifier is the person's
  domain, so never write to it.

## Checking approvals in a signed run

Native approvals need a build signed with `WEIR_DEVELOPMENT_TEAM`, started
with `make run`, not with `launch`: `make run` starts the build itself, under
its own bundle identifier and signature, which the approval service needs, not
the ad hoc copy `launch` makes. The approval service is one per user, so
these checks run one worktree at a time; `make run` quits only this
checkout's Weir Dev and never reaches another worktree's. Native approvals
are off in any run with the channel on, so this run is started without it.
Drive it through accessibility, with a tool that acts on a background window
without full-screen control:

1. Look: capture the window, and confirm that the program in front of the
   pane is the shell or agent you mean and that its prompt is empty. Input
   through accessibility passes none of the channel's checks (`--expect`,
   the session, the person's draft), so this look is the only check.
2. Type the prompt: set the pane's `AXSelectedText` to it. Several lines
   arrive as one paste, so a program without bracketed paste meets the paste
   confirmation (see Pitfalls).
3. Send it: set `AXSelectedText` to a line break alone, which the pane takes
   as the Return key.
4. Answer the request: click the approval card's button.

`docs/verification-channel.md`, "Checking approvals in a signed run", has
what the pane does with each input. This does not conflict with ADR 0006's
rule of "keys, never text": that rule covers what the channel posts, and this
input does not come from the channel. It reaches the pane through
accessibility, from a tool the person granted.

## Check it worked

- The reply of each step is `done`, and the capture shows the change.
- After changing the channel itself (`Weir/Automation`,
  `scripts/weir-automation.py`), run `make check-automation`, and
  `CHECK_AUTOMATION_FLAGS="--keys --agents" make check-automation` when the
  change touches typing, focus, captures, or agents. It must end with every
  check passed. When one agent's plan has no model use left, name the others
  (`--agents claude,codex,agy`) and say in the pull request which ran.
