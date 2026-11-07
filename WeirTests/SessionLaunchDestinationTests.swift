// SessionLaunchDestinationTests.swift
// Weir — where a new session's tab lands once its setup ends: in front or behind, and in which window.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// Where a setup that ends lands: decided once, in the
/// launch's window while it shows the session's project, and in no shown
/// window otherwise.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLaunchDestinationTests {
    typealias Fixture = SessionLaunchFixture

    private func begin(_ fixture: Fixture, in window: WindowID? = nil) {
        fixture.begin(Fixture.shell, in: window)
    }

    private static func row(_ fixture: Fixture) -> ContainerID {
        .worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
    }

    @Test func aSetupThatStaysBehind_opensItsTabWithoutSelectingIt() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let elsewhere = fixture.session.openTab(container: .project(fixture.project.id))
            let selection = fixture.session.primarySelection
            let changed = Recorded(false)
            withObservationTracking {
                _ = selection.activeTabID
                _ = selection.activeContainerID
            } onChange: {
                changed.value = true
            }

            begin(fixture)

            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.primarySelection.activeTabID == elsewhere.id)
            // Not opened in front and put back: never written at all.
            #expect(!changed.value)
        }
    }

    @Test func aSetupBehindAShellOfItsRow_leavesTheRowsLastTabOnTheShell() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let shell = fixture.session.openTab(container: Self.row(fixture))

            begin(fixture)

            #expect(fixture.tabs.count == 2)
            #expect(fixture.session.primarySelection.activeTabID == shell.id)
            #expect(fixture.session.lastActiveTabID(for: Self.row(fixture)) == shell.id)
        }
    }

    @Test func aSetupBehindAnotherRow_makesTheNewTabTheRowsLastTab() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let elsewhere = fixture.session.openTab(container: .project(fixture.project.id))

            begin(fixture)

            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.primarySelection.activeTabID == elsewhere.id)
            #expect(fixture.session.lastActiveTabID(for: Self.row(fixture)) == tab.id)
            // Choosing the row then shows it.
            fixture.session.setActiveContainer(Self.row(fixture))
            #expect(fixture.session.primarySelection.activeTabID == tab.id)
        }
    }

    private static let setupCommand = "printf ready > setup-log"

    private func beginShellSetup(_ fixture: Fixture, in window: WindowID? = nil) throws {
        begin(fixture, in: window)
        let launch = try #require(fixture.store.launches[fixture.worktree.id])
        #expect(launch.windowID == (window ?? fixture.session.primaryWindowID))
        try #require(launch.phase == .settingUp(stepIndex: 0, stepCount: 1, command: Self.setupCommand))
        #expect(fixture.tabs.isEmpty)
    }

    private func finishedShell(_ fixture: Fixture) async throws -> Tab {
        await pollUntil(timeout: .seconds(10)) { fixture.store.launches[fixture.worktree.id] == nil }
        #expect(fixture.store.launches.isEmpty)
        let tab = try #require(fixture.tabs.first)
        #expect(fixture.tabs.count == 1)
        #expect(tab.initialCommands.isEmpty)
        return tab
    }

    private func finishedShellAfterSetup(_ fixture: Fixture) async throws -> Tab {
        let tab = try await finishedShell(fixture)
        let log = fixture.worktree.workingDirectory.appendingPathComponent("setup-log")
        #expect(try String(contentsOf: log, encoding: .utf8) == "ready")
        return tab
    }

    @Test func aSetupFinishingInAProjectAnotherWindowShows_leavesThatWindowsSelection() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand(Self.setupCommand)])
            let session = fixture.session
            let original = Self.row(fixture)
            let other = session.addOrActivateProject(rootURL: dir.appendingPathComponent("other"), suggestedName: "other")
            session.setActiveContainer(original)
            try #require(session.primarySelection.shownProjectID == fixture.project.id)
            try beginShellSetup(fixture)

            let shell = session.openTab(container: .project(other.id))
            let second = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(original, in: second)
            let primaryBefore = WorkspaceSession.NavTarget(container: .project(other.id), tabID: shell.id)
            let secondBefore = WorkspaceSession.NavTarget(container: original, tabID: nil)
            try #require(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
            try #require(session.currentNavTarget(in: second) == secondBefore)
            let switches = ProjectSwitchRecorder.connect(to: session)

            _ = try await finishedShellAfterSetup(fixture)

            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
            #expect(session.currentNavTarget(in: second) == secondBefore)
            #expect(switches.isUntouched)
        }
    }

    @Test func skippingASetup_afterThePersonMovedToAnotherRow_opensItBehind() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, ignoresTERM: true, request: Fixture.shell)
            defer { fixture.store.cancelAll() }
            let session = fixture.session
            session.setActiveContainer(Self.row(fixture))
            try #require(Fixture.isRunning(pid))

            fixture.store.skipSetup(worktreeID: fixture.worktree.id, in: session)
            try #require(fixture.store.launches[fixture.worktree.id]?.isStoppingSetup == true)
            try #require(fixture.tabs.isEmpty)
            let shell = session.openTab(container: .project(fixture.project.id))
            let selected = WorkspaceSession.NavTarget(container: .project(fixture.project.id), tabID: shell.id)

            let tab = try await finishedShell(fixture)

            #expect(!Fixture.isRunning(pid))
            #expect(session.currentNavTarget(in: session.primaryWindowID) == selected)
            #expect(session.lastActiveTabID(for: Self.row(fixture)) == tab.id)
        }
    }

    @Test func aSetupFinishingWhileItsWindowIsHidden_selectsItThere() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand(Self.setupCommand)])
            let session = fixture.session
            let other = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(Self.row(fixture), in: other)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))
            try beginShellSetup(fixture, in: other)
            session.setWindow(other, isHidden: true)
            let switches = ProjectSwitchRecorder.connect(to: session)

            let tab = try await finishedShellAfterSetup(fixture)

            #expect(session.hiddenWindowIDs.contains(other))
            #expect(session.currentNavTarget(in: other) == .init(container: Self.row(fixture), tabID: tab.id))
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
            #expect(switches.isUntouched)
        }
    }

    @Test func setupFinishingAfterThePersonSwitchedToAnotherProject_keepsTheWindowThere() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand(Self.setupCommand)])
            let session = fixture.session
            let original = Self.row(fixture)
            let window = session.primaryWindowID
            let other = session.addOrActivateProject(rootURL: dir.appendingPathComponent("other"), suggestedName: "other")
            session.setActiveContainer(original)
            try #require(session.primarySelection.shownProjectID == fixture.project.id)
            try beginShellSetup(fixture)

            let shell = session.openTab(container: .project(other.id))
            let otherSelection = WorkspaceSession.NavTarget(container: .project(other.id), tabID: shell.id)
            try #require(session.currentNavTarget(in: window) == otherSelection)
            try #require(session.projectViews[fixture.project.id]?.activeContainerID == original)
            try #require(session.projectViews[fixture.project.id]?.activeTabID == nil)
            let switches = ProjectSwitchRecorder.connect(to: session)

            let tab = try await finishedShellAfterSetup(fixture)

            #expect(switches.isUntouched)
            #expect(session.currentNavTarget(in: window) == otherSelection)
            #expect(session.windowIDs.allSatisfy { session.selection($0)?.shownProjectID != fixture.project.id })
            #expect(session.lastActiveTabID(for: original) == tab.id)
            #expect(session.projectViews[fixture.project.id]?.activeContainerID == original)
            #expect(session.projectViews[fixture.project.id]?.activeTabID == tab.id)

            #expect(session.chooseProject(fixture.project.id, in: window) == window)
            #expect(session.currentNavTarget(in: window) == .init(container: original, tabID: tab.id))
        }
    }

    // MARK: - In front, or behind

    @Test func aSetupThatEndsWhileAnEmptyRowIsShown_leavesThatRowShown() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            // The project's own row, with no tab.
            fixture.session.setActiveContainer(.project(fixture.project.id))
            try #require(fixture.session.primarySelection.activeTabID == nil)
            let before = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                fixture.store.launches[fixture.worktree.id]?.phase == .starting(isLaunched: false)
            }
            let launch = try #require(fixture.store.launches[fixture.worktree.id])
            try #require(launch.phase == .starting(isLaunched: false))
            let pane = try #require(launch.paneID)
            let launchedTab = try #require(fixture.session.tab(containing: pane))
            #expect(launchedTab.container == Self.row(fixture))
            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == before)
            #expect(fixture.session.primarySelection.activeTabID == nil)
        }
    }

    private func startingAgentTab(_ fixture: Fixture) throws -> Tab {
        let launch = try #require(fixture.store.launches[fixture.worktree.id])
        try #require(launch.phase == .starting(isLaunched: false))
        let pane = try #require(launch.paneID)
        let tab = try #require(fixture.session.tab(containing: pane))
        #expect(tab.container == Self.row(fixture))
        #expect(tab.initialCommands == [pane: "claude"])
        return tab
    }

    @Test func skippingTheSetup_bringsTheAgentToFront_overAShellOfTheRow() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir)
            defer { fixture.store.cancelAll() }
            let id = fixture.worktree.id
            let container = Self.row(fixture)
            let shell = fixture.session.openTab(container: container)
            try #require(Fixture.isRunning(pid))

            fixture.store.skipSetup(worktreeID: id, in: fixture.session)
            try #require(fixture.store.launches[id]?.isStoppingSetup == true)
            #expect(fixture.tabs.map(\.id) == [shell.id])
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.phase == .starting(isLaunched: false) }

            let tab = try startingAgentTab(fixture)
            #expect(!Fixture.isRunning(pid))
            #expect(Set(fixture.tabs.map(\.id)) == [shell.id, tab.id])
            #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == .init(container: container, tabID: tab.id))
        }
    }

    @Test func aSetupThatEndsInTheShownRow_bringsTheAgentToFront() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            let container = ContainerID.worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)
            fixture.session.setActiveContainer(container)
            fixture.begin()
            await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) {
                fixture.store.launches[fixture.worktree.id]?.phase == .starting(isLaunched: false)
            }
            let launch = try #require(fixture.store.launches[fixture.worktree.id])
            try #require(launch.phase == .starting(isLaunched: false))
            let pane = try #require(launch.paneID)
            let launchedTab = try #require(fixture.session.tab(containing: pane))
            #expect(launchedTab.container == Self.row(fixture))
            #expect(fixture.session.stagedLaunch(paneID: pane)?.command == "claude")
            let tab = try #require(fixture.tabs.first)
            #expect(fixture.session.primarySelection.activeContainerID == container)
            #expect(fixture.session.primarySelection.activeTabID == tab.id)
        }
    }

    // MARK: - The window it opens in

    @Test func theAgentsTab_opensInTheWindowTheSessionWasAskedForIn() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let session = fixture.session
            let other = WorkspaceSessionFixture.addWindow(to: session)
            let worktree = Self.row(fixture)
            session.setActiveContainer(worktree, in: other)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))
            try #require(session.currentNavTarget(in: other) == .init(container: worktree, tabID: nil))

            fixture.begin(in: other)

            let tab = try startingAgentTab(fixture)
            #expect(fixture.tabs.count == 1)
            #expect(session.currentNavTarget(in: other) == .init(container: worktree, tabID: tab.id))
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func aWindowLookingElsewhere_getsTheTabBehind_andKeepsWhatItShows() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let other = WorkspaceSessionFixture.addWindow(to: fixture.session)
            // The asking window works in a shell of the project's own folder.
            let shell = fixture.session.openTab(container: .project(fixture.project.id), in: other)
            let primaryBefore = try #require(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID))

            begin(fixture, in: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }

            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.selection(other)?.activeTabID == shell.id)
            #expect(fixture.session.currentNavTarget(in: fixture.session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func aSetupEndingBehind_leavesTheScratchWithTheWindowThatChoseIt() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let session = fixture.session
            let scratch = session.openTab(container: .loose)
            let other = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveTab(scratch.id, in: other)
            // The primary chose the scratch tabs last and draws them.
            session.claimScratch(for: nil)

            begin(fixture, in: other)
            await pollUntil(timeout: .seconds(10)) { !fixture.tabs.isEmpty }
            _ = try #require(fixture.tabs.first)

            #expect(session.selection(other)?.activeTabID == scratch.id)
            #expect(session.scratchOwnerWindowID == session.primaryWindowID)
            #expect(session.showsScratch(in: nil))
        }
    }

    @Test func aRetry_opensTheTabInTheWindowWhoseBarWasUsed() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("test -f marker || exit 3")])
            let session = fixture.session
            let id = fixture.worktree.id
            let worktree = Self.row(fixture)
            begin(fixture)
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.failure != nil }
            try #require(fixture.store.launches[id]?.failure?.stage == .setup(stepIndex: 0))
            #expect(fixture.tabs.isEmpty)
            let other = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(worktree, in: other)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))

            try Data().write(to: fixture.worktree.workingDirectory.appendingPathComponent("marker"))
            fixture.store.retry(worktreeID: id, in: session, window: other)
            let tab = try await finishedShell(fixture)

            #expect(session.currentNavTarget(in: other) == .init(container: worktree, tabID: tab.id))
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func skippingTheSetup_opensTheTabInTheWindowWhoseBarWasUsed() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, request: Fixture.shell)
            defer { fixture.store.cancelAll() }
            let session = fixture.session
            let id = fixture.worktree.id
            let worktree = Self.row(fixture)
            let other = WorkspaceSessionFixture.addWindow(to: session)
            session.setActiveContainer(worktree, in: other)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))
            try #require(Fixture.isRunning(pid))

            fixture.store.skipSetup(worktreeID: id, in: session, window: other)
            try #require(fixture.store.launches[id]?.isStoppingSetup == true)
            let tab = try await finishedShell(fixture)

            #expect(!Fixture.isRunning(pid))
            #expect(session.currentNavTarget(in: other) == .init(container: worktree, tabID: tab.id))
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
        }
    }

    @Test func aPressThatDoesNothing_leavesTheLaunchInItsWindow() async throws {
        try await withTempDir { dir in
            let (fixture, pid) = try await Fixture.startBlockingSetup(in: dir, request: Fixture.shell)
            defer { fixture.store.cancelAll() }
            let session = fixture.session
            let id = fixture.worktree.id
            let second = WorkspaceSessionFixture.addWindow(to: session)
            let third = WorkspaceSessionFixture.addWindow(to: session)
            let worktree = Self.row(fixture)
            session.setActiveContainer(worktree, in: second)
            // A delayed duplicate can still carry a different window ID.
            try #require(session.selection(second)?.shownProjectID == fixture.project.id)
            let primaryBefore = try #require(session.currentNavTarget(in: session.primaryWindowID))
            let thirdBefore = try #require(session.currentNavTarget(in: third))
            try #require(Fixture.isRunning(pid))
            let before = try #require(fixture.store.launches[id])
            try #require(before.windowID == session.primaryWindowID)

            fixture.store.retry(worktreeID: id, in: session, window: second)
            #expect(fixture.store.launches[id]?.windowID == before.windowID)
            #expect(fixture.store.launches[id]?.phase == before.phase)

            fixture.store.skipSetup(worktreeID: id, in: session, window: second)
            try #require(fixture.store.launches[id]?.isStoppingSetup == true)
            try #require(fixture.store.launches[id]?.windowID == second)
            #expect(fixture.tabs.isEmpty)

            fixture.store.skipSetup(worktreeID: id, in: session, window: third)
            #expect(fixture.store.launches[id]?.windowID == second)
            #expect(fixture.store.launches[id]?.isStoppingSetup == true)
            let tab = try await finishedShell(fixture)

            #expect(!Fixture.isRunning(pid))
            #expect(session.currentNavTarget(in: second) == .init(container: worktree, tabID: tab.id))
            #expect(session.currentNavTarget(in: session.primaryWindowID) == primaryBefore)
            #expect(session.currentNavTarget(in: third) == thirdBefore)
        }
    }

}
