# ADR 0005: Agent Verification Surface

- Status: Accepted. Layer 1 is implemented (plan steps 0 to 3); layers 2 and 3 are not.
- Date: 2026-11-03.

## Context

Coding agents verify a change to Weir by driving the real app. The tool they
use has a background mode that acts on one app without taking over the
person's display, and it fails on Weir in two ways:

- Letters it typed into a terminal pane did not show, so the agent concluded
  it could not send a prompt to an agent CLI running there. The spike below
  found that the letters do arrive; the pane stops drawing while its window
  is covered.
- It could not open a menu that a check needed.

The fallback is full-screen control, which takes the whole display from the
person for the length of the check. Several sessions run checks in parallel,
so the display is taken often.

No Apple API drives an arbitrary app's UI in the background within the same
login session. XCUITest activates the app and needs keyboard focus for
`typeText`; `CGEventPostToPid` does not guarantee delivery to the right
responder; Accessibility actions cover only what an element exposes, and our
terminal surface exposes a role and a label but no writable text. Other
terminals solve the same problem inside the app: a scripting API over a
socket authenticated by a cookie or a password, a command line that sends
text to a pane, or an AppleScript command that types into one (Ghostty 1.3's
`input text`).

What Weir has today, and its limits:

- `typeAgentCommand(_:)` types one line into a pane through `commitText(_:)`
  without a key event, then sends Return 120 ms later
  (`SurfaceView+AgentCommand.swift`). It refuses C0, DEL, and C1, so a
  newline or a tab is refused. A second call cancels the first call's
  pending Return but not its text. Its callers check the person's unsent
  draft and the agent's prompt state before calling
  (`PromptCacheRules.swift`, `AttentionState+PromptCache.swift`); the
  function itself does not.
- `window.commands.send(_:)` delivers a `WindowCommand` and returns whether a
  view took it, not whether the action finished (`WindowCommandChannel.swift`).
  Review, for one, returns once its `Task` starts. Not every action is a
  `WindowCommand`: Reopen Closed Tab and Close Pane call `TabActions` and
  `PaneActions` directly, and `WindowCommand.review` acts on the current
  selection rather than a named pane.
- A pane is a `UUID` leaf of `SplitTree`. `SurfaceRegistry` can register a
  new view under the same UUID, and there is no generation an outside caller
  could hold.
- `SurfaceRegistry.updateOcclusion(visibleIDs:)` stops the display link of
  every surface not on screen, so a terminal that is not visible does not
  draw new frames.
- `scripts/screenshot.sh` captures one window with ScreenCaptureKit, but
  activates the app first and refuses an image taken while another app is in
  front, because the window draws differently then.
- `Weir Dev/` is one Application Support folder shared by every Debug run.
  Only the test host gets a folder per run. The demo is isolated by
  `screenshot.sh` setting `CFFIXED_USER_HOME`, not by `WEIR_DEMO` itself.

### Spike results (2026-11-03)

We launched a Debug build in the background with its own data
(`CFFIXED_USER_HOME`), its window covered by other apps' windows, and sent it
key events with `CGEventPostToPid` from a script, with Google Japanese Input
as the selected input source. Temporary logging (since removed) recorded the
key path.

- Every letter reached `keyDown` with the window not key, the app not active,
  and the surface first responder. The input context consumed each one and
  committed it as text, and `keyDown` forwarded it to Ghostty. Return ran the
  line: `touch /tmp/…` typed this way created the file.
- The pane showed nothing, not even the shell's first prompt. The window was
  covered from launch, so `WindowOcclusionSync` reported it off screen and
  `SurfaceRegistry.updateOcclusion(visibleIDs:)` set every surface occluded,
  which stops Ghostty drawing.
- With the occlusion call forced to visible (a spike-only switch), the same
  background run typed `echo background ok`, ran it, and a ScreenCaptureKit
  capture of the covered, inactive window showed the prompt, the command,
  and its output.
- The rest of the window (SwiftUI) drew and captured correctly while covered
  and inactive. Only the window chrome shows its inactive look.
- libghostty has `ghostty_surface_draw(_:)`, a synchronous draw, so a capture
  can draw the panes it is about to capture once instead of keeping them
  awake. We have not tried it.

So the loss is in drawing, not input. The computer-use tool's own way of
sending keys was not tested, and how it behaves with a hiragana-mode input
source is unknown; the earlier session reported the symptom, not its cause.

macOS 27 adds View Annotations, which tie a view to an `AppEntity`, and
AppIntentsTesting, which runs intents end to end from a UI test bundle in a
separate process. CI builds with Xcode 26.6, whose SDK has neither.

## Decision

We will make Weir verifiable without the person's display through three
layers, each used for what it can prove.

