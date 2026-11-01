---
title: Quick start
description: Open a project, run an agent in its own worktree, and review what it changed.
sidebar:
  order: 3
---

This walks through one task from start to finish. You need [Weir installed](/docs/install/), a Git repository, and Claude Code or Codex signed in.

## 1. Open your project

Press <kbd>⌘O</kbd> and choose your repository's folder. It appears in the sidebar as a project, with its own folder as the first row.

## 2. Make a worktree for the task

Press <kbd>⌘N</kbd> to open **New Worktree**. Choose a new or existing branch and the agent to open, then press <kbd>⌘⏎</kbd> to create it.

The worktree gets its own folder and a new row in the sidebar, so this task's files stay apart from your other work.

Files Git ignores, such as `.env`, are not copied unless you choose them in **Project Settings**.

## 3. Give the agent its first instruction

Weir opens the agent in a terminal. In a folder it has not seen, the agent may first ask whether you trust it. Then type your instruction in its prompt, as you would anywhere else.

The sidebar row and the bar under the pane now show what the agent is doing. Nothing moves or takes focus on its own, so you can leave it running and do something else.

## 4. Go to it when it needs you

When the agent asks for approval, asks a question, stops, or finishes a turn, the item joins **Needs Attention**. Press <kbd>⌘J</kbd> to go to it.

Answer approvals and questions in the agent's prompt. See [Needs Attention and approvals](/docs/needs-attention/) for the other ways.

## 5. Review the turn

A finished turn that changed files opens in a review tab when you reach it with <kbd>⌘J</kbd>. If you are already at its pane, press <kbd>⌥⌘R</kbd>.

To ask for a fix, click a line number, press <kbd>C</kbd>, write your comment, and choose **Add**. Then choose **Insert *n* Comments**. Your comments go into the agent's input as one message, and you press <kbd>Return</kbd> to send it. Nothing is sent until you do.

## 6. Mark it as viewed

When you have read the turn, press <kbd>⌘⏎</kbd> for **Mark as Viewed**. It leaves **Needs Attention**, and the review closes.

If you do not want the turn, use **Restore Code to Before This Turn…** in the bar's **⋯** menu instead. With several unviewed turns, the menu names the first one, such as **Restore Code to Before T1…**. Once the turn is marked as viewed, the same command is on its card in the Changes panel (<kbd>⌥⌘I</kbd>). See [Review changes](/docs/review/).

## Where to go next

Press <kbd>⌘/</kbd> to see every shortcut, or <kbd>⇧⌘P</kbd> to find a command by name. To run another task at the same time, go back to step 2.
