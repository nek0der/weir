// ToastView.swift
// Weir — the bottom-anchored toast that surfaces the current
// `ToastCenter` slot, an inverted box that fades in and out on identity
// change.

import SwiftUI
import WeirDomain

struct ToastHost: View {
    /// The gap below the toast, measured from the window's bottom edge.
    let bottomInset: CGFloat
    @Environment(ToastCenter.self) private var toastCenter
    /// The window this host is in, which shows its own toasts only. The
    /// one host, `WindowChromeHost`, lays this over a main window's content,
    /// and `MainWindowContent` puts that window in the environment.
    @Environment(ProjectWindowState.self) private var window
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.locale) private var locale

    private var windowID: WindowID {
        window.id
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let item = toastCenter.current(in: windowID) {
                ToastCapsule(item: item, windowID: windowID)
                    .padding(.bottom, bottomInset)
                    // Reduce Motion stops the toast's animation: it
                    // appears and goes at once, with no slide and no fade.
                    .modalTransition(.transientBanner, reduceMotion: reduceMotion)
                    .id(item.id)
            }
        }
        .allowsHitTesting(toastCenter.current(in: windowID) != nil)
        .animation(
            ModalMotion.transientBanner.animation(reduceMotion: reduceMotion),
            value: toastCenter.current(in: windowID)?.id
        )
        // The palette's Undo row names the toast it takes back, so the toast
        // stays while the palette is open in this window.
        .onChange(of: PaletteHold(toast: toastCenter.current(in: windowID)?.id, isPaletteOpen: isPaletteOpen), initial: true) { old, new in
            if let toast = old.toast, old.isPaletteOpen {
                toastCenter.releaseDismiss(toast, in: windowID, reason: .palette)
            }
            if let toast = new.toast, new.isPaletteOpen {
                toastCenter.holdDismiss(toast, in: windowID, reason: .palette)
            }
        }
        // A toast says nothing to VoiceOver by being drawn; the window with
        // the keyboard reads each one out as it comes, so a toast behind
        // does not speak over what the person is doing.
        .onChange(of: toastCenter.current(in: windowID)?.id) { _, id in
            guard id != nil, appearsActive, let item = toastCenter.current(in: windowID) else { return }
            AccessibilityNotification.Announcement(ToastAnnouncement.text(for: item, locale: locale)).post()
        }
    }

    private var isPaletteOpen: Bool {
        session.commandPaletteState?.windowID == windowID
    }

    /// The toast the palette holds, compared as one value so a change to
    /// either moves the hold once.
    private struct PaletteHold: Equatable {
        let toast: UUID?
        let isPaletteOpen: Bool
    }
}

/// What VoiceOver hears as a toast comes: its message, and where its Undo is
/// for a person who does not point.
enum ToastAnnouncement {
    static func text(for item: ToastItem, locale: Locale) -> String {
        let message = item.message.resolved(in: locale)
        guard item.undo != nil else { return message }
        let hint = LocalizedStringResource(
            "Undo is also in the command palette.",
            comment: "VoiceOver, after a toast's message: its Undo is also a row of the command palette (⇧⌘P)"
        ).resolved(in: locale)
        return message + " " + hint
    }
}

private struct ToastCapsule: View {
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.colorScheme) private var colorScheme
    let item: ToastItem
    let windowID: WindowID

    /// A box in the text color with the window's color on it, its Undo in
    /// `toastLink`, the link color that reads on that inverted ground.
    var body: some View {
        content(
            font: .supervision(.body),
            linkFont: .supervision(.body, weight: .semibold),
            text: SupervisionTokens.window.color,
            link: SupervisionTokens.toastLink.color,
            spacing: WeirLayout.Supervision.toastSpacing
        )
        .padding(WeirLayout.Supervision.toastInsets)
        .background(
            RoundedRectangle(cornerRadius: WeirLayout.Supervision.toastCornerRadius, style: .continuous)
                .fill(SupervisionTokens.text.color)
                .modifier(FloatingSurfaceShadow())
        )
        .pointerStyle(.default)
        // The pointer on the toast keeps it, so it does not go from under a
        // person reading it or reaching for its Undo.
        .onHover { [toastCenter, windowID, id = item.id] isHovering in
            if isHovering {
                toastCenter.holdDismiss(id, in: windowID, reason: .pointer)
            } else {
                toastCenter.releaseDismiss(id, in: windowID, reason: .pointer)
            }
        }
        // Hover's end is not heard once the toast is gone from under it.
        .onDisappear { [toastCenter, windowID, id = item.id] in
            toastCenter.releaseDismiss(id, in: windowID, reason: .pointer)
        }
    }

    private func content(font: Font, linkFont: Font, text: Color, link: Color, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Text(display: item.message)
                .font(font)
                .foregroundStyle(text)
                .lineLimit(2)
            if item.undo != nil {
                Button {
                    toastCenter.undo(in: windowID)
                } label: {
                    Text("Undo", comment: "Takes back the last move: a toast's, the decision bar's after Mark as Viewed, or a restore's")
                        .font(linkFont)
                        .foregroundStyle(link)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A mark across conversations takes every line back, which
                // "Undo" alone does not say.
                .help(item.undoLabel.map { Text($0) } ?? Text(verbatim: ""))
                .accessibilityLabel(item.undoLabel.map { Text($0) } ?? Text("Undo"))
            }
            // No ⌘Z shortcut — Weir runs terminal sessions where
            // ⌘Z routes into the focused pane (editor undo), so the
            // toast can't claim that key without breaking the host
            // app's primary use case. The command palette lists the
            // toast's Undo for the keyboard instead.
            DismissGlyphButton(label: "Dismiss") {
                toastCenter.dismiss(in: windowID)
            }
            // On the inverted box the × takes the other appearance's
            // gray, which reads on a ground of the opposite lightness.
            .environment(\.colorScheme, colorScheme == .dark ? .light : .dark)
        }
    }
}
