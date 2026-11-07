// SessionTerminalRegionTests.swift
// Weir — what the terminal region reports as the window moves to a row with no tabs.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@Suite(.hostsWindows)
@MainActor
struct SessionTerminalRegionTests {
    /// A window on a tab with one pane, hosted with a stand-in for the
    /// terminals, and the app in front so an attended pane counts as seen.
    @MainActor
    private struct Fixture {
        let session: WorkspaceSession
        let registry: WindowRegistry
        let tab: Weir.Tab
        let pane: UUID
        let emptyContainer: ContainerID
        let window: NSWindow
        let host: NSView

        init(directory: URL) {
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            let project = session.addOrActivateProject(rootURL: directory, suggestedName: "Empty project")
            session.setActiveTab(tab.id)
            let registry = WindowRegistry(primary: session.primarySelection)
            registry.appActivityChanged(isActive: true)
            let view = SessionTerminalRegion { Color.clear }
                .environment(session)
                .environment(registry.primary)
                .environment(registry.primary.reviewPresentation)
                .environment(SettingsStore(directory: directory, writesFiles: false))
                .environment(AttentionState())
                .environment(\.paneVisibilityReporter, PaneVisibilityReporter(windowID: registry.primary.id, registry: registry))
            let (window, host) = hostedInWindow(view, width: 800, height: 600)
            self.session = session
            self.registry = registry
            self.tab = tab
            self.pane = pane
            emptyContainer = .project(project.id)
            self.window = window
            self.host = host
        }

        var isPaneReported: Bool {
            registry.visibility.union.contains(pane) && registry.attention.isSeen(pane)
        }

        var isPaneAbsent: Bool {
            !registry.visibility.union.contains(pane) && !registry.attention.isSeen(pane)
        }
    }

    @Test func selectingAnEmptyRowAndReturning_updatesDrawingAndAttention() async throws {
        try await withTempDir { directory in
            let fixture = Fixture(directory: directory)
            defer { fixture.window.close() }
            await settle(fixture.host) { fixture.isPaneReported }
            try #require(fixture.isPaneReported)
            let selection = fixture.session.primarySelection
            try #require(fixture.session.tabs(in: fixture.emptyContainer).isEmpty)

            fixture.session.setActiveContainer(fixture.emptyContainer, at: .window(selection), intent: .repair)

            #expect(selection.activeContainerID == fixture.emptyContainer)
            #expect(selection.activeTabID == nil)
            await settle(fixture.host) { fixture.isPaneAbsent }
            try #require(fixture.isPaneAbsent)

            fixture.session.setActiveTab(fixture.tab.id)

            #expect(selection.activeTabID == fixture.tab.id)
            await settle(fixture.host) { fixture.isPaneReported }
            #expect(fixture.isPaneReported)
        }
    }
}
