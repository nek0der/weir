// AppState+GitSync.swift
// Weir — starts worktree sync only for sessions with real folders.

extension AppState {
    /// Starts worktree sync for a live session, or returns nil in demo
    /// mode, which keeps the fixture's projects and Git facts because
    /// its folders do not exist.
    static func makeGitSync(
        session: WorkspaceSession,
        readsFolders: Bool = writesUserFilesAtLaunch
    ) -> GitSyncCoordinator? {
        guard readsFolders else { return nil }
        return GitSyncCoordinator(session: session)
    }
}
