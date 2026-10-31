// IconControlButton.swift
// Weir — the icon button of the left rail and the title bar's edge, and the face it draws.

import SwiftUI

/// One icon control: quiet until hovered or lit (`IconControlFace`). The pointer
/// resting on it brings up a chip naming it: beside it on the rail, under it in
/// the title bar, where the window's edge leaves no room beside it.
struct IconControlButton: View {
    var placement = HoverChipPlacement.beside
    let systemImage: String
    let name: LocalizedStringResource
    /// The key that does the same, shown in the chip; `nil` when none is bound.
    let shortcut: String?
    /// Whether what it opens is open, as VoiceOver hears it.
    var isSelected = false
    /// Whether it draws lit, where that differs from `isSelected`: a group
    /// that lights one button at a time decides it for each.
    var isLit: Bool?
    /// The mark drawn on the icon: a count of unviewed turns, a dot for
    /// unread history. Optional because most icons carry none.
    var badge: IconBadge?
    /// What VoiceOver hears as a hint, when it says more than the name and
    /// the key the chip shows.
    var hint: String?
    /// What VoiceOver reads as the button's value: its mark or its state.
    /// Optional because most icons have nothing to read.
    var value: String?
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            IconControlFace(
                systemImage: systemImage,
                isLit: isLit ?? isSelected,
                isHovering: isHovering,
                badge: badge,
                standsOnCorner: placement != .beside
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .hoverChip(name, shortcut: shortcut, placement: placement)
        .accessibilityLabel(Text(name))
        .accessibilityHint(Text(verbatim: hint ?? ShortcutHelpText.make(name: name, shortcut: shortcut, locale: locale)))
        .accessibilityValue(Text(verbatim: value ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The face every icon control of the rail and the title bar's edge shares: the
/// icon in `iconControlFrame`'s frame, its mark on the corner, cut into the icon.
struct IconControlFace: View {
    let systemImage: String
    let isLit: Bool
    let isHovering: Bool
    var badge: IconBadge?
    /// Out on the corner, clear of the art, as in the title bar, where a count
    /// is common.
    var standsOnCorner = false

    var body: some View {
        let outset = standsOnCorner ? WeirLayout.Supervision.spaceXS : 0
        Image(systemName: systemImage)
            .foregroundStyle(isLit || isHovering ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
            .iconControlFrame(isLit: isLit, isHovering: isHovering)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    IconBadgeMark(badge: badge)
                        .offset(x: outset, y: -outset)
                }
            }
            // The badge's ring cuts through the icon and its fill, and
            // no further.
            .compositingGroup()
    }
}

extension View {
    /// An icon control's frame: 16pt art in a 32pt square, filled while
    /// lit or hovered. Every icon control draws its icon through this.
    /// The fill is as see-through as the window's ground under the rail
    /// (`SurfaceGround`), so an open panel's button is not an opaque box.
    func iconControlFrame(isLit: Bool, isHovering: Bool) -> some View {
        font(.supervision(WeirLayout.Supervision.railSymbolSize, weight: .regular))
            .frame(width: WeirLayout.Supervision.railButtonSize, height: WeirLayout.Supervision.railButtonSize)
            .background(SurfaceGround {
                RoundedRectangle(cornerRadius: WeirLayout.Supervision.iconControlCornerRadius, style: .continuous)
                    .fill(isLit ? SupervisionTokens.railSelection.color : isHovering ? SupervisionTokens.hover.color : .clear)
            })
            .contentShape(Rectangle())
    }
}
