// AgentIntegrationServiceAlertTests.swift
// Weir — the approval service alert answers for the reason it shows.

import Testing
@testable import Weir

struct AgentIntegrationServiceAlertTests {
    private typealias Slot = AgentIntegrationServiceAlertSlot

    private static func issue(_ reason: AgentIntegrationServiceIssue.Reason) -> AgentIntegrationServiceIssue {
        AgentIntegrationServiceIssue(reason: reason, diagnostic: nil)
    }

    /// The backoff shows the generic failure, and a replacement refused on a
    /// disk image then turns it into the disk image's. The alert presented
    /// first must give way, so the one on screen has no Retry.
    @Test func reasonChanges_theEarlierAlertStepsAsideAndTheNewOneShows() {
        let failed = Slot(reason: .reconciliationFailed)
        let temporary = Slot(reason: .temporaryLocation)
        let current = Self.issue(.temporaryLocation)

        #expect(!failed.isPresented(for: current, isShown: true))
        #expect(temporary.isPresented(for: current, isShown: true))
        #expect(Slot.actions(for: .temporaryLocation) == [])
    }

    /// The earlier alert closing as it steps aside is not the person's
    /// answer, and must not dismiss the issue that replaced it.
    @Test func reasonChanges_theEarlierAlertClosing_doesNotDismissTheNewIssue() {
        let failed = Slot(reason: .reconciliationFailed)
        #expect(!failed.dismisses(Self.issue(.temporaryLocation), isShown: true))
        #expect(failed.dismisses(Self.issue(.reconciliationFailed), isShown: true))
    }

    @Test func anotherWindow_neitherShowsNorDismisses() {
        let slot = Slot(reason: .reconciliationFailed)
        let current = Self.issue(.reconciliationFailed)
        #expect(!slot.isPresented(for: current, isShown: false))
        #expect(!slot.dismisses(current, isShown: false))
    }

    @Test func noIssue_presentsNothing() {
        #expect(!Slot(reason: nil).isPresented(for: nil, isShown: true))
        #expect(!Slot(reason: .reconciliationFailed).isPresented(for: nil, isShown: true))
    }

    @Test func actions_followTheReason() {
        #expect(Slot.actions(for: .requiresApproval) == [.openLoginItems, .retry])
        #expect(Slot.actions(for: .serviceNotFound) == [.retry])
        #expect(Slot.actions(for: .reconciliationFailed) == [.retry])
        #expect(Slot.actions(for: .temporaryLocation) == [])
    }
}
