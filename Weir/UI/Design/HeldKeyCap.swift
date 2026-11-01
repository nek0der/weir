// HeldKeyCap.swift
// Weir — the key a control answers, laid on it while its modifier keys are held.

import SwiftUI
import WeirDomain

extension EnvironmentValues {
    /// The window's keys on show; `nil` outside a supervision window, where
    /// no control shows one.
    @Entry var heldKeyHints: HeldKeyHints?
}

/// Where a held key's cap stands on its control.
enum HeldKeyCapPlacement {
    /// Out on an icon's bottom corner, leaving the icon to be read.
    case corner
    /// Inside a row or a tab, at its start, where its mark is: a row's edge
    /// is clipped by the list or the strip it stands in.
    case leading
    /// On the control itself, for one in the pane strip: the strip's rule is
    /// drawn over the strip and would cross a cap reaching past its control.
    case center

    fileprivate var alignment: Alignment {
        switch self {
        case .corner: .bottomTrailing
        case .leading: .leading
        case .center: .center
        }
    }

    fileprivate var offset: CGSize {
        let space = WeirLayout.Supervision.spaceXS
        switch self {
        case .corner: return CGSize(width: space, height: space)
        case .leading: return CGSize(width: space, height: 0)
        case .center: return .zero
        }
    }
}

extension View {
    /// Shows the key of whichever of `actions` the held modifier keys reach,
    /// as the person has bound it.
    func heldKeyCap(_ actions: WeirShortcutAction..., placement: HeldKeyCapPlacement = .corner) -> some View {
        modifier(HeldActionKeyCap(actions: actions, placement: placement))
    }

    /// Shows a key that is not a rebindable action's (⌘1…9, ⌘⏎, ⌘,) while
    /// exactly `chord` is held. `key` is asked only then, so a key worked out
    /// from the rows costs nothing the rest of the time.
    func heldKeyCap(
        chord: ShortcutModifiers,
        placement: HeldKeyCapPlacement = .corner,
        key: @escaping @MainActor () -> String?
    ) -> some View {
        modifier(HeldKeyCap(placement: placement) { $0 == chord ? key() : nil })
    }
}

private struct HeldActionKeyCap: ViewModifier {
    let actions: [WeirShortcutAction]
    let placement: HeldKeyCapPlacement
    @Environment(SettingsStore.self) private var settings

    func body(content: Content) -> some View {
        let keyboard = settings.settings.keyboard
        content.modifier(HeldKeyCap(placement: placement) { held in
            actions.lazy.compactMap { HeldKeyCapRule.key(of: keyboard.shortcut(for: $0), held: held) }.first
        })
    }
}

/// The cap itself, drawn over the control without moving it. For the eye only:
/// VoiceOver already hears each control's key in its hint.
private struct HeldKeyCap: ViewModifier {
    let placement: HeldKeyCapPlacement
    let key: @MainActor (ShortcutModifiers) -> String?
    @Environment(\.heldKeyHints) private var hints
    /// A control that is off answers no key, whatever its menu item is bound
    /// to. Only `.disabled` applied outside the cap reaches here.
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shownKey = isEnabled ? hints?.shownChord.flatMap(key) : nil
        content.overlay(alignment: placement.alignment) {
            ZStack {
                if let shownKey {
                    HeldKeyCapFace(key: shownKey)
                        .offset(placement.offset)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shownKey)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The text's color for a face and the window's for its letter, solid: a cap
/// has to read over whatever it lands on, a white row, a blue button, or a
/// terminal showing through a see-through ground, for the moment ⌘ is held.
/// `SupervisionKeycap`'s face is the ground's own color, made for a key at
/// rest beside a name, and on these it left only a faint edge.
private struct HeldKeyCapFace: View {
    let key: String

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: WeirFont.Supervision.Size.caption.rawValue, weight: .medium))
            .foregroundStyle(SupervisionTokens.window.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Layout.keycapHorizontalPadding)
            .frame(minWidth: Layout.keycapHeight, minHeight: Layout.keycapHeight)
            .background(
                SupervisionTokens.text.color,
                in: RoundedRectangle(cornerRadius: Layout.keycapCornerRadius, style: .continuous)
            )
    }
}
