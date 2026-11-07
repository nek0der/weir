# Contributing to Weir

This guide covers setup, verification, and pull requests for human
contributors and coding agents. Weir is in pre-alpha, and its APIs are unstable.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- For non-trivial changes, open an issue first to discuss the approach.
- For bug fixes and small improvements, a direct PR is fine.

## Setup

### Prerequisites

- macOS 26 (Tahoe) or later
- Xcode 26 with the Metal Toolchain component

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

- [Homebrew](https://brew.sh)
- [Node](https://nodejs.org), for the OpenCode plugin's tests in `make test`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), Zig 0.17.0, and Rustup

  ```bash
  brew install xcodegen zig@0.17 rustup
  export PATH="$(brew --prefix rustup)/bin:$PATH"
  ```

  The version of record is `minimum_zig_version` in
  `vendor/ghostty/build.zig.zon`. The build script reads it and runs the
  Homebrew Zig of exactly that version by its full path, so no `PATH` change
  is required. It looks in `/opt/homebrew/opt/zig@0.17/bin/zig` and in
  `/opt/homebrew/opt/zig/bin/zig`, because `zig@0.17` is an alias of `zig`
  while 0.17 is Homebrew's current release.

- [Mint](https://github.com/yonaskolb/Mint), for the `swiftformat` version
  pinned in `Mintfile` (`make fmt` / `make lint`)

  ```bash
  brew install mint
  mint bootstrap
  ```

- [SwiftLint](https://github.com/realm/SwiftLint), for `make lint`

  ```bash
  brew install swiftlint
  ```

  It is not pinned: CI installs Homebrew's current release the same way,
  and `make lint` runs whichever `swiftlint` is on your `PATH`.

### Build

```bash
# 1. Clone with submodules (Ghostty lives at vendor/ghostty)
git clone --recursive https://github.com/nek0der/weir.git
cd weir

# If you already cloned without --recursive, pull the submodules
# now — `make ghostty` fails on an empty vendor/ghostty/ checkout:
#   git submodule update --init --recursive

# 2. Confirm Zig 0.17.0 is installed (the build script only looks in
# Homebrew's opt paths, so a missing zig@0.17 yields a clear error
# rather than silently picking up a system Zig):
#   brew list --versions zig@0.17

# 3. Build libghostty as an xcframework (10–20 min on first run; cached after)
make ghostty

# 4. Install the Rust toolchain rust-toolchain.toml pins, then verify the
# workspace with it
rustup toolchain install
make rust-test

# 5. Generate the Xcode project
make xcodegen

# 6. Build + launch (Debug)
make dev
```

`make help` lists the common targets (`build`, `run`, `test`, `lint`, `dmg`, `screenshot`, `clean`, …).

You should see a Weir window with a working terminal pane (zsh by default), the Worktrees sidebar with that terminal on its Scratch row, and the pane strip. Weir logs the embedded libghostty version through `Logger` under the `com.nekoder.weir` subsystem (`log stream --predicate 'subsystem == "com.nekoder.weir"'`). What a terminal reports as it runs, such as its title, its directory, a bell, or a search, is logged at the debug level; add `--level debug` to see it.

> First-launch tip: a locally built Debug binary is ad-hoc signed, so macOS may quarantine it. Right-click the app and choose Open the first time.

### Native approvals in a Debug build

The approval service accepts connections only from executables signed with its own Team ID. A Debug build is ad-hoc signed by default, so it runs without native approvals, and Claude and Codex use their own permission prompts. To try native approvals, build with a signing identity that has a Team ID. The service accepts an Apple Development certificate, which a free Apple Account can create in Xcode.

Replace `YOUR_TEAM_ID` with the Team ID for your signing identity:

```bash
export WEIR_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
# Optional; the identity defaults to "Apple Development".
# export WEIR_CODE_SIGN_IDENTITY="Developer ID Application"
make dev
```

### Slowing the motion in a Debug build

`WEIR_SLOW_MOTION=<factor>` makes every animation in a Debug build `<factor>` times as long (`WeirMotion.pace`). Use it to step frame by frame through a recording of a surface as it opens. `open`, and therefore `make run`, does not pass the shell's environment on, so start the built binary directly: `WEIR_SLOW_MOTION=10 "<DerivedData>/Build/Products/Debug/Weir Dev.app/Contents/MacOS/Weir Dev"`. A Release build ignores the variable.

### Open in Xcode

```bash
make xcodegen
open Weir.xcodeproj
```

`Weir.xcodeproj` is generated and gitignored. Edit `project.yml`, never `project.pbxproj`. `make build` and `make test` regenerate it on their own when `project.yml` changes, or when a file under `Weir/`, `WeirTests/`, or `AgentIntegrationService/` is added, removed, or renamed. Run `make xcodegen` to force a regeneration.

### Changes to libghostty

Patch libghostty in the fork's `weir` branch, then bump the submodule reference
here. Do not edit `vendor/ghostty/` in place. Follow
[the fork maintenance rules](docs/libghostty-fork.md) for patch requirements
and removal conditions.

## Language policy

| Content | Language |
| --- | --- |
| Source code, comments, and doc comments | English. |
| `README.md` and `README.ja.md` | English and Japanese, respectively; update both in the same PR. |
| Contributor documents, including this guide, `SECURITY.md`, and `CODE_OF_CONDUCT.md` | English. |
| Documents under `docs/`, including ADRs | English. |
| Commit messages, PR titles, and PR descriptions | English. |
| Issues and discussions | English or Japanese. |
| All user-facing app strings, including labels, tooltips, alerts, and accessibility text | English and Japanese in `Weir/Resources/Localizable.xcstrings`. |

CI and `make lint` run `scripts/check-localization.sh`. It rejects translatable
keys without Japanese string units and any English or Japanese string unit
whose state is not `translated`. It also checks specific Japanese spelling
conventions, but does not establish whether the wording reads naturally;
review the wording as well.

## Pull requests

Read the [writing guide](docs/writing-guide.md) when writing comments,
documents, commit messages, or PR text, whether you write them yourself or use
an AI assistant. Follow the PR template for the required sections.

- Branch off `main`, and name the branch and the PR title as
  [Commit titles and branches](#commit-titles-and-branches) describes. Keep
  commits focused.
- Do not add `Co-Authored-By` trailers or AI attribution to commits.
- Code style: see [`AGENTS.md`](AGENTS.md) §3 for the conventions a linter can't enforce (file banners, naming, and code structure).
- `release-please` generates `CHANGELOG.md` from commit messages, so don't edit it by hand.

### Commit titles and branches

A pull request is squashed into one commit on `main`, and the commit takes
the PR title as its whole message. `release-please` builds `CHANGELOG.md`
from those titles, and the PR Lint workflow
(`.github/workflows/pr-lint.yml`) checks the type, the form of the scope, and
the first character of the subject. Titles follow
[Conventional Commits](https://www.conventionalcommits.org/) in the form
`<type>(<scope>): <subject>`, such as
`fix(session): preserve saved projects when decoding fails`.

| Type | Use it for | In `CHANGELOG.md` |
| --- | --- | --- |
| `feat` | A new capability for the person using Weir. | Features |
| `fix` | A correction to something the person using Weir can see, including wording, layout, and appearance. | Bug Fixes |
| `perf` | Less time or memory for the same behavior. | Performance |
| `refactor` | A code change that the person using Weir cannot see. | Refactors |
| `docs` | Documents: `docs/` with its ADRs, the READMEs, `site/` (the landing page and its documents), and the contributor and agent instructions (`AGENTS.md`, this guide, `.agents/skills/`, the PR template, and the writing guide). | Documentation |
| `build` | The build and the release: `Makefile`, `project.yml`, the build and packaging scripts, toolchain pins, and `.github/release-please-config.json`. | Hidden |
| `ci` | `.github/workflows/` and the CI configuration in `.github/`, such as `dependabot.yml` and `actionlint.yaml`. | Hidden |
| `test` | Tests, test fixtures, and the verification tools, with no change to the app. | Hidden |
| `chore` | Dependency updates, release pull requests, and maintenance that no other type covers. | Hidden |
| `revert` | A change that undoes an earlier commit on `main`. | Reverts |

The line between `fix` and `refactor` is what the person using Weir sees. A
change they can see is `fix`, or `feat` when it adds a capability, even when
it comes from restructuring code. `refactor` is only for changes with no
visible effect.

Name the branch `<type>/<short-description>` with the PR's type, such as
`fix/session-decode` or `ci/pr-lint-rules`. Branches that Dependabot and
`release-please` create keep their own names.

Choose the scope from the table below. A scope is lowercase, with hyphens
between words. A PR that adds a screen or a feature that no scope covers adds
its scope to this table in the same PR. The scope is optional when a change
covers its type's whole area, such as a change to every CI job.

| Scope | Covers |
| --- | --- |
| `agent` | Behavior shared by every agent, such as hooks, shims, turns, and agent state, and agents with no scope of their own, such as Antigravity and OpenCode. With `docs`, the contributor and agent instructions. |
| `claude` | Behavior specific to Claude Code. |
| `codex` | Behavior specific to Codex. |
| `app` | The app as a whole: launch, its name and icon, the `weir` command, and logging. |
| `approval` | Native approvals: the approval service, its protocol, and the approval card. |
| `changes` | The Changes panel and each turn's Changes card. |
| `confirmations` | The questions Weir asks before a close or a quit. |
| `core` | The Core and Domain modules. |
| `demo` | Demo mode and the hero screenshot. |
| `design` | Shared UI components, tokens, materials, and motion. |
| `ghostty` | The libghostty fork and its bindings. |
| `keyboard` | Shortcuts and key handling. |
| `l10n` | Localization. |
| `notifications` | Notifications. |
| `palette` | The command palette. |
| `persistence` | Weir's data files: how they are read, written, and recovered. |
| `quick-terminal` | The Quick Terminal. |
| `review` | The review of an agent's changes. |
| `session` | The saved workspace and its restoration. |
| `settings` | The Settings window. |
| `sidebar` | The Worktrees sidebar. |
| `supervision` | The main window: panes and tabs, the title bar, the rails, Needs Attention, and All Projects. The Changes panel has `changes`, and the approval card has `approval`. |
| `surface` | A pane's terminal: input, output, and what the shell reports. |
| `tmux` | Panes that run tmux. |
| `updates` | App updates through Sparkle. |
| `worktree` | Worktrees and the Git operations on them. |
| `site` | The website and the READMEs. |
| `support` | Test fixtures, the test host, and the verification channel. |
| `lint` | Linters, formatters, and the PR title check. |
| `release` | Archives, the dmg, the appcast, the bundled notices, and `release-please`. |
| `rust` | The Rust toolchain and the build of the Rust bridge. |
| `deps` | Dependency updates. |
| `main` | Release pull requests, which `release-please` titles itself. |

Earlier commits used scopes that are now folded into others:

| Earlier scope | Now |
| --- | --- |
| `chore(build)` | `build` or `ci`, by the files changed, with `release` or `rust` when one applies. |
| `chore(github)` | `docs(agent)` for the PR template, and `ci` for other files in `.github/`. |
| `docs(adr)` | `docs` with the scope of the area the ADR decides, or `docs(agent)` for rules that apply to every ADR. |
| `chore(site)` | `docs(site)`. |
| `docs(readme)` | `docs(site)`. |
| `domain` | `core`. |
| `glass` | `design`. |
| `layout` | `supervision`. |
| `log` | `app`. |
| `notices` | `release`. |
| `process` | `support`. |
| `screenshot` | `demo`. |

The subject follows these rules:

- Start with a lowercase verb in the imperative: `preserve`, not `preserves`
  or `Preserve`. An identifier with its own capitalization may come first in
  backticks, which keep its spelling.
- Aim for about 90 characters for the whole title, and keep it within 110.
- Do not end it with a period.

The [writing guide](docs/writing-guide.md#commit-messages-and-pull-requests)
covers the wording of the subject.

Mark a change that breaks compatibility with `!` after the type or scope, such
as `feat(settings)!: <subject>`. `release-please` treats the commit as
breaking from the `!` alone. The squashed commit has no body unless the person
merging adds one, so they add a `BREAKING CHANGE:` footer as its body, saying
what breaks and what to do, such as
`gh pr merge --squash --body "BREAKING CHANGE: <what breaks and what to do>"`.
The PR's Summary says the same.

Title a revert `revert(<scope>): <subject>` with the scope and subject of the
reverted commit, without its PR number. GitHub's Revert button titles the PR
`Revert "<title>"`, which the PR Lint workflow rejects, so retitle it. Name
the reverted PR in Related issue, such as `Reverts #123.`

### Before opening the PR

Choose the local checks below for the behavior and files changed. Combine
requirements when a change affects more than one area. These local checks
do not replace CI; every required CI check must still pass.

During development, start with tests closest to the changed behavior. Before
submission, complete the applicable checks below. Reuse passing results while
the source, dependencies, build settings, and relevant environment remain
unchanged. Committing, squashing, or starting a review without changing
those inputs does not require a rerun. Reassess the inputs after a rebase.

| Change | Required local checks |
| --- | --- |
| Repository prose only, including agent instructions and the PR template | Review wording, examples, relative links, and heading anchors. Compare instructions with the implementation. No app build or test suite is required for prose alone. |
| App code, tests, plugins, or resources, including Swift and Rust | Run `make build`, `make lint`, `make test`, and `make review-core`. The Debug build must have no warnings. |
| `site/` | Run `pnpm build` in `site/` and follow [the site guide](site/README.md) for language, layout, and procedure checks. |
| Scripts, workflows, or build configuration | Run the changed script's self-test, if one exists, and validate the affected command or workflow. App build or test tooling requires the app checks; site tooling requires the site checks. |

Add these checks when the change affects the corresponding area:

- **Site documents:** when a change affects what a site document describes,
  update `site/src/content/docs/` in every language in the same PR and run
  the site checks, even if the implementation change is outside `site/`.
- **Bundled dependencies:** after adding or updating one, run
  `scripts/check-notices-coverage.sh`.
- **Swift/Rust FFI:** exercise the changed contract through its Swift caller.
  Rust tests alone do not verify the integration. `make lint` includes the
  generated C header check through `make rust-lint`.
- **App strings:** review English and Japanese wording, then check affected
  labels in the app for clipping and meaning. `make lint` checks the catalog,
  but cannot establish that the wording is natural.
- **UI behavior or appearance:** verify the changed interaction or layout in
  the running app, following the procedure below.
- **Verification channel:** after changes to `Weir/Automation/` or
  `scripts/weir-automation.py`, run the app checks and `make check-automation`.
  The [verification procedure](.agents/skills/verify-in-app/SKILL.md#check-it-worked)
  defines additional checks for typing, focus, captures, and agents.
- **Packaging or archives:** run `make release-check` in addition to the
  checks for the affected build tooling.

A file extension alone does not determine the checks. If documentation changes
an executable example, setup command, or verification procedure, try the
changed steps in the environment they describe. For a behavior or API-contract
correction, compare the text with the implementation and relevant tests.
Update and check both READMEs when either changes. If a change does not fit a
row, identify what executes or consumes it and check that path.

Before the final checks, fetch the PR's target branch and stage new files
so the diff and the forbidden-terms check include them.
From the repository root, run the commands below. Replace `origin/main` with
the fetched target ref if the PR targets another branch or remote, such as
`upstream/main` when contributing from a fork.

```bash
pr_base_commit=$(git merge-base HEAD origin/main) &&
  git diff --check "$pr_base_commit" &&
  scripts/check-forbidden-terms.sh
```

The diff check covers committed and uncommitted changes since the branch
diverged from the target. Inspect that diff for unrelated changes too.

### Running the checks

Use the [setup instructions](#setup) for tools and dependencies. Run
`make ghostty` when `vendor/ghostty/macos/GhosttyKit.xcframework` is missing,
or when the Ghostty submodule pin or build inputs change. `make build` and
`make test` do not rebuild libghostty. They do regenerate the Xcode project
when its inputs change; see [Open in Xcode](#open-in-xcode) for manual use.

Script self-tests use the pattern `scripts/test-*.sh` and are usually named
after the script they check. Check the relevant workflow too: some self-tests run only
in CI, including those in `.github/workflows/guardrails.yml`.

For focused checks during development:

- **Rust:** use `make rust-test` and `make rust-lint`, or
  `cargo test --locked -p <package>` for one workspace package.
- **OpenCode plugin:** use `make plugin-test`.
- **Swift:** select the suite in Xcode or pass
  `-only-testing:WeirTests/<Suite>` to `xcodebuild test`, with the project,
  scheme, destination, and signing settings from the Makefile's `test` target.

Before running Swift tests directly, use `make xcodegen` if the project inputs
changed and `make build` if the Debug signing identity changed. Direct Xcode
commands do not run the Makefile's project and signing preparation.

Check that the intended tests ran. A successful command with no matching
tests does not verify the change.

For checks in the running app, follow
[verify-in-app](.agents/skills/verify-in-app/SKILL.md). Native approvals need
[the signed Debug setup](#native-approvals-in-a-debug-build) and the
[signed-run procedure](.agents/skills/verify-in-app/SKILL.md#checking-approvals-in-a-signed-run).
Start that build with `make run`, not the verification channel's `launch`;
native approvals are disabled when the channel is active. Demo mode also
cannot verify normal-session persistence or the approval service.

### What the checks establish

- `make build` builds the app; it does not establish that the test target
  compiles or that tests pass.
- `make test` runs Rust, OpenCode plugin, and Swift tests. It excludes
  `make review-core`, `make check-automation`, and `make test-measure`.
- `make test-measure` prints timing measurements rather than asserting
  performance thresholds. Use relevant measurements for performance changes.
- `make release-check` checks an unsigned archive. It does not verify signing,
  notarization, or updates to an installed app.
- Local results cover the OS and toolchain used for that run. CI also tests
  Rust on Linux and Windows; `.github/workflows/ci.yml` defines the platform
  matrix and the Xcode version used for app checks.
- `make build`, `make test`, and `make lint` do not cover the site.

### Reporting results

Report checks performed and their outcomes in the PR's How verified section,
following the [writing guide](docs/writing-guide.md#commit-messages-and-pull-requests).
Leave checklist items that do not apply unchecked; no explanation is needed.
For an applicable check you could not complete, leave the item unchecked and
explain why in How verified. Do not report a check as passed if missing tools,
dependencies, or credentials prevented it from running.

CI runs build, test, lint, review-core, release-archive, and site checks,
plus security, repository, and PR checks. A site-only PR skips app jobs.
The workflow files under `.github/workflows/` define which jobs run.

Release pull requests reuse the checks on `main` instead of rerunning builds,
tests, and Swift lint. Their `Main CI passed` check blocks the merge until CI
passes for the latest commit on `main`. To run the full workflow on a release
PR, dispatch it on that branch from the Actions tab and read the results there;
they do not appear among the PR's checks.

### Opening the PR

1. Copy `.github/pull_request_template.md` into a draft file.
2. Fill in the four sections and checklist, keeping their headings and rows.
   Write `Skip.` in a section with nothing to report, such as Related issue
   when there is no issue. Leave checklist items unchecked unless verified.
3. Pass the completed file to `gh pr create --body-file <file>`.

`--body-file` reads the supplied file without adding the repository's template.
Use the completed draft rather than `gh pr create --fill`, which generates
the title and body from commits.

## Tests

- Use [Swift Testing](https://developer.apple.com/documentation/testing)
  (`@Test`, `#expect`), not XCTest.
- Give tests descriptive names without a `test_` prefix, such as
  `@Test func openProject_existingProjectWithTabs_activatesWithoutOpeningAnother()`.
- Use `@MainActor` for stateful and UI suites.
- Reuse fixtures from `WeirTests/Support/`, including `RepoFixture`,
  `TempGitRepo`, `WithTempDir`, `FakeGit`, `WorkspaceSessionFixture`,
  `TurnSummaryFixture`, and `Tags`.
- Gate smoke tests that require a local repository with
  `.disabled(if: !RepoFixture.hasLocalRepo)` so they skip when the fixture
  repository is unavailable.

Never write to the real `~/Library` or `~/.codex` from a test. Inject a
temporary directory through `init(directory:)` or use `WithTempDir`.
Tests that called production initializers have corrupted real user data.
Under the test host, `WeirPaths.applicationSupportDirectory()` returns a
per-run temporary folder. Use `SecureFileWrite` for Weir's data files, not
`FileManager`, so `TestWriteGuard` can reject writes under the real
`~/Library` and `~/.codex`.

A rejected write also means the test did not exercise the intended behavior.
Check the `com.nekoder.weir` / `fs.guard` log for faults after a run. A
`~/Library/Application Support/Weir Tests Stray/` folder left by older tests
can be removed by hand.

After changing `Tab`, `SplitTree`, or `SessionSnapshot`, run
`DemoFixtureTests` first and update the fixture before shipping the model
change. The fixture uses stable UUIDs and a JSON round-trip.

## Regenerating the hero screenshot

The hero image at the top of `README.md`, `.github/assets/hero.png`, is captured from the app launched in demo mode. To refresh it after a UI change:

```bash
make screenshot   # Release build → launch in demo mode → capture → quit.
                  # Output lands at .github/assets/hero.png.
```

The screenshot script launches with `WEIR_DEMO=1`. To check the app with isolated demo data, use
`scripts/weir-automation.py launch --demo` as described in
[verify-in-app](.agents/skills/verify-in-app/SKILL.md).

Demo mode uses `DemoFixture` instead of the on-disk session. It shows a
fictional invoicing product with three projects and 18 worktree rows in a
1440×900 window with the Changes panel open. Persistence and session restoration are
disabled. The fixture supplies agent turns, Git facts, pane output, review
content, and the sample approval. Demo mode skips the approval service and
updater, so it cannot verify either and does not replace the running app's
service. Agents use their native permission prompts.

The panes run a dedicated zsh from `DemoFixture+Shell.swift` that reads no
user startup files and keeps no history. The terminal uses the default font
family at 12pt. The fixed fixture and clock make captures reproducible.

| Variable | Effect |
| --- | --- |
| `WEIR_DEMO_APPEARANCE=dark` | Uses the dark appearance. |
| `WEIR_DEMO_LAYER` | Opens `needs-attention`, `all-projects`, `review`, `approval-list`, or `approval-card`. |
| `WEIR_DEMO_LANGUAGE=ja` | Uses Japanese UI text. |
| `WEIR_DEMO_TIME=09:15` | Sets the displayed time; the default is 14:30. |
| `WEIR_SCREENSHOT_CROP=1` | Crops the capture to the selected surface. |
| `WEIR_SCREENSHOT_OUT` | Changes the output path. |

Display requirements:

- The capture is a 1440×900pt window at 2x, producing a 2880×1800-pixel image.
- The demo opens at (16, 16) on the main display. Use a 2x (Retina) display
  with at least 1456×956pt of space, including the menu bar.
- A 13.6-inch MacBook Air at its default resolution has enough room; a
  1440×900 display does not. The script rejects captures of the wrong size.

**One-time setup**: grant your terminal Screen Recording permission so the script can find Weir's window and capture it through ScreenCaptureKit (one permission covers both).

> System Settings → Privacy & Security → Screen Recording → click `+` → add your terminal app (Terminal, Ghostty, etc.) → toggle on.

## AI tools

Using AI assistants (Claude, Copilot, Cursor, etc.) is welcome. Please be able to explain what your PR does without leaning on the tool.

See [`AGENTS.md`](AGENTS.md) for the conventions agents (and humans) should follow inside the repository.

## Reporting security issues

See [SECURITY.md](SECURITY.md).

## Questions

Open a [Discussion](https://github.com/nek0der/weir/discussions) or an issue.
