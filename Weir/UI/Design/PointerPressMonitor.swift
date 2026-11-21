// PointerPressMonitor.swift
// Weir — whether the pointer holds a view down where it pressed, seen without taking the press.

import AppKit
import SwiftUI

/// Reports whether the pointer's left button holds the view it is laid
/// behind down, from the press until the release or until the pointer
/// moves `slop` away. It only watches the window's mouse events and sends
/// each on as it came: a SwiftUI gesture that sees the press, even one
/// that never ends, keeps a `.draggable` beside it from starting a drag
/// on macOS 26. The view takes no hits, so the press still reaches the
/// views it lies under.
struct PointerPressMonitor: NSViewRepresentable {
    /// Whether a new press is watched. Turning it off ends a press in
    /// progress.
    let isEnabled: Bool
    /// How far the pointer may move from the press and still hold it.
    let slop: CGFloat
    /// A part of the view, in its own coordinates with the origin at the
    /// top left, whose press belongs to something laid over it; `nil` for
    /// none.
    let excludedRect: CGRect?
    let onChange: @MainActor (_ isPressed: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.watchKey(of: window)
        }
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        coordinator.hostView = view
        coordinator.tracker.slop = slop
        coordinator.excludedRect = excludedRect
        coordinator.isEnabled = isEnabled
        if !isEnabled {
            coordinator.reportLater(coordinator.tracker.cancel())
        }
    }

    static func dismantleNSView(_: HostView, coordinator: Coordinator) {
        coordinator.remove()
        coordinator.hostView = nil
    }

    @MainActor
    final class HostView: NSView {
        /// Set by the representable as it makes the view; `nil` before.
        var onWindowChange: ((NSWindow?) -> Void)?

        /// Flipped, so its coordinates read as SwiftUI's do.
        override var isFlipped: Bool {
            true
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var onChange: @MainActor (Bool) -> Void
        /// The view whose frame a press must land in; `nil` once the view
        /// is taken down.
        weak var hostView: NSView?
        var tracker = PointerPressTracker(slop: 0)
        var isEnabled = true
        var excludedRect: CGRect?

        /// The installed event monitor; `nil` before `install` and after
        /// `remove`.
        private var token: Any?
        /// The observer of the window's losing key; `nil` while the view is
        /// in no window.
        private var resignObserver: (any NSObjectProtocol)?
        /// The observer of a menu's tracking; `nil` before `install` and
        /// after `remove`.
        private var menuObserver: (any NSObjectProtocol)?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
        }

        func install() {
            guard token == nil else { return }
            // A menu opened mid-press, by a right-click for one, tracks the
            // pointer itself and takes the release.
            menuObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.report(self.tracker.cancel())
                }
            }
            token = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        func remove() {
            if let token {
                NSEvent.removeMonitor(token)
            }
            token = nil
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            menuObserver = nil
            watchKey(of: nil)
            reportLater(tracker.cancel())
        }

        /// A window that loses key mid-press, to a sheet or another app,
        /// may never send the release here.
        func watchKey(of window: NSWindow?) {
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
            resignObserver = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.report(self.tracker.cancel())
                    }
                }
            }
        }

        private func observe(_ event: NSEvent) {
            guard let hostView, let window = hostView.window, event.window === window else { return }
            let point = event.locationInWindow
            switch event.type {
            case .leftMouseDown:
                report(tracker.press(at: point, isInside: isPress(event, in: hostView)))
            case .leftMouseDragged:
                report(tracker.move(to: point))
            default:
                report(tracker.cancel())
            }
        }

        /// Whether `event` presses the part of the view on screen. A
        /// ⌃-click opens the context menu, whose tracking takes the
        /// release, so it is never a press. A view SwiftUI hosts can
        /// answer a `visibleRect` past its own bounds, so the two are
        /// intersected.
        private func isPress(_ event: NSEvent, in view: NSView) -> Bool {
            guard isEnabled, !event.modifierFlags.contains(.control) else { return false }
            let local = view.convert(event.locationInWindow, from: nil)
            return view.bounds.intersection(view.visibleRect).contains(local) && excludedRect?.contains(local) != true
        }

        /// Passes on a change found during a SwiftUI update or teardown
        /// once the update is over, since SwiftUI does not take state
        /// changes made during one. A press must still be reported as
        /// ended: SwiftUI can take this view down while the row it lies
        /// behind, and the row's pressed state, stay.
        func reportLater(_ change: Bool?) {
            guard let change else { return }
            let onChange = onChange
            Task { @MainActor in onChange(change) }
        }

        /// Passes on a change; `nil` is none.
        private func report(_ change: Bool?) {
            if let change {
                onChange(change)
            }
        }
    }
}

/// The press a `PointerPressMonitor` follows, as a pure value: each step
/// answers the new state when it changed, and `nil` when it did not.
struct PointerPressTracker {
    var slop: CGFloat
    /// Where the press that holds began; `nil` while none holds.
    private(set) var origin: CGPoint?

    var isPressed: Bool {
        origin != nil
    }

    /// A press anywhere in the window; only one inside the view holds.
    mutating func press(at point: CGPoint, isInside: Bool) -> Bool? {
        let wasPressed = isPressed
        origin = isInside ? point : nil
        return wasPressed == isPressed ? nil : isPressed
    }

    /// The pointer moved with the button down. A press that moved past
    /// the slop ends, and does not hold again if the pointer comes back.
    mutating func move(to point: CGPoint) -> Bool? {
        guard let origin, hypot(point.x - origin.x, point.y - origin.y) >= slop else { return nil }
        self.origin = nil
        return false
    }

    /// The release, or the watch ending.
    mutating func cancel() -> Bool? {
        guard isPressed else { return nil }
        origin = nil
        return false
    }
}
