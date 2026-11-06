# ADR 0005: Agent verification surface

- Status: Accepted.
- Date: 2026-11-03.
- Amended by: [ADR 0006](0006-keys-posted-to-a-background-run.md), which lets a
  check post named keys to a background run.
- Amended: 2026-11-03. Rewritten as a record of the decision. How the channel
  works moved to [`docs/verification-channel.md`](../verification-channel.md).
  The App Intents layer that the first revision (merged in #283) planned is
  withdrawn (see "Withdrawn"). The rest of the decision is unchanged.
- Amended: 2026-11-04. Added what the channel may answer for the person
  ("Answering for the person"), and which changes keep the protocol marker.
  The decision is unchanged.
- Amended: 2026-11-06. The person's data that a run refuses includes their
  user defaults, which macOS keeps by bundle identifier whatever the run's
  home. The decision is unchanged.

## Context

Coding agents checked a change to Weir by driving the real app with a
desktop-control tool. Its background mode acts on one app without taking over
the person's display, and on Weir it failed in two ways. Letters typed into a
terminal pane did not show, and a menu a check needed would not open. Its
fallback is full-screen control, which takes the whole display for the length of
the check. Several sessions run checks at once, so the display is taken often.

No Apple API drives an arbitrary app's UI in the background within the same
login session. XCUITest activates the app and needs keyboard focus for
`typeText`. `CGEventPostToPid` does not guarantee delivery to the right
responder. Accessibility actions cover only what an element exposes, and our
terminal surface exposes no writable text. Other terminals solve this inside
the app: a scripting API over a socket authenticated by a cookie or a
password, a command line that sends text to a pane, or an AppleScript
command that types into one.

A spike on 2026-11-03 sent key events with `CGEventPostToPid` to a Debug
build that ran in the background with its window covered:

- Every letter reached the terminal, and Return ran the line. The pane showed
  nothing, because `SurfaceRegistry.updateOcclusion(visibleIDs:)` stops
  drawing every surface that is not on screen.
- With the panes kept drawing, a ScreenCaptureKit capture of the covered,
  inactive window showed the command and its output. The SwiftUI parts of the
  window drew and captured correctly; only the window chrome showed its
  inactive look.

So the loss was in drawing, not in input.

## Decision

We make a Debug build verifiable through a channel inside the app, which an
agent drives from Bash. The rules below are the decision; the protocol, its
operations, and its limits are in
[`docs/verification-channel.md`](../verification-channel.md).

- **Never in Release.** The channel compiles only under
  `DEBUG && WEIR_AUTOMATION`. `scripts/check-release-archive.sh` fails a
  Release binary that contains the protocol's marker or the channel's type
  names.
- **Off unless asked for, and never on the person's data.** `WEIR_AUTOMATION=1`
  turns it on. A run with the channel on refuses the person's `Weir Dev/`
  data and user defaults, and leaves the approval service's registration
  alone.
- **Who may connect.** A client that reaches the run's Unix socket and presents
  the random token kept in the run's private folder. The token is not in the
  environment of the panes, because the agent under test runs there and has no
  business driving the app around it. Another process of the same user can read
  the token. We accept that: the boundary is that the build is Debug, the
  channel is opted into, and the run's data is not the person's.
- **Off the main actor, then on it.** Socket work runs on a queue of its own.
  Only the main actor resolves a target and acts, and no code off it touches
  app state or a terminal surface.
- **An operation does what a person's control does.** It calls the code the
  app's own control calls, reaches nothing a person could not reach in the
  app's windows, names its pane and window exactly, and replies `done` only
  for what it did.
- **Typing into a pane is running code.** A request names the agent and
  session it expects. It is refused when the pane runs something else, runs
  inside tmux, or holds an unsent draft of the person's. The checks run again
  before Return. What the channel types is marked as a draft, so the app's own
  commands do not type over it. Where an agent offers its own way to send a
  prompt to a named session, that is preferred.
- **Answering for the person.** An operation may press Allow once on the
  approval card, because the channel can already type any command, so the
  press gives it no new power. It names the approval by its ID, goes through
  the card's own resolve with its delay before a press counts, and acts only
  on a request whose command `state` has already shown. Allow on the paste
  confirmation stays the person's alone, because that confirmation is what
  keeps the channel's own `paste` from running lines in a shell. An operation
  may press only Deny there.
- **Menus are not opened.** A standard macOS menu tracks the real pointer and
  keyboard while it is open, so nothing from outside can open one. The
  channel runs the command a menu runs, as a command palette row, and changes
  a setting by its `settings.json` key.
- **The run keeps its panes drawing, and the client captures.** A channel run
  draws the panes of a covered window. The capture itself runs in the client,
  whose terminal already holds the Screen Recording grant. Weir asking for its
  own grant would put a system prompt in front of the person.
- **What the channel cannot show stays elsewhere.** Real key input, input
  methods, a menu opening on screen, and the active window's look stay a
  check in front, a manual check, or a check in a macOS virtual machine. The
  pull request says which. Visual iteration on a view uses SwiftUI previews
  and `ImageRenderer` in tests, not a running app.

### Adding an operation

An operation is added when a check needs it and nothing in the channel
reaches it, not ahead of need, and not by exposing every `WindowCommand`. In
order:

1. Use an existing operation, or a command palette row through `command`. A
   control a person uses that has no palette row may get one when the row
   helps people too; the channel then needs nothing new.
2. Otherwise add an operation that follows the rules above. It says what it
   returns when it cannot act (`failed` with a reason, `notObservable`,
   `timedOut`).
3. The operation lands whole, in one pull request: its handler, its client
   subcommand, a check against a real run, its row in
   [`docs/verification-channel.md`](../verification-channel.md), and the
   `verify-in-app` skill's steps when agents should use it.

A new operation keeps the protocol marker, because the client ships in the
same checkout as the app and an app without the operation answers it
`failed`. So do a new reply field, a new optional request field, and a new
refusal, which a client from before the change reads correctly or meets as
`failed`. Changing what an existing field or reply means moves the marker to
the next version, so a client from before the change is refused at `hello`
rather than misread.

### Withdrawn

The first revision of this ADR had a second layer: App Intents for opening
layers and reading a pane's state, projects and panes as `AppEntity` types,
View Annotations on the sidebar and the pane strip, and AppIntentsTesting in
a UI test target. It is withdrawn for three reasons:

- The intents it planned were to ship in Release, where any app the person
  allows can call them. That makes them a feature for people, to be decided
  as one. Test-only intents kept to Debug builds are possible, but they would
  be a second way in for operations the channel already has.
- View Annotations tell Siri and Apple Intelligence what is on screen. They
  drive nothing a check needs. The revision also said they need macOS 27, but
  `appEntityIdentifier(_:)`, `appEntityUIElements(_:)`, and
  `NSView.appEntityUIElementProvider` are macOS 15.4 and later. Only
  AppIntentsTesting needs macOS 27.
- AppIntentsTesting is XCTest-based and would add a UI test target, a scheme,
  and a signing condition for checks the channel already makes.

If Weir adds App Intents as a feature, that decision gets its own ADR.

## Consequences

- An agent can send a prompt to a pane, open a layer, run a command, and read
  the result without taking over the display.
- A channel operation proves that an action does what it should, not that the
  menu item or shortcut reaches it. Menu wiring keeps its own tests.
- The channel is a second way to type into a pane. Its checks are its own;
  the person's typing keeps the paste confirmation and draft handling it had.
- The channel is code that ships in every Debug build, with a client and a
  check of its own (`make check-automation`) to keep in step with it.

## Alternatives considered

- **Full-screen computer use.** It works and covers real input, but it takes
  the display and serializes every check.
- **Synthetic events from outside (`CGEventPostToPid`, or the private
  SkyLight variant).** Letters reached the pane in the spike, but each is a
  key code of one keyboard layout. An input method in a composing mode can
  hold it as marked text. It needs the Accessibility grant, and nothing says
  when it took effect or whether it reached the pane the caller meant.
- **An AppleScript dictionary.** It ships in Release, and it puts shell input
  behind a permission the person may grant once and forget. It has no natural
  way to wait for an outcome.
- **XPC with a code signing requirement.** This is the strongest peer check,
  and the one `AgentIntegrationService` uses. It needs signed clients, which
  ad-hoc Debug builds and agents' shells are not. It is worth revisiting if
  the channel ever ships beyond Debug.
- **A URL scheme.** It brings the app to the front and is reachable from any
  web page.

## References

- [`docs/verification-channel.md`](../verification-channel.md).
- [`.agents/skills/verify-in-app/SKILL.md`](../../.agents/skills/verify-in-app/SKILL.md).
- [Apple, Providing contextual cues to Apple Intelligence and Siri](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri).
