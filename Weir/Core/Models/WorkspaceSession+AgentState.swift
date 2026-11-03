// WorkspaceSession+AgentState.swift
// Weir — "is anything live?" predicates that read raw agent badges
// and the agents in front of each pane. Used by the close confirmations only — these are
// intentionally NOT read from the attention list, because a finished
// turn already read leaves no item there and is still a live session
// worth protecting before close.

import Foundation
import WeirDomain

@MainActor
extension WorkspaceSession {
    /// "Is any agent live in this tab right now?" — used by close-
    /// confirmation. A pane whose finished turn has been read, and so has
    /// no attention item, still counts as live (closing the tab would tear
    /// down the session and force a `--resume` later), so we read raw
    /// badges and the agents in front here rather than the attention list. An `.idle` agent (Claude
    /// open at the prompt) has no attention item either, but for
    /// confirm-on-close, idle still counts.
    func hasLiveAgent(in tab: Tab) -> Bool {
        tab.splitTree.allLeafIDs().contains { hasLiveAgent(pane: $0, in: tab) }
    }

    /// Per-pane twin of `hasLiveAgent(in:)`. Used by pane-close
    /// confirmation in a split tab — only the focused leaf is being
    /// torn down, so the question is whether *that* leaf carries a
    /// tracked agent, not the tab as a whole.
    ///
    /// An agent the terminal runs in front counts with or without a
    /// record: a Codex typed into a shell writes its record at its first
    /// prompt, an agent started where Weir's shim installed no hooks
    /// never writes one, and a resume restored at launch is in front
    /// while its record stays unknown until the agent reports. So does
    /// the agent the pane strip's "+" staged before its command runs:
    /// under a tmux Weir hosts, the job in front cannot be told, and the
    /// staged entry is what is left of it.
    ///
    /// A run whose state is unknown and that nothing runs in front of
    /// counts only inside a tmux Weir hosts, where the agent goes on
    /// behind a client that has left. Elsewhere we take it for a run whose
    /// agent ended (`SessionEnd` leaves its record unknown) and whose
    /// badge waits for the sweep that finds its process gone, its pane
    /// back at the shell. A resume restored at launch reads the same until
    /// its terminal is read; the close confirmation reads the terminal
    /// itself at the moment of the close (`AppState.confirmClose`).
    func hasLiveAgent(pane paneID: UUID, in tab: Tab) -> Bool {
        if tab.agentsInFront[paneID] != nil {
            return true
        }
        return AgentKind.allCases.contains { kind in
            tab.agentBadges[kind]?[paneID].map { $0.state != .unknown || $0.isTmuxHosted == true } ?? false
        }
    }

    /// Window-wide twin of `hasLiveAgent(in:)`. Used by ⌘Q's
    /// `onlyWhenAgent` policy so any tab with a tracked agent gates
    /// the terminate.
    func hasLiveAgentAnywhere() -> Bool {
        tabs.contains { hasLiveAgent(in: $0) }
    }

    /// Project-wide twin of `hasLiveAgent(in:)`. Close Project… closes
    /// every tab of the project without `CloseConfirmer`, so its own
    /// confirmation says the agents stop only when one runs there.
    func hasLiveAgent(inProject projectID: UUID) -> Bool {
        tabs.contains { $0.container.projectID == projectID && hasLiveAgent(in: $0) }
    }

    /// "Does any of these panes carry a live agent?" — used by
    /// `CloseConfirmer` so the same predicate works for a single-pane
    /// close (one id), a multi-pane tab close (every leaf), or a
    /// "close N tabs" prompt. Iterates the split tree (not the
    /// badges directly) so we stay symmetrical with
    /// `hasLiveAgent(in:)` / `hasLiveAgentAnywhere()` — a stale badge
    /// for a pane that no longer exists in any tree must not light
    /// the predicate up.
    func hasLiveAgent(inAnyOf paneIDs: [UUID]) -> Bool {
        guard !paneIDs.isEmpty else { return false }
        let needle = Set(paneIDs)
        for tab in tabs {
            for leaf in tab.splitTree.allLeafIDs()
                where needle.contains(leaf) && hasLiveAgent(pane: leaf, in: tab)
            {
                return true
            }
        }
        return false
    }

}
