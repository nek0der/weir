// SystemPasteboard.swift
// Weir — the one way the app puts text on the general pasteboard.

import AppKit

/// Writes text to the general pasteboard. Every copy the app makes (a
/// path, a prompt, a comment, a diff's code, and a terminal's write,
/// trusted or approved) comes here, so each one replaces what was there
/// with plain text and nothing else.
@MainActor
enum SystemPasteboard {
    /// Replaces the pasteboard's contents with `text`. `false` when AppKit
    /// refused the write.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
