// SurfaceView+Automation.swift
// Weir — the bare Return the verification channel sends to a pane, beyond
// `commitText(_:)` and the paste review uses.

#if DEBUG && WEIR_AUTOMATION

    import GhosttyKit

    extension SurfaceView {
        /// Sends Return. `false` when the terminal is gone.
        func automationSendReturn() -> Bool {
            guard let surface else { return false }
            sendReturnKey(to: surface)
            return true
        }
    }

#endif
