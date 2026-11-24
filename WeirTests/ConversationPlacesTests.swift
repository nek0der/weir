// ConversationPlacesTests.swift
// Weir — where conversations run and what the tabs are, kept apart from what a run is doing.

import Foundation
import Observation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct ConversationPlacesTests {
    private static func key(_ id: String) -> ConversationKey {
        TurnSummaryFixture.conversation(id)
    }

    private static func badge(at seconds: TimeInterval, detail: String? = nil) -> AgentBadge {
        var badge = AgentBadge(state: .running, updatedAt: Date(timeIntervalSince1970: seconds))
        badge.detail = detail
        return badge
    }

    // MARK: - The runs

    /// A hook that changes only what a run is doing, its activity and its
    /// time, leaves the places and the restore gate's runs as they were, so
    /// the changes panel is not drawn again for it.
    @Test func activityOnlyHook_keepsThePlacesAndTheGatesRuns() {
        let pane = UUID()
        let attention = AttentionState()
        let first = AgentRuntimePresentation.test(
            badge: Self.badge(at: 100, detail: "Bash: sleep 1"),
            paneIDs: [pane],
            conversation: Self.key("a")
        )
        attention.replaceRuntimes([first], kind: .claude)
        let placesChanged = Recorded(false)
        let gateChanged = Recorded(false)
        withObservationTracking {
            _ = attention.conversationPlaces
        } onChange: {
            placesChanged.value = true
        }
        withObservationTracking {
            _ = attention.restoreGateRuntimes
        } onChange: {
            gateChanged.value = true
        }

        let next = AgentRuntimePresentation.test(
            badge: Self.badge(at: 101, detail: "Bash: sleep 2"),
            paneIDs: [pane],
            conversation: Self.key("a")
        )
        attention.replaceRuntimes([next], kind: .claude)

        #expect(attention.runtimesByKind[.claude] == [next])
        #expect(!placesChanged.value)
        #expect(!gateChanged.value)
        #expect(attention.conversationPlaces.headerConversation[pane] == Self.key("a"))
    }

    /// A run that moves to another pane moves its conversation there.
    @Test func runInAnotherPane_movesItsConversation() {
        let (pane, other) = (UUID(), UUID())
        let attention = AttentionState()
        attention.replaceRuntimes([.test(paneIDs: [pane], conversation: Self.key("a"))], kind: .claude)
        let placesChanged = Recorded(false)
        withObservationTracking {
            _ = attention.conversationPlaces
        } onChange: {
            placesChanged.value = true
        }

        attention.replaceRuntimes([.test(paneIDs: [other], conversation: Self.key("a"))], kind: .claude)

        #expect(placesChanged.value)
        #expect(attention.conversationPlaces.headerConversation == [other: Self.key("a")])
    }

    /// Each pane's header speaks for its latest run whose state is known, and
    /// the provider's titles are that run's; a run of unknown state names
    /// nothing.
    @Test func places_takeTheLatestKnownRunOfEachPane() {
        let pane = UUID()
        let titled = { (seconds: TimeInterval, title: String) in
            var badge = Self.badge(at: seconds)
            badge.providerSessionTitle = title
            return badge
        }
        var unknownBadge = Self.badge(at: 300)
        unknownBadge.state = .unknown
        let older = AgentRuntimePresentation.test(runID: "older", badge: titled(100, "Older"), paneIDs: [pane], conversation: Self.key("a"))
        let newer = AgentRuntimePresentation.test(runID: "newer", badge: titled(200, "Newer"), paneIDs: [pane], conversation: Self.key("a"))
        let unknown = AgentRuntimePresentation.test(runID: "unknown", badge: unknownBadge, paneIDs: [pane], conversation: Self.key("b"))

        let places = ConversationPlaces(runtimes: [older, newer, unknown])

        #expect(places.headerConversation == [pane: Self.key("a")])
        #expect(places.providerTitles[.init(paneID: pane, conversation: Self.key("a"))]?.session == "Newer")
        #expect(places.providerTitles[.init(paneID: pane, conversation: Self.key("b"))] == nil)
    }

    /// A session in a tab behind the one on screen still runs in the pane:
    /// the mapping places it there after the conversation the header speaks
    /// for, as it did from the runs.
    @Test func conversationTabs_placeASessionBehindTheShownTab() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        _ = session
        let front = AgentRuntimePresentation.test(runID: "front", paneIDs: [pane], conversation: Self.key("a"))
        var behind = AgentRuntimePresentation.test(runID: "behind", conversation: Self.key("b"))
        behind.panesBehindShownTab = [pane]

        let fromRuns = ConversationTabs(tabs: [tab], runtimes: [front, behind])
        let fromPlaces = ConversationTabs(outlines: [TabOutline(tab)], places: ConversationPlaces(runtimes: [front, behind]))

        #expect(fromRuns.conversations(of: tab.id)?.all == [Self.key("a"), Self.key("b")])
        #expect(fromRuns.place(of: Self.key("b"))?.paneID == pane)
        #expect(fromPlaces == fromRuns)
    }

    // MARK: - The tabs

    /// A badge written into a tab leaves the tabs' outlines as they were;
    /// renaming the tab changes them.
    @Test func badgeOnlyTabWrite_keepsTheOutlines() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let outlinesChanged = Recorded(false)
        withObservationTracking {
            _ = session.tabOutlines
        } onChange: {
            outlinesChanged.value = true
        }

        session.update(tab.id) { $0.agentBadges[.claude] = [pane: Self.badge(at: 100, detail: "Bash: sleep 1")] }
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: Self.badge(at: 101, detail: "Bash: sleep 2")] }
        #expect(!outlinesChanged.value)

        session.update(tab.id) { $0.titleOverride = "Renamed" }
        #expect(outlinesChanged.value)
        #expect(session.tabOutlines.map(\.titleOverride) == ["Renamed"])
    }

    /// A pass that changes no tab writes no tabs, and one that changes
    /// several gives each its change.
    @Test func applyAcrossTabs_writesNoTabsWhenNoneChanges() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        session.openTab(container: .loose)
        let writes = Recorded(0)
        func watch() {
            withObservationTracking {
                _ = session.tabs
            } onChange: {
                writes.value += 1
            }
        }
        watch()

        session.applyAcrossTabs { _ in }
        #expect(writes.value == 0)

        session.applyAcrossTabs { $0.titleOverride = "Renamed" }
        #expect(writes.value > 0)
        #expect(session.tabs.map(\.titleOverride) == ["Renamed", "Renamed"])
    }

    /// The focused pane is read from the outlines, as the tab's split tree
    /// has it.
    @Test func focusedPane_isTheActiveTabsFocusedPane() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()

        #expect(session.tabOutlines == [TabOutline(tab)])
        #expect(session.focusedPaneID(in: session.primaryWindowID) == pane)
    }
}
