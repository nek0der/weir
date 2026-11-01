// HeldKeyHintMonitor.swift
// Weir — hears the modifier keys in its window for the held-key hints, and passes every event on.

import AppKit
import SwiftUI
import WeirDomain

/// Feeds `HeldKeyHints` from the events of the window this view is in. A local
/// monitor sees the modifier keys whoever holds the keyboard, a terminal
/// included, and it always hands the event back: what reaches libghostty is
/// the same with the hints on or off.
struct HeldKeyHintMonitor: NSViewRepresentable {
    let hints: HeldKeyHints
    /// Whether the window has room for the keys now. Asked when the wait ends.
    let isAllowed: @MainActor (NSWindow) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(hints: hints, isAllowed: isAllowed)
    }

    func makeNSView(context: Context) -> WindowKeyDownMonitor.HostView {
        let view = WindowKeyDownMonitor.HostView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.hostWindow = window
        }
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: WindowKeyDownMonitor.HostView, context: Context) {
        context.coordinator.isAllowed = isAllowed
        context.coordinator.hostWindow = view.window
    }

    static func dismantleNSView(_: WindowKeyDownMonitor.HostView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        private let hints: HeldKeyHints
        var isAllowed: @MainActor (NSWindow) -> Bool
        /// The window the view is in; `nil` until it is in one.
        weak var hostWindow: NSWindow?
        /// The installed event monitor; `nil` before `install` and after
        /// `remove`.
        private var token: Any?
        private var observers: [any NSObjectProtocol] = []

        init(hints: HeldKeyHints, isAllowed: @escaping @MainActor (NSWindow) -> Bool) {
            self.hints = hints
            self.isAllowed = isAllowed
        }

        func install() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.note(event) }
                return event
            }
            // ⌘⇥ away takes the key-up with it.
            for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    // Only its identity crosses: a notification is not `Sendable`.
                    let window = note.object.map { ObjectIdentifier($0 as AnyObject) }
                    MainActor.assumeIsolated { self?.resigned(name, window: window) }
                })
            }
        }

        func remove() {
            if let token {
                NSEvent.removeMonitor(token)
            }
            token = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            hints.windowResigned()
        }

        private func note(_ event: NSEvent) {
            guard let hostWindow, event.window === hostWindow else { return }
            guard event.type == .flagsChanged else {
                hints.actionTaken()
                return
            }
            hints.modifiersChanged(to: ShortcutModifiers(event.modifierFlags)) { [weak self, weak hostWindow] in
                // Read afresh, Caps Lock and the device's flags aside.
                let chord = ShortcutModifiers(NSEvent.modifierFlags)
                guard let self, let hostWindow else { return (chord, false) }
                return (chord, hostWindow.isKeyWindow && !hostWindow.isComposingText && isAllowed(hostWindow))
            }
        }

        private func resigned(_ name: Notification.Name, window: ObjectIdentifier?) {
            if name == NSApplication.didResignActiveNotification || window == hostWindow.map(ObjectIdentifier.init) {
                hints.windowResigned()
            }
        }
    }
}
