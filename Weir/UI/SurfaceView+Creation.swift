// SurfaceView+Creation.swift
// Weir — how a `SurfaceView` makes its libghostty surface, and whether it failed.
// Lives outside `SurfaceView.swift` so the host file stays under the
// SwiftLint file-length warning band; the call site is `createSurface()`.

import AppKit
import GhosttyKit
import Observation

/// Makes a libghostty surface from an app and a surface config, or returns
/// NULL when libghostty could not. See `SurfaceView.newGhosttySurface`.
typealias SurfaceMaker = @MainActor (ghostty_app_t, ghostty_surface_config_s) -> ghostty_surface_t?

/// Whether libghostty failed to make a `SurfaceView`'s surface. A pane and
/// the quick terminal read it in their bodies to show the failure card with
/// its Retry button, so it is `@Observable`: the card has to appear when
/// creation fails and go the moment a retry succeeds.
@MainActor
@Observable
final class SurfaceCreationState {
    /// `true` from a `ghostty_surface_new` that returned NULL until a later
    /// attempt returns a surface. Only `SurfaceView.createSurface` sets it.
    var hasFailed = false
}

extension SurfaceView {
    /// Makes a surface the way the app does. `config` is copied because the
    /// C call takes a pointer; the buffers it points at stay owned by the view.
    static func newGhosttySurface(app: ghostty_app_t, config: ghostty_surface_config_s) -> ghostty_surface_t? {
        var config = config
        return ghostty_surface_new(app, &config)
    }
}
