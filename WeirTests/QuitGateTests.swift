// QuitGateTests.swift
// Weir — ⌘Q asks about every agent, those of hidden windows, of projects no window shows, and of the quick terminal included.

import AppKit
import Foundation
import Testing
import WeirDomain
@testable import Weir

@MainActor
struct QuitGateTests {
    @Test func anAgentInAHiddenWindowsTab_stillAsksBeforeQuitting() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let registry = WindowRegistry(primary: session.primarySelection)
        let other = WorkspaceSessionFixture.addWindow(to: session)
        try registry.addWindow(#require(session.selection(other)))
        let tab = session.openTab(container: .project(project.id), in: other)
        session.setActiveContainer(.loose)
        registry.hide(other)
        #expect(registry.window(other)?.isHidden == true)
        let pane = tab.splitTree.allLeafIDs()[0]
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())] }

        #expect(session.hasLiveAgentAnywhere())
    }

    @Test func agentsOfAProjectNoWindowShows_count() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        try registry.addWindow(#require(session.selection(other)))
        let tab = session.openTab(container: .project(project.id), in: other)
        session.setActiveContainer(.loose)
        registry.show(registry.primary.id)
        registry.show(other)
        let pane = tab.splitTree.allLeafIDs()[0]
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())] }

        // The window that showed the project closes for good.
        registry.close(other, in: session)

        #expect(registry.window(other) == nil)
        #expect(session.windowIDs.allSatisfy { session.selection($0)?.shownProjectID != project.id })
        #expect(session.hasLiveAgentAnywhere())
    }

    /// The quick terminal's agents run without hooks, so nothing of them is
    /// on the session's record: only its foreground process group shows an
    /// agent running there, for every kind of agent. The surfaces are real,
    /// a pane's and the quick terminal's; only what runs in front of each is
    /// handed in, as no agent is started.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() }, arguments: AgentKind.allCases)
    func anAgentOnlyInTheQuickTerminal_asksBeforeQuitting(kind: AgentKind) throws {
        let name = try #require(AgentProviderRegistry.processNames(for: kind).first)
        try withTempDir { directory in
            let (session, _) = WorkspaceSessionFixture.withProject()
            let surfaces = try Self.paneAndQuickTerminal(settingsDirectory: directory)

            let asks = AppState.hasAgentAQuitWouldEnd(
                session: session,
                registry: surfaces.registry,
                quickTerminal: surfaces.controller
            ) {
                $0 === surfaces.controller.surfaceView ? ["zsh", name] : ["zsh"]
            }

            #expect(asks)
        }
    }

    /// With a shell in front of every terminal, the quit goes through, after
    /// both the pane's terminal and the quick terminal's are read.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func shellsAlone_letTheQuitGoThrough() throws {
        try withTempDir { directory in
            let (session, _) = WorkspaceSessionFixture.withProject()
            let surfaces = try Self.paneAndQuickTerminal(settingsDirectory: directory)
            var reads = 0

            let asks = AppState.hasAgentAQuitWouldEnd(
                session: session,
                registry: surfaces.registry,
                quickTerminal: surfaces.controller
            ) { _ in
                reads += 1
                return ["zsh"]
            }

            #expect(!asks)
            #expect(reads == 2, "the pane's terminal and the quick terminal's are both read")
        }
    }

    /// The record answers first, so no terminal's process group is read.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func anAgentOnTheRecord_asksWithNoTerminalRead() throws {
        try withTempDir { directory in
            let (session, project) = WorkspaceSessionFixture.withProject()
            let tab = session.openTab(container: .project(project.id), in: session.primaryWindowID)
            let pane = tab.splitTree.allLeafIDs()[0]
            session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())] }
            let surfaces = try Self.paneAndQuickTerminal(settingsDirectory: directory)
            var reads = 0

            let asks = AppState.hasAgentAQuitWouldEnd(
                session: session,
                registry: surfaces.registry,
                quickTerminal: surfaces.controller
            ) { _ in
                reads += 1
                return ["zsh"]
            }

            #expect(asks)
            #expect(reads == 0)
        }
    }

    /// Returns a registry holding one pane's surface, and a quick terminal
    /// whose surface is made. Needs the host app's `GhosttyApp`; no view is
    /// put in a window, so no shell starts.
    private static func paneAndQuickTerminal(
        settingsDirectory directory: URL
    ) throws -> (registry: SurfaceRegistry, controller: QuickTerminalController) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let registry = SurfaceRegistry()
        registry.register(PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:]), for: UUID())
        let controller = QuickTerminalController(
            settingsStore: SettingsStore(directory: directory),
            reduceTransparencyResolver: ReduceTransparencyResolver(),
            clipboard: ClipboardConfirmationCoordinator(answerer: .system),
            secureInputManager: SecureInputManager(),
            surfaceFactory: {
                PaneHostRepresentable.makeSurfaceView(
                    ghosttyApp: ghosttyApp,
                    environment: AppState.quickTerminalEnvironment
                )
            }
        )
        controller.prepareSurface()
        _ = try #require(controller.surfaceView)
        return (registry, controller)
    }
}
