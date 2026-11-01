// TerminalTitle.swift
// Weir — cleans a title a terminal reports before anything shows it.

import Foundation

package enum TerminalTitle {
    /// Strip bidi / zero-width / control characters and collapse runs of
    /// whitespace into single spaces so titles render cleanly in
    /// `NSWindow.title` and the tab bar's single-line `Text`. We do **not**
    /// truncate — single-line UI containers handle that with ellipsis.
    package static func sanitized(_ s: String) -> String {
        let bidi: ClosedRange<Unicode.Scalar> = "\u{202A}"..."\u{202E}"
        let bidi2: ClosedRange<Unicode.Scalar> = "\u{2066}"..."\u{2069}"
        let zwsp: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{FEFF}"
        ]
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar == "\r" {
                scalars.append(" ")
                continue
            }
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) {
                continue
            }
            if bidi.contains(scalar) || bidi2.contains(scalar) {
                continue
            }
            if zwsp.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Match the zsh/bash preexec transformation before applying the same UI
    /// sanitization every incoming title receives. Shell integration deletes
    /// control characters rather than replacing them with spaces.
    package static func sanitizedInjectedCommand(_ command: String) -> String {
        let visibleScalars = command.unicodeScalars.filter {
            $0.value >= 0x20 && !($0.value >= 0x7F && $0.value <= 0x9F)
        }
        return sanitized(String(String.UnicodeScalarView(visibleScalars)))
    }
}
