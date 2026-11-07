// TabActionsMovePaneTests.swift
// Weir — a pane moved into another tab or a tab of its own, and everything of the pane's that goes with it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("TabActions moving a pane")
struct TabActionsMovePaneTests {

    // A tuple keeps the call sites' destructuring, as the fixtures' do.
    // swiftlint:disable large_tuple

    /// Two loose tabs, the source in front and split in two through the
    /// action the UI uses, so the default case moves a pane out of a tab
    /// that keeps another; `sourcePanes: 1` leaves the source a lone pane.
    /// The pane moved is the one focused after the splits. When staging an
    /// agent, the original pane carries the staged launch instead.
    private static func sessionWithSourceAndTarget(
        sourcePanes: Int = 2,
        running agent: AgentKind? = nil
    ) throws -> (session: WorkspaceSession, source: Tab, target: Tab, movedPane: UUID) {
        let session = WorkspaceSession()
        let target = session.openTab(container: .loose)
        let firstPane = try #require(TabActions.newTab(session, in: .loose, running: agent))
        let source = try #require(session.tab(containing: firstPane))
        for _ in 1..<sourcePanes {
            PaneActions.split(session, direction: .horizontal)
        }
        let live = try #require(session.tab(source.id))
        let focused = try #require(live.splitTree.focusedLeafID)
        return (session, live, target, agent == nil ? focused : firstPane)
    }

    // swiftlint:enable large_tuple

    enum Destination: Sendable {
        case existingTab
        case newTab
    }

    private static func move(_ pane: UUID, in session: WorkspaceSession, to destination: Destination, target: Tab) -> UUID? {
        switch destination {
        case .existingTab:
            TabActions.mergePaneIntoTab(session, paneID: pane, into: target.id)
            return target.id
        case .newTab:
            return TabActions.movePaneToNewTab(session, paneID: pane, in: session.primaryWindowID, intent: .person)
        }
    }

