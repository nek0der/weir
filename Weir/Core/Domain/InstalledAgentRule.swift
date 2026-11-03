// InstalledAgentRule.swift
// Weir — which agents a list names: the ones found on this Mac, until they were looked for, every one.

import Foundation

/// Which of the agents a list could name it does name. A person who never
/// installed an agent's CLI is not shown it, so the "+" menu and the plan
/// usage panel do not grow with every agent Weir supports.
package enum InstalledAgentRule {
    /// The agents of `catalog`, in its order, that were found
    /// (`installed`) or that the list has something of its own to show for
    /// (`alsoShowing`, as an agent whose usage was reported). Every one
    /// while `installed` is `nil`, before they were looked for once: a list
    /// opened as the app starts would otherwise name none.
    package static func shown(
        catalog: [AgentKind],
        installed: [AgentKind]?,
        alsoShowing: Set<AgentKind> = []
    ) -> [AgentKind] {
        guard let installed else { return catalog }
        return catalog.filter { installed.contains($0) || alsoShowing.contains($0) }
    }
}
