# Weir

A native Mac window for Claude Code, Codex, and Antigravity. See which one needs you and what each turn changed.

**[Website](https://weir.nekoder.com)** · **[Documentation](https://weir.nekoder.com/docs/)** · **[Download](https://github.com/nek0der/weir/releases/latest)**

English | [日本語](README.ja.md)

[![Release](https://img.shields.io/github/v/release/nek0der/weir?sort=semver)](https://github.com/nek0der/weir/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)

<p align="center"><img src=".github/assets/hero.png" alt="A Weir window: worktrees on the left, a terminal in the middle, each turn's changes on the right." width="900" /></p>

## Why Weir

When several agents work at once, the hard part is not typing. It is knowing which one is blocked, what each turn changed, and what you have already read.

- **One list of what needs you.** Approvals, questions, stops, and unviewed turns, across every project. ⌘J goes to the next one.
- **Every turn is recorded.** Weir snapshots the worktree around each round of an agent's work, so you can review that turn or restore the code to before it.
- **One worktree per task.** Each task gets its own branch and folder, with its pull request status beside it.
- **Comments go back to the agent.** Comment on any line, then insert your comments into the agent's prompt. Nothing is sent until you press Return.

Weir is not an editor, and it is not an agent. The agents keep their own terminal UI in real terminals, built on libghostty, and you still type in their prompts.

## Install

Weir needs macOS 26 or later on Apple Silicon, Git, and Claude Code, Codex, or the Antigravity CLI (`agy`).

Download the DMG from the [latest release](https://github.com/nek0der/weir/releases/latest) and drag `Weir.app` to `/Applications`. Weir updates itself through Sparkle when you choose to. To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md#setup).

## Quick start

1. Press ⌘O and choose your repository's folder.
2. Press ⌘N to make a worktree on a new or existing branch, and choose the agent to open.
3. Give the agent its first instruction in its own prompt, then leave it running.
4. When it needs you, press ⌘J to go to it.
5. Read the turn, comment on it if you want a fix, and press ⌘⏎ to mark it as viewed.

The [quick start](https://weir.nekoder.com/docs/quick-start/) has each step in full.

## Privacy

Weir has no accounts, analytics, or telemetry. It adds nothing to `~/.claude/` or `~/.codex/`: wrappers in its panes pass the hooks on each launch, so agents you start elsewhere are not affected. For Antigravity, it places a plugin in `~/.gemini/config/plugins/weir`. Turn snapshots stay in each repository's Git directory.

[Privacy and data](https://weir.nekoder.com/docs/privacy/) lists what Weir sends and writes, and [Uninstall](https://weir.nekoder.com/docs/install/#uninstall) how to remove it all.

## Documentation

For using Weir:

- [Documentation](https://weir.nekoder.com/docs/): install, quick start, review, Needs Attention, shortcuts, and troubleshooting.
- [User guide](docs/user-guide.md): every part of the window in detail.
- [Known limitations](docs/known-limitations.md): what does not work yet, and what is surprising on purpose.
- [Data migration](docs/data-migration.md): the files Weir keeps, and how to go back one release.

For working on Weir:

- [CONTRIBUTING.md](CONTRIBUTING.md): setup, build, signing, and the pull request workflow.
- [ARCHITECTURE.md](ARCHITECTURE.md): the modules, load-bearing files, and invariants.
- [AGENTS.md](AGENTS.md): repository conventions, for people and agents.
- [Agent integration protocol](docs/agent-integration-protocol.md): the contract between the hook helper, the approval service, and the app.

## Status

Weir is pre-alpha. Settings and data formats may change between releases.

## Contributing

Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md) to report a vulnerability. Questions and ideas go in [Discussions](https://github.com/nek0der/weir/discussions).

## Acknowledgements

Built on [Ghostty](https://github.com/ghostty-org/ghostty) (libghostty) and [Sparkle](https://github.com/sparkle-project/Sparkle). The full list is in [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES).

## License

[MIT](LICENSE) © 2026 nek0der
