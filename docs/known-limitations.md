# Known limitations

Each Weir window shows one project at a time: a sidebar of worktrees, the
terminal, and the Changes panel. This page lists what Weir does not do
yet, what it does on purpose that may surprise you, and what has not been
checked on a real machine. It describes the current build. Entries go away
as they are fixed or confirmed.

## Accessibility

- **VoiceOver cannot read the terminal.** A terminal pane is announced as
  "Terminal", but its text and cursor are not exposed. What an agent changed
  can be read in the review tab and the Changes panel; what it printed
  cannot.
- **A hunk header's Comment and Discard buttons cannot be reached with the
  review's keys.** From the keyboard, `]` moves to the next hunk, ⇧J
  extends the selection over its lines, and `c` comments on them.
  Discarding a hunk needs the pointer.

## Approvals and questions

- **Native approvals need a signed build.** The approval service starts only
  in a build signed with a Team ID. An ad-hoc signed Debug build (the default
  for `make build`) leaves every approval to the agent's own terminal prompt.
  `CONTRIBUTING.md` explains how to sign a development build.
- **Claude Code shows its own prompt while Weir holds its request.** Weir
  holds every request until it is answered on the card or handed to the
  terminal ("Answer in terminal"), wherever its pane is. Claude Code draws
  its own permission dialog in the pane meanwhile, and whichever is
  answered first counts; a request answered "Yes" there keeps its card
  until the turn ends. OpenCode does the same: its prompt is up beside the
  card, and an answer at either withdraws the other. Codex shows no prompt
  until the request is handed to it. When Weir is not in front, the menu bar can answer a short shell
  command that is not high-impact; any other request opens Weir.
- **Codex questions are answered in the terminal.** While Codex waits on a
  question, Weir shows "Needs answer" with the first question's words, but
  no Codex hook can answer it, so there is no card. A question Codex asks
  without stopping, as it does in its default mode, shows as work in
  progress: the turn goes on, and the question is answered in Codex's own
  prompt. If it is still open when the turn ends, Weir shows "Needs
  answer" without its words.
- **Some waits show only outside tmux, and without their words.** A sign-in
  the agent needs, and an MCP server's request for input under Codex, send
  no hook. Weir reads them from the status the agent reports to the
  terminal (OSC 7501), which does not reach Weir from inside tmux, and
  which Claude Code does not report with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`
  set. There the row shows the turn as running, or at rest. Elsewhere it
  shows "Needs answer" or "Needs sign-in" without the server's name or the
  request's words. Under Claude Code, an MCP server's request comes through
  its `Elicitation` hook, so it shows with its words, inside tmux too. Every
  one of these waits is answered in the terminal.
- **An MCP server's request under Claude Code can be shown longer than it
  lasts.** A hook of your own that answers the request leaves no sign of the
  answer, so "Needs answer" stays until Claude Code's next tool or the end of
  its turn. The answer to a request from a background subagent shows the
  agent as working until the subagent reports back, and it also ends any
  wait the agent itself was in at that moment, because the answer does not
  say whose request it was.
- **An approval refused in Claude Code's own dialog can stay listed for a
  while inside tmux.** Claude Code sends no hook when you choose "No" in the
  terminal. Weir reads the answer from the status Claude Code reports to
  the terminal (OSC 7501), which it does not report inside tmux or with
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` set. There the row keeps saying
  "Needs approval" until the next prompt in that pane or the end of the
  turn.
- **No time left is shown after an approval goes to the terminal.** Once a
  request is handed to the agent's own prompt, the agent decides how long it
  waits, and Weir cannot read that time.
- **"Always allow" is the agent's own choice.** Weir adds no such option and
  writes nothing to an agent's settings. Use the agent's prompt in the
  terminal.

## Notifications

- **Weir cannot tell whether a Focus is on**, so the notification history
  never warns that a Focus may hold banners back. Reading it needs an
  entitlement and a permission prompt that Weir does not ask for.
- **A reset notification you asked for is not kept across a restart.** After
  a restart, a usage-limit stop offers "Notify When It Resets" again.
