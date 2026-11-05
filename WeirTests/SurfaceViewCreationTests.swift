// SurfaceViewCreationTests.swift
// Weir — a pane's surface is made once, and its failed state is one SwiftUI sees.

import AppKit
import GhosttyKit
import Observation
import Testing
@testable import Weir

@Suite("SurfaceView creation")
@MainActor
struct SurfaceViewCreationTests {

    /// Every call our maker answered, and how many of the first ones it
    /// failed as libghostty does when it cannot allocate a surface.
    @MainActor
    private final class Maker {
        private(set) var calls = 0
        let failures: Int

        init(failures: Int) {
            self.failures = failures
        }

        func make(app: ghostty_app_t, config: ghostty_surface_config_s) -> ghostty_surface_t? {
            calls += 1
            guard calls > failures else { return nil }
            return SurfaceView.newGhosttySurface(app: app, config: config)
        }
    }

    /// A view made with `maker`, mounted in a window that is never shown.
    /// The mount runs the first `createSurface`, as it does in a pane.
    private func mountedView(_ maker: Maker) throws -> (window: NSWindow, view: SurfaceView) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: ghosttyApp, makeSurface: maker.make)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (window, view)
    }

    /// A second `createSurface` on a view that has a surface would start a
    /// second shell under the same userdata, which nothing frees. A Retry
    /// press on a card that outlived its failure did exactly that.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func createSurface_calledAgain_keepsTheSurfaceItHas() throws {
        let maker = Maker(failures: 0)
        let (window, view) = try mountedView(maker)
        defer { window.close() }
        let surface = try #require(view.surface, "the mount never created the surface")

        view.createSurface()
        view.createSurface()

        #expect(maker.calls == 1)
        #expect(view.surface == surface)
        #expect(!view.creation.hasFailed)
    }

    /// The failure card is drawn from `creation.hasFailed`, so the flag has
    /// to tell SwiftUI when a retry clears it: the card goes with the
    /// failure instead of lingering until some unrelated redraw.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func createSurface_afterAFailure_retriesAndClearsTheObservedFailure() throws {
        let maker = Maker(failures: 1)
        let (window, view) = try mountedView(maker)
        defer { window.close() }
        #expect(view.surface == nil)
        #expect(view.creation.hasFailed)

        let notified = Recorded(false)
        withObservationTracking {
            _ = view.creation.hasFailed
        } onChange: {
            notified.value = true
        }
        view.createSurface()

        #expect(maker.calls == 2)
        #expect(view.surface != nil)
        #expect(!view.creation.hasFailed)
        #expect(notified.value, "SwiftUI was not told the failure cleared")

        // The Retry button stays wired to `createSurface`; once there is a
        // surface, another press makes nothing.
        view.createSurface()
        #expect(maker.calls == 2)
    }

    /// A restored pane's saved path stays in its tab until its terminal
    /// exists. A failed surface has nothing to dump at ⌘Q, so dropping the
    /// path then would let the prune delete the `.vt` with its scrollback.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func aRestoredPanesPath_staysUntilItsSurfaceIsMade() async throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        _ = session.update(tab.id) { $0.scrollbackPaths[pane] = "/saved.vt" }
        let maker = Maker(failures: 1)
        let view = SurfaceView(ghosttyApp: ghosttyApp, makeSurface: maker.make)
        PaneHostRepresentable.stageScrollback(view: view, session: session, paneID: pane)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        #expect(view.creation.hasFailed)
        #expect(session.scrollbackPath(ofPane: pane) == "/saved.vt")

        view.createSurface()

        #expect(view.surface != nil)
        await pollUntil { session.scrollbackPath(ofPane: pane) == nil }
        #expect(session.tab(tab.id)?.scrollbackPaths[pane] == nil)
    }

    /// The failure itself is observed too, so the card appears when
    /// libghostty returns NULL rather than on the next redraw.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func createSurface_failing_notifiesTheObservedFailure() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let maker = Maker(failures: 1)
        let view = SurfaceView(ghosttyApp: ghosttyApp, makeSurface: maker.make)
        let notified = Recorded(false)
        withObservationTracking {
            _ = view.creation.hasFailed
        } onChange: {
            notified.value = true
        }

        view.createSurface()

        #expect(view.surface == nil)
        #expect(view.creation.hasFailed)
        #expect(notified.value, "SwiftUI was not told creation failed")
    }
}
