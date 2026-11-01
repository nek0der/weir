---
title: Troubleshooting
description: What to do when something in Weir looks wrong.
sidebar:
  order: 8
---

## A turn stays in Needs Attention

A turn that changed files stays there until you mark it as viewed. Press <kbd>⌘⏎</kbd> for **Mark as Viewed**, or see [Review changes](/docs/review/#mark-turns-as-viewed).

## An approval did not appear on the card

The card does not open by itself. For a request whose pane is out of sight, choose **Answer…** in the **Needs Attention** list, or hover over the worktree's sidebar row and choose it there. A request from a pane you can see goes to the agent's own prompt, so answer it there.

If every approval goes to the prompt, check that Weir's service is on in **System Settings → General → Login Items & Extensions**. A build you made yourself without a Team ID has no approval service.

## The sidebar keeps saying an agent is running or needs approval

This can happen inside tmux. Weir does not hear about a Claude Code turn you stop with <kbd>Esc</kbd> or <kbd>Ctrl+C</kbd> there, or an approval you refuse in its dialog, until your next prompt in that pane. Sending the next prompt clears it.

The same thing happens outside tmux if `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is set.

## Plan Usage shows nothing for Claude Code

Claude Code reports its usage only to a status line, so Weir needs one of your own. Run `/statusline` in Claude Code to set one up. The panel then fills in with the next reply in a Weir pane.

## Plan Usage shows nothing for Codex

Plan usage appears when you are signed in to Codex with ChatGPT. Weir asks for the account in `~/.codex`, so a `CODEX_HOME` set in your shell does not change which account it reads.

## A row has no pull request status

Install `gh` or `glab` and sign in to the project's remote. **Create PR** needs `gh`, so Weir does not create GitLab merge requests.

## New Worktree cannot carry my uncommitted changes

Carrying changes needs Git 2.40 or later. Weir also stops before making anything when the worktree has a merge or rebase under way, has conflicts, or uses a sparse checkout. Finish or undo that first, or make the worktree without the changes.

Files Git ignores do not come along. To copy them, such as `.env`, choose them in **Project Settings**.

## A prompt seems stuck when a turn starts or ends

Weir takes a snapshot at each turn's start and end, and a stalled snapshot can hold the prompt for up to 10 minutes. If it keeps happening, please report it.

## An old turn is gone

Weir deletes old turns. To keep them longer, raise the days and the turns per conversation in **Settings → Advanced → Turn History**. [Privacy and data](/docs/privacy/#where-your-data-is) has all the limits.

## Still stuck

The full list of what does not work yet is in [Known limitations](https://github.com/nek0der/weir/blob/main/docs/known-limitations.md).

Ask in [Discussions](https://github.com/nek0der/weir/discussions) or open an [issue](https://github.com/nek0der/weir/issues). Please include your Weir and macOS versions, the agent you use, and what you expected to happen. Weir has one developer, so a reply can take a while.

To report a security problem, follow the [security policy](https://github.com/nek0der/weir/blob/main/SECURITY.md) rather than opening an issue.