### 1. A Debug-only verification channel

#### Exclusion from Release

`project.yml` sets `WEIR_AUTOMATION` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
for Debug only. Every file of the channel is wrapped in
`#if DEBUG && WEIR_AUTOMATION`, and so is the one call that starts it. This
lands with the first commit of the channel, not after it.

The protocol's handshake carries a marker that appears nowhere else,
`weir-automation-protocol/1`. `scripts/check-release-archive.sh` fails when
the Release binary contains the marker, whatever its version, or the
channel's type names, and `scripts/test-check-release-archive.sh` gains a
fake archive that contains the marker. Operation names such as `state` are
common words and are not checked.

#### Turning it on

The channel is off by default even in Debug. `WEIR_AUTOMATION=1` in the
launching environment turns it on. A run with the channel on refuses to use
the person's `Weir Dev/` data: it requires `WEIR_DEMO=1` or a
`CFFIXED_USER_HOME` that is not the real home, so an automated check never
writes the session the person is using. Like the demo, it leaves the
approval service's registration alone, which is one per user and would
otherwise be replaced by this build's.

`CFFIXED_USER_HOME` moves Weir's own data only. The shells and agents in the
run's panes still have the real `HOME`, so what they read and write (agent
settings, history, the repository) is the person's.

#### Where it listens and who may connect

- Each run makes `$TMPDIR/wa/<first 8 hex digits of the run UUID>/` with
  mode 0700, inside a base it refuses unless that base is this user's and
  private. The path stays short because a Unix socket path is limited to 104
  bytes, which `$TMPDIR` (about 49) with a full UUID, or an Application
  Support path, can exceed.
- The socket is created there with mode 0600. A token from
  `SecRandomCopyBytes` is written next to it with mode 0600 through
  `SecureFileWrite`, along with `info.json` (run UUID, process ID, socket
  path, protocol version).
- The token is not put in the environment of the panes' processes. The agent
  under test runs in those panes and has no business driving the app around
  it. A caller reads the token from the run's folder.
- On quit, Weir removes the folder only after checking that `info.json` still
  names its own process ID. A folder whose process is gone is removed by the
  next run that finds it.
- A process of the same user can read the token. Neither the token nor the
  file modes keep it out. The boundary is that the build is Debug, the
  channel is opted into, and the run's data is not the person's.

#### Concurrency

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

#### Identity and revisions

- A pane is named by `runID`, `paneID`, and a generation that
  `SurfaceRegistry` increments whenever a different view is registered
  under the pane ID. The generation is not persisted and does not change
  `Tab` or `SplitTree`. A request whose triple no longer matches is refused.
  It counts views, not terminals: a Retry that makes a new terminal in the
  same view keeps the generation, and the expected process is what catches
  the new shell.
- The main actor counts the changes the channel itself made (a layer
  opened, text typed, a Return sent), and every reply carries that count.
  Every request carries an ID its reply repeats; the client checks it.

#### Operations

The wire protocol is its own list of operations, not `WindowCommand`
serialized. Each maps to code the app's own controls call, and each states
what it returns when it cannot act.

| Operation | Effect |
|---|---|
| `state` | Projects, and per window its open layers and the tabs of the worktree it shows, with each pane's identity triple, agent state, and foreground process. |
| `open` | Opens Needs Attention, All Projects, the notification history, the keyboard shortcuts, the plan usage panel, or review of a named pane's uncommitted changes, through the code its own control runs. Review is opened for the named pane, not for whatever the window has selected, in the window that shows that pane, and another pane's review already up does not count as open, for `open` or for `wait`. |
| `typeLine` | One line of text, with `submit` true or false. Same character rules as `typeAgentCommand(_:)`. |
| `paste` | Text that may span lines, through Ghostty's own paste action as review sends it. A program that asked for bracketed paste gets one block and nothing is submitted; any other program meets the paste confirmation, so its lines are not run unseen. |
| `submit` | Sends Return to a pane. |
| `wait` | Waits for a named outcome (see below). |
| `capture` | Readies one window for a capture and returns its window number (see below). |
| `commands` | Lists the window's command palette rows (the menus' and the keyboard shortcuts' commands) with whether each can run now. |
| `command` | Runs one row by its ID, as the palette runs it. A row the palette shows disabled is refused, as its menu item would be. |
| `setting` | Reads one setting by its `settings.json` key (`font.family`), sets it through the settings store, or clears an optional one (`unset`). A key counts as known by what the app's own decoding does with a probe there, so a field the file keeps as unknown is refused, and a value is checked and normalized in full before the store takes it. |
| `focus` | Gives a pane the keyboard within its window, through the model as ⌘J does (which can change the selected tab and its zoom), without bringing the window or the app forward, so keys from outside the channel land there. |
| `quit` | Ends the run as Quit does, without its confirmation, which is a native alert raised above other apps that the channel could not answer. It refuses while agents run unless `force` is given, and answers No to a paste confirmation left up, since the app does not finish quitting under one. |

