// AllProjectsStores.swift
// Weir — what the all projects sheet's actions read and change, handed over by the app.

/// The stores the all projects sheet's actions use (`AllProjectsActions`),
/// and nothing else of the app. The app builds it
/// (`AppState.allProjectsStores`).
@MainActor
struct AllProjectsStores {
    let session: WorkspaceSession
    let windows: WindowRegistry
    let attentionQueue: AttentionQueueStore
    /// Project ▾'s order, which opening another project's card counts toward.
    let frecency: FrecencyStore
    /// The terminals, which closing the sheet hands the keyboard to.
    let registry: any SurfaceViewProviding
}
