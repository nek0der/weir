// TerminalThemeFile.swift
// Weir — reads a Ghostty theme file's colors: its background, and the color-only copy Weir hands libghostty.

import Foundation

/// Reading of a Ghostty theme file's `key = value` lines.
///
/// This is not a config parser: libghostty evaluates the theme the terminal
/// uses. We read only enough to place a theme in the picker's light or dark
/// list without building a config for each of hundreds of files, and to
/// keep the color lines of a theme Weir did not ship (`sanitized(_:)`).
package enum TerminalThemeFile {
    /// The largest theme file we read. Theme files are a few hundred bytes;
    /// a larger file is not one, and reading it would only slow the listing
    /// and the config build.
    package static let maxBytes = 64 * 1024

    /// The keys a theme may set when its file is not one Weir ships.
    ///
    /// libghostty loads a theme file as a config file, so a theme can set
    /// any key, `command` and `initial-command` among them, and change what
    /// a new pane runs. A theme's job is its colors, so only these keys of a
    /// third-party theme reach libghostty.
    package static let colorKeys: Set<String> = [
        "palette",
        "background",
        "foreground",
        "cursor-color",
        "cursor-text",
        "selection-background",
        "selection-foreground",
        "bold-color"
    ]

    /// Returns the color the file's `background` key sets, or `nil` when no
    /// line sets a color we can read.
    ///
    /// The last `background = …` line wins, as it does in libghostty. A value
    /// is `#rrggbb` or `rrggbb`, case-insensitive. A later line whose value
    /// we cannot read does not undo an earlier readable one, since libghostty
    /// would reject that line rather than clear the color.
    package static func parseBackground(_ text: String) -> RGB8? {
        var result: RGB8?
        for (key, value) in entries(of: text) where key == "background" {
            if let color = parseHex(value) {
                result = color
            }
        }
        return result
    }

    /// Returns the file's color lines, rewritten by us, or `nil` when no
    /// line sets a `background` we can read.
    ///
    /// Each line is kept only when its key is in `colorKeys` and its value
    /// is one we can check: a `#rrggbb`/`rrggbb` color; for `palette`, an
    /// index from 0 to 255 and such a color; for the cursor and selection
    /// keys also `cell-foreground` or `cell-background`; and for
    /// `bold-color` also `bright`. Every other line is dropped, and each
    /// kept line is written out in one form (`key = value`), so nothing of
    /// the original text but those values reaches libghostty. Lines keep
    /// their order, so the last one for a key still wins.
    package static func sanitized(_ text: String) -> String? {
        var lines: [String] = []
        var hasBackground = false
        for (key, value) in entries(of: text) {
            guard let canonical = canonicalValue(key: key, value: value) else { continue }
            if key == "background" {
                hasBackground = true
            }
            lines.append("\(key) = \(canonical)")
        }
        guard hasBackground else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    /// The `key = value` pairs of `text`, keys and values trimmed of spaces
    /// and tabs, without comment lines. Lines end at `\n`, as libghostty
    /// splits them, with a trailing `\r` dropped. Swift reads `\r\n` as one
    /// character, so it is a separator of its own here.
    private static func entries(of text: String) -> [(key: String, value: String)] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return (key, value)
        }
    }

    private static func canonicalValue(key: String, value: String) -> String? {
        switch key {
        case "background", "foreground":
            return parseHex(value).map(format)
        case "cursor-color", "cursor-text", "selection-background", "selection-foreground":
            if value == "cell-foreground" || value == "cell-background" {
                return value
            }
            return parseHex(value).map(format)
        case "bold-color":
            if value == "bright" {
                return value
            }
            return parseHex(value).map(format)
        case "palette":
            guard let equals = value.firstIndex(of: "=") else { return nil }
            let index = value[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let color = value[value.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            // Decimal digits only: libghostty also reads `0x`/`0b`/`0o`
            // prefixes, which no theme file we know of uses.
            guard !index.isEmpty, index.count <= 3, index.allSatisfy(\.isASCIIDigit),
                  let number = Int(index), number <= 255,
                  let rgb = parseHex(color)
            else { return nil }
            return "\(number)=\(format(rgb))"
        default:
            return nil
        }
    }

    private static func parseHex(_ value: String) -> RGB8? {
        let digits = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
        guard digits.count == 6,
              digits.allSatisfy(\.isASCIIHexDigit),
              let number = UInt32(digits, radix: 16)
        else { return nil }
        return RGB8(
            r: UInt8((number >> 16) & 0xFF),
            g: UInt8((number >> 8) & 0xFF),
            b: UInt8(number & 0xFF)
        )
    }

    private static func format(_ color: RGB8) -> String {
        String(format: "#%02x%02x%02x", color.r, color.g, color.b)
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }

    var isASCIIHexDigit: Bool {
        isASCII && isHexDigit
    }
}
