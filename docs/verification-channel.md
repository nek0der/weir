# Verification channel

A Debug build of Weir can be driven from outside through a local socket, so a
coding agent can check a change in a real run without taking over the
person's display. [ADR 0005](adr/0005-agent-verification-surface.md) says
why it exists, what it may and may not do, and how an operation is added. This
document says how it works today and changes with the code. The procedure an
agent follows is the `verify-in-app` skill
(`.agents/skills/verify-in-app/SKILL.md`).

## Exclusion from Release

`project.yml` sets `WEIR_AUTOMATION` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
for Debug only. Every file of the channel is wrapped in
`#if DEBUG && WEIR_AUTOMATION`, and so is the one call that starts it.

The protocol's handshake carries a marker that appears nowhere else,
`weir-automation-protocol/1`. `scripts/check-release-archive.sh` fails when
the Release binary contains the marker, whatever its version, or the
channel's type names, and `scripts/test-check-release-archive.sh` keeps a
fake archive that contains the marker. Operation names such as `state` are
common words and are not checked.

## Turning it on

The channel is off by default even in Debug. `WEIR_AUTOMATION=1` in the
launching environment turns it on. A run with the channel on refuses to use
the person's `Weir Dev/` data: it requires `WEIR_DEMO=1` or a
`CFFIXED_USER_HOME` that is not the real home, so an automated check never
writes the session the person is using. Like the demo, it leaves the
approval service's registration alone, which is one per user and would
otherwise be replaced by this build's.

A run with the channel on also refuses the build's own bundle identifier.
macOS keeps an app's user defaults by bundle identifier under the account's
own `~/Library/Preferences`, whatever `CFFIXED_USER_HOME` says. Under
`com.nekoder.Weir.dev` the run would read and write the person's defaults:
the language they picked, and what AppKit and Sparkle keep there.
`scripts/weir-automation.py launch` therefore starts a copy of the build in
the run's home, an APFS clone signed again ad hoc, whose identifier is
`com.nekoder.Weir.automation-<first 8 hex digits of the SHA-256 of the
home's path>.dev`. The app refuses the channel under any identifier that does
not start with `com.nekoder.Weir.automation-`
(`AutomationChannel.automationBundlePrefix`).

Each home has its own defaults domain under that identifier, and the `.dev`
suffix keeps every Debug rule: the `Weir Dev` data folder, no automatic update
checks, and hook links of its own. The domain lives in
`~/Library/Preferences` and outlives the home. A run that finds no
`automation-defaults` mark in its data folder empties the domain before
anything reads it (`AutomationDefaults`), so a home made again starts empty.
`make check-automation` deletes its home's domain, and takes the copy out of
Launch Services, when it removes the home. A run in a home named with
`--home`, or one kept with `--keep`, leaves its domain's plist in
`~/Library/Preferences`, where the next run in that home finds it. The
launcher makes the copy again when the build has changed, and refuses while a
run of the old copy is still open.

`quit` takes the copy out of Launch Services, which `open` added it to, so it
is not offered as an app for folders. A copy started outside the channel
anyway, by Relaunch, Spotlight, or Finder, has none of the launch's
environment and would open the person's `Weir Dev/` data, so it quits at once
(`AutomationChannel.isCopyOutsideTheChannel`).

The copy's identifier is one the person never allowed to post notifications,
so a channel run asks for no permission, which would put a system prompt in
front of them. It posts no banners; its notifications still reach the history.

`CFFIXED_USER_HOME` moves Weir's own data only. The shells and agents in the
run's panes still have the real `HOME`, so what they read and write (agent
settings, history, the repository) is the person's.

## Where it listens and who may connect

- Each run makes `$TMPDIR/wa/<first 8 hex digits of the run UUID>/` with
  mode 0700, inside a base it refuses unless that base is this user's and
  private. The path stays short because a Unix socket path is limited to 104
  bytes, which `$TMPDIR` (about 49) with a full UUID, or an Application
  Support path, can exceed.
