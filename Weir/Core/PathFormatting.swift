// PathFormatting.swift
// Weir — how a path and a folder's name are shown: the home abbreviation
// and control characters. In Core so the command palette and tab titles
// share the one home abbreviation the sheets use; a copy that matched
// `$HOME` without the trailing separator turned `/Users/nameX` into `~X`.

import Foundation

enum PathFormatting {
    /// Collapse `$HOME` to `~`, and show control characters
    /// (`showingControlCharacters`), for display.
    static func abbreviateHome(_ path: String) -> String {
        showingControlCharacters(homeRelative(path))
    }

    /// `path` with `$HOME` collapsed to `~` and every character kept, for a
    /// title that is stored and shown later. Inputs that aren't inside the
    /// user's home directory are returned verbatim.
    static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// A folder's own name, as a line of text shows it.
    static func name(of folder: URL) -> String {
        showingControlCharacters(folder.lastPathComponent)
    }

    /// `text` with each C0 control character and DEL replaced by its
    /// Unicode control picture (a newline becomes "␊", a tab "␉"), and NEL
    /// and the line and paragraph separators by "␤".
    ///
    /// A folder's name may hold a newline, which Git allows in a worktree's
    /// path. A one-line label drops it, so "feat\nline" read "featline", a
    /// folder that does not exist. A control picture keeps the line whole
    /// and cannot be mistaken for a backslash and an "n" that a name really
    /// holds. Stored names keep their characters; only what is shown goes
    /// through here.
    static func showingControlCharacters(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { controlPicture(for: $0) != nil }) else { return text }
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            shown.append(controlPicture(for: scalar) ?? scalar)
        }
        return String(shown)
    }

    /// The control picture for a C0 control character or DEL, and the
    /// newline symbol for the other characters that break a line (NEL, the
    /// line and the paragraph separators); nil for any other character.
    private static func controlPicture(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.value {
        case 0x00...0x1F: Unicode.Scalar(0x2400 + scalar.value)
        case 0x7F: "\u{2421}"
        case 0x85, 0x2028, 0x2029: "\u{2424}"
        default: nil
        }
    }
}
