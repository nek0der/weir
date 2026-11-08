// SurfaceView+Clipboard.swift
// Weir — the surface's userdata token and the clipboard requests it tracks.

import AppKit

/// Its address, unique while retained, is a surface's `userdata`. It also
/// carries the surface's unanswered clipboard requests, because it is the
/// one thing a callback can reach that lives until the surface is freed,
/// after the view itself is gone. Deferred callbacks retain it until delivery
/// so its address cannot be reused for another surface in the meantime.
/// `Sendable` is safe because its only state is an immutable reference to a
/// lock-protected, `Sendable` request tracker.
final class SurfaceUserdataToken: Sendable {
    let clipboardRequests = ClipboardRequestTracker()

    /// Acquires a strong reference while the native surface keeps its userdata
    /// valid. Call only in the callback frame or while the view owns it;
    /// acquiring it after an asynchronous hop could read freed memory.
    nonisolated static func capture(userdata: UnsafeMutableRawPointer) -> SurfaceUserdataToken {
        Unmanaged<SurfaceUserdataToken>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Resolves the original view while keeping its userdata address reserved.
    @MainActor
    func liveView() -> SurfaceView? {
        withExtendedLifetime(self) {
            SurfaceView.liveView(forUserdata: Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

extension ClipboardRequestAnswerer {
    /// What answers a request in the running app. A terminal's write is
    /// plain text like every other copy the app makes, so it takes the
    /// same path (`SystemPasteboard`).
    static let system = ClipboardRequestAnswerer.libghostty { text in
        _ = SystemPasteboard.copy(text)
    }
}

extension SurfaceView: ClipboardRequestTarget {
    /// The unanswered clipboard requests of this view's surface.
    var clipboardRequests: ClipboardRequestTracker {
        Self.clipboardRequests(forUserdata: userdata)
    }

    /// The clipboard requests of the surface `userdata` belongs to, read in
    /// a libghostty callback's own frame, before any hop, or by the view
    /// itself. Safe there and only there: the token is retained until
    /// `ghostty_surface_free` has returned, and libghostty calls a surface's
    /// callbacks before then. The tracker returned is a strong reference,
    /// so it stays valid after the token is released.
    nonisolated static func clipboardRequests(forUserdata userdata: UnsafeMutableRawPointer) -> ClipboardRequestTracker {
        SurfaceUserdataToken.capture(userdata: userdata).clipboardRequests
    }
}
