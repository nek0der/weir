---
title: Troubleshooting
description: What to do when something in Weir looks wrong.
sidebar:
  order: 8
---

## A turn stays in Needs Attention

A turn that changed files stays there until you mark it as viewed. Press <kbd>⌘⏎</kbd> for **Mark as Viewed**, or see [Review changes](/docs/review/#mark-turns-as-viewed).

## An approval did not appear on the card

The card does not open by itself. Choose **Answer…** in any of these places to open it:

- The bar under the agent's pane (or press <kbd>⌘⏎</kbd> there)
- The **Needs Attention** list
- **All Projects**
- The worktree's sidebar row, when you hover over it

A request you sent to the terminal with **Answer in terminal** is answered in the agent's own prompt.

If every approval goes to the prompt, check that Weir's service is on in **System Settings → General → Login Items & Extensions**. Weir does not register the service while it runs from its disk image or from a temporary copy macOS made of it, so move Weir to the Applications folder and open it from there.

## The sidebar keeps saying an agent is running or needs approval

This can happen inside tmux. Weir does not hear about a Claude Code turn you stop with <kbd>Esc</kbd> or <kbd>Ctrl+C</kbd> there, or an approval you refuse in its dialog, until your next prompt in that pane. Sending the next prompt clears it.

The same thing happens outside tmux if `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is set.

## Plan Usage shows nothing for Claude Code

Claude Code reports its usage only to a status line, so Weir needs one of your own. Run `/statusline` in Claude Code to set one up. The panel then fills in with the next reply in a Weir pane.

## Plan Usage shows nothing for Codex

Plan usage appears when you are signed in to Codex with ChatGPT. Weir asks for the account in `~/.codex`, so a `CODEX_HOME` set in your shell does not change which account it reads.

## Plan Usage shows nothing for Antigravity

Antigravity reports its usage only to a status line, so Weir needs one of your own. Run `/statusline` in `agy` to set one up. The panel then fills in with the next reply in a Weir pane. A launch that passes its own `--settings` shows no usage.

## Antigravity keeps saying it is at work

This can happen inside a tmux you started yourself, where `agy` does not report its status. A stopped generation or a canceled question stays at work until your next prompt, and a permission prompt does not show as a wait. Weir does not host `agy` in tmux, so running it directly in the pane avoids this.

## Antigravity reports nothing to Weir

Weir places a plugin at `~/.gemini/config/plugins/weir` the first time `agy` runs in a pane. If a folder of that name already exists without Weir's `.weir-managed` file, Weir leaves it alone, so move it aside. If you ran `agy plugin disable weir`, enable the plugin again in `agy`.

## OpenCode reports nothing to Weir

Weir places a plugin at `~/.config/opencode/plugins/weir` the first time `opencode` runs in a pane, or at `plugins/weir` in the folder `OPENCODE_CONFIG_DIR` names when you set it. If a folder of that name already exists without Weir's `.weir-managed` file, Weir leaves it alone, so move it aside. Weir does not watch a launch with `--server`, or `opencode run` and OpenCode's other subcommands. A newer OpenCode than this Weir supports may also have changed what the plugin relies on, and the pane then works as a plain OpenCode.

## An OpenCode turn shows no changes

Weir saves a turn's start when you press Enter, or before OpenCode starts for a `--prompt` launch. A slash command chosen from OpenCode's menu, a rebound submit key, and a turn the agent goes on to by itself have no start, so they show no change summary or **Restore Code**. If the save takes more than ten seconds, as it can in a very large repository, Weir sends your input without a start.

## Kiro reports nothing to Weir

Weir watches only Kiro's v3 engine, which loads hooks. A Kiro tab Weir opens runs `kiro-cli --v3`. A `kiro-cli` you type runs v3 on Kiro 3.0 or later, unless you chose to stay on v2 or started it with `--no-interactive`. Add `--v3`, or choose v3 in Kiro's settings. Weir places a hook file at `~/.kiro/hooks/weir.json` the first time `kiro-cli` runs in a pane. If a file of that name was already there, or you edited Weir's, Weir leaves it alone, so move it aside. Kiro runs no hooks in a folder you did not trust, and none from `~/.kiro` while `KIRO_HOME` points elsewhere. A cloud session (`--cloud`) runs in Kiro's sandbox, so Weir does not watch it.

## Kiro keeps saying it is at work

This can happen inside a tmux you started yourself, where `kiro-cli` does not report its status. A turn you stopped with Esc stays at work until your next prompt, and a permission prompt does not show as a wait. Weir does not host `kiro-cli` in tmux, so running it directly in the pane avoids this.

## A row has no pull request status

Install `gh` or `glab` and sign in to the project's remote. **Create PR** needs `gh`, so Weir does not create GitLab merge requests.

If the status stops changing, the service's rate limit may have run out. Weir then keeps showing the last status and asks again once the limit resets.

## New Worktree cannot carry my uncommitted changes

Carrying changes needs Git 2.41 or later. Weir also stops before making anything when the worktree has a merge or rebase under way, has conflicts, or uses a sparse checkout. Finish or undo that first, or make the worktree without the changes.

Files Git ignores do not come along. To copy them, such as `.env`, choose them in **Project Settings**.

## A prompt seems stuck when a turn starts or ends

Weir takes a snapshot at each turn's start and end, and a stalled snapshot can hold the prompt for up to 10 minutes. If it keeps happening, please report it.

## An old turn is gone

Weir deletes old turns. To keep them longer, raise the days and the turns per conversation in **Settings → Advanced → Turn History**. [Privacy and data](/docs/privacy/#where-your-data-is) has all the limits.

## Still stuck

The full list of what does not work yet is in [Known limitations](https://github.com/nek0der/weir/blob/main/docs/known-limitations.md).

Ask in [Discussions](https://github.com/nek0der/weir/discussions) or open an [issue](https://github.com/nek0der/weir/issues). Please include your Weir and macOS versions, the agent you use, and what you expected to happen. Weir has one developer, so a reply can take a while.

To report a security problem, follow the [security policy](https://github.com/nek0der/weir/blob/main/SECURITY.md) rather than opening an issue.