#### Adding an operation

An operation is added when a check needs it and nothing here reaches it,
not ahead of need and not by exposing every `WindowCommand`. A tab a person
picks by clicking it, for one, is reached today by `focus` on one of its
panes. In order:

1. An existing operation, or a command palette row through `command`. A
   control a person uses that has no palette row may get one when the row
   helps people too; the channel then needs nothing new.
2. Otherwise a new operation, held to the rules the others follow:
   - It calls the code the app's own control calls rather than setting the
     model around it, so a check exercises what a person's click does.
   - It reaches nothing a person could not reach in the app's own windows.
   - It names a pane by the identity triple and a window by its ID, and
     says what it returns when it cannot act (`failed` with a reason,
     `notObservable`, `timedOut`); it never replies `done` for what it did
     not do.
   - Anything that sends text to a pane follows the typing rules below.
   - It exists only in Debug builds, as the rest of the channel does.
3. An operation lands whole: with its client, a check against a real run,
   its row in the table above, and the skill's steps when agents should use
   it, so no part of the channel offers what another does not.

A new operation keeps the protocol marker: the client ships in the same
checkout as the app, and an app without the operation answers it `failed`
(the line is not a request). Changing what an existing operation does or
returns changes the marker to `weir-automation-protocol/2`, so a client
from before the change is refused at `hello` rather than misread.

#### Menus and settings

A standard macOS menu (a `Picker`, a `Menu`, a context menu, the menu bar)
tracks the real pointer and keyboard while it is open, so no request from
outside opens one, and macOS 27 and Xcode 27 add nothing for a Mac app here.
Other projects reach what a menu does instead: terminals run an action by
its keybinding name (Ghostty's `perform action`) or select a menu item by
its identifier and read whether it is enabled, and editors' tests run
commands by ID and change settings by key.

The channel does the same with two operations. `command` runs a command
palette row, which is how Weir names its commands: the 52 keyboard shortcut
actions, and the palette's project, tab, and settings rows. `setting`
changes a setting by its key in `settings.json`, through `WeirSettings`'s own
decoding, so a value the app would not read from the file is refused, and so
is a key the app does not know, which the file would keep as an unknown
field. Neither checks that a menu opens or that its item reaches the
command; that stays a check in front, and context menus whose items have no
palette row get an operation when a check needs one.

#### Typing into a pane

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
  does not resolve yet), or when the pane holds an unsent draft of the
  person's.
- The same checks run again just before the Return. If they fail, the
  Return is not sent and the reply says the text was typed but not
  submitted.
- A process can still exit between a check and the write that follows. The
  reply reports what was checked and when; it does not claim more.
- A request reaches the terminal at once, as a fast typist's keys would. Text
  pasted into a shell before it is back at its prompt, while the command
  just sent is starting, can arrive with bracketed paste still on and show
  its brackets as text. A caller waits for the command to finish (a capture,
  or a file it writes) before the next paste.
- Where an agent offers its own way to send a prompt to a named session,
  that is preferred over typing.

#### Waiting

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

#### Capturing

A run with the channel on keeps the panes of a covered, hidden, or
minimized window drawing (`WindowRegistry.keepsOffScreenPanesDrawing`),
which the spike showed is enough for a capture of a covered window to show
the terminal as it is. What counts as seen still follows the screen, so
unread marks and attention behave as they would.

`capture` never activates the app. It refuses a window that is hidden or
minimized, waits 150 ms for the last change to reach the window server, and
returns the window's number. The client then runs `screencapture -l` with
it. The capture runs in the client because the client's terminal already
holds the Screen Recording grant; Weir asking for its own would put a system
prompt in front of the person. The image shows the window's inactive chrome;
it is for checking content, not for the hero shot, which `screenshot.sh`
keeps taking in front.

#### Client

