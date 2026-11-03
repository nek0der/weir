// AutomationPostedKeys.swift
// Weir — where a key the verification client posts may land, checked as it arrives (ADR 0006).

#if DEBUG && WEIR_AUTOMATION

    import AppKit
    import CoreGraphics
    import OSLog

    private let log = Logger.weir("automation")

    /// The client posts named keys from outside (`scripts/weir-automation.py
    /// keys`) after `state` shows one of Weir's own controls holding the
    /// keyboard. The keyboard can move between that read and the key's
    /// arrival: a dropdown closes, a sheet comes up, the quick terminal takes
    /// it. So the app looks again as each posted key arrives and drops one
    /// bound anywhere else, before any control sees it. Return in a terminal
    /// pane runs code there, and Return on a sheet can answer it for the
    /// person (the paste confirmation's Allow).
    ///
    /// A posted key is told from the person's by the marker the client sets
    /// in its source's user data; keys without it go their usual way.
    @MainActor
    enum AutomationPostedKeys {
        /// "WEIRKEYS", in `eventSourceUserData` of every key the client posts.
        /// `scripts/weir-automation.py` sets the same value.
        nonisolated static let marker: Int64 = 0x5745_4952_4B45_5953

        nonisolated static func isPosted(_ event: NSEvent) -> Bool {
            event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
        }

        /// Whether a posted key bound for `window` may reach it: a project
        /// window with no sheet up, whose keyboard one of Weir's own controls
        /// holds. Never a terminal pane, a sheet, the quick terminal, or
        /// Settings, and never a window whose keyboard nothing holds.
        /// The client asks the same of `state` before it posts
        /// (`keyboard_window` and `post_keys` in `scripts/weir-automation.py`);
        /// the two change together.
        static func mayDeliver(to window: NSWindow?, isProjectWindow: (NSWindow) -> Bool) -> Bool {
            guard let window, isProjectWindow(window), window.attachedSheet == nil,
                  let responder = window.firstResponder, !(responder is NSWindow)
            else { return false }
            return !(responder is SurfaceView)
        }

        /// The check, as a local monitor of the key events: it returns `nil`
        /// for a posted key that may not land where it is going, which
        /// AppKit then delivers nowhere. `SurfaceView` refuses posted keys
        /// as well (`SurfaceView+Keyboard`), should another monitor run first.
        static func installGate(isProjectWindow: @escaping @MainActor (NSWindow) -> Bool) -> Any? {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
                guard isPosted(event) else { return event }
                // Monitors run on the main thread. The event stays out of the
                // isolated part, which takes only its window.
                let window = event.window
                let delivers = MainActor.assumeIsolated {
                    let target = window ?? NSApp.keyWindow
                    guard mayDeliver(to: target, isProjectWindow: isProjectWindow) else {
                        let holder = target?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
                        log.notice("dropped a posted key bound for \(holder, privacy: .public)")
                        return false
                    }
                    return true
                }
                return delivers ? event : nil
            }
        }
    }

#endif
