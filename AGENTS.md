# Weir Agent Guide

> `CLAUDE.md` is a symlink to this file. They are the same document.

Weir is a macOS 26 terminal app written in Swift 6 and SwiftUI, with
libghostty and Rust components connected through C ABIs. Its supervision
window shows a project's worktrees, agent panes, approvals, and changes
recorded during agent turns.

This guide defines the rules agents need while working in the repository.
[CONTRIBUTING.md](CONTRIBUTING.md) holds the shared setup, verification, test,
and PR procedures for human contributors and agents.

## Table of contents

1. [Build / Test / Run](#1-build--test--run)
2. [Repository layout](#2-repository-layout)
3. [Code conventions](#3-code-conventions)
4. [Architecture pointers](#4-architecture-pointers)
5. [Do not touch](#5-do-not-touch)
6. [PR & workflow](#6-pr--workflow)
7. [Agent-specific tips](#7-agent-specific-tips)

## 1. Build / Test / Run

Use the Makefile as the command entry point; `make help` lists the targets.
Read [the verification requirements](CONTRIBUTING.md#before-opening-the-pr)
to choose checks for the change. For app code changes, run `make build`,
`make lint`, `make test`, and `make review-core`; the build must have no
warnings. For prose-only changes, follow the repository prose row in the table.

```bash
make build         # Build this checkout's Debug app
make dev           # Build and launch this checkout's Debug app
make test          # Rust, OpenCode plugin, and Swift tests
make lint          # Rust and Swift lint, localization, and script checks
make review-core   # Separate terminal-probe scenario; not in make test
make release-check # Unsigned Release archive and packaging checks
```

- Use the available Xcode build and test tools for focused iteration when
  they provide the checks needed. Use `make build` for the initial full
  build, CI reproduction, or when those tools are unavailable.
- Direct tool commands may supply flags the Makefile does not expose. Keep
  the same project, scheme, destination, and signing settings; see
  [Running the checks](CONTRIBUTING.md#running-the-checks).
- Ad-hoc Debug builds cannot exercise native approvals. Use the
  [signed Debug setup](CONTRIBUTING.md#native-approvals-in-a-debug-build)
  when checking the approval service.
- `make build` and `make test` do not rebuild libghostty. Run `make ghostty`
  if the framework is missing or the Ghostty submodule pin or build inputs
  changed.

## 2. Repository layout

```
Weir/
  App/         entry point, AppState, window controllers and syncs, commands
  Core/        models, settings, notifications, git, persistence, clipboard, agents
               (`Domain/`: plain values and pure rules)
  Presentation/ display stores: window registry, attention list, view models
  FFI/         libghostty C ABI wrapper (`GhosttyFFI`)
  UI/          SwiftUI views (`Supervision/` window, panes, review, settings, design system, clipboard sheet)
  Resources/   Info.plist, Localizable.xcstrings, assets
AgentIntegrationService/  launchd-managed XPC service for native approvals
WeirTests/   Swift Testing suites (no XCTest)
rust/          OS-independent Rust crates; `weir-rust-bridge` owns the C ABI
vendor/ghostty/  submodule of our fork github.com/nek0der/ghostty (branch `weir`).
                 Upstream ghostty-org is tracked via the `upstream` remote for rebases.
                 Run `git -C vendor/ghostty describe` for the current pin.
scripts/       Rust/Ghostty build bridges, packaging, and validation scripts
site/          The landing page and documents (`site/README.md`); published with a release
Cargo.toml     Rust workspace source of truth; toolchain is pinned separately
project.yml    xcodegen source of truth for the .xcodeproj
```

## 3. Code conventions

Code formatting and many style rules are enforced by `make lint` (`cargo fmt`, Clippy,
`swiftformat --lint`, and `swiftlint --strict`).

Before writing or reviewing comments, documents, commit messages, or PR text,
read the relevant section of [the writing guide](docs/writing-guide.md).

Additional conventions:

- **English only** for source, comments, commits, and PR titles and bodies.
  Use US spelling even where older files use British spelling. No emoji
  anywhere. See the [writing guide](docs/writing-guide.md#common-wording)
  for wording and tone.
- **SwiftUI before AppKit.** AppKit is the boundary (`NSWindow`,
  `NSTextInputClient`, `NSPasteboard`, `NSVisualEffectView`), not the
  default. Wrap AppKit classes in `*Representable` types and keep the
  boundary thin.
- **`@MainActor final class`** for long-lived state stores. Hot
  off-actor writes go through a `nonisolated static func` write helper
  that takes a value-typed snapshot and routes through
  `SecureFileWrite.writeAtomic` (see `SessionStore`,
  `NotificationHistoryStore`, `FrecencyStore`, `TurnReadStore`).
  `SettingsStore` is the exception: it writes its small `settings.json`
  on the main actor. Use `actor` only when `MainActor` serializes too much.
- **FFI requires explicit `Sendable` proof.** The canonical wrapper is
  `GhosttyFFI.swift`. `nonisolated(unsafe)` is reserved for `deinit`
  cleanup of resources captured during a known-safe lifetime.
  Document the safety argument in the property's doc comment.
- **Comments** describe API contracts or explain implementation choices;
  use `we` / `our`, not `I`, when explaining our choices. Follow the
  [comment guide](docs/writing-guide.md#code-comments) for sentence forms.
  Every Swift file starts with a banner: `// FileName.swift` /
  `// Weir — one-line description`.
- **Booleans read as predicates** (`isFocused`, `hasPendingChanges`),
  never bare `focused` / `pending`.
- **No force-unwrap (`!`)** in production. Document *why* a stored
  property is optional in its doc comment.
- **`throws` for recoverable failures**; `try?` is fine when the
  failure mode is "use a default" — document the intent inline.
  User-facing errors implement `LocalizedError`.
- **All user-facing app strings**, including tooltips, alerts, and
  accessibility text, use `Localizable.xcstrings` with both `en` and `ja`.
  `WeirDomain` also uses the app catalog; the build fails if its new strings
  are missing. Internal log messages stay English.
- **One subsystem (`com.nekoder.weir`)**. User content (paths, prompts,
  hostnames) is `privacy: .private`. No `print()` in production.
- **Accessibility:** every interactive element has an
  `.accessibilityLabel`. Read `@Environment(\.accessibilityReduceMotion)`
  and gate decorative transitions on it. Liquid Glass appearance
  must not be the only thing that carries meaning.
- **Tests use Swift Testing** (`@Test`, `#expect`), not XCTest. Reuse
  `WeirTests/Support/` fixtures and follow [the test rules](CONTRIBUTING.md#tests).
  Never write to the real `~/Library` or `~/.codex` from a test; inject a
  temporary directory. Use `SecureFileWrite` for Weir's data files so the
  test write guard can reject writes to real user data.

## 4. Architecture pointers

Read the relevant files before changing a subsystem. The ADRs in `docs/adr/`
explain the design of agent integration and the verification channel.

- `Weir/Core/Settings/GhosttyConfigBridge.swift` — four-layer config model
  and the forced-override keys handed to `libghostty`.
- `Weir/Core/Rust/WeirRustBridge.swift` — typed Swift entry point for the
  versioned Rust C ABI; `scripts/build-rust-bridge.sh` owns Xcode integration.
- `Weir/Core/Models/WorkspaceSession.swift` — the session-state hub every
  window shares: projects, worktrees, tabs, each window's selection, and
  restore.
- `Weir/UI/Supervision/SupervisionWindowView.swift` — the supervision
  window's root; `ARCHITECTURE.md` maps each part to its view and model.
- `Weir/Presentation/Window/WindowRegistry.swift` — the windows, which one
  commands act on, and how a window switches projects in place.
- `Weir/Presentation/Attention/AttentionQueueStore.swift` — the app's one
  attention list behind ⌘J, Needs Attention, and the decision bars.
- `Weir/Core/Agent/ApprovalPresentationStore.swift` — native approval
  requests, their ledger, and handoffs to the agent's own permission prompt.
  Each window's approval card is
  `Weir/Presentation/Approval/WindowApprovalCard.swift`.
- `Weir/Core/Persistence/TurnReadStore.swift` — tracks read turns and works
  with `ViewedLineStore` to determine which turns are unread.
- `Weir/Core/Review/ReviewSession.swift` — the review's state machine: what
  each comment state means, why a comment is validated against Git rather than
  trusted, and which failures the banner is allowed to clear.
- `Weir/Core/Updates/SparkleUpdater.swift` — Sparkle auto-update wiring.

## 5. Do not touch

- `vendor/ghostty/` — our libghostty fork (`nek0der/ghostty`, branch `weir`).
  C ABI patches land on the fork's `weir` branch, then bump the submodule ref
  here. Don't edit the checkout in place from the Weir repo — commit patches
  on the fork. A patch stays additive and carries a class and a retirement
  condition; `docs/libghostty-fork.md` holds the rules and the current
  inventory.
- `Weir.xcodeproj/project.pbxproj` — generated. Edit `project.yml` and run
  `make xcodegen` instead.
- `Weir/Resources/Info.plist` Sparkle public key (`SUPublicEDKey`). Changing
  it breaks update signature verification for every shipped build.
- The repository's GitHub Pages settings. Do not give them a custom domain. They
  serve the update feed that shipped apps read at
  `nek0der.github.io/weir/appcast.xml`, and the site lives on Cloudflare Pages.
- The forced-override config keys passed to `libghostty`
  (`background-opacity=0`, `shell-integration-features=no-cursor`, …). They
  protect the UI compositor; removing one will silently break the rendering
  path. `clipboard-paste-protection = true` is in that block for a different
  reason. Review pastes repository content into whatever the pane is running.
  An unbracketed multi-line paste then needs confirmation, and that
  confirmation keeps a shell from running those lines as commands. The key
  overrides a user's own opt-out in `~/.config/ghostty/config` for every pane,
  because the C ABI has no per-surface form of it. Settings → Review tells the
  user so.
- `Localizable.xcstrings` — if you hand-edit the JSON, validate that Xcode can
  re-parse it. A malformed `xcstrings` file fails the build.

## 6. PR & workflow

Follow [the contribution workflow](CONTRIBUTING.md#pull-requests) for branch
names, commit scopes, required checks, and PR creation.

- Title each PR, and so its squashed commit, `<type>(<scope>): <subject>`
  as [Commit titles and branches](CONTRIBUTING.md#commit-titles-and-branches)
  describes:
  - Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `build`, `ci`, `test`,
    `chore`, and `revert`. A change the person using Weir can see is `fix`,
    not `refactor`. Documents and the contributor and agent instructions,
    including this file, are `docs`. The build and the release configuration
    are `build`, `.github/workflows/` and the CI configuration are `ci`, and
    dependency updates and other maintenance are `chore`.
  - The subject starts with a lowercase verb in the imperative (an
    identifier in backticks may come first), the whole title aims for about
    90 characters and stays within 110, and the subject has no final period.
  - Choose the scope from the list in that section. A PR that adds a screen
    or a feature that no scope covers adds its scope there.
  - The branch is `<type>/<short-description>` with the PR's type.
- Do not add AI attribution or `Co-Authored-By` trailers to commits.
- Fill in every section of `.github/pull_request_template.md` and pass the
  completed body to `gh pr create --body-file`.
- Report checks performed and their outcomes. Reuse passing results only
  while their relevant inputs remain unchanged; never report an incomplete
  check as passed.

## 7. Agent-specific tips

- **Parallel agents:** use separate worktrees for concurrent edits
  (`isolation: worktree` where supported). Integrate completed commits by
  cherry-pick.
- **App verification:** use [verify-in-app](.agents/skills/verify-in-app/SKILL.md)
  to check this checkout's Debug app behind the person's windows with its own
  data. Prefer it to full-screen computer use. Channel changes, including
  `scripts/weir-automation.py`, require `make check-automation`; the skill
  defines the additional `--keys` and `--agents` checks.
- **Skills:** procedures live in `.agents/skills/`, with links in
  `.claude/skills/`. Follow [the skill guide](.agents/skills/README.md) and
  update a skill in the same PR as changes to the procedure it describes.
- **Documents and decisions:** read the relevant ADRs before changing an
  area's design. Follow [the document guide](docs/README.md) for ownership
  and ADR maintenance. Update affected documents in the same PR. Record a
  changed decision in a new ADR; follow the guide for corrections to an
  existing record.
- **Site:** app checks do not cover `site/`. Run `pnpm build` there and follow
  [the site guide](site/README.md). When a change affects what a site document
  describes, update `site/src/content/docs/` in every language in the same PR.
  Site UI text needs English and Japanese updates in `site/src/site.ts`; it
  does not use the app's string catalog.
- **README:** update `README.md` and `README.ja.md` together.
- **Demo mode:** it uses fixture data and skips persistence, the approval
  service, and the updater. It cannot verify normal-session behavior or
  native approvals. See [the capture procedure](CONTRIBUTING.md#regenerating-the-hero-screenshot)
  for controls and display requirements. After changing `Tab`, `SplitTree`,
  or `SessionSnapshot`, run `DemoFixtureTests` and update the fixture before
  shipping the model change.
- **When stuck:** consult relevant issues, upstream sources, and platform
  documentation before guessing or repeatedly rebuilding.
