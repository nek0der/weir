---
title: Install
description: What Weir needs, how to install it, and how to remove it.
sidebar:
  order: 2
---

## What you need

- macOS 26 or later, on Apple Silicon.
- Git.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), the Antigravity CLI (`agy`), [OpenCode](https://opencode.ai), the [Kiro CLI](https://kiro.dev/cli/) (`kiro-cli`), or any of them together. Weir runs the copies you already have, signed in as you.

To see pull request status in the sidebar, also install `gh` or `glab` and sign in. Weir works without them.

## Install

1. Download the DMG from the [latest release](https://github.com/nek0der/weir/releases/latest).
2. Open it and drag `Weir.app` to `/Applications`.
3. Open Weir.

The release is signed and notarized, so macOS does not block it as coming from an unknown developer. The first time, macOS asks you to confirm opening a downloaded app.

Weir registers a small background service for approvals. You will see it in **System Settings → General → Login Items & Extensions**. If you turn it off, approvals stay in each agent's own prompt.

Next: [run your first agent](/docs/quick-start/).

## Update

Weir checks for updates once a day and installs one when you choose to. To check now, open the **Weir** menu and choose **Check for Updates…**.

## Uninstall

1. Quit Weir and move `Weir.app` to the Trash.
2. Delete `~/Library/Application Support/Weir/` and `~/Library/Preferences/com.nekoder.Weir.plist`.
3. If **Login Items & Extensions** still lists Weir, turn it off there.
4. If you ran Antigravity in Weir and `~/.gemini/config/plugins/weir` holds a file named `.weir-managed`, delete that folder. Without that file, the folder is not Weir's.
5. If you ran OpenCode in Weir and `~/.config/opencode/plugins/weir` holds a file named `.weir-managed`, delete that folder too.
6. If you ran Kiro in Weir, compare the output of `cksum < ~/.kiro/hooks/weir.json` with the contents of `~/.kiro/hooks/.weir.json.cksum`. If they match, delete both files. If not, you edited `weir.json`, so keep it and delete only `.weir.json.cksum`.

Each repository also keeps Weir's turn snapshots. To delete them, run this in the repository:

```bash
git for-each-ref --format='%(refname)' refs/weir/ | xargs -n1 git update-ref -d
```

Then delete the `weir` folder in the directory `git rev-parse --git-common-dir` prints, and in each folder under its `worktrees/`.

Worktrees Weir made are ordinary Git worktrees. Remove the ones you no longer want with `git worktree remove`.
