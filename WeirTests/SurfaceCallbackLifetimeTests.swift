// SurfaceCallbackLifetimeTests.swift
// Weir — delayed callbacks preserve the identity of their original surface.

import AppKit
import GhosttyKit
import Testing
@testable import Weir

@Suite(
    "Surface callback lifetime",
    .serialized,
    .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() }
)
@MainActor
struct SurfaceCallbackLifetimeTests {
    @Test(arguments: [false, true])
    func closeDeliveryReachesItsLiveView(processAlive: Bool) throws {
        let app = try #require(GhosttyApp.placeholder.target)
        let view = SurfaceView(ghosttyApp: app)
        let delivery = GhosttyApp.closeSurfaceDelivery(userdata: view.userdata, processAlive: processAlive)
        let previousSink = GhosttyActionRouter.sink
        defer { GhosttyActionRouter.sink = previousSink }
        var recipients: [SurfaceView] = []
        var aliveValues: [Bool] = []
        GhosttyActionRouter.sink = { event in
            if case let .closeSurface(recipient, alive) = event {
                recipients.append(recipient)
                aliveValues.append(alive)
            }
        }
        delivery()
        #expect(recipients.count == 1)
        #expect(recipients.first === view)
        #expect(aliveValues == [processAlive])
    }

    @Test
    func confirmedClipboardWriteRetainsTokenAcrossTheQueueHop() async {
        let pointer = Unmanaged.passRetained(SurfaceUserdataToken()).toOpaque()
        weak var token: SurfaceUserdataToken?
        token = Unmanaged<SurfaceUserdataToken>.fromOpaque(pointer).takeUnretainedValue()
        "text/plain".withCString { mime in
            "old pane write".withCString { text in
                var content = ghostty_clipboard_content_s(mime: mime, data: text, len: strlen(text))
                GhosttyApp.writeClipboardCallback(pointer, GHOSTTY_CLIPBOARD_STANDARD, &content, 1, true)
            }
        }
        // Release the surface's ownership before the queued callback can run.
        // No view is registered, so delivery cannot write the real clipboard.
        Unmanaged<SurfaceUserdataToken>.fromOpaque(pointer).release()
        #expect(token != nil, "The write callback must retain the token before leaving its C frame")
        await pollUntil(timeout: .seconds(5)) { token == nil }
        #expect(token == nil, "Discarding a write for a missing view must release the token")
    }

    @Test
    func closeDeliveryRetainsTokenUntilDeliveryEnds() async throws {
        let app = try #require(GhosttyApp.placeholder.target)
        var view: SurfaceView? = SurfaceView(ghosttyApp: app)
        let pointer = try #require(view?.userdata)
        try #require(view?.surface == nil)
        weak var token: SurfaceUserdataToken?
        token = Unmanaged<SurfaceUserdataToken>.fromOpaque(pointer).takeUnretainedValue()
        let tracker = try #require(token?.clipboardRequests)
        // This unmounted view has no native surface, so teardown removes the
        // marker without passing its synthetic pointer to C. Its removal
        // establishes that the main-actor teardown job completed.
        let state = try ClipboardRequestState(pointer: #require(UnsafeMutableRawPointer(bitPattern: 1)))
        try #require(tracker.track(state))
        var delivery: (@MainActor @Sendable () -> Void)? = GhosttyApp.closeSurfaceDelivery(
            userdata: pointer, processAlive: false
        )
        weak var oldView: SurfaceView?
        oldView = view
        view = nil
        await pollUntil(timeout: .seconds(5)) { !tracker.isTracking(state) }
        try #require(!tracker.isTracking(state))
        #expect(oldView == nil)
        #expect(token != nil, "The queued callback must keep its userdata address reserved")
        #expect(SurfaceView.liveView(forUserdata: pointer) == nil)
        let replacement = SurfaceView(ghosttyApp: app)
        #expect(replacement.userdata != pointer)
        let previousSink = GhosttyActionRouter.sink
        defer { GhosttyActionRouter.sink = previousSink }
        var recipients: [SurfaceView] = []
        GhosttyActionRouter.sink = { event in
            if case let .closeSurface(recipient, _) = event {
                recipients.append(recipient)
            }
        }
        delivery?()
        #expect(recipients.isEmpty)
        delivery = nil
        #expect(token == nil, "Completing delivery must release the token")
        withExtendedLifetime(replacement) {}
    }
}
