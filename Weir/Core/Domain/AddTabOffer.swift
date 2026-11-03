// AddTabOffer.swift
// Weir — which agents the pane strip's "+" offers, and the one note under them.

import Foundation

/// What the pane strip's "+" lists before its shell: the agents found on
/// this Mac, in the catalog's order, and at most one note. A person who
/// never installed an agent's CLI never sees it there; the new worktree
/// sheet, which also names the one a person chose before, lists every one
/// (`WorktreeOpenChoice.menuAgents`).
package struct AddTabOffer: Hashable, Sendable {
    /// The line under the items, said once for all of them rather than
    /// under each.
    package enum Note: Hashable, Sendable {
        /// An agent already works in the folder the tab opens in, so a
        /// second one edits the same files.
        case agentAlreadyWorking
        /// Nothing was found, which more often means a `PATH` we cannot
        /// read than an agent never installed: the note says where we
        /// looked, so the person can tell which.
        case noAgentFound
    }

    package let agents: [AgentKind]
    /// `nil` for no note.
    package let note: Note?

    /// The offer for `catalog`. `installed` is `nil` until the agents were
    /// looked for once, and then every one is offered (`InstalledAgentRule`),
    /// so the note never says none was found when none was looked for.
    package init(catalog: [AgentKind], installed: [AgentKind]?, isAgentWorkingInFolder: Bool) {
        agents = InstalledAgentRule.shown(catalog: catalog, installed: installed)
        note = if agents.isEmpty {
            .noAgentFound
        } else if isAgentWorkingInFolder {
            .agentAlreadyWorking
        } else {
            nil
        }
    }
}
