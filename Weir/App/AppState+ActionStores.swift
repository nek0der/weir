// AppState+ActionStores.swift
// Weir — the narrow sets of stores the supervision window's and the menu bar extra's actions are handed.

import Foundation

/// The closures hold the app state itself, which lives as long as the app,
/// so each reads it afresh when called.
extension AppState {
    /// What the changes panel's actions use (`ChangesPanelActions`): the
    /// app's own stores, and the review tab as the panel's rows open it.
    var changesPanelStores: ChangesPanelStores {
        ChangesPanelStores(
            session: session,
            repositoryRoots: repositoryRoots,
            worktreeChanges: worktreeChanges,
            turnHistory: agentProjection.turnHistory,
            viewedLines: viewedLines,
            attention: attention,
            attentionQueue: attentionQueue,
            toasts: toastCenter,
            conversationIdentities: conversationIdentities,
            isAppActive: { [windowRegistry] in windowRegistry.attention.isAppActive },
            restoredTurnIDs: { self.restoredTurnIDs() },
            restoreGateLookup: { self.restoreGateLookup() },
            restoreRecord: { RestoreActions.record(forRoot: $0, state: self) },
            askRestore: { RestoreActions.ask($0, window: $1, state: self) },
            openReview: { request, pane, conversation, window in
                await ReviewTabActions.open(
                    request,
                    agentPaneID: pane,
                    conversation: conversation,
                    window: window,
                    stores: self.reviewTabStores
                )
            },
            registry: registry,
            paneVisibility: { [windowRegistry] window in
                PaneVisibilityReporter(windowID: window.id, registry: windowRegistry)
            }
        )
    }

    /// What the "Commit & PR" section's actions use (`CommitAndPRActions`).
    var commitAndPRStores: CommitAndPRStores {
        CommitAndPRStores(
            changes: changesPanelStores,
            gitFacts: gitFacts,
            prStatus: prStatusStore,
            settingsStore: settingsStore
        )
    }

    /// What the all projects sheet's actions use (`AllProjectsActions`).
    var allProjectsStores: AllProjectsStores {
        AllProjectsStores(
            session: session,
            windows: windowRegistry,
            attentionQueue: attentionQueue,
            frecency: frecencyStore,
            registry: registry
        )
    }

    /// What the menu bar extra's actions use (`MenuBarActions`).
    var menuBarStores: MenuBarStores {
        MenuBarStores(
            session: session,
            windows: windowRegistry,
            attentionQueue: attentionQueue,
            approvals: approvalPresentation,
            stopLedger: stopLedger,
            resetNotice: { self.usageLimitResetSync?.notice(for: $0, now: $1) },
            requestResetNotice: { _ = SupervisionWindowActions.requestResetNotice($0, state: self) },
            resume: { id, paneID, window in
                SupervisionWindowActions.perform(.resume(id), inPane: paneID, window: window, state: self)
            }
        )
    }

    /// What the review tab's actions use (`ReviewTabActions`).
    var reviewTabStores: ReviewTabStores {
        ReviewTabStores(
            changes: changesPanelStores,
            windows: windowRegistry,
            registry: registry,
            reviewWriters: reviewWriters,
            primaryKeyHint: primaryKeyHint,
            locale: { [settingsStore] in settingsStore.appLocale },
            gitRoot: { [reviewWriters] in try await reviewWriters.root(of: $0) },
            hunks: ReviewHunkDiscardStores(
                session: session,
                windows: windowRegistry,
                toasts: toastCenter,
                turnHistory: agentProjection.turnHistory,
                worktreePaths: worktreePaths,
                restores: restores,
                restoreGateInput: { self.restoreGateInput(for: $0) },
                laterTurns: reviewLaterTurns
            )
        )
    }
}
