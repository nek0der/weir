// KeyboardShortcut+Layout.swift
// Weir — reads the keyCode-to-character mapping of the current keyboard
// layout, for a captured shortcut and for the global hotkey's reverse lookup.

import Carbon.HIToolbox
import Foundation
import WeirDomain

extension StoredShortcut {
    /// A translator bound to the input source that is current now, for
    /// callers that translate many keyCodes in one pass (the global
    /// hotkey's reverse lookup scans all 128). Reading the layout once
    /// keeps that scan from querying the input source per keyCode. `nil`
    /// when the current input source has no Unicode layout data.
    @MainActor
    static func currentLayoutTranslator() -> ((UInt16) -> String?)? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return { keyCode in
            translate(keyCode, layoutData: layoutData, keyboardType: keyboardType)
        }
    }

    private static func translate(_ keyCode: UInt16, layoutData: Data, keyboardType: UInt32) -> String? {
        layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let layoutBytes = rawBuffer.baseAddress else { return nil }
            let keyLayoutPtr = layoutBytes.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var actualStringLength = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(kUCKeyActionDown),
                0, // modifierKeyState — zero strips Shift, Option, …
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &actualStringLength,
                &chars
            )
            guard status == noErr, actualStringLength > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: actualStringLength)
        }
    }
}