- The socket is created there with mode 0600. A token from
  `SecRandomCopyBytes` is written next to it with mode 0600 through
  `SecureFileWrite`, along with `info.json` (run UUID, process ID, socket
  path, protocol marker, and the launcher's nonce).
- The token is not put in the environment of the panes' processes. The agent
  under test runs in those panes and has no business driving the app around
  it. A caller reads the token from the run's folder.
- On quit, Weir removes the folder only after checking that `info.json` still
  names its own process ID. A folder whose process is gone is removed by the
  next run that finds it.
- A process of the same user can read the token. Neither the token nor the
  file modes keep it out. The boundary is that the build is Debug, the
  channel is opted into, and the run's data is not the person's.

## Concurrency

Socket accept, reads, framing, and token checks run on a queue of their own,
never on the main actor, which would stall the UI the caller is waiting on.
A request is decoded into a value and handed to the main actor; the main
actor resolves its target, checks it, acts, and hands back a value-typed
result. No code off the main actor touches `AppState`, `SurfaceRegistry`, or
a `SurfaceView`. `SurfaceView.surface` being `nonisolated(unsafe)` is for
`deinit` and is not a license to call it from the queue.

Limits: a message is at most 64 KiB, a run accepts at most 4 connections, a
`wait` waits at most 30 s, and a dropped connection cancels its pending
requests. A typing request waits behind the pane's earlier ones without a
limit of its own; the client gives up on any reply after 60 s.

## Identity and revisions

- A pane is named by `runID`, `paneID`, and a generation that
  `SurfaceRegistry` increments whenever a different view is registered
  under the pane ID. The generation is not persisted and does not change
  `Tab` or `SplitTree`. A request whose triple no longer matches is refused.
  It counts views, not terminals: a Retry that makes a new terminal in the
  same view keeps the generation, and the expected process is what catches
  the new shell.
- The main actor counts the changes the channel itself made (a layer
  opened, text typed, a Return sent, a command run, a setting changed, the
  keyboard moved), and every reply carries that count.
- Every request carries an ID its reply repeats; the client checks it.

## Operations

The wire protocol is its own list of operations, not `WindowCommand`
serialized. Each maps to code the app's own controls call, and each states
what it returns when it cannot act.

| Operation | Effect |
|---|---|
| `hello` | Checks the token and the protocol marker. Every connection starts with it. |
| `state` | Projects, and per window its open layers and the tabs of the worktree it shows, with each pane's identity triple, agent state, and foreground process. Per window also the dropdown open on the title bar or the pane strip (`dropdown`), whether a sheet or an alert is attached (`hasSheet`, which the channel cannot answer), whether the sidebar, the icon bars, and the Changes panel show, its review tab with the pane and the scope it compares, and what holds its keyboard (`keyboard`: a terminal pane, with its ID, one of Weir's own controls, or a sheet). While Settings is open, `settings` names the section it shows. `postedKeys` says where a key posted now would land (`window`), or why the app would drop it (`refusal`), and how many posted key presses its gate has seen and dropped so far. A field with no value is left out of the reply. |
| `open` | Opens Needs Attention, All Projects, the notification history, the keyboard shortcuts, the plan usage panel, or review of a named pane's uncommitted changes. Each but review opens through the palette row of the action that opens it, as `command` runs a row, so a layer whose row is disabled now (the plan usage panel with the icon bars hidden) is refused at once. Review is opened for the named pane, not for whatever the window has selected, in the window that shows that pane, and another pane's review already up does not count as open, for `open` or for `wait`. |
| `typeLine` | One line of text, with `submit` true or false. Same character rules as `typeAgentCommand(_:)`. |
| `paste` | Text that may span lines, through Ghostty's own paste action as review sends it. A program that asked for bracketed paste gets one block and nothing is submitted; any other program meets the paste confirmation, so its lines are not run unseen. |
| `submit` | Sends Return to a pane. |
| `wait` | Waits for a named outcome (see "Waiting"). |
| `capture` | Readies one window, or Settings with `settings`, for a capture and returns its window number (see "Capturing"). |
| `commands` | Lists the window's command palette rows (the menus' and the keyboard shortcuts' commands) with whether each can run now. |
| `command` | Runs one row by its ID, as the palette runs it. A row the palette shows disabled is refused, as its menu item would be. `newWindow` commits it as ⌘Return does, which opens another project's row in a new window. |
| `setting` | Reads one setting by its `settings.json` key (`font.family`), sets it through the settings store, or clears an optional one (`unset`). A key counts as known by what the app's own decoding does with a probe there, so a field the file keeps as unknown is refused, and a value is checked and normalized in full before the store takes it. A value the Settings control would refuse, or ask about first, is refused too: a narrower turn retention (Settings asks before it deletes records), a binding the Keyboard pane refuses, and a quick terminal hotkey its recorder refuses, each checked against the bindings before the change, as the recorders check. A change to `review.externalDiffCommand` has its smart quotes made plain, as the field makes them. |
| `focus` | Gives a pane the keyboard within its window, through the model as ⌘J does (which can change the selected tab and its zoom), without bringing the window or the app forward, so keys from outside the channel land there. |
| `quit` | Ends the run as Quit does, without its confirmation, which is a native alert raised above other apps that the channel could not answer. It refuses while agents run unless `force` is given, and answers No to a paste confirmation left up, since the app does not finish quitting under one. |

