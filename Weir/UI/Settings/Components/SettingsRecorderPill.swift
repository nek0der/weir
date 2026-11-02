// SettingsRecorderPill.swift
// Weir — the pill a shortcut recorder in Settings is drawn as, recording or not.

import SwiftUI

/// The shape every shortcut recorder in Settings takes (Keyboard's rows, the
/// Quick Terminal hotkey, and the Keyboard row that opens the Quick Terminal
/// pane), so the pills line up and read alike: a gray fill at rest, an
/// accent tint and edge while it records.
struct SettingsRecorderPill: ViewModifier {
    let isRecording: Bool

    @Environment(\.weirAccent) private var accent

    /// How strong the fill is: the accent's while recording, the gray's at
    /// rest.
    private static let recordingFillOpacity = 0.2
    private static let restingFillOpacity = 0.12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.settingsRecorderPillCornerRadius)
        content
            .padding(.horizontal, WeirLayout.settingsRecorderPillHorizontalPadding)
            .frame(height: WeirLayout.settingsRecorderPillHeight)
            .background(
                shape.fill(
                    isRecording
                        ? accent.opacity(Self.recordingFillOpacity)
                        : Color.secondary.opacity(Self.restingFillOpacity)
                )
            )
            .overlay(shape.stroke(isRecording ? accent : Color.clear, lineWidth: 1))
    }
}

extension View {
    /// Draws the view as a shortcut recorder's pill (`SettingsRecorderPill`).
    func settingsRecorderPill(isRecording: Bool = false) -> some View {
        modifier(SettingsRecorderPill(isRecording: isRecording))
    }
}

/// What a recorder's pill says: the shortcut in `KeyComboText`'s face, so the
/// pills down Keyboard's rows show theirs at one width per key, or the words
/// for recording and for no shortcut in the form's own.
struct SettingsRecorderLabel: View {
    let shortcut: StoredShortcut?
    let isRecording: Bool

    var body: some View {
        if let keys = Self.keys(shortcut: shortcut, isRecording: isRecording) {
            KeyComboText(keys, size: NSFont.systemFontSize, weight: .regular)
        } else {
            Text(display: Self.text(shortcut: shortcut, isRecording: isRecording))
                .font(.body)
                .lineLimit(1)
        }
    }

    /// The same as words, for VoiceOver's value.
    static func text(shortcut: StoredShortcut?, isRecording: Bool) -> DisplayText {
        if let keys = keys(shortcut: shortcut, isRecording: isRecording) {
            return .verbatim(keys)
        }
        return isRecording ? .localized("Press a key…") : .localized("Unbound")
    }

    private static func keys(shortcut: StoredShortcut?, isRecording: Bool) -> String? {
        isRecording ? nil : shortcut?.displayString
    }
}
