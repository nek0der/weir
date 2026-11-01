// CommitAndPRStores.swift
// Weir — what the changes panel's "Commit & PR" reads and changes, handed over by the app.

/// The stores the "Commit & PR" section's actions use (`CommitAndPRActions`)
/// beyond the panel's own, and nothing else of the app. The app builds it
/// (`AppState.commitAndPRStores`).
@MainActor
struct CommitAndPRStores {
    /// The panel's stores, whose session, turns, and way to the review the
    /// section shares.
    let changes: ChangesPanelStores
    let gitFacts: GitFactsStore
    let prStatus: PRStatusStore
    let settingsStore: SettingsStore
}
