// PaneActionsTests.swift
// Weir — the pane-level verbs that wrap WorkspaceSession mutations.
//
// Registry-coupled actions inject the production `NoopSurfaceRegistry`
// (already used by SwiftUI previews) so we exercise the same code path
// without instantiating a real libghostty surface.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("PaneActions")
struct PaneActionsTests {

    // MARK: - Zoom

    @Test("toggleZoom on a single-leaf tab is a no-op")
    func toggleZoom_singleLeaf_doesNothing() {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.toggleZoom(session)
        #expect(session.activeTab(in: session.primaryWindowID)?.zoomedLeafID == nil)
    }

    @Test("toggleZoom on a split tab zooms the focused leaf, then unzooms")
    func toggleZoom_splitTab_togglesFocusedLeaf() throws {
        let (session, tab, paneA) = WorkspaceSessionFixture.withLooseTab()
        // Add a sibling pane so toggleZoom has something to act on.
        PaneActions.split(session, direction: .horizontal)
        let active = try #require(session.tab(tab.id))
        let focused = try #require(active.splitTree.focusedLeafID)
        #expect(focused != paneA)

        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == focused)

        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("splitting while zoomed exits zoom so the new sibling is visible")
    func split_whileZoomed_clearsZoom() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        PaneActions.split(session, direction: .vertical)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    @Test("split preflight accounts for siblings hidden by zoom")
    func hasRoomToSplit_zoomedTree_rejectsInsufficientPaneArea() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let tree = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: b, direction: .horizontal, newID: c).tree
            .insert(at: c, direction: .horizontal, newID: d).tree

        #expect(!PaneActions.hasRoomToSplit(
            tree: tree,
            paneID: d,
            direction: .horizontal,
            availableSize: CGSize(width: 400, height: 400),
            minPaneSize: 80
        ))
    }

    @Test("split preflight accepts a candidate that fits both axes")
    func hasRoomToSplit_singlePane_acceptsSufficientPaneArea() {
        let paneID = UUID()
        let tree = SplitTree(leafID: paneID)

        #expect(PaneActions.hasRoomToSplit(
            tree: tree,
            paneID: paneID,
            direction: .horizontal,
            availableSize: CGSize(width: 400, height: 400),
            minPaneSize: 80
        ))
    }

    @Test("an edge drop that frees room fits an area the current tree overflows")
    func fitsPaneArea_dropThatShrinksTheTree_fitsUndersizedArea() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let row = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: b, direction: .horizontal, newID: c).tree
        let stacked = row.inserting(c, beside: b, on: .bottom)

        #expect(PaneActions.fitsPaneArea(
            stacked,
            replacing: row,
            availableSize: CGSize(width: 200, height: 400),
            minPaneSize: 80
        ))
    }

    @Test("a candidate that needs more room than the area and the current tree is rejected")
    func fitsPaneArea_candidateLargerThanArea_isRejected() {
        let a = UUID()
        let tree = SplitTree(leafID: a)
        let candidate = tree.insert(at: a, direction: .horizontal, newID: UUID()).tree

        #expect(!PaneActions.fitsPaneArea(
            candidate,
            replacing: tree,
            availableSize: CGSize(width: 100, height: 400),
            minPaneSize: 80
        ))
    }

    @Test("closeActivePane clears zoom when the zoomed leaf is the one removed")
    func closeActivePane_removesZoomedLeaf_clearsZoom() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID != nil)

        PaneActions.closeActivePane(session, registry: registry)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
    }

    /// Closing a pane reconciles the registry with every tab's leaves, not
    /// only the active tab's: a surface of an inactive tab left out would
    /// be swept, and the next visit to that tab would start a fresh shell
    /// over the pty still running.
    @Test("closeActivePane keeps inactive tabs' surfaces in the reconcile set")
    func closeActivePane_doesNotSweepInactiveTabsSurfaces() throws {
        let (session, tabA, _, _, paneB) = WorkspaceSessionFixture.withTwoLooseTabs()
        let registry = RecordingSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        // After the split, tabA holds two leaves; the focused one is the
        // newly-spawned sibling. Capture the surviving leaf so we can
        // confirm it remains alongside paneB after the close.
        let liveLeavesBefore = try #require(session.tab(tabA.id))
            .splitTree.allLeafIDs()
        #expect(liveLeavesBefore.count == 2)

        PaneActions.closeActivePane(session, registry: registry)

        let lastReconcile = try #require(registry.lastReconcileIDs)
        // paneB must still appear — the bug would have evicted it.
        #expect(lastReconcile.contains(paneB))
        // The closed leaf is the only one missing from the reconcile.
        let expectedSurvivor = liveLeavesBefore
            .first { $0 != registry.unregisteredIDs.first }
        #expect(expectedSurvivor != nil)
        #expect(try lastReconcile.contains(#require(expectedSurvivor)))
        #expect(lastReconcile.count == 2)
    }

    // MARK: - A pane that closes

    // A tuple keeps the call sites' destructuring, as the fixtures' do.
    // swiftlint:disable large_tuple

    /// Three panes, a | b | c, with `a` focused: the person is in `a`.
    private static func threePanes() throws -> (session: WorkspaceSession, tabID: UUID, a: UUID, b: UUID, c: UUID) {
        let (session, tab, a) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        PaneActions.split(session, direction: .horizontal)
        let leaves = try #require(session.tab(tab.id)).splitTree.allLeafIDs()
        try #require(leaves.count == 3 && leaves[0] == a)
        session.update(tab.id) { $0.splitTree.focusedLeafID = a }
        return (session, tab.id, a, leaves[1], leaves[2])
    }

    // swiftlint:enable large_tuple

    @Test("a pane closing behind the person's back leaves the focus and the keyboard where they were")
    func removeClosedLeaf_unfocusedPane_keepsFocusAndKeyboard() throws {
        let (session, tabID, a, _, c) = try Self.threePanes()
        let registry = RecordingSurfaceRegistry()
        let surfaceA = RecordingPaneSurface()
        registry.surfaces[a] = surfaceA

        PaneActions.removeClosedLeaf(
            c, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
        )

        #expect(session.tab(tabID)?.splitTree.focusedLeafID == a)
        #expect(surfaceA.keyboardFocusRequests == 0)
    }

    @Test("the focused pane's shell ending hands the keyboard to the pane that takes the focus")
    func removeClosedLeaf_focusedPane_pullsKeyboardToSuccessor() throws {
        let (session, tabID, a, b, _) = try Self.threePanes()
        let registry = RecordingSurfaceRegistry()
        let surfaceB = RecordingPaneSurface()
        registry.surfaces[b] = surfaceB

        PaneActions.removeClosedLeaf(
            a, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: true
        )

        let focused = try #require(session.tab(tabID)?.splitTree.focusedLeafID)
        #expect(focused != a)
        #expect(focused == b)
        #expect(surfaceB.keyboardFocusRequests == 1)
    }

    @Test("a hidden pane closing keeps the zoom; the zoomed pane closing ends it")
    func removeClosedLeaf_zoom_endsOnlyWithTheZoomedPane() throws {
        let (session, tabID, a, b, c) = try Self.threePanes()
        let registry = RecordingSurfaceRegistry()
        session.update(tabID) { $0.zoomedLeafID = a }

        PaneActions.removeClosedLeaf(
            b, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
        )
        #expect(session.tab(tabID)?.zoomedLeafID == a)
        #expect(session.tab(tabID)?.splitTree.focusedLeafID == a)

        PaneActions.removeClosedLeaf(
            a, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
        )
        #expect(session.tab(tabID)?.zoomedLeafID == nil)
        #expect(session.tab(tabID)?.splitTree.focusedLeafID == c)
    }

    @Test("a closed pane leaves nothing of its own behind in its tab or the session")
    func removeClosedLeaf_dropsEveryPerPaneEntry() throws {
        let (session, tabID, a, _, c) = try Self.threePanes()
        let registry = RecordingSurfaceRegistry()
        session.update(tabID) { t in
            t.paneStates[c] = PaneState()
            t.scrollbackPaths[c] = "/tmp/scrollback"
            t.initialCommands[c] = "make test"
        }
        session.paneSearchStates[c] = PaneSearchState()
        session.paneTransients[c] = PaneTransients(isBellRinging: true)

        PaneActions.removeClosedLeaf(
            c, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
        )

        let tab = try #require(session.tab(tabID))
        #expect(tab.paneTransferState(of: c) == Tab.PaneTransferState())
        #expect(session.paneSearchStates[c] == nil)
        #expect(session.paneTransients[c] == nil)
        #expect(registry.unregisteredIDs == [c])
        #expect(registry.lastReconcileIDs?.contains(a) == true)
        #expect(registry.lastReconcileIDs?.contains(c) == false)
    }

    @Test("the last pane closing closes its tab")
    func removeClosedLeaf_lastPane_closesTab() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()

        PaneActions.removeClosedLeaf(
            pane, fromTab: tab.id, session, registry: RecordingSurfaceRegistry(), agentProjection: nil, pullsKeyboardFocus: true
        )

        #expect(session.tab(tab.id) == nil)
    }

    @Test("jumping to a pane from a notification ends a zoom on another pane")
    func jumpToPane_whileAnotherPaneIsZoomed_unzooms() throws {
        let (session, tabID, a, b, _) = try Self.threePanes()
        session.update(tabID) { $0.zoomedLeafID = a }

        jumpToPane(b, session: session, registry: NoopSurfaceRegistry(), in: session.primaryWindowID, intent: .person)

        #expect(session.tab(tabID)?.zoomedLeafID == nil)
        #expect(session.tab(tabID)?.splitTree.focusedLeafID == b)
    }

    // MARK: - Equalize

    @Test("equalizeSplits routes the SplitTree primitive through the active tab")
    func equalizeSplits_drivesSplitTreeEqualize() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        // Drift the ratio off-center so equalize has work to do.
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.resize(
                splitAt: [],
                by: 200,
                bounds: CGSize(width: 800, height: 600),
                minSize: 80
            )
        }
        let root = try #require(session.tab(tab.id)?.splitTree.root)
        guard case let .split(beforeData) = root else {
            Issue.record("Expected a split node before equalize")
            return
        }
        #expect(beforeData.ratio != 0.5)

        PaneActions.equalizeSplits(session)

        let afterRoot = try #require(session.tab(tab.id)?.splitTree.root)
        guard case let .split(afterData) = afterRoot else {
            Issue.record("Expected a split node after equalize")
            return
        }
        #expect(afterData.ratio == 0.5)
    }

    // MARK: - Directional focus

    @Test("focusPane moves the focused leaf to the immediate neighbor")
    func focusPane_splitTab_movesFocus() throws {
        let (session, tab, paneA) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        // After split, focused leaf is the new pane (right of paneA).
        PaneActions.focusPane(session, registry: registry, direction: .left)
        let focused = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        #expect(focused == paneA)
    }

    @Test("focusPane is a no-op on a single-leaf tab")
    func focusPane_singleLeaf_doesNothing() {
        let (session, _, paneA) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.focusPane(session, registry: registry, direction: .right)
        #expect(session.activeTab(in: session.primaryWindowID)?.splitTree.focusedLeafID == paneA)
    }

    @Test("toggleZoom pins focusedLeafID to the zoomed leaf even when focus was nil")
    func toggleZoom_pinsFocusedLeafIDToZoomedLeaf() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        // Wipe focus to force toggleZoom into its fallback path.
        session.update(tab.id) { $0.splitTree.focusedLeafID = nil }
        PaneActions.toggleZoom(session)
        let stored = session.tab(tab.id)
        #expect(stored?.zoomedLeafID != nil)
        #expect(stored?.splitTree.focusedLeafID == stored?.zoomedLeafID)
    }

    @Test("focusPane is a no-op while a pane is zoomed")
    func focusPane_whileZoomed_doesNotMoveFocus() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        let beforeZoom = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        PaneActions.toggleZoom(session)

        PaneActions.focusPane(session, registry: registry, direction: .left)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == beforeZoom)
    }

    // MARK: - In a window of its own

    @Test("split, zoom, and equalize act on the tab of the window they run in")
    func splitAndZoom_inASecondWindow_actOnThatWindowsTab() {
        let (session, tabA, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tabB.id, in: other)

        PaneActions.split(session, direction: .horizontal, in: other)
        #expect(session.tab(tabB.id)?.splitTree.allLeafIDs().count == 2)
        #expect(session.tab(tabA.id)?.splitTree.allLeafIDs().count == 1)

        PaneActions.toggleZoom(session, in: other)
        #expect(session.tab(tabB.id)?.zoomedLeafID != nil)
        PaneActions.toggleZoom(session, in: other)
        #expect(session.tab(tabB.id)?.zoomedLeafID == nil)
        #expect(session.primarySelection.activeTabID == tabA.id)
    }

    @Test("activateAndFocus brings the pane's tab forward in the window given")
    func activateAndFocus_inASecondWindow_leavesThePrimaryAlone() {
        let (session, tabA, _, tabB, paneB) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)

        PaneActions.activateAndFocus(session, registry: NoopSurfaceRegistry(), tabID: tabB.id, paneID: paneB, in: other)

        #expect(session.selection(other)?.activeTabID == tabB.id)
        #expect(session.primarySelection.activeTabID == tabA.id)
    }
}
