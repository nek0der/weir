// PathFormattingTests.swift
// Weir — covers how a display path and a folder's name are shown: the home abbreviation and control characters.

import Foundation
import Testing
@testable import Weir

@Suite("PathFormatting")
struct PathFormattingTests {
    /// The command palette once matched the prefix without the separator
    /// and showed a sibling directory such as `/Users/nameX` as `~X`.
    @Test("a sibling that only shares the home prefix is left alone")
    func abbreviateHome_siblingWithSharedPrefix_isUnchanged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PathFormatting.abbreviateHome(home + "X/dev") == home + "X/dev")
    }

    /// A worktree's folder may hold a newline, which a one-line label drops:
    /// "feat\nline" read "featline", a folder that does not exist.
    @Test("a control character shows as its control picture")
    func showingControlCharacters_newlineAndTab_becomeControlPictures() {
        #expect(PathFormatting.showingControlCharacters("feat\nline") == "feat\u{240A}line")
        #expect(PathFormatting.showingControlCharacters("a\tb\rc\u{7F}d") == "a\u{2409}b\u{240D}c\u{2421}d")
        #expect(PathFormatting.showingControlCharacters("a\u{2028}b\u{85}c\u{2029}d") == "a\u{2424}b\u{2424}c\u{2424}d")
        for value in UInt32(0x00)...0x1F {
            let control = String(Character(Unicode.Scalar(value) ?? " "))
            let picture = String(Character(Unicode.Scalar(0x2400 + value) ?? " "))
            #expect(PathFormatting.showingControlCharacters("a" + control + "b") == "a" + picture + "b", "U+\(String(value, radix: 16))")
        }
        // C1 controls other than NEL have no control picture and stay.
        #expect(PathFormatting.showingControlCharacters("a\u{9B}b") == "a\u{9B}b")
        #expect(PathFormatting.showingControlCharacters("~/dev/weir-feat x") == "~/dev/weir-feat x")
    }

    /// A backslash and an "n" that a name really holds stay as they are, so
    /// they are never read as the newline's picture.
    @Test("a literal backslash-n is left alone")
    func showingControlCharacters_literalBackslashN_isUnchanged() {
        #expect(PathFormatting.showingControlCharacters(#"feat\nline"#) == #"feat\nline"#)
    }

    @Test("a path and a folder's name show their newline")
    func abbreviateHomeAndName_showANewlineInTheFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PathFormatting.abbreviateHome(home + "/dev/feat\nline") == "~/dev/feat\u{240A}line")
        #expect(PathFormatting.abbreviateHome("/tmp/feat\nline") == "/tmp/feat\u{240A}line")
        #expect(PathFormatting.name(of: URL(fileURLWithPath: "/tmp/feat\nline")) == "feat\u{240A}line")
    }
}
