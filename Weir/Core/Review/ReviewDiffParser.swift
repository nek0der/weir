// ReviewDiffParser.swift
// Weir — validated old/new line positions for unified diffs.

import Foundation

enum ReviewDiffParser {
    /// The most rows any one file may contribute.
    ///
    /// Shared with the untracked path, which builds its rows without going
    /// through `parse`: a file that is only newlines is cheap to write and
    /// expensive to lay out, and the two routes disagreeing on the ceiling is
    /// how one of them ended up without one.
    static let maxRows = 100_000

    /// Split a blob into the lines a reader will see.
    ///
    /// Two things happen here rather than at each of the three call sites,
    /// so the three cannot disagree. Git writes the file's own line
    /// endings through, so a CRLF file leaves a carriage return at the end of
    /// every line; it belongs to the file's encoding rather than to the line
    /// being reviewed, and it is refused on the way to a terminal — a comment
    /// on a Windows-authored file could be written but never sent. And what
    /// must not reach a terminal at all is replaced, so what is drawn and what
    /// is quoted are the same text.
    static func lines(of text: String) -> [String] {
        endedLines(of: text).map(\.text)
    }

    /// `lines(of:)`, with whether each line ended in the carriage return it
    /// lost. The return is still taken off the text, for the reasons above;
    /// the flag is what lets a change that only converted line endings be
    /// shown as one, rather than as a line replaced by itself.
    private static func endedLines(of text: String) -> [(text: String, endsInCarriageReturn: Bool)] {
        text.components(separatedBy: "\n").map {
            let endsInCarriageReturn = $0.hasSuffix("\r")
            return (ReviewText.neutralized(endsInCarriageReturn ? String($0.dropLast()) : $0), endsInCarriageReturn)
        }
    }

    /// The file modes Git marks a symlink and a submodule with.
    private static let nonTextModes: Set<Substring> = ["120000", "160000"]

    /// Whether a side of the patch is a symlink or a submodule, whose "lines"
    /// are a link target or a commit rather than text anyone wrote.
    ///
    /// Read from the extended header lines that carry a mode, never from the
    /// end of any header line: the `diff --git` line ends in the path, so a
    /// text file named `notes 120000` was refused as a symlink.
    static func hasNonTextMode(_ lines: [ReviewLine]) -> Bool {
        lines.contains { line in
            guard line.kind == .fileHeader else { return false }
            let text = line.text
            for prefix in ["old mode ", "new mode ", "new file mode ", "deleted file mode "] where text.hasPrefix(prefix) {
                return nonTextModes.contains(text.dropFirst(prefix.count))
            }
            // `index <old>..<new> <mode>`, the mode present when both sides
            // share it.
            guard text.hasPrefix("index ") else { return false }
            let fields = text.split(separator: " ", omittingEmptySubsequences: false)
            return fields.count == 3 && nonTextModes.contains(fields[2])
        }
    }

    /// File identity must come from Git's NUL-delimited metadata, not these display headers.
    static func parse(_ patch: String) throws -> [ReviewLine] {
        let header = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var rows: [ReviewLine] = []
        var oldLine = 0
        var newLine = 0
        var oldRemaining = 0
        var newRemaining = 0
        var isInHunk = false
        // Counted from the headers rather than from the rows, so every line of
        // one hunk answers with the same number and a reader's run can be held
        // inside it.
        var hunkIndex: Int?
        let lines = endedLines(of: patch).dropLast(patch.hasSuffix("\n") ? 1 : 0)
        for (line, endsInCarriageReturn) in lines {
            guard rows.count < maxRows else { throw ReviewError.tooLarge }
            if line.hasPrefix("@@ ") {
                guard oldRemaining == 0, newRemaining == 0 else {
                    throw ReviewError.invalidDiff
                }
                let string = line as NSString
                guard let match = header.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else {
                    throw ReviewError.invalidDiff
                }
                func number(_ index: Int, default fallback: Int) throws -> Int {
                    let range = match.range(at: index)
                    if range.location == NSNotFound {
                        return fallback
                    }
                    guard let value = Int(string.substring(with: range)) else {
                        throw ReviewError.invalidDiff
                    }
                    return value
                }
                let header = try ReviewHunkHeader(
                    oldStart: number(1, default: 0),
                    oldCount: number(2, default: 1),
                    newStart: number(3, default: 0),
                    newCount: number(4, default: 1)
                )
                oldLine = header.oldStart
                oldRemaining = header.oldCount
                newLine = header.newStart
                newRemaining = header.newCount
                isInHunk = true
                hunkIndex = hunkIndex.map { $0 + 1 } ?? 0
                rows.append(ReviewLine(
                    id: rows.count,
                    kind: .hunk,
                    text: line,
                    oldLine: nil,
                    newLine: nil,
                    hunkIndex: hunkIndex,
                    hunkHeader: header
                ))
                continue
            } else if line.hasPrefix("\\ No newline at end of file") {
                guard isInHunk else { throw ReviewError.invalidDiff }
                rows.append(ReviewLine(id: rows.count, kind: .marker, text: line, oldLine: nil, newLine: nil, hunkIndex: hunkIndex))
                continue
            } else if isInHunk, oldRemaining > 0 || newRemaining > 0 {
                // The marker is one scalar, not one `Character`. A line whose
                // content starts with a combining mark joins it to the marker
                // into a single grapheme, so reading the first `Character`
                // matched neither `+` nor `-` and refused the whole file — and
                // dropping the first `Character` would have eaten the mark
                // along with the marker.
                let marker = line.unicodeScalars.first
                let consumesOld = marker == " " || marker == "-"
                let consumesNew = marker == " " || marker == "+"
                guard consumesOld || consumesNew,
                      !consumesOld || oldRemaining > 0,
                      !consumesNew || newRemaining > 0,
                      oldLine < Int.max, newLine < Int.max
                else { throw ReviewError.invalidDiff }
                rows.append(ReviewLine(
                    id: rows.count,
                    kind: marker == "+" ? .added : (marker == "-" ? .removed : .context),
                    text: String(String.UnicodeScalarView(line.unicodeScalars.dropFirst())),
                    oldLine: consumesOld ? oldLine : nil, newLine: consumesNew ? newLine : nil, hunkIndex: hunkIndex,
                    endsInCarriageReturn: endsInCarriageReturn
                ))
                if consumesOld {
                    oldLine += 1
                    oldRemaining -= 1
                }
                if consumesNew {
                    newLine += 1
                    newRemaining -= 1
                }
                continue
            } else {
                if line.hasPrefix("@@@") {
                    throw ReviewError.invalidDiff
                }
                isInHunk = false
            }
            rows.append(ReviewLine(id: rows.count, kind: .fileHeader, text: line, oldLine: nil, newLine: nil))
        }
        guard oldRemaining == 0, newRemaining == 0 else { throw ReviewError.invalidDiff }
        return rows
    }
}
