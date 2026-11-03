---
name: verify-in-app
description: Checks a change to Weir in a real run of the Debug app without taking over the person's screen, through the verification channel (scripts/weir-automation.py, ADR 0005). Use when asked to verify, try, or see a change in the running app, to send a prompt to Claude Code, Codex, OpenCode, or Antigravity in a pane and wait for its turn, to open a layer such as Needs Attention or review, to run a menu or palette command, to change a setting and see it, or to capture the window; and to run make check-automation after changing Weir/Automation.
---

# Verify a change in the running app

Use this when a change has to be seen in the app itself: what a pane shows,
what an agent does with a prompt, whether a layer opens, how a setting looks.
Unit tests come first; this is for what they cannot show.

Do not use it for real key presses, input methods, or a menu opening on
screen: no request from outside can do those (ADR 0005). Ask the person for
full-screen control for those, or leave them to a manual check, and say which.

When a check needs something no operation or palette row reaches, add an
operation as ADR 0005's "Adding an operation" says, rather than reaching for
full-screen control.

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
     run now; `$A command splitRight` runs one.
   - A setting: `$A setting font.family '"Menlo"'` (the value is JSON).

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
- An agent's first start in a folder may ask whether to trust it. Do not
  answer yes on the person's behalf: it writes to their agent's settings. Ask.
- A paste into a program without bracketed paste raises the paste
  confirmation (`notObservable`), which only the person can answer; `quit`
  clears it by refusing the paste.
- Native approvals need a build signed with `WEIR_DEVELOPMENT_TEAM`, and the
  approval service is one per user, so checks of approvals run one worktree
  at a time, in a run started with `make run`, not with `launch`.
- The run's panes have the person's real `HOME`: an agent started there reads
  and writes the person's agent settings and history.
- `make run` quits only this checkout's Weir Dev; it never reaches another
  worktree's.

## Check it worked

- The reply of each step is `done`, and the capture shows the change.
- After changing the channel itself (`Weir/Automation`,
  `scripts/weir-automation.py`), run `make check-automation`, and
  `CHECK_AUTOMATION_FLAGS="--keys --agents" make check-automation` when the
  change touches typing, focus, captures, or agents. It must end with every
  check passed. When one agent's plan has no model use left, name the others
  (`--agents claude,codex,agy`) and say in the pull request which ran.
