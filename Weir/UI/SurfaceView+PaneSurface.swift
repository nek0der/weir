// SurfaceView+PaneSurface.swift
// Weir — answers Core's questions about a pane's terminal.

import AppKit

extension SurfaceView: PaneSurface {
    var isInWindow: Bool {
        window != nil
    }

    var boundsSize: CGSize {
        bounds.size
    }

    var rectInWindow: CGRect {
        convert(bounds, to: nil)
    }

    var holdsKeyboardFocus: Bool {
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow else { return false }
        return window === keyWindow && keyWindow.firstResponder === self
    }

    func takeKeyboardFocus() {
        window?.makeFirstResponder(self)
    }
}
