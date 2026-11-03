// WorkspaceSession+Tmux.swift
// Weir — records, at quit, which tmux session each pane was showing,
// so the next launch can put it back there instead of leaving the
// session running unreferenced while a fresh shell starts beside it.

import Foundation

extension WorkspaceSession {
    /// Both ongoing capture and final flush consume the same verified values.
    /// An unavailable server is not evidence that the user detached.
    ///
    /// A pane with no surface, or none that reports a tty, is one we learned
    /// nothing about (usually a tab not opened this run), so its binding
    /// stands. Entries are rebuilt from each tab's leaves, so a pane the tab
    /// no longer has loses its own.
    func captureTmuxBindings(
        surfaces: [TmuxSurfaceSnapshot], bindings: [UUID: TmuxBinding],
        observedAt: [String: TimeInterval], now: TimeInterval, detachedPaneIDs: Set<UUID>
    ) {
        for index in tabs.indices {
            var next: [UUID: TmuxBinding] = [:]
            for pane in tabs[index].splitTree.allLeafIDs() {
                guard let surface = surfaces.first(where: { $0.paneID == pane }), surface.tty != nil else {
                    next[pane] = tabs[index].tmuxBindings[pane]
                    continue
                }
                guard surface.isTmuxClient else {
                    // A newly mounted shell after a skipped/provisional
                    // restore is not a user detach. Only a witnessed exit
                    // from tmux grants authority to erase that restore hint.
                    if !detachedPaneIDs.contains(pane) {
                        next[pane] = tabs[index].tmuxBindings[pane]
                    }
                    continue
                }
                if let binding = bindings[pane], let stamp = observedAt[binding.socketPath],
                   now - stamp <= TmuxTiming.snapshotLifetime
                {
                    next[pane] = binding
                } else if var prior = tabs[index].tmuxBindings[pane] {
                    prior.isProvisional = true
                    next[pane] = prior
                }
            }
            if tabs[index].tmuxBindings != next {
                tabs[index].tmuxBindings = next
            }
        }
    }
}