## Menus and settings

A standard macOS menu (a `Picker`, a `Menu`, a context menu, the menu bar)
tracks the real pointer and keyboard while it is open, so no request from
outside opens one (ADR 0005). The channel reaches what a menu does instead,
with two operations. `command` runs a command palette row, which is how Weir
names its commands: the keyboard shortcut actions, and the palette's project,
tab, and settings rows. Controls with no shortcut have rows of their own for
the same reason, which people use too: `newTab.<agent>` adds a tab running
the agent as the pane strip's "+" does, for the agents "+" offers (those
found on this Mac), `settings.section.<section>` opens Settings on a section,
`pane.moveToNewTab` moves the focused pane as the pane's ⋯ does, and
`view.toggleIconBars` hides or shows the icon bars as the View menu does.
`setting` changes a setting by its key in `settings.json`, through
`WeirSettings`'s own decoding, so a value the app would not read from the file
is refused, and so is a key the app does not know, which the file would keep
as an unknown field. Neither checks that a menu opens or that its item reaches
the command; that stays a check in front. A context menu item with no palette
row cannot be run through the channel.

## Typing into a pane

Typing into a pane is running code, so this is the operation with the most
rules, and it still cannot promise that text never reaches a shell.

- Requests to one pane run one after another. A request does not start
  until the previous one's Return has been sent or canceled, nor before a
  Return the app scheduled for its own command has landed.
- A request whose caller left before the main actor took it is dropped
  before it acts, and an operation that waits looks again before each
  change it makes.
- What the channel types or pastes is marked as a draft, as the person's
  typing is, so the app's own commands (the prompt cache panel's) refuse
  to type into it. The channel records the text as its own, with the pane's
  generation and the pane's last input from anywhere else; only the
  channel's `submit` (or the Return of its `typeLine`) may send it, and the
  record lapses as soon as the person types, sends, or drops anything
  there. The Return of a `typeLine` is held to the same record, so a line
  the person already sent from the keyboard does not get a second Return.
- A paste carries the receipt a review insert uses, whose settlement says
  whether the text reached the terminal. The text is recorded as the
  channel's inside that settlement, in the clipboard read that delivers it,
  so no key of the person's can be taken for part of it. It is `done`, and
  the channel's to submit, only once the text has reached the terminal; one
  refused is `failed`, and one still held by the paste confirmation after a
  second is `notObservable`, since only the person can answer that sheet.
