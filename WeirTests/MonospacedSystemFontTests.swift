// MonospacedSystemFontTests.swift
// Weir — a monospaced system font is made once per size and weight and kept, so none is let go.

import AppKit
import Testing
@testable import Weir

/// The CoreText abort `MonospacedSystemFont` works around, as a program to
/// run on its own (`swiftc -Onone repro.swift && ./repro`), since it ends
/// the process it runs in. On macOS 27.2 it aborted within 20 seconds with
/// "attempt to insert nil object from objects[0]"; with the font made once
/// outside the loop, or with `NSFont.systemFont(ofSize:)`, it ran the 20
/// seconds out.
///
///     import AppKit
///     let end = Date().addingTimeInterval(20)
///     while Date() < end {
///         autoreleasepool {
///             let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
///             _ = ("T1000" as NSString).size(withAttributes: [.font: font])
///         }
///     }
///     print("no abort")
@Suite("Monospaced system font")
struct MonospacedSystemFontTests {
    @Test func aSizeAndWeight_isOneFont_keptOnceNothingElseHoldsIt() {
        // An odd size no other test asks for, held only weakly here, so
        // what keeps it alive is the owner.
        weak var asked: NSFont?
        autoreleasepool {
            asked = MonospacedSystemFont.font(ofSize: 13.25, weight: .bold)
        }
        #expect(asked != nil, "the font outlives every caller's hold")
        let kept = asked
        #expect(MonospacedSystemFont.font(ofSize: 13.25, weight: .bold) === kept)
        #expect(MonospacedSystemFont.font(ofSize: 13.25, weight: .regular) !== kept)
        #expect(kept?.isFixedPitch == true)
        #expect(kept?.pointSize == 13.25)
        let anotherSize = MonospacedSystemFont.font(ofSize: 14.25, weight: .bold)
        #expect(anotherSize !== kept)
        #expect(anotherSize.pointSize == 14.25)
    }
}
