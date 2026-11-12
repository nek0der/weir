// AutomationPostedKeys.swift
// Weir — where a key the verification client posts may land, checked as it arrives (ADR 0006).

#if DEBUG && WEIR_AUTOMATION

    import AppKit
    import CoreGraphics
    import OSLog

    private let log = Logger.weir("automation")

    /// The client posts named keys from outside (`scripts/weir-automation.py
    /// keys`) after `state` reports, in `postedKeys`, that a key would land on
    /// one of Weir's own controls. The keyboard can move between that read
    /// and the key's arrival: a dropdown closes, a sheet comes up, the quick
    /// terminal takes it. So the app looks again as each posted key arrives
    /// and drops one bound anywhere else, before any control sees it. Return
    /// in a terminal pane runs code there, and Return on a sheet can answer it
    /// for the person (the paste confirmation's Allow, which pastes into a
    /// shell).
    ///
    /// Both reads judge the window by `refusal(hasSheet:firstResponder:)`, so
    /// they cannot disagree about a sheet or a pane. The read before posting
    /// is stricter: it also refuses while Settings or the quick terminal is
    /// shown, or while the run shows more than one window, since it cannot
    /// know which window the key will reach. The gate counts the posted key
    /// presses it sees and drops, and `state` reports the counts, so the
    /// client can tell a dropped key from one that changed nothing.
    ///
    /// A posted key is told from the person's by the marker the client sets
    /// in its source's user data; keys without it go their usual way.
    @MainActor
    enum AutomationPostedKeys {
        /// "WEIRKEYS", in `eventSourceUserData` of every key the client posts.
        /// `scripts/weir-automation.py` sets the same value.
        nonisolated static let marker: Int64 = 0x5745_4952_4B45_5953

        /// Posted key presses (`keyDown`) the gate has seen since the run
        /// started, and those of them it dropped. The client posts one press
        /// per key, so it waits until `seen` has grown by the number it
        /// posted, then reads `dropped`. A press that a control's own monitor
        /// or a menu's tracking loop takes first never reaches the gate (a
        /// dropdown's Esc), so `seen` can fall short of what was posted, and
        /// the client then stops waiting after a while instead of failing.
        private(set) static var seen = 0
        private(set) static var dropped = 0

        nonisolated static func isPosted(_ event: NSEvent) -> Bool {
            event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
        }

        /// Why a posted key would not land in a project window, or `nil` when
        /// one of Weir's own controls there holds the keyboard. Never a
        /// terminal pane or a sheet, and never a window whose keyboard nothing
        /// holds.
        static func refusal(hasSheet: Bool, firstResponder: NSResponder?) -> AutomationPostedKeyRefusal? {
            if hasSheet {
                return .sheet
            }
            guard let firstResponder, !(firstResponder is NSWindow) else { return .nothingHoldsKeyboard }
            return firstResponder is SurfaceView ? .pane : nil
        }

        /// Why the client must not post a key now, as `state` reports it. A
        /// run behind other apps has no key window it can report
        /// (`NSApp.keyWindow` is nil), yet a posted key still lands in one of
        /// its windows. With one project window shown, Settings closed, and
        /// the quick terminal hidden, that window is the only place it can
        /// land. The shown window's own refusal (a sheet, a
        /// pane) comes before Settings and the quick terminal, since it names
        /// what holds the keyboard where the key was going.
        static func refusal(
            isSettingsShown: Bool,
            isQuickTerminalShown: Bool,
            shownWindows: [NSWindow?]
        ) -> AutomationPostedKeyRefusal? {
            // A shown window that AppKit has no window for still counts, so
            // two shown windows are never taken for one.
            guard shownWindows.count == 1, let window = shownWindows.first ?? nil else { return .notOneWindow }
            if let refusal = refusal(hasSheet: window.attachedSheet != nil, firstResponder: window.firstResponder) {
                return refusal
            }
            if isSettingsShown {
                return .settingsShown
            }
            if isQuickTerminalShown {
                return .quickTerminalShown
            }
            return nil
        }

        /// Whether a posted key bound for `window` may reach it: a project
        /// window that `refusal(hasSheet:firstResponder:)` does not refuse.
        /// Never the quick terminal or Settings.
        static func mayDeliver(to window: NSWindow?, isProjectWindow: (NSWindow) -> Bool) -> Bool {
            guard let window, isProjectWindow(window) else { return false }
            return refusal(hasSheet: window.attachedSheet != nil, firstResponder: window.firstResponder) == nil
        }

        /// The check, as a local monitor of the key events: it returns `nil`
        /// for a posted key that may not land where it is going, which
        /// AppKit then delivers nowhere. `SurfaceView` refuses posted keys
        /// as well (`SurfaceView+Keyboard`), should another monitor run first.
        static func installGate(isProjectWindow: @escaping @MainActor (NSWindow) -> Bool) -> Any? {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
                guard isPosted(event) else { return event }
                // Monitors run on the main thread. The event stays out of the
                // isolated part, which takes only its window and its type.
                let window = event.window
                let isPress = event.type == .keyDown
                let delivers = MainActor.assumeIsolated {
                    let target = window ?? NSApp.keyWindow
                    let delivers = mayDeliver(to: target, isProjectWindow: isProjectWindow)
                    if isPress {
                        seen += 1
                        if !delivers {
                            dropped += 1
                        }
                    }
                    if !delivers {
                        let holder = target?.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
                        log.notice("dropped a posted key bound for \(holder, privacy: .public)")
                    }
                    return delivers
                }
                return delivers ? event : nil
            }
        }
    }

#endif