    @Test("dropping a pane on its own tab preserves both tabs and the selection")
    func sourceEqualsTarget_isNoOp() throws {
        let (session, source, _, pane) = try Self.sessionWithSourceAndTarget()
        session.update(source.id) {
            $0.zoomedLeafID = pane
            $0.paneStates[pane] = PaneState(unreadCount: 3, name: "Kept pane")
        }
        let search = PaneSearchState()
        session.paneSearchStates[pane] = search
        let before = session.tabs
        let focused = session.focusedPaneID(in: session.primaryWindowID)

        TabActions.mergePaneIntoTab(session, paneID: pane, into: source.id)

        #expect(session.tabs == before)
        #expect(session.primarySelection.activeTabID == source.id)
        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.focusedPaneID(in: session.primaryWindowID) == focused)
        #expect(session.paneSearchStates[pane] === search)
        #expect(session.closedTabStack.isEmpty)
    }

    @Test(arguments: [1, 2])
    func mergePane_placesItOnTheRight_andRepairsItsSource(sourcePanes: Int) throws {
        let (session, source, target, pane) = try Self.sessionWithSourceAndTarget(sourcePanes: sourcePanes)
        let unrelated = session.openTab(container: .loose, in: session.primaryWindowID, intent: .person, selects: false)
        let first = try #require(target.splitTree.allLeafIDs().first)
        session.setActiveTab(target.id)
        PaneActions.split(session, direction: .vertical)
        let pivot = try #require(session.tab(target.id)?.splitTree.focusedLeafID)
        try #require(session.tab(target.id)?.splitTree.allLeafIDs() == [first, pivot])
        try #require(first != pivot)
        session.setActiveTab(source.id)
        let siblings = source.splitTree.allLeafIDs().filter { $0 != pane }
        try #require(siblings.count == sourcePanes - 1)
        let search = PaneSearchState()
        session.paneSearchStates[pane] = search
        session.setWorkingDirectory(paneID: pane, path: "/tmp/weir-live-merged-pane")
        let previous = ClosedTab(
            tab: Tab(title: "Earlier closed tab", splitTree: SplitTree(leafID: UUID()), container: .loose),
            closedAt: Date(timeIntervalSince1970: 10)
        )
        session.closedTabStack = [previous]

        TabActions.mergePaneIntoTab(session, paneID: pane, into: target.id)

        let merged = try #require(session.tab(target.id))
        #expect(merged.splitTree.allLeafIDs() == [first, pivot, pane])
        guard case let .split(root)? = merged.splitTree.root,
              case let .split(added) = root.second
        else {
            Issue.record("expected a split of the target’s last pane")
            return
        }
        #expect(root.direction == .vertical)
        #expect(root.first.leafID == first)
        #expect(added.direction == .horizontal)
        #expect(added.first.leafID == pivot)
        #expect(added.second.leafID == pane)
        #expect(merged.splitTree.focusedLeafID == pane)
        #expect(session.primarySelection.activeTabID == target.id)
        #expect(session.tab(containing: pane)?.id == target.id)
        #expect(session.tab(unrelated.id) == unrelated)
        #expect(session.paneSearchStates[pane] === search)
        #expect(session.workingDirectory(paneID: pane) == "/tmp/weir-live-merged-pane")
        #expect(session.closedTabStack == [previous])
        if siblings.isEmpty {
            #expect(session.tab(source.id) == nil)
            #expect(session.tabs.map(\.id) == [target.id, unrelated.id])
        } else {
            #expect(session.tab(source.id)?.splitTree.allLeafIDs() == siblings)
            #expect(session.tabs.map(\.id) == [target.id, source.id, unrelated.id])
        }
    }

    @Test(arguments: [Destination.existingTab, .newTab])
    func perPaneState_migratesWithLeaf(_ destination: Destination) throws {
        let (session, source, target, pane) = try Self.sessionWithSourceAndTarget(running: destination == .newTab ? .codex : nil)
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != pane })
        let paneState = PaneState(unreadCount: 7, name: "Tests")
        let siblingState = PaneState(unreadCount: 2, name: "Sibling")
        let scrollback = "/tmp/scrollback-\(pane).vt"
        let command = destination == .newTab ? "codex" : "codex resume moved-session"
        let prompt = "/tmp/weir-prompts/first"
        let found = AgentInstallation(kind: .codex, executable: "/opt/tools/bin/codex")
        let foreground = PaneAgentInFront(kind: .codex, isStaged: true)
        if destination == .newTab {
            try #require(source.agentsInFront[pane] == foreground)
            try #require(session.stagedLaunch(paneID: pane)?.command == command)
        }
        let claudeSession = AgentSessionInfo(sessionId: "claude-\(pane)", cwd: "/tmp/claude")
        let codexSession = AgentSessionInfo(sessionId: "codex-\(pane)", cwd: "/tmp/codex")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claudeBadge = AgentBadge(
            state: .finished, detail: "claude-detail", runStartedAt: now, updatedAt: now, lastPrompt: "claude prompt"
        )
        let codexBadge = AgentBadge(
            state: .running, detail: "codex-detail", runStartedAt: now, updatedAt: now, lastPrompt: "codex prompt"
        )
        let tmux = TmuxBinding(socketPath: "/tmp/weir-moved-tmux.sock", sessionID: "$4", sessionName: "moved")
        session.update(source.id) {
            $0.paneStates[pane] = paneState
            $0.paneStates[sibling] = siblingState
            $0.scrollbackPaths[pane] = scrollback
            $0.initialCommands[pane] = command
            $0.initialPromptFiles[pane] = prompt
            $0.agentSessions[.claude, default: [:]][pane] = claudeSession
            $0.agentSessions[.codex, default: [:]][pane] = codexSession
            $0.agentBadges[.claude, default: [:]][pane] = claudeBadge
            $0.agentBadges[.codex, default: [:]][pane] = codexBadge
            $0.agentsInFront[pane] = foreground
            $0.tmuxBindings[pane] = tmux
        }
        session.stageAgentExecutable(found, paneID: pane)
        session.setWorkingDirectory(paneID: pane, path: "/tmp/weir-moved-live")
        session.setWorkingDirectory(paneID: sibling, path: "/tmp/weir-sibling-live")
        let search = PaneSearchState()
        search.needle = "moved needle"
        session.paneSearchStates[pane] = search

        let destinationID = try #require(Self.move(pane, in: session, to: destination, target: target))
        let moved = try #require(session.tab(containing: pane))
        let remaining = try #require(session.tab(source.id))

        #expect(moved.id == destinationID)
        #expect(remaining.splitTree.allLeafIDs() == [sibling])
        #expect(moved.paneTransferState(of: pane) == Tab.PaneTransferState(
            paneState: paneState,
            agentSessions: [.claude: claudeSession, .codex: codexSession],
            agentBadges: [.claude: claudeBadge, .codex: codexBadge],
            agentInFront: foreground,
            scrollbackPath: scrollback,
            initialCommand: command,
            initialPromptFile: prompt,
            initialAgentExecutable: found,
            tmuxBinding: tmux
        ))
        #expect(remaining.paneTransferState(of: pane) == Tab.PaneTransferState())
        #expect(remaining.paneTransferState(of: sibling) == Tab.PaneTransferState(paneState: siblingState))
        #expect(session.paneState(pane) == paneState)
        #expect(session.stagedLaunch(paneID: pane) == WorkspaceSession.StagedLaunch(
            command: command, promptFile: prompt, agentExecutable: found
        ))
        #expect(session.workingDirectory(paneID: pane) == "/tmp/weir-moved-live")
        #expect(session.workingDirectory(paneID: sibling) == "/tmp/weir-sibling-live")
        #expect(session.paneSearchStates[pane] === search)
        #expect(session.paneSearchStates[pane]?.needle == "moved needle")

        // Without a run's badge, the foreground agent still supplies the pane's provider.
        session.update(moved.id) {
            $0.agentSessions = [:]
            $0.agentBadges = [:]
        }
        #expect(session.tab(moved.id)?.agentKind(inPane: pane) == .codex)
        #expect(session.tab(moved.id)?.agentKinds == [.codex])
    }

    @Test(arguments: [Destination.existingTab, .newTab], [false, true])
    func movingAZoomedPane_clearsOnlyItsOwnZoom(_ destination: Destination, zoomsMovedPane: Bool) throws {
        let (session, source, target, pane) = try Self.sessionWithSourceAndTarget()
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != pane })
        let zoom = zoomsMovedPane ? pane : sibling
        session.update(source.id) { $0.zoomedLeafID = zoom }
        try #require(session.tab(source.id)?.zoomedLeafID == zoom)

        let moved = try #require(Self.move(pane, in: session, to: destination, target: target))
        let remaining = try #require(session.tab(source.id))

        #expect(session.tab(containing: pane)?.id == moved)
        #expect(remaining.splitTree.allLeafIDs() == [sibling])
        #expect(remaining.zoomedLeafID == (zoomsMovedPane ? nil : sibling))
        #expect(session.tab(moved)?.zoomedLeafID == nil)
    }

    @Test(arguments: [Destination.existingTab, .newTab])
    func unfocusedMovedLeaf_keepsSourceFocus(_ destination: Destination) throws {
        let (session, source, target, _) = try Self.sessionWithSourceAndTarget(sourcePanes: 3)
        let leaves = source.splitTree.allLeafIDs()
        try #require(leaves.count == 3)
        let typingIn = leaves[1]
        let pane = leaves[2]
        session.update(source.id) { $0.splitTree.focusedLeafID = typingIn }

        let moved = try #require(Self.move(pane, in: session, to: destination, target: target))

        #expect(session.tab(source.id)?.splitTree.allLeafIDs() == [leaves[0], typingIn])
        #expect(session.tab(source.id)?.splitTree.focusedLeafID == typingIn)
        #expect(session.tab(containing: pane)?.id == moved)
        #expect(session.tab(moved)?.splitTree.focusedLeafID == pane)
    }

    // MARK: - Conversation names

    private static func conversation(_ name: String, paneID: UUID, startedAt seconds: TimeInterval) -> ConversationName {
        ConversationName(
            name: name,
            provider: .claude,
            paneID: paneID,
            conversationID: name,
            startedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    enum ConversationPlacement: Sendable {
        case emptyTarget
        case earlierTarget
        case earlierIncoming
        case namedSibling
    }

    @Test(arguments: [ConversationPlacement.emptyTarget, .earlierTarget, .earlierIncoming, .namedSibling])
    func mergePane_keepsTheEarlierNameThatBelongsToTheDestination(_ placement: ConversationPlacement) throws {
        let (session, source, target, pane) = try Self.sessionWithSourceAndTarget()
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != pane })
        let pivot = try #require(target.splitTree.allLeafIDs().first)
        let incoming = Self.conversation("Source task", paneID: placement == .namedSibling ? sibling : pane, startedAt: 10)
        let existing = Self.conversation("Target task", paneID: pivot, startedAt: placement == .earlierTarget ? 5 : 15)
        session.update(source.id) { $0.conversationName = incoming }
        if placement == .earlierTarget || placement == .earlierIncoming {
            session.update(target.id) { $0.conversationName = existing }
        }

        TabActions.mergePaneIntoTab(session, paneID: pane, into: target.id)

        #expect(session.tab(source.id)?.splitTree.allLeafIDs() == [sibling])
        #expect(session.tab(target.id)?.splitTree.allLeafIDs() == [pivot, pane])
        #expect(session.tab(source.id)?.conversationName == (placement == .namedSibling ? incoming : nil))
        let expected: ConversationName? = switch placement {
        case .emptyTarget, .earlierIncoming: incoming
        case .earlierTarget: existing
        case .namedSibling: nil
        }
        #expect(session.tab(target.id)?.conversationName == expected)
    }

    @Test("a pane moved to a new tab takes its conversation name there")
    func movedToNewTab_takesItsConversationName() throws {
        let (session, source, _, paneID) = try Self.sessionWithSourceAndTarget()
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != paneID })
        let moved = Self.conversation("Moved task", paneID: paneID, startedAt: 10)
        _ = session.update(source.id) { $0.conversationName = moved }

        let opened = try #require(TabActions.movePaneToNewTab(
            session, paneID: paneID, in: session.primaryWindowID, intent: .person
        ))

        #expect(session.tab(source.id)?.conversationName == nil)
        #expect(session.tab(source.id)?.splitTree.allLeafIDs() == [sibling])
        #expect(session.tab(opened)?.splitTree.allLeafIDs() == [paneID])
        #expect(session.tab(opened)?.conversationName == moved)
    }

    /// The source tab of `sessionWithSourceAndTarget`, split in two.
    private static func sourceAndPane() throws -> (session: WorkspaceSession, source: Tab) {
        let (session, source, _, _) = try sessionWithSourceAndTarget()
        return (session, source)
    }

    // MARK: - A tab of its own

    @Test(arguments: [false, true])
    func movePaneToNewTab_pinsOnlyAManualPaneName(hasManualName: Bool) throws {
        let (session, source) = try Self.sourceAndPane()
        let pane = try #require(source.splitTree.allLeafIDs().last)
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != pane })
        let sourceTitle = "Source title"
        let paneName = hasManualName ? "Server" : nil
        session.update(source.id) { $0.title = sourceTitle }
        if let paneName {
            session.renamePane(pane, to: paneName)
        }

        let id = try #require(TabActions.movePaneToNewTab(session, paneID: pane, in: session.primaryWindowID, intent: .person))
        let opened = try #require(session.tab(id))

        #expect(opened.id != source.id)
        #expect(opened.splitTree.allLeafIDs() == [pane])
        #expect(opened.title == (paneName ?? sourceTitle))
        #expect(opened.displayTitle == (paneName ?? sourceTitle))
        #expect(opened.titleOverride == paneName)
        #expect(opened.paneStates[pane]?.name == paneName)
        #expect(session.tab(source.id)?.splitTree.allLeafIDs() == [sibling])
        #expect(session.tab(source.id)?.paneStates[pane] == nil)
        #expect(session.tab(source.id)?.title == sourceTitle)

        session.update(id) { $0.title = "New shell title" }
        #expect(session.tab(id)?.displayTitle == (paneName ?? "New shell title"))
    }

    @Test func movePaneToNewTab_keepsItsOwnReportedDirectory() throws {
        let (session, source) = try Self.sourceAndPane()
        session.quickTabDefaultsProvider = { (mode: .inheritPrevious, path: nil) }
        let pane = try #require(source.splitTree.allLeafIDs().last)
        let sibling = try #require(source.splitTree.allLeafIDs().first)
        try #require(pane != sibling)
        session.update(source.id) {
            $0.workingDirectory = "/tmp/weir-launch"
            $0.pwd = "/tmp/weir-sibling"
        }
        session.setWorkingDirectory(paneID: sibling, path: "/tmp/weir-sibling")
        session.setWorkingDirectory(paneID: pane, path: "/tmp/weir-moved")

        TabActions.movePaneToNewTab(session, paneID: pane)

        let moved = try #require(session.tab(containing: pane))
        #expect(moved.id != source.id)
        #expect(moved.pwd == "/tmp/weir-moved")
        #expect(session.workingDirectory(paneID: sibling) == "/tmp/weir-sibling")
        #expect(session.tab(source.id)?.pwd == "/tmp/weir-sibling")
        let next = session.openTab(container: .loose)
        #expect(next.workingDirectory == "/tmp/weir-moved")
    }

    /// A pane not shown by any window goes to the explicitly requested window.
    @Test func movePaneToNewTab_ofAPaneNoWindowShows_movesItInTheWindowNamed() throws {
        let (session, source) = try Self.sourceAndPane()
        let pane = try #require(source.splitTree.allLeafIDs().last)
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != pane })
        let primary = session.openTab(container: .loose)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let otherTab = session.openTab(container: .loose, in: other, intent: .person, selects: true)
        try #require(session.activeTab(in: other)?.id == otherTab.id)
        try #require(session.primarySelection.activeTabID == primary.id)
        try #require(session.window(showingPane: pane) == nil)

        let opened = try #require(TabActions.movePaneToNewTab(session, paneID: pane, in: other, intent: .person))

        #expect(session.tab(opened)?.splitTree.allLeafIDs() == [pane])
        #expect(session.tab(source.id)?.splitTree.allLeafIDs() == [sibling])
        #expect(session.activeTab(in: other)?.id == opened)
        #expect(session.window(showingPane: pane) == other)
        #expect(session.primarySelection.activeTabID == primary.id)
        #expect(session.primarySelection.activeContainerID == .loose)
    }

    @Test func paneTransferState_keepsAbsentScrollback_andClearsAbsentForeground() {
        let pane = UUID()
        let sibling = UUID()
        let targetPane = UUID()
        let sourceTree = SplitTree(leafID: sibling).insert(at: sibling, direction: .horizontal, newID: pane).tree
        var source = Tab(title: "source", splitTree: sourceTree, container: .loose)
        source.paneStates[pane] = PaneState(unreadCount: 2, name: "moved")
        source.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: "/tmp/c")
        source.initialCommands[pane] = "make test"
        let siblingState = PaneState(unreadCount: 4, name: "kept sibling")
        source.paneStates[sibling] = siblingState
        // The target already holds a scrollback path for the pane id, which
        // the moved pane has none of: applying keeps it, as the merge did.
        let targetTree = SplitTree(leafID: targetPane).insert(at: targetPane, direction: .horizontal, newID: pane).tree
        var target = Tab(title: "target", splitTree: targetTree, container: .loose)
        target.scrollbackPaths[pane] = "/tmp/kept.vt"
        target.agentsInFront[pane] = PaneAgentInFront(kind: .codex, isStaged: false)
        target.initialCommands[targetPane] = "target command"

        let state = source.paneTransferState(of: pane)
        target.apply(state, to: pane)
        source.splitTree = source.splitTree.remove(pane).tree
        source.removePaneTransferState(of: pane)

        #expect(target.paneTransferState(of: pane) == Tab.PaneTransferState(
            paneState: PaneState(unreadCount: 2, name: "moved"),
            agentSessions: [.claude: AgentSessionInfo(sessionId: "c1", cwd: "/tmp/c")],
            scrollbackPath: "/tmp/kept.vt",
            initialCommand: "make test"
        ))
        #expect(source.paneTransferState(of: pane) == Tab.PaneTransferState())
        #expect(source.paneTransferState(of: sibling) == Tab.PaneTransferState(paneState: siblingState))
        #expect(target.paneTransferState(of: targetPane) == Tab.PaneTransferState(initialCommand: "target command"))
    }
}
