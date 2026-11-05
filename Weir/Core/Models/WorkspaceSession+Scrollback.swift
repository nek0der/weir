// WorkspaceSession+Scrollback.swift
// Weir — session-restore plumbing on top of the ghostty fork's
// `ghostty_surface_write_scrollback` / `initial_scrollback_path` C
// API. Quit captures every live surface's scrollback into a `.vt`
// file under Application Support and remembers the path on each Tab;
// restore plumbs the path back through `SurfaceView.initialScrollbackPath`
// so libghostty replays it before the first prompt.
//
// File lifecycle:
//   * Files live in the folder the app hands the session
//     (`scrollbackFiles`): `<WeirPaths app support>/scrollback/`.
//   * One per pane, named `<paneUUID>.vt` (`ScrollbackFiles`).
//   * Captured fresh on every ⌘Q.
//   * Consumed in `PaneHostView.stageScrollback` through
//     `consumeScrollbackPath`: the path is moved onto the SurfaceView and
//     immediately cleared from the model so a later split / re-mount
//     can't double-replay.
//   * `ScrollbackFiles.prune` deletes any file not referenced by a live
//     tab so the directory doesn't grow unboundedly across months, except
//     in a run whose state.json was set aside (`keepsUnreferencedFiles`).

import Foundation

@MainActor
extension WorkspaceSession {
    /// Iterate every live surface and ask libghostty to dump its
    /// scrollback to disk. Paths are stashed back into each tab so
    /// `makeSnapshot` carries them through JSON persistence. Called
    /// from `applicationWillTerminate`; crashes only retain whatever
    /// was last debounce-saved (which has no scrollback yet).
    func captureScrollbackPaths(from writer: any ScrollbackWriting) {
        // A demo run's panes are not the person's: writing their scrollback
        // would leave strays, and the prune below would delete the files
        // the person's own state.json points at. A session handed no folder
        // saves none.
        guard writesUserFiles, let files = scrollbackFiles else { return }
        var liveFiles: Set<String> = []
        for tabIdx in tabs.indices {
            // A leaf whose terminal was never mounted this run (a restored
            // tab the person never clicked into) keeps its inherited path:
            // wiping it would also let the prune below delete the `.vt`,
            // taking real scrollback with it.
            let paths = files.capturePaths(
                of: tabs[tabIdx].splitTree.allLeafIDs(),
                inheriting: tabs[tabIdx].scrollbackPaths,
                with: writer
            )
            tabs[tabIdx].scrollbackPaths = paths
            liveFiles.formUnion(paths.values)
        }
        // Keep `.vt` files referenced by the reopen-closed-tab stack
        // too — they're about to be replayed when the user hits ⌘⇧T.
        for closed in closedTabStack {
            for path in closed.tab.scrollbackPaths.values {
                liveFiles.insert(path)
            }
        }
        // The files of a state.json set aside this launch are not this
        // session's; the next launch that reads a state.json prunes them.
        guard !keepsUnreferencedFiles else { return }
        files.prune(keeping: liveFiles)
    }

    /// Takes the saved scrollback path of `paneID` out of its tab and hands
    /// it back, so the pane's terminal replays it once and a later split or
    /// re-mount does not replay it again. `nil`, and nothing changes, when
    /// the pane has no path to replay.
    func consumeScrollbackPath(tabID: UUID, paneID: UUID) -> String? {
        guard let path = tab(tabID)?.scrollbackPaths[paneID], !path.isEmpty else { return nil }
        update(tabID) { tab in
            tab.scrollbackPaths.removeValue(forKey: paneID)
        }
        return path
    }
}
