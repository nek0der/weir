---
title: Privacy and data
description: What Weir sends over the network, what it writes, and where it keeps your data.
sidebar:
  order: 9
---

Weir has no accounts, analytics, or telemetry. The agents you run talk to their own services as they always do, under their own terms.

## What Weir sends

Weir reaches the network only in these ways:

| For | What happens |
|---|---|
| Update checks | Fetches the update feed from GitHub once a day, and downloads a release only when you choose to install it |
| New worktrees | Runs `git fetch` with your own Git credentials, when you start from a remote branch or a pull request |
| Pull request status | Runs the `gh` or `glab` you installed, with its own credentials |
| Create PR | Runs the `gh` you installed, when you choose it |
| Plan Usage | Starts the `codex` you installed, and asks it for your plan's usage |

To turn off the daily update check, use **Settings → General → Software Update → Automatically check for updates**. You can still check at any time with **Check for Updates…**.

## What Weir writes

- **Agent hooks.** Weir adds nothing to `~/.claude/` or `~/.codex/`. At launch it only removes a hook trust entry that an older version added to `~/.codex/config.toml`. Its panes put a small `claude` and `codex` wrapper first on the `PATH`, which passes the hooks on each launch. Agents you start outside Weir are not affected.
- **Approval service.** The release registers a per-user background service, listed in **System Settings → General → Login Items & Extensions**.
- **Turn snapshots.** They live in each repository's Git directory, as refs under `refs/weir/` and files under `weir/`.

## Where your data is

| What | Where |
|---|---|
| Session, settings, notification history, scrollback, review drafts, and turn records | `~/Library/Application Support/Weir/` |
| Preferences | `~/Library/Preferences/com.nekoder.Weir.plist` |
| Turn snapshots | Each repository's Git directory |

Weir deletes turn snapshots after 14 days, or once a conversation passes 200 turns. It also deletes them when a repository's snapshots pass 500 MB or all turns pass 8,000. Unviewed turns of open sessions are kept for up to 90 days. You can change the days and the turns per conversation in **Settings → Advanced → Turn History**. The other limits are fixed.

To remove all of it, see [Uninstall](/docs/install/#uninstall).