- An open All Projects card or Needs Attention list can keep saying that a
  limit "resets" at a time that has already passed, until you close and
  reopen it.

## Turn history and restore

- **Restore and Discard do not lock out other programs.** Weir checks the
  files before and after, and stops if an agent or an editor changed them.
  Another program can still write in between.
- **Undo Restore lasts while the undo can apply.** After a commit, a reset,
  or a checkout moves HEAD or the branch from where a restore left it, the
  undo is refused, and the restore's record goes 30 days after the
  restore. Moving HEAD back before then makes the undo apply again.
- **A pane with turn snapshots turned off** (`WEIR_TURN_SNAPSHOT=0` in its
  environment, which stops Weir from recording what each turn changed)
  takes no lock, so its agent can start a turn while another pane of the
  same worktree restores one.
- **A stalled snapshot can hold a Claude Code or Codex prompt for up to 10
  minutes**, the timeout of the hooks that take it at a turn's start
  (`UserPromptSubmit`) and end (`Stop`). The snapshot has no shorter limit
  of its own.
- **A turn that goes on after a failed stop** is recorded as a failed turn
  with only its end, and the turn before keeps the first end.
- **A turn record larger than 4 MiB is not read.** The turn keeps what
  Weir read of it before, or is not listed if Weir read nothing.
  Nothing on screen says so; Weir logs it once (`agent.turn-records`).
- **A turn's tokens are read when it ends**, so a running turn shows none.
  Claude Code's tokens are read from the last 4 MiB of its transcript; a
  turn that began before that, or whose last response was still not
  written a second after the turn ended, shows its count with "≥". A
  subagent still running when the turn ended counts only what it had used
  by then.