`scripts/weir-automation.py` wraps the protocol so an agent can use it from
Bash. Its `launch` starts this checkout's Debug build with `open -g -n`
(behind the person's windows, as a run of its own), with the channel on,
Claude Code's own variables taken out of the environment, data in
`build/automation-home`, and a nonce the run writes into its `info.json`, so
two launches at once each find their own run. It returns once the run
answers hello, ends a run that never does, and prints the run; `quit` ends
it.

`scripts/check-automation.py` (`make check-automation`) launches a fresh run,
checks the channel against it section by section, and quits it; `--keys`
adds the checks that need the Accessibility and Screen Recording grants, and
`--agents` those that start each coding agent (or those it names), each in
a pane of its own that is closed afterwards. The client finds the live
run under `$TMPDIR/wa` and refuses to guess when there is more than one
(`--run` names it), says hello with its token, and names a pane by a UUID
prefix, reading the run and generation from `state` first. An MCP adapter
can come later if it earns its place.

### 2. App Intents for what a person would also want

Operations that are safe for any caller become App Intents: open Needs
Attention, open a project or worktree, open review for a pane, and read a
pane's agent state. Projects, worktrees, and panes become `AppEntity` types.
On macOS 27, View Annotations tie the sidebar rows and the pane strip to
those entities.

These ship in Release. They never type into a pane, because an intent can be
called by any app the person allows, and typing into a pane is running code.

AppIntentsTesting runs in a separate UI test target and scheme, not in
`WeirTests`. It is XCTest-based, an exception to our Swift Testing rule that
CLAUDE.md will name. The app it launches gets an isolated data folder through
its launch environment, because the test host detection in `WeirPaths` does
not apply to a separate process. The tests run only when the test runner and
the app are actually signed by the same team, checked at run time rather
than inferred from `WEIR_DEVELOPMENT_TEAM` being set.

The macOS 27 APIs are not in Xcode 26.6's SDK, and `if #available` does not
make an unknown declaration compile. CI moves to Xcode 27 before the first
use, or the files that use them are excluded at compile time until it does.

### 3. Rendering checks without the app

Visual iteration stays out of the running app: SwiftUI previews rendered
through Xcode's MCP (`RenderPreview`), `ImageRenderer` in tests as
`DecisionBarRowFitTests` already does, and, as an addition, Swift Testing
image attachments so a failing test leaves the image it drew.

Real key input, input methods, and menus opening on screen are not covered by
any layer above. They stay a manual check, or a check in a macOS virtual
machine, and the PR says which.

## Consequences

- An agent can send a prompt to a pane, open a layer, and read the result
  without taking over the display. Checks of state and of content on screen move
  to the channel; checks of the active window's look stay in front.
- `open` proves that an action does what it should, not that the menu item
  or shortcut reaches it. Menu wiring keeps its own tests.
- The channel is a second way to type into a pane. Its checks are its own;
  the person's own typing keeps the paste confirmation and draft handling it
  has today.
- App Intents add user-visible strings, which need `en` and `ja` in
  `Localizable.xcstrings`, and entity queries that must stay cheap.
- A UI test target joins the project, with its own scheme and signing
  condition.

## Alternatives considered

- **Full-screen computer use.** Works today and covers real input, but takes
  the display and serializes every check.
- **Synthetic events from outside (`CGEventPostToPid`, the private SkyLight
  variant).** Letters reached the pane in the spike, but each is sent as a
  key code of one keyboard layout, an input method in a composing mode can
  hold it as marked text, it needs the Accessibility grant, and nothing says
  when it took effect or whether it reached the pane the caller meant.
- **AppleScript dictionary.** Clear for a few commands and gated by the
  Automation permission, but it ships in Release, puts shell input behind a
  permission prompt the person may grant once and forget, and has no natural
  way to wait for an outcome.
- **XPC with a code signing requirement.** The strongest peer check, and the
  model `AgentIntegrationService` uses. It needs signed clients, which ad-hoc
  Debug builds and agents' shells are not. Worth revisiting if the channel
  ever ships beyond Debug.
- **URL scheme.** Brings the app to the front and is reachable from any web
  page.

## Plan

Steps 0 to 3 are done.

0. Spikes, results above.
1. The channel skeleton with the Release exclusion and its archive check,
   the run folder and token, the queue and main-actor boundary, `state`,
   `open`, `wait`, and the CLI.
2. The pane generation, then `typeLine`, `paste`, and `submit` with
   per-pane ordering, and a test for each refusal.
3. `capture`, with the panes of a covered window kept drawing.
4. App Intents and entities, with AppIntentsTesting in its own target, run
   locally.
5. View Annotations, once CI builds with Xcode 27.

## Open questions

- After `scripts/check-automation.py`'s commands section has split and closed
  panes, `focus` gives the remaining pane the keyboard and the keyboard is
  gone again within 0.3 s, and a second later the pane's view is out of its window. The
  same split, close, and focus in a fresh run do not show it, so the cause
  is not found yet; the check runs its keyboard sections first meanwhile.
- How the computer-use tool sends keys, and whether a hiragana-mode input
  source turns its letters into marked text.
- How to resolve the tmux client of a pane, so typing can reach an agent
  that runs inside tmux.
- Which agents offer a way to send a prompt to a named session, so typing
  can be avoided for them.
- Which menu failed to open in the earlier check, so the menu case can be
  covered or knowingly left manual.