- A request names the agent and, when Weir knows it, the agent's session it
  expects in the pane. It is refused when the pane's foreground process or
  session differs, when the pane runs inside tmux (whose client the channel
  does not resolve yet), when the pane holds an unsent draft of the
  person's, or when the pane's agent waits for the person to answer it (a
  permission, a question, or whether to trust the folder). Return in that
  question would pick an answer for the person, often the default one, and
  the text would be lost. Only an agent that reports the wait is caught: the
  Kiro CLI shows as at rest while it asks whether to trust a folder.
- The same checks run again just before the Return, on the agent state the
  app holds then. If they fail, the Return is not sent and the reply says
  the text was typed but not submitted. A wait the agent has reported but
  the app has not taken in yet is not caught.
- A process can still exit between a check and the write that follows. The
  reply reports what was checked and when; it does not claim more.
- A request reaches the terminal at once, as a fast typist's keys would. Text
  pasted into a shell before it is back at its prompt, while the command
  just sent is starting, can arrive with bracketed paste still on and show
  its brackets as text. A caller waits for the command to finish (a capture,
  or a file it writes) before the next paste.
- Where an agent offers its own way to send a prompt to a named session,
  that is preferred over typing.

## Waiting

`wait` takes an outcome and a timeout, and looks at the app every 100 ms on
the main actor. Outcomes are concrete: `layerOpen`, the named layer is open
in the window; `turnEnded`, the pane's agent was seen in a turn and is no
longer, or its state episode changed to one that ends a turn (finished, or
an error), which a turn that started and ended between two looks leaves.
That rule needs an episode known when the wait began: an agent's first
report after it (idle as it starts, as Codex's first hook says, or a
restored pane's "finished") changes the episode without ending anything
the wait saw start, so it does not count. Neither does a turn that ended
before the wait began, so an agent idle before the prompt is not mistaken
for one that finished it. A run waiting on an answer is in its turn, so a
wait over an approval times out. `typeLine` replies
only after its Return was sent or given up, so it needs no wait of its own.

A reply is one of `done`, `cancelled`, `failed` with a reason, `timedOut`,
or `notObservable` with a reason. A wait is `notObservable` when its window
is gone or its pane was made again; it reads the app's state, so a layer
open in a hidden or minimized window still counts as open. A capture is
`notObservable` when the window is hidden or minimized. Only `done` is
success.

"Drawn" is not an outcome. SwiftUI and Ghostty draw on different schedules
and libghostty reports no frame completion. The run keeps its panes
drawing, and `capture` pauses before it hands back the window, so a caller
waits for the state it needs and then captures.

## Capturing

A run with the channel on keeps the panes of a covered, hidden, or minimized
window drawing (`WindowRegistry.keepsOffScreenPanesDrawing`), so a capture of a
covered window shows the terminal as it is. What counts as seen still follows
the screen, so unread marks and attention behave as they would.

`capture` never activates the app. It refuses a window that is hidden or
minimized, waits 150 ms for the last change to reach the window server, and
returns the window's number. With `settings` it does the same for the Settings
window, which is not a project window. The client then runs `screencapture -l`
with it. The capture runs in the client because the client's terminal already
holds the Screen Recording grant; Weir asking for its own would put a system
prompt in front of the person. The image shows the window's inactive chrome;
it is for checking content, not for the hero shot, which `screenshot.sh` keeps
taking in front.

## Client

`scripts/weir-automation.py` wraps the protocol so an agent can use it from
Bash. Its `launch` starts this checkout's Debug build with `open -g -n`
(behind the person's windows, as a run of its own), with the channel on,
Claude Code's own variables taken out of the environment, data in
`build/automation-home`, and a nonce the run writes into its `info.json`, so
two launches at once each find their own run. It returns once the run
answers hello, ends a run that never does, and prints the run with its
`bundleID`; `quit` ends
it. A run's data starts with no project, and Open Folder… asks through a
panel the channel cannot answer, so `launch --project FOLDER` hands folders
to the new run as Finder's Open With does, which opens each as a project,
and `launch --demo` starts the demo's projects instead (`WEIR_DEMO=1`, with
`--layer`, `--appearance`, and `--language` for its other settings). Both
leave the run behind the person's windows.

`keys` posts named keys and modifiers to the run with `CGEventPostToPid`
(ADR 0006): Esc, Return, Tab, the arrows, Home, End, and those with ⌘, ⇧,
⌥, or ⌃. It posts nothing that types text. Before each key it reads
`postedKeys` from `state` and posts only when that has no `refusal`: the
run shows one project window, and one of Weir's own controls holds its
keyboard, not a terminal pane, and no sheet or alert is up there, where
Return could answer for the person. Settings and the quick terminal must be
closed too, since a run behind other apps has no key window it can report
(`NSApp.keyWindow` is nil) and a key could land in them. The keyboard can
move between that read and the key's arrival, so the app checks each posted
key again as it arrives (`AutomationPostedKeys`, which tells one by the
marker the client sets in its source's user data). That check judges the
window the key is bound for by the same rule as `state` and drops a key
bound for a terminal pane, a window with a sheet up, the quick terminal,
Settings, or a window whose keyboard nothing holds; a terminal pane refuses
one too. The check counts the posted key presses it sees and drops. After
posting, the client waits until `seen` has grown by the keys it posted, or a
second at most, since a control's own monitor can take a key before the
check sees it (a dropdown's Esc), and fails when `dropped` grew. The counts say nothing of what a key
did, so the check reads its effect with `state` or `capture`. The terminal
that runs it needs the Accessibility grant.

`scripts/check-automation.py` (`make check-automation`) launches a fresh run,
checks the channel against it section by section, and quits it; `--keys`
adds the checks that need the Accessibility and Screen Recording grants, and
`--agents` those that start each coding agent (or those it names), each in
a pane of its own that is closed afterwards. The client finds the live
run under `$TMPDIR/wa` and refuses to guess when there is more than one
(`--run` names it), says hello with its token, and names a pane by a UUID
prefix, reading the run and generation from `state` first.

## Checking approvals in a signed run

A channel run leaves native approvals off (see "Turning it on"), so the
approval card's round trip is checked instead in a build signed with
`WEIR_DEVELOPMENT_TEAM` and started with `make run`, which has no channel.
A tool that acts on a background window through accessibility drives that
run, without full-screen control. What the pane does with each input:

| Input | Effect |
|---|---|
| One line set as the pane's `AXSelectedText` | Types it, the way Dictation's text arrives. |
| Several lines, or text with any control character, set the same way | Pastes it through Ghostty's own paste action. A program that asked for bracketed paste gets one block and nothing is submitted; any other program meets the paste confirmation when the text has a newline. Text with a character a paste refuses, such as an escape, is dropped whole. |
| A line break alone, set the same way | Presses Return. A tool may send its Return key this way. |
| A keystroke posted to the window | Reaches the pane, when the pane holds the window's keyboard. |
| A click on the approval card | Presses the button, as a pointer click does. |

Each write first commits any composition the person has open. None of this
passes the channel's checks; the `verify-in-app` skill says what to confirm
before each step.

## Not solved yet

- After `scripts/check-automation.py`'s commands section has split and closed
  panes, `focus` gives the remaining pane the keyboard and the keyboard is gone
  again within 0.3 s, and a second later the pane's view is out of its window.
  The same split, close, and focus in a fresh run do not show it, so the cause
  is not found yet; the check runs its keyboard sections first meanwhile.
- Whether a hiragana-mode input source turns keystrokes that a tool outside
  the channel posts to a run into marked text. Text set as a pane's
  `AXSelectedText` does not go through the input source.
- How to resolve the tmux client of a pane, so typing can reach an agent
  that runs inside tmux.
- Which agents offer a way to send a prompt to a named session, so typing
  can be avoided for them.
- Whether any menu needs a check that only opening it on screen can make.
- Which window a key posted to a run behind other apps lands in when it
  shows several, so `keys` could work there too. Until then it refuses.
- ⌘⏎ for the decision bar's primary action is read by the terminal pane that
  holds the keyboard, so `keys` does not post it; the action needs a palette
  row instead.

