// DemoFixture+Approval.swift
// Weir — the one native approval demo mode stages for the documents' captures.

import Foundation
import WeirDomain

extension DemoFixture {
    /// The Claude agent in feat/proration asks to run its tests. Its worktree
    /// is not the one the window shows, so the request stays held for the
    /// card, as it would for a person looking at another worktree.
    static var stagedApproval: ApprovalPresentation {
        ApprovalPresentation(
            epoch: fixtureID(0xF0, 1),
            runID: fixtureID(0xF0, 2),
            requestID: fixtureID(0xF0, 3),
            provider: .claude,
            sessionID: nil,
            operationID: nil,
            toolName: "Bash",
            summary: "pnpm test",
            requestDescription: "Run the billing tests",
            inputDescription: "{\"command\":\"pnpm test\",\"description\":\"Run the billing tests\"}",
            deadlineMilliseconds: stagedApprovalDeadlineMs,
            questions: [],
            command: "pnpm test",
            hasInputCommand: true,
            // The card shows all its input holds, as for a real request of
            // only a command and its description.
            inputAddsToSummary: false,
            // A staged run's id is its pane's (`AgentProjectionAdapter.seedRuntimes`).
            agentRunID: Slot.proration.paneID
        )
    }

    /// Demo mode's store, which reaches for no service: the app's own may be
    /// running, under the same label (`AgentIntegrationServiceRegistrar`).
    @MainActor
    static func makeApprovalStore() -> ApprovalPresentationStore {
        ApprovalPresentationStore(
            decisionSender: { _, _ in },
            serviceClockReader: { throw CancellationError() }
        )
    }

    private static let stagedApprovalDeadlineMs: UInt64 = 600_000

    /// Hands the store the request as the service would, with 8:42 left. A
    /// reading received in the future leaves no time elapsed
    /// (`ServiceDeadline.remaining`), so every capture draws the same clock.
    @MainActor
    static func stageApproval(in store: ApprovalPresentationStore, now: SuspendingClock.Instant = .now) {
        let approval = stagedApproval
        let deadline = ServiceDeadline(
            deadlineMs: stagedApprovalDeadlineMs,
            serviceNowMs: stagedApprovalDeadlineMs - 522_000,
            receivedAt: now.advanced(by: .seconds(86400))
        )
        store.stage(
            ApprovalControllerConnection.Projection(
                sequence: 1,
                requests: [approval],
                terminals: [:],
                missingIDs: [],
                unevictableCount: 0,
                deadlines: [approval.id: deadline]
            ),
            epoch: approval.epoch,
            now: now
        )
    }
}
