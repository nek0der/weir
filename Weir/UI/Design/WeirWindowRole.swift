// WeirWindowRole.swift
// Weir — which of our windows an `NSWindow` is, as the updater reads it.

import AppKit

/// The SwiftUI `Window(id:)` scene id does not propagate to
/// `NSWindow.identifier`, so identifier-string filtering cannot tell the
/// main window from Settings. The UI tags each window through an associated
/// object instead (`WeirWindowRoleMarker`),
/// and `isUpdateControlInSight` reads the tag for `WeirUpdateDriver`. Both
/// windows can show the inline update popover; a Sparkle alert window
/// carries neither tag.
enum WeirWindowRole {
    case main
    case settings

    /// True when a visible window can show the update inline: a main Weir
    /// window, in the left rail's icon, or Settings. The two are told from
    /// other windows by the markers their roots set on the host `NSWindow`
    /// (`weirMainWindowEnvironment`, `SettingsScene`).
    @MainActor
    static var isUpdateControlInSight: Bool {
        NSApp.windows.contains { window in
            // Both the main window and the Settings window host an
            // inline `UpdatePopover` (GeneralPane mirrors the main
            // window's popover so the user who initiated the check from
            // Settings sees the result in place). Treating Settings as
            // a valid inline target stops the driver from layering
            // Sparkle's standard modal on top of the Settings popover
            // when the main window is hidden.
            // A main window whose rails are hidden shows no update control.
            window.isVisible
                && ((window.isWeirMainWindow && !window.hidesUpdateControl) || window.isWeirSettingsWindow)
        }
    }

    /// `objc_setAssociatedObject` needs a stable raw key. A static let keeps
    /// the address fixed for the process lifetime.
    fileprivate var associatedKey: UnsafeRawPointer {
        switch self {
        case .main: Self.mainKey
        case .settings: Self.settingsKey
        }
    }

    private nonisolated(unsafe) static let mainKey = makeKey()
    private nonisolated(unsafe) static let settingsKey = makeKey()
    fileprivate nonisolated(unsafe) static let updateControlKey = makeKey()

    private static func makeKey() -> UnsafeRawPointer {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        p.initialize(to: 0)
        return UnsafeRawPointer(p)
    }
}

extension NSWindow {
    func tagAsWeir(_ role: WeirWindowRole) {
        objc_setAssociatedObject(self, role.associatedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func isWeir(_ role: WeirWindowRole) -> Bool {
        (objc_getAssociatedObject(self, role.associatedKey) as? NSNumber)?.boolValue == true
    }

    /// `true` when the window is a Weir main window, not the
    /// Settings scene or a Sparkle alert window.
    var isWeirMainWindow: Bool {
        isWeir(.main)
    }

    /// `true` when the window hosts the `SettingsScene`, which also renders
    /// an inline `UpdatePopover` for the Update affordance on `GeneralPane`.
    var isWeirSettingsWindow: Bool {
        isWeir(.settings)
    }
}

extension NSWindow {
    /// Whether the window's update control is out of sight because its
    /// rails are hidden. The updater then shows Sparkle's own dialog
    /// rather than an inline popover no one could open. Set by the
    /// supervision window's `UpdateControlVisibilityMarker`.
    var hidesUpdateControl: Bool {
        get { (objc_getAssociatedObject(self, WeirWindowRole.updateControlKey) as? NSNumber)?.boolValue == true }
        set {
            objc_setAssociatedObject(
                self,
                WeirWindowRole.updateControlKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}
