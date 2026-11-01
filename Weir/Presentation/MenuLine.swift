// MenuLine.swift
// Weir — how wide one line of a menu may grow, cut by its width in the menu's own font.

import CoreText
import Foundation

/// A menu is as wide as its widest item and cannot cut a line itself, so one
/// long branch or title would widen the whole menu. Every menu's lines are
/// cut here before the menu is built. We measure rather than count, because
/// a count lets a Japanese line grow about twice as wide as an English one.
/// Which part of a line goes is the line's kind (`SupervisionTruncation`).
enum MenuLine {
    /// The widest a line may be.
    static let maxWidth: CGFloat = 320
    /// The widest a name may be when words follow it in the same line ("main
    /// との差分", "(Current Worktree)"), which are never cut.
    static let nameBeforeWordsWidth: CGFloat = 200
    /// The widest a conversation's title may be, leaving room for its number
    /// ("Fix the flaky… #2").
    static let titleBeforeNumberWidth: CGFloat = 280

    /// `text` whole if it fits `maxWidth`, otherwise the longest cut at
    /// `kind`'s edge that does.
    static func fit(_ text: String, as kind: SupervisionTruncation = .name, maxWidth: CGFloat = maxWidth) -> String {
        guard width(of: text) > maxWidth else { return text }
        var fits = 0
        var tooLong = text.count
        // Width grows with what is kept, so the longest that fits is found
        // by halving, without measuring every length of a long line.
        while tooLong - fits > 1 {
            let kept = (fits + tooLong) / 2
            if width(of: cut(text, at: kind.edge, keeping: kept)) <= maxWidth {
                fits = kept
            } else {
                tooLong = kept
            }
        }
        return cut(text, at: kind.edge, keeping: fits)
    }

    /// `text`'s width as the menu draws it: the system's menu item font,
    /// which is what `NSFont.menuFont(ofSize: 0)` and a SwiftUI menu use.
    static func width(of text: String) -> CGFloat {
        let font = CTFontCreateUIFontForLanguage(.menuItem, 0, nil)
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font as Any]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func cut(_ text: String, at edge: SupervisionTruncation.Edge, keeping kept: Int) -> String {
        switch edge {
        case .tail:
            // A cut that falls after a space would leave "Fix the …".
            String(text.prefix(kept)).trimmingCharacters(in: .whitespaces) + "…"
        case .middle:
            // A little more of the end, where branches and paths differ.
            String(text.prefix(kept / 2)) + "…" + String(text.suffix(kept - kept / 2))
        case .head:
            "…" + String(text.suffix(kept))
        }
    }
}
