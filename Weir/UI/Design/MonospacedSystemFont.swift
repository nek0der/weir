// MonospacedSystemFont.swift
// Weir — the one way to ask for AppKit's monospaced system font: each size and weight kept for the app's life.

import AppKit
import os

/// AppKit's monospaced system font, made once per size and weight and kept
/// for the app's life.
///
/// This works around a CoreText abort seen on macOS 27.2: text measured
/// with a monospaced system font made after an earlier one of the same size
/// and weight was let go aborted in `NSString.size(withAttributes:)`
/// ("attempt to insert nil object"). While one is kept, AppKit hands that
/// same font out again, and none is let go. Remove this cache and the
/// `monospaced_system_font` lint rule when the reproduction in
/// `MonospacedSystemFontTests` no longer aborts on the oldest macOS Weir
/// supports.
enum MonospacedSystemFont {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
    }

    /// `NSFont` is immutable and safe to share between threads, but not
    /// `Sendable`, hence the unchecked lock.
    private static let kept = OSAllocatedUnfairLock(uncheckedState: [Key: NSFont]())

    static func font(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        kept.withLockUnchecked { kept in
            let key = Key(size: size, weight: weight)
            if let font = kept[key] {
                return font
            }
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            kept[key] = font
            return font
        }
    }
}