- **A Claude turn stopped inside tmux can keep showing as running.**
  Claude sends no hook when you stop its work with Esc or Ctrl+C. Weir
  reads the stop from the status Claude Code reports to the terminal (OSC
  7501), which it does not report inside tmux or with
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` set. There the turn shows as running
  until your next prompt in that pane, or until Claude's idle notification
  if one comes a minute later; none comes while one of Claude's subagents
  runs in the background. A turn your next prompt ends shows no tokens.
- **A Codex turn is read when it ends.** Its checks are read from its
  rollout at that moment, so they appear together rather than as each one
  finishes. A Codex turn interrupted before its first response arrives
  shows no tokens, since Codex records none for it. A very long Codex turn
  may count fewer test runs than it ran: its card says so with "…" and its
  tooltip with "at least", while the decision bar's count of failures is
  the one Weir read.
- **A Codex turn can leave some subagents' tokens out.** Codex keeps each
  subagent's work in a rollout of its own, which Weir finds by the
  thread the turn's rollout names it by. A subagent's own subagents are
  named only in its rollout, which Weir does not search, so their tokens
  are not counted. Nor are those of a subagent that only the start of a
  very long turn named, when Weir reads only the end of that turn's
  rollout.
- **A turn's card lists only what Claude Code's auto mode refused.** Claude
  Code reports no refusal from `dontAsk` mode, and Codex has no such hook, so
  those leave no line on the card.
- **A Claude subagent named again in a later turn is counted again**:
  Weir reads the subagent's whole transcript at each turn that names it.
- **A turn record written by an older Weir and a newer one in turn** can
  show a test count that leaves out the runs the older one recorded.
- **A turn keeps its last 16 test runs** one by one; the card shows the last
  three, and the tooltip counts all of them.
- **"Create PR" needs `gh`**, so Weir does not create a GitLab merge
  request.

## New worktrees

- **A `git worktree add` an agent runs goes to the project's folder only when
  the command is plain.** Weir changes the folder in the command before the
  agent's own permission checks, so a command with more after it (`&& cd ...`),
  quoting, or an option Weir does not know runs as written, in the folder the
  agent named. So does one whose branch gets a folder that already holds something,
  such as another branch whose name gives the same folder. Its setup steps run after the command. If the turn stops before the
  agent reports the command finished, or it reports that before Git has listed
  the worktree, as a command moved to the background can, the worktree goes
  without them. With Codex, the agent's next try within the hour runs them, unless
  Weir had already waited five minutes for the checkout. That next try also runs
  them a second time if you refused the command and then made the same worktree
  from the new worktree sheet. They can start before a slow `post-checkout` hook of
  your own has finished, when the command was moved to the background, and in an
  empty folder after `--no-checkout`.
- **The new worktree sheet takes no first prompt.** A tab that an earlier
  build opened in the background with one, and that has not been shown
  since, still hands the prompt to its agent the first time it is shown. If
  you close that tab before then, the prompt is dropped with it.
- **Making a worktree from a pull request needs `gh` or `glab`**, installed
  and signed in to the project's remote. The head is fetched from the
  forge's own ref for the request, so a fork needs no remote of its own,
  but GitLab may stop keeping that ref for a merge request closed long ago.
  A local branch with the request's branch name is used only when it is
  already at the request's commit; otherwise the worktree gets `pr/<number>`.
- **Carrying uncommitted changes into a new worktree** stops before anything
  is made when the worktree they are in has a merge, rebase, cherry-pick, or
  revert under way, has conflicts to resolve, uses a sparse checkout or a
  split index, has files marked skip-worktree or assume-unchanged or added
  with `git add -N`, changes a submodule or a repository inside it, or has
  a folder with ignored files where a tracked file was, and when the
  changes conflict with the new worktree's starting point. It needs Git
  2.40 or later. If a file would come out of the new worktree with other
  bytes than it has (a line-ending setting or a filter), nothing is moved. Empty folders do not come along, nor do files Git ignores
  (those come only through the copy that Project Settings names), and
  changes inside a submodule stay where they are.
- **A worktree that changes while its changes are carried keeps them.** If
  an agent or an editor writes in it, or Git holds its index, in the moment
  the changes are moved, they end up in both worktrees, and the bar under
  the new one says so; nothing is taken out of the first one. A write in
  the instant Git puts the first worktree's files back can still be lost,
  as it can in any `git checkout`. A `git commit` still waiting on its
  message editor in that worktree is not seen: once it finishes, its commit
  shows as undone by staged changes, which `git restore --staged --worktree
  .` puts right. If Weir quits while it holds that
  worktree's index, Git stops on the `index.lock` left behind until it is
  removed.

## Background work

- **A task you stop from Claude Code's task list stays counted until your
  next prompt.** The decision bar takes the count from the last stop, and a
  task that ends on its own starts a turn of Claude's whose stop updates it.
  For a task stopped from `/tasks`, Claude only queues its end for the next
  prompt and starts no turn, so the bar and the circling dot on the row, the
  tab, and the pane header keep saying it is running until then.
- **A turn that fails or that you interrupt says nothing about what is
  still running,** because no stop listed it.
- **`/compact` after a turn hides the count and the circling dot,** although
  the tasks keep running. The compaction restarts Claude's session, and
  nothing says so again until a later turn ends.
- **After a failed turn or `/compact`, a Claude subagent still running shows
  the pane working while it uses tools,** until it ends: its end starts a
  turn of Claude's, whose stop leaves the pane finished. Neither the failure
  nor the compaction came with a stop that counted the subagent, so its
  tools are the only sign that it is still at work. After a turn that ended
  normally, the stop counts it and its tools leave the pane finished.
- **Codex's background terminals are not shown.** Codex keeps them running
  after a turn, but its `Stop` does not list them and no hook reports their
  end.

## Pane headers

- **A permission mode changed at the agent's prompt shows with its next
  report.** Neither Claude Code nor Codex reports a mode change, such as
  Claude Code's Shift+Tab, when it happens. The header shows the new mode
  once the next prompt, tool, or stop carries it, and a new Claude Code
  session shows its mode from its first prompt. A Codex model change shows
  the same way; Claude Code reports its model changes at once.
- **An effort shows late.** Claude Code reports its effort with a tool or a
  stop, so a new session shows it from then on. No Codex hook reports it, so
  the header reads it from the session's rollout as a turn ends. A change made
  at the prompt shows the same way, and a new model shows no effort until the
  agent reports one for it.
- **A resumed Claude Code session shows its model late.** Claude Code does not
  name the model when a session resumes, so the header reads it from the first
  answer as that turn ends. An answer does not say whether the session uses
  the 1M context window, so the header leaves "1M" out until the model is
  switched.
- **Codex's header says only whether it asks.** Codex reports two modes to
  its hooks: one for an approval policy that never asks, which the header
  warns of as **Runs without asking**, and the default for every other
  policy. Its sandbox is not reported, so the header does not say what the
  agent may write.

## Plan usage

- **Claude Code's usage is only as fresh as its last reply in Weir.**
  Claude Code gives it to its status line and nowhere else, so Weir sees it
  when a Claude Code session in a Weir pane replies. Use in another
  terminal or on claude.ai counts toward the plan but reaches the panel only
  with the next reply in Weir.
- **Claude Code's usage needs a status line of your own.** Claude Code keeps
  a row for a status line even when it prints nothing, so Weir takes the
  slot only when you have set one up, and runs yours in it.
- **A status line your organization sets through managed-settings drop-in
  files or a device management profile is not seen.** Weir reads
  `managed-settings.json` itself, and otherwise runs the status line from
  your own settings in its place.
- **One Claude Code account at a time.** Sessions with different
  `CLAUDE_CONFIG_DIR`s write the same record, so the panel shows whichever
  answered last.
- **Codex's usage is read for the account in `~/.codex`.** Weir asks
  Codex from its own environment, so a `CODEX_HOME` your shell sets for
  another account does not reach that request, and the panel shows the
  default account, or no plan when that one is signed out.
- **Claude Code's per-model weekly limits and extra usage are not shown.**
  Its status line carries only the 5-hour and weekly windows.

## Codex

- **A failed Codex turn shows as failed up to ten seconds late.** Codex runs
  no hook when a turn fails (an error from the server, a model it does not
  have, the plan's usage limit), so Weir reads the failure from the
  session's rollout, which it checks every ten seconds.
- **A resume inside your own tmux is judged by what tmux says.** If your
  shell starts tmux at its prompt, or the pane was inside tmux when Weir
  quit, the resume Weir types runs inside that tmux. Codex reports nothing
  until its first prompt, so at the 45-second deadline Weir asks your tmux
  server what is running in the pane its client shows. If the server does
  not answer within half a second, or Weir has not yet matched the client
  to the pane, Weir treats the resume as successful. A resume that failed
  there then lists no stop, and only the terminal shows why.
- **A stop stays over a Codex you start by hand until its first prompt.**
  Starting an agent again in a stopped pane ends the stop once the new
  agent reports to Weir. Codex reports nothing until its first prompt, so
  until then the pane still shows the stop.

## Antigravity

These describe the Antigravity CLI (`agy`) 1.4.12.

- **Weir places a plugin in `agy`'s own folder.** `agy` takes no hooks on its
  command line, so the first `agy` run in a Weir pane places one at
  `~/.gemini/config/plugins/weir`, marked by a `.weir-managed` file. A folder
  there without the mark is left alone, and `agy` then reports nothing to Weir.
  The plugin does nothing outside a Weir pane. `agy plugin disable weir` stops
  the reporting. So does removing the folder, until the next `agy` run in a
  Weir pane places it again.
- **No approval card.** `agy` has no permission hook, and its `PreToolUse`
  runs before its policy decides. A card there could appear for an action `agy`
  would not ask about, or let through one it should ask about. So `agy`'s own
  prompt asks, and Weir shows only that it waits. Its questions are answered in
  the terminal too.
- **Inside your own tmux, some of this does not show.** `agy` reports its
  status to the terminal only outside tmux. Inside tmux, a permission prompt
  does not show as a wait, and a stopped generation or a canceled question stays
  at work until your next prompt. Weir never hosts `agy` in tmux, so this
  takes a tmux you started yourself.
- **Its hook always succeeds, whatever happens in Weir.** `agy` fails the tool
  on anything but exit status 0 with valid JSON, against its documentation, and
  its model retries the call. So a Weir problem shows as a run that reports
  nothing, never as a failing tool. A `git worktree add` aimed at another
  folder reaches the agent as a refusal that gives the command to run instead,
  so it costs a model request, and a model that does not follow it makes no
  worktree.
- **A stop is read from `agy`'s status report.** Esc, Ctrl+C, and "No" at its
  prompt send no hook, so the turn ends when `agy` reports itself idle, and
  "No" reads as interrupted, not as declined. A command refused with "No" is
  left out only if `agy` has written the refusal when Weir reads the turn, and
  `agy` does not always write it in time. Otherwise the command stays with no
  result, so a refused test shows as a test with no pass or fail mark. Its usage
  and commands end at your next input, however late the report comes.
- **`/compact` shows no state of its own.** `agy` has no hook for compaction,
  and stopping one with Esc sends none either, so a state for it could never
  end. `/compact` with a message goes on to answer it, and is recorded as an
  ordinary turn.
- **Subagents' calls are not shown.** A subagent's tools do not appear in the
  row. A turn `agy` begins itself, when a background command ends or a subagent
  reports back, is recorded as a turn with no prompt.
- **A subagent's wait does not always show, nor its work after the turn.** A
  subagent waiting for approval shows as a wait in some runs and not in others.
  `agy` shows it as Blocked, and `ctrl+k` there approves it. Weir also does not
  report a subagent still running after the turn ends, because `agy`'s
  `fullyIdle` is false for a pending `schedule` timer too, and no report says
  when either ends.
- **A turn that uses a subagent shows at least what it used.** Weir reads only
  the parent's transcript, so the turn's tokens exclude the subagent's and are
  marked as partial.
- **A failure before the first request has no words.** Started offline, for
  one, `agy` sends no hook and only reports an error to the terminal. Weir shows
  the run as failed until `agy`'s next report, without the reason, since the
  report's message does not reach it. `agy`'s own screen says why.
- **A usage limit is read from the words of the failure, and no real limit has
  been seen.** `agy` gives the failure only as text, so Weir takes words like
  "exhausted your quota" as a limit and reads the reset from "reset after
  3h0m0s". Those words come from `agy`'s program and a 429 we relayed ourselves,
  not from a real limit. A real limit in other words shows as an ordinary stop,
  with no "Notify When It Resets". A limit with no readable time shows without
  one.
- **A lost connection records two failures.** `agy` sends its request once more
  by itself after the failure, so Weir records two failures, one of them a turn
  with no prompt, and notifies of a stop twice. The run shows as running during
  the retry, about four and a half minutes.
- **With the plugin disabled, a run sits at rest.** Weir records each launch
  itself, so after `agy plugin disable weir` the run still shows, and only
  `agy`'s status reports move it: no turns, no tool, no prompt.
- **Plan usage needs a status line of your own.** It comes only from the
  status line, as for Claude Code, and is as fresh as `agy`'s last reply in
  Weir. Only the weekly Gemini limit (`quota.gemini-weekly`) is shown. A launch
  that passes `--settings` itself shows no usage, because `agy` takes that flag
  once.
- **No permission mode in the pane header.** `agy` does not report it, so
  neither the mode nor the **Runs without asking** warning shows.

## OpenCode

These describe OpenCode 2.2.5.

- **Weir places a plugin in OpenCode's own folder.** The first `opencode` run in a
  Weir pane places one at `~/.config/opencode/plugins/weir` (or in `plugins/weir`
  under `OPENCODE_CONFIG_DIR` when that is set), marked by a
  `.weir-managed` file. A folder there without the mark is left alone, and OpenCode
  then reports nothing to Weir. The plugin does nothing outside a Weir pane. It relies
  on an interface API OpenCode may change. If part of it is gone, the plugin does
  nothing, and the pane is an ordinary, unwatched OpenCode.
- **Only the interface is watched.** `opencode run`, `serve`, `acp`, and `mini` go
  straight through, and a launch with `--server` goes unwatched, since that server's
  folders are not this Mac's to snapshot.
- **A turn may have no start.** Weir saves a turn's start at the Enter that sends the
  input, or, for a `--prompt` launch, before OpenCode starts. A slash command chosen
  from its menu (where Enter picks the command), a rebound submit key, and a turn the
  agent goes on to by itself come with no saved start, and show no change summary or
  Restore Code. A slash
  command typed out, the menu closed, goes through Enter like any input. So does a save that takes over ten
  seconds, in a very large repository, which sends the input anyway. A restore in the
  moment between Enter and the turn's start is not noticed, and that turn's change
  summary then counts it.
- **Closing a pane or quitting stops what this pane began, unless the process is
  killed.** Closing the Weir tab sends `SIGHUP`, and Ctrl+C or `/exit` runs the plugin's cleanup;
  either way the plugin ends the turn's record as stopped at once, so the pane shows no
  failure, and asks the service to stop the executions this pane began, waiting up to two
  seconds. A later input another pane sent to the same session is that
  pane's. `SIGKILL` or a crash of the interface leaves every session of the pane running on
  the service with nothing watching, which is OpenCode's own behavior. Weir shows each that was
  at work as stopped, though it may not have.
- **The service can restart unfinished work.** When OpenCode's service starts, it
  takes up any execution that never finished, and a command in it can run again. That
  is OpenCode's own recovery, and it runs outside Weir.
- **A command run outside any interface's session gets the service's environment.**
  Weir keeps its own variables out of the interface, and so out of a session it shows and
  of a service it starts. A service started earlier some other way keeps what it had,
  which reaches only a session no interface has shown.
- **Each tab is watched as its own session, and shares one working tree.** Every session
  tab this pane has to do with gets a run of its own, so a wait, a failure, or a finish
  behind the tab on screen is not lost. Sessions running at once in one tree each count the
  other's edits in their changes, as Git cannot say whose an edit was, and restoring such
  a turn takes the other's edits back too.
- **The pane's badge shows one state.** With several sessions in a pane, the bar's badge
  shows the most urgent of them. Each still has its own row in **Needs Attention**.
- **Which tab is on screen is read twice a second.** Moving between tabs sends no event,
  so the header and what counts as seen can be up to half a second behind, plus the hook
  that writes it, longer while its record is busy. One that cannot be written is tried
  again ten times, then every half minute until it is.
- **The home screen is no session.** Until a new tab has its first input, the header goes
  on naming the session before it, though nothing counts as seen and **Review** will not
  paste there.
- **Going to a session brings its tab forward, a moment later.** ⌘J, the decision bar, a card's **Show Tab**,
  and a notification ask OpenCode's interface for the tab, which looks about ten times a
  second and opens one closed since. A request older than three seconds is ignored, so
  it cannot pull you away from where you went since.
- **Review confirms its conversation just before pasting, not as it pastes.** It asks
  OpenCode's interface to bring the conversation forward and what is on screen, up to
  four seconds, and refuses rather than paste into another one. The paste follows a read
  milliseconds old. Switching tabs inside those milliseconds still sends it to the tab you went to.
- **Closing one of OpenCode's tabs does not stop its execution.** That is OpenCode's behavior. Its turn
  ends when it ends, and it still stops when you close the pane. A closed tab holding a
  question stays a wait until you go to it, which opens the tab again.
- **The tab bar is OpenCode's across all its windows.** Two panes running OpenCode list
  the same tabs, and closing one closes it in both. Opening another pane's session here
  gives it a run in this pane too, which shows it at rest while that pane works.
- **Approvals show in both places.** The approval card appears and OpenCode's own
  prompt stays up, and answering one withdraws the other. A request from a tab behind the
  one on screen waits there; going to it, or **Answer in terminal**, brings its tab forward.
  **Allow always** is only at
  OpenCode's prompt. Its questions are answered in the terminal. A native approval
  needs the approval service, as for the others.
- **A slash command or a rebound key is told apart by a recent key press.** An input
  that does not come through Enter counts as this pane's when a key was pressed here in
  the last three seconds and the pane showed that session before it. Two panes on one
  session could be mixed up in that moment.
- **An input sent while a session works joins the turn that is running.** OpenCode
  delivers it, sent with Enter or queued, into the execution under way, and starts no
  execution of its own for it. That turn, and its change summary, belong to the pane
  that started it, even when another pane sent the input; the pane that sent it records
  no turn.
- **Runs without asking shows for `--auto`.** OpenCode's `--auto` approves whatever a
  permission does not deny, and the header warns of it. `session.permissions` set to
  auto-accept in a config file does the same, but a plugin cannot read OpenCode's config,
  so that one shows no warning.
- **`/undo` and `/redo` make no turn.** OpenCode reverts files outside any turn, so the
  turns before keep their changes as recorded, undone edits included, and so does the
  range of changes not yet viewed.
- **Switching agent between turns shows at the next step.** The header names the agent
  (`build`, `plan`) from the first step of the next turn, not when you switch.
- **Enter waits for the turn's start.** If the prompt or the session on screen changes
  in that moment, nothing is sent, and a notice asks you to press Enter again.
- **No plan usage, cost, or context share.** The plan's limits belong to whoever serves
  the model, not to OpenCode, so **Plan Usage** has no OpenCode section. A cost of 0 in
  its reports can mean free, unpriced, or not reported, so Weir shows none. Tokens are
  the sum of each step, a subagent's and an automatic compaction's included; a title's
  are not.
- **Your data goes where its model is.** OpenCode's free models may use what they
  receive to improve the model (its [Zen documentation](https://opencode.ai/docs/zen/)
  has the list), and `OPENCODE_DISABLE_FREE_MODELS=1` hides them. Review pastes repository
  content into the pane's agent, which sends it to whatever model that agent runs.
- **A limit is read only from what OpenCode names.** Its error's type says which limit
  it is, and the reset comes only when it gives a delay. Only its free tier's limit
  has been seen for real; the others come from its source. A limit on a model or a
  service marks no other row, and its stop offers **Resume** rather than **Notify When
  It Resets**, since you can go on by changing model. (Claude's weekly limit of one
  model keeps the notification.) A rate limit that OpenCode gives up on is an ordinary
  stop.
- **The name of a session follows OpenCode's.** OpenCode names a session a moment after
  it begins, and renames it as it likes; Weir takes each name as it is given, between
  turns too, for a session this pane has to do with.
- **No worktree placement.** The interface cannot stop or change a tool before it runs,
  so an agent's `git worktree add` runs as written, in the folder it names, and the
  project's placement is not applied. When the command is a plain
  `git worktree add -b <branch> <folder>` and nothing else, it exits 0, and that folder is
  the one the placement gives the branch, the project's bootstrap runs afterward. In any other folder it does not run, and the sidebar lists
  that worktree the next time Weir refreshes the project's worktrees, for instance when
  Weir comes back to the front. A subagent's `git worktree add` gets no bootstrap either,
  as only the session's own tools reach Weir. Project Settings has no switch for OpenCode
  under Agent Worktrees, as there is nothing to route; a note there says why, and that its
  worktrees get the setup only in the project's location.

## For contributors: not yet confirmed on a real machine

These need a signed approval service, sleep, or physical input that the
automated checks cannot provide. They still have to be checked by hand:

- that each agent's own prompt, after an update, still behaves as described
  under "Claude Code shows its own prompt while Weir holds its request"
  above (last checked with Claude Code 2.1.316, Codex 0.166, and OpenCode
  2.2.5);
- the warning shown when the held approvals near their limit of 128;
- the time left after the Mac sleeps and wakes;
- whether locking the screen or switching users stops a pane from counting as
  seen;
- which pane counts as seen with splits, zoom, and tmux;
- a hidden full-screen window's Space, Stage Manager, several displays, and
  ⌥⌘W;
- that an ad-hoc signed Debug build leaves every approval to the agent's own
  prompt, as described above;
- a full pass through the window by keyboard alone with VoiceOver.
