// SurfaceContextMenuReleaseTests.swift
// Weir — a right-click menu delegates its close event to the live surface.

import AppKit
import GhosttyKit
import Testing
@testable import Weir

@Suite("Surface context menu release")
@MainActor
struct SurfaceContextMenuReleaseTests {

    /// A view with a live surface, mounted in a window that is never shown.
    private func mountedView() throws -> (window: NSWindow, view: SurfaceView) {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: ghosttyApp)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (window, view)
    }

    private func rightMouseDown(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    /// This checks the delegate wiring. It does not observe libghostty's
    /// button state after the close callback.
    @Test(.tags(.ffi), .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() })
    func menu_afterAPressSent_delegatesClosureToTheSurface() throws {
        let (window, view) = try mountedView()
        defer { window.close() }
        let surface = try #require(view.surface, "the mount never created the surface")
        #expect(!ghostty_surface_has_selection(surface))

        let menu = try #require(view.menu(for: rightMouseDown(in: window)))

        #expect(menu.delegate === view)
    }
}
