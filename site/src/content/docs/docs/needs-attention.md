---
title: Needs Attention and approvals
description: Go to the next agent that is waiting, and answer its requests.
sidebar:
  order: 6
---

## The list

**Needs Attention** holds what is waiting for you across every project, in the order it arrived: approvals, questions, stops, and unviewed turns.

| Key | What it does |
|---|---|
| <kbd>⌘J</kbd> | Go to the next item |
| <kbd>⇧⌘J</kbd> | Go to the previous item |
| <kbd>⌥⌘J</kbd> | Open the list |

![The Needs Attention list: seven items in the order they arrived, the last with an Answer button](../../../assets/captures/docs/needs-attention-en.png)

A turn that changed files stays in the list until you [mark it as viewed](/docs/review/#mark-turns-as-viewed).

To see every project's worktrees grouped by state, press <kbd>⇧⌘O</kbd> for **All Projects**.

## Answer an approval

Weir holds each request until you answer it, wherever its pane is. You answer it on the approval card, which opens from any of these:

| Where | How |
|---|---|
| The bar under the agent's pane | Choose **Answer…**, or press <kbd>⌘⏎</kbd> |
| The **Needs Attention** list | Choose **Answer…** |
| The worktree's sidebar row | Hover over it and choose **Answer…** |
| **All Projects** | Choose the worktree's **Answer…** |
| The menu bar, while another app is in front | A short, low-impact shell command can be answered right there. For any other request, choose **Answer…** to open Weir |

The card opens next to where you chose **Answer…**, in the same window. If you opened it from a row in a list or the sidebar, that row stays highlighted while the card is open.

Going to the pane leaves the request with Weir, so you can still answer it on the card after you leave. Claude Code and OpenCode also show their own prompts in the pane, and whichever you answer first counts. Codex shows its prompt only after you choose **Answer in terminal** or the request times out.

![The approval card: the command the agent wants to run, the time left, and Answer in terminal, Deny, and Allow once](../../../assets/captures/docs/approval-en.png)

**Answer in terminal** on the card, or in the bar's **⋯** menu, goes to the pane and sends the request to the agent's prompt. After that you answer it there. The card shows the time left. Once a request times out, you answer it in the terminal.

Weir adds no "always allow" option and writes nothing to an agent's settings. To always allow something, use the agent's own prompt.

Codex questions are always answered in the terminal.

Antigravity has no approval card. Its approvals and questions are always answered in its own prompt, and Weir shows that it waits. A subagent's approval does not always show as a wait: `agy` shows it as Blocked, and `ctrl+k` there approves it.

For OpenCode, **Allow always** and answers to its questions are only at its own prompt.

Each of OpenCode's tabs is watched on its own, so a wait or a failure in a tab behind the one on screen still reaches you here. Going to it, or choosing **Answer in terminal** for its request, brings its tab forward. The pane's badge shows the most urgent of its tabs.

## After a stop

When an agent stops on an API error, a usage limit, or by exiting, the bar under its pane offers:

- **Resume Same Conversation**, to pick up where it left off
- **Show Partial Changes** and **Start New Conversation**, in its **⋯** menu

If a usage limit stopped it, Weir can also notify you when the limit resets. Antigravity reports a limit only in the words of its error, so a limit in words Weir does not recognize stops like any other error, and one with no readable reset time offers no notification.

OpenCode reaches many services and models, so a limit on one of them does not mark your other OpenCode panes. Its stop offers **Resume** rather than the notification, since changing the model may be all it takes.

## An agent that runs without asking

When an agent is set to run every action without asking, its pane header says **Runs without asking** beside a warning sign, so you can tell at a glance.
