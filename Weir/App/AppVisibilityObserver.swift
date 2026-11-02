// AppVisibilityObserver.swift
// Weir — tells the window registry whether Weir is in front.

import AppKit

/// Feeds the app-wide fact of `AttentionVisibility` into the window
/// registry. In the app layer because it comes from AppKit, which Core and
/// Presentation do not import; the registry only stores what it is told.
@MainActor
final class AppVisibilityObserver: NSObject {
    private weak var registry: WindowRegistry?
    private let onBecomeActive: @MainActor () -> Void

    /// `onBecomeActive` runs each time Weir comes to the front, for the Core
    /// code that refreshes what may have changed outside it.
    init(registry: WindowRegistry, onBecomeActive: @escaping @MainActor () -> Void) {
        self.registry = registry
        self.onBecomeActive = onBecomeActive
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(didBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(activityChanged(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        // `NSApplication.shared`, not `NSApp`: this runs inside `AppState.init`,
        // where `NSApp` may still be nil.
        registry.appActivityChanged(isActive: NSApplication.shared.isActive)
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didBecomeActive(_ note: Notification) {
        activityChanged(note)
        onBecomeActive()
    }

    @objc private func activityChanged(_ note: Notification) {
        registry?.appActivityChanged(isActive: NSApplication.shared.isActive)
    }
}
