// PaneSurface.swift
// Weir — what Core may ask of the terminal behind a pane.

import CoreGraphics
import Foundation
import GhosttyKit

/// The terminal behind a pane, as Core sees it. The view that implements it
/// lives in UI, and Core sits below UI, so Core reads these answers and never
/// names the view.
@MainActor
protocol PaneSurface: AnyObject {
    /// The live libghostty surface; nil when the pane has none.
    var surface: ghostty_surface_t? { get }
    var ttyName: String? { get }
    var isInWindow: Bool { get }
    var boundsSize: CGSize { get }
    /// The pane's rect in its window's coordinates, which grow upward.
    var rectInWindow: CGRect { get }
    /// Whether the pane holds keyboard focus in the app's key window.
    var isFirstResponderOfKeyWindow: Bool { get }
    /// Asks the pane's window for keyboard focus; nothing happens while the
    /// pane is not in a window.
    func takeKeyboardFocus()
}

/// The panes' terminals by leaf id, for the Core code that acts on a pane.
@MainActor
protocol PaneSurfaceProviding: ScrollbackWriting {
    func paneSurface(for id: UUID) -> (any PaneSurface)?
    func unregister(_ id: UUID)
    /// Drop any registry entries whose ids aren't in the given set —
    /// used by TabActions when a pane close mutates the tree so
    /// orphaned surfaces don't pile up.
    func reconcile(activeIDs: Set<UUID>)
    /// The pane's text destination, or `nil` when it has none. Separate from
    /// `paneSurface(for:)` so review's delivery path can be answered by a
    /// stand-in — the concrete registry returns the view itself.
    func deliverer(for id: UUID) -> (any ReviewTextDelivering)?
}
