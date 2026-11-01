// HoverChip.swift
// Weir — the chip naming an icon control, with its key, while the pointer rests on it.

import AppKit
import SwiftUI

/// Where a hover chip stands from its control.
enum HoverChipPlacement {
    /// To its right, as on the rail.
    case beside
    /// Under it, its right edge on the control's, as at the window's edge.
    case below
    /// Under it, its left edge on the control's, for a control that has the
    /// room on its right.
    case belowLeading

    /// What the chip is laid over its control by, before it moves clear.
    var alignment: Alignment {
        switch self {
        case .beside: .leading
        case .below: .topTrailing
        case .belowLeading: .topLeading
        }
    }

    /// How far the chip moves to clear a control of `size`.
    func offset(clearing size: CGSize) -> CGSize {
        let gap = WeirLayout.Supervision.spaceSnug
        return self == .beside ? CGSize(width: size.width + gap, height: 0) : CGSize(width: 0, height: size.height + gap)
    }
}

extension View {
    /// Names an icon control, with its key in a cap, in a chip the pointer
    /// resting on it brings up, drawn over what is there without moving it. The
    /// control's container has to stand over what the chip covers (`zIndex`).
    func hoverChip(_ name: LocalizedStringResource, shortcut: String?, placement: HoverChipPlacement) -> some View {
        modifier(HoverChip(name: name, shortcut: shortcut, placement: placement))
    }
}

private struct HoverChip: ViewModifier {
    let name: LocalizedStringResource
    let shortcut: String?
    let placement: HoverChipPlacement
    @State private var isHovering = false
    @State private var isShown = false
    /// The control was pressed or a menu opened since the pointer came: the
    /// person has moved on, and the chip stays down until the pointer leaves.
    @State private var isDismissed = false
    @State private var controlSize = CGSize.zero
    /// The keys on show while ⌘ is held, which the chip would stand over.
    @Environment(\.heldKeyHints) private var heldKeyHints

    /// How long the pointer rests before the chip comes up.
    private static let delay: Duration = .milliseconds(600)
    /// The longest it stays: a pointer left at rest must not keep covering
    /// what the person came to read.
    private static let longestShown: Duration = .seconds(10)

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { controlSize = $0 }
            .simultaneousGesture(TapGesture().onEnded { dismiss() })
            // A right-click's menu is no tap, and would open beside the chip.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                if isHovering {
                    dismiss()
                }
            }
            // The window can go without the pointer ever leaving the control.
            // Only the control under the pointer: the mark on any other would
            // stay until a hover that its first chip then never showed for.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if isHovering {
                    dismiss()
                }
            }
            .overlay(alignment: placement.alignment) {
                if isShown, heldKeyHints?.shownChord == nil {
                    HoverChipFace(name: name, shortcut: shortcut)
                        .offset(placement.offset(clearing: controlSize))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: isHovering) {
                guard isHovering else {
                    isShown = false
                    isDismissed = false
                    return
                }
                try? await Task.sleep(for: Self.delay)
                // A pointer that moved on cancels the wait, which the sleep
                // swallows.
                if !Task.isCancelled, !isDismissed {
                    isShown = true
                }
            }
            .task(id: isShown) {
                guard isShown else { return }
                // Typing with the pointer left here: the chip covers the
                // terminal being typed in. Watched only while it shows.
                let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated { dismiss() }
                    return event
                }
                try? await Task.sleep(for: Self.longestShown)
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                if !Task.isCancelled {
                    dismiss()
                }
            }
    }

    private func dismiss() {
        isDismissed = true
        isShown = false
    }
}

/// The chip itself. Its modifier moves it clear of the control by the control's
/// measured size rather than by alignment guides, which an overlay's branches
/// did not carry: the chip landed on the control.
struct HoverChipFace: View {
    let name: LocalizedStringResource
    var shortcut: String?

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.floatingChipCornerRadius, style: .continuous)
        HStack(spacing: Layout.spaceS) {
            Text(name)
                .font(.supervision(.label))
                .foregroundStyle(SupervisionTokens.text.color)
            if let shortcut {
                // On the chip's own window color, as in the palette's field.
                SupervisionKeycap(keys: shortcut, isFaceFilled: false)
            }
        }
        .padding(.horizontal, Layout.spaceM)
        .padding(.vertical, Layout.spaceS)
        .background(shape.fill(SupervisionTokens.window.color))
        .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
        .modifier(FloatingSurfaceShadow())
        .fixedSize()
    }
}
