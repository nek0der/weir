// AgentProjectionAdapter+TabReopen.swift
// Weir — gives a reopened tab's panes the runs they will resume back.

import Foundation

extension AgentProjectionAdapter {
    /// A closed tab comes back under new pane ids (`paneIDs`, old to new):
    /// every resume its panes will type gets its run back. Runs before the
    /// tab is in the session, so no pass can see the panes without their
    /// hints and take their resumes away.
    func reviveRuns(of closed: Tab, paneIDs: [UUID: UUID]) {
        guard writesFiles else { return }
        for (kind, sessions) in closed.agentSessions {
            for (oldPane, session) in sessions {
                guard let newPane = paneIDs[oldPane],
                      closed.tmuxBindings[oldPane] == nil,
                      closed.agentResumeCandidates[oldPane]?.contains(kind) == true
                else { continue }
                executor.reviveRun(provider: kind.rawValue, session: session, fromPane: oldPane, toPane: newPane)
            }
        }
    }
}
