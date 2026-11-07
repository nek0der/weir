// NotificationSanitizerTests.swift
// Weir — regression guard for the scalar-by-scalar notification body filter.

import Testing
@testable import Weir

@Suite("NotificationSanitizer")
struct NotificationSanitizerTests {

    @Test("normalizes newlines and preserves empty input", arguments: [
        ("\n\nhello\n\n", "hello"),
        ("a\n\n\n\nb", "a\nb"),
        ("line1\nline2", "line1\nline2"),
        ("line1\r\nline2", "line1\nline2"),
        ("", "")
    ])
    func sanitize_newlines(input: String, expected: String) {
        #expect(NotificationSanitizer.sanitize(input) == expected)
    }

    @Test(
        "filters control and invisible characters while preserving tab and joiners",
        arguments: [
            ("a\u{0001}b", "ab"), // C0 (SOH)
            ("a\u{001F}b", "ab"), // C0 (US)
            ("a\u{007F}b", "ab"), // DEL
            ("a\u{0085}b", "ab"), // C1 (NEL)
            ("a\tb", "a\tb"), // tab preserved
            ("a\u{200B}b", "ab"), // ZWSP
            ("a\u{200E}b", "ab"), // LRM
            ("a\u{200F}b", "ab"), // RLM
            ("a\u{FEFF}b", "ab"), // BOM
            ("a\u{202A}b", "ab"), // LRE
            ("a\u{202E}b", "ab"), // RLO (bidi override)
            ("a\u{2066}b\u{2069}", "ab"), // LRI / PDI
            // Joiners preserve emoji sequences and Persian / Arabic ligature suppression.
            ("a\u{200C}b", "a\u{200C}b"),
            ("a\u{200D}b", "a\u{200D}b"),
        ]
    )
    func sanitize_scalarFilter(input: String, expected: String) {
        #expect(NotificationSanitizer.sanitize(input) == expected)
    }

    @Test("caps text by whole grapheme clusters", arguments: [
        ("a", 1000, 256),
        ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", 255, 255),
        ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", 256, 256),
        ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", 257, 256)
    ])
    func sanitize_lengthLimit_preservesWholeGraphemes(grapheme: String, count: Int, expectedCount: Int) {
        let input = String(repeating: grapheme, count: count)
        let expected = String(repeating: grapheme, count: expectedCount)

        #expect(NotificationSanitizer.sanitize(input) == expected)
    }

    @Test("NFC normalizes decomposed forms")
    func sanitize_decomposedUnicode_isNormalizedToNFC() {
        // 'é' as decomposed (e + COMBINING ACUTE ACCENT, 2 scalars)
        let decomposed = "e\u{0301}"
        let sanitized = NotificationSanitizer.sanitize(decomposed)
        // NFC composed form is a single scalar U+00E9.
        #expect(sanitized.unicodeScalars.map(\.value) == [0x00E9])
    }

}
