// PaneActionsTests.swift
// Weir — the pane-level verbs that wrap WorkspaceSession mutations.
//
// Registry-coupled actions inject the production `NoopSurfaceRegistry`
// (already used by SwiftUI previews) so we exercise the same code path
// without instantiating a real libghostty surface.

import Foundation
import GhosttyKit
import Testing
@testable import Weir
@testable import WeirDomain

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
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == focused)

        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == nil)
        #expect(session.tab(tab.id)?.splitTree == active.splitTree)

        session.update(tab.id) { $0.splitTree.focusedLeafID = nil }
        PaneActions.toggleZoom(session)
        #expect(session.tab(tab.id)?.zoomedLeafID == paneA)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == paneA)
    }

    @Test("splitting while zoomed exits zoom so the new sibling is visible")
    func split_whileZoomed_clearsZoom() throws {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        PaneActions.split(session, direction: .horizontal)
        let split = try #require(session.tab(tab.id))
        let second = try #require(split.splitTree.focusedLeafID)
        try #require(split.splitTree.allLeafIDs() == [first, second])
        PaneActions.toggleZoom(session)
        try #require(session.tab(tab.id)?.zoomedLeafID == second)

        PaneActions.split(session, direction: .vertical)
        let unzoomed = try #require(session.tab(tab.id))
        let new = try #require(unzoomed.splitTree.focusedLeafID)
        #expect(new != first && new != second)
        #expect(unzoomed.splitTree.allLeafIDs() == [first, second, new])
        #expect(unzoomed.zoomedLeafID == nil)
        let root = try #require(unzoomed.splitTree.root)
        guard case let .split(row) = root, case let .split(column) = row.second else {
            Issue.record("Expected a column beside the first pane")
            return
        }
        #expect(row.direction == .horizontal)
        #expect(row.first == .leaf(id: first))
        #expect(column.direction == .vertical)
        #expect(column.first == .leaf(id: second))
        #expect(column.second == .leaf(id: new))
    }

    @Test("split preflight accounts for siblings hidden by zoom")
    func splitPreflight_zoomedTree_rejectsInsufficientPaneAreaInItsWindow() throws {
        let (session, primaryTab, _, tab, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let window = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tab.id, in: window)
        for _ in 0..<3 {
            PaneActions.split(session, direction: .horizontal, in: window)
        }
        PaneActions.toggleZoom(session, in: window)
        let before = try #require(session.tab(tab.id))
        let pivot = try #require(before.splitTree.focusedLeafID)
        try #require(before.splitTree.allLeafIDs().count == 4)
        try #require(before.zoomedLeafID == pivot)
        let registry = MountedPaneRegistry(pane: pivot, size: CGSize(width: 400, height: 400))
        let toasts = ToastCenter()
        defer { toasts.dismiss(in: window) }

        PaneActions.split(
            session, direction: .horizontal, registry: registry, minPaneSize: 80,
            toastCenter: toasts, in: window
        )

        #expect(session.tab(tab.id)?.splitTree == before.splitTree)
        #expect(session.tab(tab.id)?.zoomedLeafID == pivot)
        #expect(session.tab(primaryTab.id)?.splitTree == primaryTab.splitTree)
        #expect(toasts.current(in: window)?.message.resolved(in: Locale(identifier: "en")) == "Not enough room to split")
        #expect(toasts.current(in: session.primaryWindowID) == nil)
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
        #expect(Set(stacked.allLeafIDs()) == [a, b, c])
        #expect(stacked.allLeafIDs().count == 3)
        let area = CGSize(width: 200, height: 400)
        let minimum: PaneMinimumSize = 80
        #expect(row.root?.minimumExtent(along: .horizontal, leafMinimum: minimum) == 242)
        #expect(row.root?.minimumExtent(along: .vertical, leafMinimum: minimum) == 80)
        #expect(stacked.root?.minimumExtent(along: .horizontal, leafMinimum: minimum) == 161)
        #expect(stacked.root?.minimumExtent(along: .vertical, leafMinimum: minimum) == 161)

        #expect(PaneActions.fitsPaneArea(
            stacked,
            replacing: row,
            availableSize: area,
            minPaneSize: minimum
        ))
        // The same rearrangement helps width but worsens an undersized height.
        #expect(!PaneActions.fitsPaneArea(
            stacked,
            replacing: row,
            availableSize: CGSize(width: 200, height: 100),
            minPaneSize: minimum
        ))
    }

    @Test("a candidate that needs more room than the area and the current tree is rejected")
    func fitsPaneArea_candidateLargerThanArea_isRejected() {
        let a = UUID()
        let tree = SplitTree(leafID: a)
        let candidate = tree.insert(at: a, direction: .horizontal, newID: UUID()).tree
        let minimum: PaneMinimumSize = 80
        #expect(tree.root?.minimumExtent(along: .horizontal, leafMinimum: minimum) == 80)
        #expect(candidate.root?.minimumExtent(along: .horizontal, leafMinimum: minimum) == 161)

        #expect(!PaneActions.fitsPaneArea(
            candidate,
            replacing: tree,
            availableSize: CGSize(width: 100, height: 400),
            minPaneSize: 80
        ))
    }

    @Test("closeActivePane clears zoom when the zoomed leaf is the one removed")
    func closeActivePane_removesZoomedLeaf_clearsZoom() throws {
        let (session, tab, first) = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        let second = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        try #require(second != first)
        PaneActions.toggleZoom(session)
        try #require(session.tab(tab.id)?.zoomedLeafID == second)

        PaneActions.closeActivePane(session, registry: registry)
        let remaining = try #require(session.tab(tab.id))
        #expect(remaining.splitTree.allLeafIDs() == [first])
        #expect(remaining.splitTree.effectiveFocusedLeafID == first)
        #expect(remaining.zoomedLeafID == nil)
        #expect(registry.unregisteredIDs == [second])
    }

    /// Closing a pane reconciles the registry with every tab's leaves, not
    /// only the active tab's: a surface of an inactive tab left out would
    /// be swept, and the next visit to that tab would start a fresh shell
    /// over the pty still running.
    @Test("closeActivePane keeps inactive tabs' surfaces in the reconcile set")
    func closeActivePane_doesNotSweepInactiveTabsSurfaces() throws {
        let (session, tabA, paneA, _, paneB) = WorkspaceSessionFixture.withTwoLooseTabs()
        let registry = RecordingSurfaceRegistry()
        PaneActions.split(session, direction: .horizontal)
        let split = try #require(session.tab(tabA.id))
        let closing = try #require(split.splitTree.focusedLeafID)
        try #require(split.splitTree.allLeafIDs() == [paneA, closing])

        PaneActions.closeActivePane(session, registry: registry)

        #expect(registry.unregisteredIDs == [closing])
        #expect(registry.lastReconcileIDs == [paneA, paneB])
        #expect(session.tab(tabA.id)?.splitTree.allLeafIDs() == [paneA])
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
        let (session, tabID, a, b, c) = try Self.threePanes()
        let registry = RecordingSurfaceRegistry()
        let surfaceA = RecordingPaneSurface()
        registry.surfaces[a] = surfaceA

        PaneActions.removeClosedLeaf(
            c, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
        )

        #expect(session.tab(tabID)?.splitTree.allLeafIDs() == [a, b])
        #expect(session.tab(tabID)?.splitTree.focusedLeafID == a)
        #expect(surfaceA.keyboardFocusRequests == 0)
        #expect(registry.unregisteredIDs == [c])
    }

    @Test("the focused pane's shell ending hands the keyboard to the pane that takes the focus")
    func removeClosedLeaf_focusedPane_pullsKeyboardToSuccessor() throws {
        let (session, tabID, a, b, c) = try Self.threePanes()
        let registry = RecordingSurfaceRegistry()
        let surfaceB = RecordingPaneSurface()
        registry.surfaces[b] = surfaceB

        PaneActions.removeClosedLeaf(
            a, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: true
        )

        let focused = try #require(session.tab(tabID)?.splitTree.focusedLeafID)
        #expect(focused != a)
        #expect(focused == b)
        #expect(session.tab(tabID)?.splitTree.allLeafIDs() == [b, c])
        #expect(surfaceB.keyboardFocusRequests == 1)
        #expect(registry.unregisteredIDs == [a])
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
        try withTempDir { directory in
            let (session, tabID, a, b, c) = try Self.threePanes()
            let registry = RecordingSurfaceRegistry()
            let closing = try Self.transferState("closing", agent: .claude, in: directory)
            let survivor = try Self.transferState("survivor", agent: .codex, in: directory)
            let survivorSearch = PaneSearchState()
            survivorSearch.needle = "kept"
            let survivorTransients = PaneTransients(isBellRinging: false, workingDirectory: "/survivor")
            session.update(tabID) { tab in
                tab.apply(closing, to: c)
                tab.apply(survivor, to: a)
                tab.scrollbackPaths[b] = "/tmp/keep-scrollback"
            }
            session.paneSearchStates[c] = PaneSearchState()
            session.paneSearchStates[a] = survivorSearch
            session.paneTransients[c] = PaneTransients(isBellRinging: true)
            session.paneTransients[a] = survivorTransients
            let removedFile = try #require(closing.initialPromptFile)
            let keptFile = try #require(survivor.initialPromptFile)
            try #require(FileManager.default.fileExists(atPath: removedFile))
            let seeded = try #require(session.tab(tabID))
            try #require(seeded.paneTransferState(of: c) == closing)
            try #require(seeded.paneTransferState(of: a) == survivor)

            PaneActions.removeClosedLeaf(
                c, fromTab: tabID, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: false
            )

            let tab = try #require(session.tab(tabID))
            #expect(tab.paneTransferState(of: c) == Tab.PaneTransferState())
            #expect(tab.paneTransferState(of: a) == survivor)
            #expect(tab.scrollbackPaths[b] == "/tmp/keep-scrollback")
            #expect(session.paneSearchStates[c] == nil)
            #expect(session.paneSearchStates[a] === survivorSearch)
            #expect(session.paneTransients[c] == nil)
            #expect(session.paneTransients[a] == survivorTransients)
            #expect(!FileManager.default.fileExists(atPath: removedFile))
            #expect(try String(contentsOfFile: keptFile, encoding: .utf8) == "survivor")
            #expect(registry.unregisteredIDs == [c])
            #expect(registry.lastReconcileIDs == [a, b])
        }
    }

    private static func transferState(_ label: String, agent: AgentKind, in directory: URL) throws -> Tab.PaneTransferState {
        let prompt = try InitialPromptFile.stagedByEarlierBuild(label, in: directory)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        return Tab.PaneTransferState(
            paneState: PaneState(unreadCount: 7, name: label),
            agentSessions: [agent: AgentSessionInfo(sessionId: label, cwd: directory.path)],
            agentBadges: [agent: AgentBadge(state: .running, detail: label, runStartedAt: time, updatedAt: time)],
            agentInFront: PaneAgentInFront(kind: agent, isStaged: true),
            scrollbackPath: directory.appendingPathComponent("\(label).vt").path,
            initialCommand: "echo \(label)",
            initialPromptFile: prompt.path,
            initialAgentExecutable: AgentInstallation(kind: agent, executable: "/test/bin/\(label)"),
            tmuxBinding: TmuxBinding(socketPath: directory.appendingPathComponent("socket").path, sessionID: "$1", sessionName: label)
        )
    }

    @Test("the last pane closing closes its tab", arguments: [false, true])
    func removeClosedLeaf_lastPane_closesTab(_ hasNeighbor: Bool) {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        let neighbor = hasNeighbor ? session.openTab(
            container: .loose, in: session.primaryWindowID, intent: .repair, selects: false
        ) : nil
        #expect(session.activeTab(in: session.primaryWindowID)?.id == tab.id)

        let registry = RecordingSurfaceRegistry()
        PaneActions.removeClosedLeaf(
            pane, fromTab: tab.id, session, registry: registry, agentProjection: nil, pullsKeyboardFocus: true
        )

        #expect(session.tab(tab.id) == nil)
        #expect(session.activeTab(in: session.primaryWindowID)?.id == neighbor?.id)
        #expect(session.tabs.map(\.id) == (neighbor.map { [$0.id] } ?? []))
        #expect(registry.unregisteredIDs == [pane])
    }

    @Test("jumping to a pane from a notification ends a zoom on another pane")
    func jumpToPane_whileAnotherPaneIsZoomed_unzooms() throws {
        let (session, tabID, a, b, _) = try Self.threePanes()
        session.update(tabID) { $0.zoomedLeafID = a }

        let registry = RecordingSurfaceRegistry()
        let surface = RecordingPaneSurface()
        let zoomedSurface = RecordingPaneSurface()
        registry.surfaces[b] = surface
        registry.surfaces[a] = zoomedSurface
        jumpToPane(a, session: session, registry: registry, in: session.primaryWindowID, intent: .person)
        #expect(session.tab(tabID)?.zoomedLeafID == a)
        #expect(session.tab(tabID)?.splitTree.focusedLeafID == a)
        #expect(zoomedSurface.keyboardFocusRequests == 1)

        jumpToPane(b, session: session, registry: registry, in: session.primaryWindowID, intent: .person)
        #expect(session.tab(tabID)?.zoomedLeafID == nil)
        #expect(session.tab(tabID)?.splitTree.focusedLeafID == b)
        #expect(surface.keyboardFocusRequests == 1)
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
        let registry = RecordingSurfaceRegistry()
        let surface = RecordingPaneSurface()
        registry.surfaces[paneA] = surface
        PaneActions.split(session, direction: .horizontal)
        let before = try #require(session.tab(tab.id))
        let priorFocus = try #require(before.splitTree.focusedLeafID)
        try #require(priorFocus != paneA)
        PaneActions.focusPane(session, registry: registry, direction: .left)
        let focused = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        #expect(focused == paneA)
        #expect(surface.keyboardFocusRequests == 1)
        #expect(session.tab(tab.id)?.title == before.title)
    }

    @Test("focusPane is a no-op on a single-leaf tab")
    func focusPane_singleLeaf_doesNothing() {
        let (session, _, paneA) = WorkspaceSessionFixture.withLooseTab()
        let registry = NoopSurfaceRegistry()
        PaneActions.focusPane(session, registry: registry, direction: .right)
        #expect(session.activeTab(in: session.primaryWindowID)?.splitTree.focusedLeafID == paneA)
    }

    @Test("focusPane is a no-op while a pane is zoomed")
    func focusPane_whileZoomed_doesNotMoveFocus() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        let registry = RecordingSurfaceRegistry()
        let surface = RecordingPaneSurface()
        let left = try #require(session.tab(tab.id)?.splitTree.allLeafIDs().first)
        registry.surfaces[left] = surface
        PaneActions.split(session, direction: .horizontal)
        let beforeZoom = try #require(session.tab(tab.id)?.splitTree.focusedLeafID)
        try #require(beforeZoom != left)
        PaneActions.toggleZoom(session)
        try #require(session.tab(tab.id)?.zoomedLeafID == beforeZoom)

        PaneActions.focusPane(session, registry: registry, direction: .left)
        #expect(session.tab(tab.id)?.splitTree.focusedLeafID == beforeZoom)
        #expect(session.tab(tab.id)?.zoomedLeafID == beforeZoom)
        #expect(surface.keyboardFocusRequests == 0)
    }

    // MARK: - In a window of its own

    @Test("split, equalize, and zoom act on the tab of the window they run in")
    func splitEqualizeAndZoom_inASecondWindow_actOnThatWindowsTab() throws {
        let (session, primaryProject) = WorkspaceSessionFixture.withProject()
        let primary = session.primaryWindowID
        let tabA = session.openTab(container: .project(primaryProject.id), in: primary)
        let otherProject = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("split-other"),
            suggestedName: "other"
        )
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let tabB = session.openTab(container: .project(otherProject.id), in: other)
        try #require(session.selection(other)?.activeTabID == tabB.id)
        try #require(session.selection(primary)?.activeTabID == tabA.id)

        PaneActions.split(session, direction: .horizontal, in: other)
        let afterSplit = try #require(session.tab(tabB.id))
        let focus = try #require(afterSplit.splitTree.focusedLeafID)
        let first = try #require(tabB.splitTree.focusedLeafID)
        try #require(afterSplit.splitTree.allLeafIDs() == [first, focus])

        session.update(tabB.id) { tab in
            tab.splitTree = tab.splitTree.resize(
                splitAt: [], by: 200, bounds: CGSize(width: 800, height: 600), minSize: 80
            )
        }
        if case let .split(skewed) = session.tab(tabB.id)?.splitTree.root {
            try #require(skewed.ratio != 0.5)
        } else {
            Issue.record("Expected the second window's off-center split")
        }
        PaneActions.equalizeSplits(session, in: other)
        let equalized = try #require(session.tab(tabB.id)?.splitTree)
        #expect(equalized.root == .split(PaneSplit(direction: .horizontal, ratio: 0.5, first: .leaf(id: first), second: .leaf(id: focus))))

        PaneActions.toggleZoom(session, in: other)
        #expect(session.tab(tabB.id)?.zoomedLeafID == focus)
        PaneActions.toggleZoom(session, in: other)
        #expect(session.tab(tabB.id)?.zoomedLeafID == nil)
        #expect(session.tab(tabB.id)?.splitTree == equalized)
        #expect(session.tab(tabA.id)?.splitTree == tabA.splitTree)
        #expect(session.tab(tabA.id)?.zoomedLeafID == nil)
        #expect(session.selection(primary)?.activeTabID == tabA.id)
    }

    @Test("activateAndFocus brings the pane's tab forward in the window given")
    func activateAndFocus_inASecondWindow_leavesThePrimaryAlone() throws {
        let (session, tabA, _, tabB, paneB) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let sibling = UUID()
        session.update(tabB.id) { tab in
            tab.splitTree = tab.splitTree.insert(at: paneB, direction: .horizontal, newID: sibling).tree
        }
        try #require(session.tab(tabB.id)?.splitTree.focusedLeafID == sibling)
        try #require(session.selection(other)?.activeTabID == nil)

        let registry = RecordingSurfaceRegistry()
        let target = RecordingPaneSurface()
        let previous = RecordingPaneSurface()
        registry.surfaces[paneB] = target
        registry.surfaces[sibling] = previous
        PaneActions.activateAndFocus(session, registry: registry, tabID: tabB.id, paneID: paneB, in: other)

        #expect(session.selection(other)?.activeTabID == tabB.id)
        #expect(session.tab(tabB.id)?.splitTree.focusedLeafID == paneB)
        #expect(target.keyboardFocusRequests == 1)
        #expect(previous.keyboardFocusRequests == 0)
        #expect(session.primarySelection.activeTabID == tabA.id)
        #expect(session.tab(tabA.id)?.splitTree == tabA.splitTree)
    }
}

/// Only the zoomed leaf is mounted. Its size is the whole visible pane area.
@MainActor
private final class MountedPaneRegistry: PaneSurfaceProviding, PaneSurface {
    let pane: UUID
    let boundsSize: CGSize

    init(pane: UUID, size: CGSize) {
        self.pane = pane
        boundsSize = size
    }

    var surface: ghostty_surface_t? {
        nil
    }

    var ttyName: String? {
        nil
    }

    var isInWindow: Bool {
        true
    }

    var rectInWindow: CGRect {
        CGRect(origin: .zero, size: boundsSize)
    }

    var holdsKeyboardFocus: Bool {
        false
    }

    func paneSurface(for id: UUID) -> (any PaneSurface)? {
        id == pane ? self : nil
    }

    func unregister(_: UUID) {}
    func reconcile(activeIDs _: Set<UUID>) {}
    func deliverer(for _: UUID) -> (any ReviewTextDelivering)? {
        nil
    }

    func writeScrollback(ofPane _: UUID, to _: URL) -> Bool {
        false
    }

    func takeKeyboardFocus() {}
}
