// SurfaceView+Accessibility.swift
// Weir — the terminal as an accessibility text area: what it shows, and text a client writes into it.

import AppKit
import OSLog

private let log = Logger.weir("surface.accessibility")

/// How text an accessibility client writes into the terminal reaches it.
///
/// A client writes text into a text area by setting its `AXSelectedText`:
/// the text replaces the selection, and an empty selection is the caret.
/// In a terminal the caret is wherever the program is reading, so the text
/// goes in as input there.
enum AccessibilityTextRoute: Equatable {
    /// One line with no control character, committed the way Dictation's
    /// text is (`insertText(_:replacementRange:)`).
    case typed(String)
    /// Text with a control character, most often a newline. It goes through
    /// libghostty's paste action, so it is handled as any paste is: a program
    /// that asked for bracketed paste receives one framed block, and one that
    /// did not gets the paste confirmation first when the text has a newline.
    /// Typed, a newline would be a Return, and a shell would run each line
    /// before anyone saw it; an escape would reach the program as keys.
    case pasted(String)
    /// A line break alone, which is how a client can press Return. We press
    /// the Return key for it, which sends what the prompt already shows,
    /// where a paste would only add a new line to it. It carries no text of
    /// its own, so nothing reaches the program unseen.
    case returnKey

    /// Nil when there is nothing to write. Line breaks are normalized to
    /// `\n`, the only line break a paste accepts: a paste refuses a carriage
    /// return, and a client may end its lines the way another platform does.
    init?(_ text: String?) {
        guard let text, !text.isEmpty else { return nil }
        guard text.containsTypedControl else {
            self = .typed(text)
            return
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        self = lines == "\n" ? .returnKey : .pasted(lines)
    }
}

extension SurfaceView {
    /// libghostty paints into a Metal layer and publishes nothing through
    /// `NSAccessibility`, so we describe the view ourselves: a text area
    /// labeled "Terminal", whose value is the screen and which takes text
    /// at its caret.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        LocalizedStringResource("Terminal", comment: "VoiceOver label for the libghostty surface view")
            .resolved(in: resolvedAppLocale)
    }

    /// The active screen, read on every request rather than cached: a client
    /// that writes text reads the value back to see that the text arrived,
    /// and a cached screen could tell it that nothing had.
    override func accessibilityValue() -> Any? {
        activeScreenText()
    }

    /// The text a client writes at the caret. See `AccessibilityTextRoute`.
    override func setAccessibilitySelectedText(_ text: String?) {
        guard let route = AccessibilityTextRoute(text) else { return }
        deliverAccessibilityText(route)
    }

    /// A text area's value can be set too, and a client that cannot insert
    /// replaces the whole value that way. A terminal's screen is the
    /// program's output, which no client can replace, so we refuse the
    /// setter: the client learns that the write is unsupported instead of
    /// being told it succeeded while nothing reached the terminal.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) {
            return false
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    func deliverAccessibilityText(_ route: AccessibilityTextRoute) {
        // A client's text is not part of the person's open composition and
        // must not replace or discard what they have composed. We commit the
        // composed text first, as a Return pressed during a composition does
        // (`doCommand`), and the client's text follows. Without this,
        // `insertText` would take the client's text for the composition's
        // result, and a Return would send the line without the composed part.
        if hasMarkedText() {
            let composed = markedText
            unmarkText()
            commitText(composed)
        }
        switch route {
        case let .typed(line):
            // The path Dictation and the character viewer take outside a key
            // press, so the draft is marked as typed.
            insertText(line, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .returnKey:
            guard let surface else { return }
            sendReturnKey(to: surface)
            noteInput(.submit)
        case let .pasted(text):
            // The path review and the verification channel paste through,
            // which keeps the paste confirmation in front of a program that
            // would run each line. Never `ghostty_surface_text`: it completes
            // the paste as already allowed. Text containing a character a
            // paste refuses, such as an escape, is dropped rather than typed.
            do {
                try deliverReviewText(ReviewPrompt(validating: text), receipt: nil)
            } catch {
                log.error("accessibility text was not pasted: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
