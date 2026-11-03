// ToastCenter.swift
// Weir — single-slot toast bus. Holds at most one active toast at a
// time in each window. Designed for "undoable destructive lite"
// actions like Hide Worktree: do the thing immediately, surface a
// short-lived banner with an Undo button, auto-dismiss after a few
// seconds. Modeled on the Apple-style "deleted message → Undo"
// pattern (Mail / Notes).
//
// One slot is intentional: stacking toasts on a desktop sidebar
// turned into noise in our prototypes, and the user can always undo
// the most recent action — older actions stay undoable through the
// normal "Show Hidden Worktrees" / context-menu paths.

import Foundation
import WeirDomain

@MainActor
@Observable
final class ToastCenter {
    /// The toast each window shows, if any: a toast belongs to the
    /// window the result happened in, and another window does not show it.
    private(set) var items: [WindowID: ToastItem] = [:]

    private var dismissTasks: [WindowID: Task<Void, Never>] = [:]

    /// Why a toast stays past its lifetime: the pointer is on it, or its
    /// window's command palette is open, whose Undo row names it.
    enum Hold: Hashable {
        case pointer
        case palette
    }

    /// What holds each window's toast, by the toast's id: a hold set for a
    /// toast that has since been replaced holds nothing.
    private var holds: [WindowID: (id: UUID, reasons: Set<Hold>)] = [:]

    /// How many times its lifetime a toast stays: longer while VoiceOver
    /// is on, so the toast is still there once its announcement has been
    /// heard. Set by the app layer, which can ask; 1 without it (a test).
    @ObservationIgnored var lifetimeScale: @MainActor () -> Double = { 1 }

    /// Where a toast goes whose caller does not know its window
    /// (`showInFrontWindow`): the window commands act on. Set by the app
    /// layer, which knows the windows; without one (a test, say) such
    /// toasts share one slot of their own.
    @ObservationIgnored var frontWindow: @MainActor () -> WindowID? = { nil }
    private static let unplaced = WindowID()

    /// The toast `window` shows.
    func current(in window: WindowID) -> ToastItem? {
        items[window]
    }

    /// Show `item` in `window`, replacing any toast still there. The
    /// previous toast is dropped without firing its undo — that matches the
    /// Apple HIG guideline that a fresh action supersedes the prior
    /// reversible state.
    func show(_ item: ToastItem, in window: WindowID) {
        holds[window] = nil
        items[window] = item
        startLifetime(in: window)
    }

    /// Starts the window's toast's lifetime over, from its whole length.
    private func startLifetime(in window: WindowID) {
        dismissTasks.removeValue(forKey: window)?.cancel()
        guard let item = items[window] else { return }
        let lifetime = item.lifetimeSeconds * lifetimeScale()
        dismissTasks[window] = Task { [weak self, id = item.id] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            guard self?.items[window]?.id == id else { return }
            self?.dismiss(in: window)
        }
    }

    /// Keeps the toast `id` on screen in `window` until `reason` lets go
    /// (`releaseDismiss`). Nothing when the window shows another toast.
    func holdDismiss(_ id: UUID, in window: WindowID, reason: Hold) {
        guard items[window]?.id == id else { return }
        var reasons = holds[window]?.id == id ? holds[window]?.reasons ?? [] : []
        reasons.insert(reason)
        holds[window] = (id, reasons)
        dismissTasks.removeValue(forKey: window)?.cancel()
    }

    /// Lets go of `reason`'s hold on the toast `id`; once nothing holds it,
    /// it stays its whole lifetime again rather than what was left of it,
    /// so the person has the time to read it that a fresh toast has.
    func releaseDismiss(_ id: UUID, in window: WindowID, reason: Hold) {
        guard let hold = holds[window], hold.id == id, hold.reasons.contains(reason) else { return }
        let reasons = hold.reasons.subtracting([reason])
        if reasons.isEmpty {
            holds[window] = nil
            startLifetime(in: window)
        } else {
            holds[window] = (id, reasons)
        }
    }

    /// Whether the toast `id` is held in `window`.
    func isHeld(_ id: UUID, in window: WindowID) -> Bool {
        holds[window]?.id == id
    }

    /// `show(_:in:)` for a caller that does not know which window its
    /// result belongs to: the window commands act on (`frontWindow`).
    func showInFrontWindow(_ item: ToastItem) {
        show(item, in: frontWindow() ?? Self.unplaced)
    }

    /// Invoke the undo action of `window`'s toast and clear it.
    /// No-op for info-only toasts (`ToastItem.undo == nil`).
    func undo(in window: WindowID) {
        guard let item = items[window], let undo = item.undo else { return }
        dismiss(in: window)
        undo()
    }

    /// `undo(in:)` for the toast `id` alone: the palette's Undo row named
    /// that toast, and one that replaced it since is not what the person
    /// chose to take back.
    func undo(_ id: UUID, in window: WindowID) {
        guard items[window]?.id == id else { return }
        undo(in: window)
    }

    /// Drop `window`'s toast without calling undo.
    func dismiss(in window: WindowID) {
        dismissTasks.removeValue(forKey: window)?.cancel()
        holds[window] = nil
        items[window] = nil
    }

    /// Drops the toast `id` wherever it is still on screen: its action was
    /// taken back elsewhere, and its Undo would now do nothing.
    func dismiss(_ id: UUID) {
        for (window, item) in items where item.id == id {
            dismiss(in: window)
        }
    }
}

/// A single toast payload. Identifiable so the view can drive an
/// `id`-keyed transition when a fresh toast replaces an older one
/// mid-flight.
struct ToastItem: Identifiable {
    /// Given by the caller only when it must find this toast again
    /// (`ToastCenter.dismiss(_:)`).
    var id = UUID()
    /// The message, kept unresolved: a literal is a catalog string
    /// (`"Hid worktree “\(label)”."`), which `ToastView` draws in the
    /// window's locale, so a toast already on screen switches with the
    /// display language. `.verbatim` is for text we cannot localize, such
    /// as a system error's own message; `DisplayText(error:)` picks.
    let message: DisplayText
    /// Closure run when the user clicks Undo. The toast is dismissed
    /// before this fires, so the closure can safely re-enter the
    /// model layer. `nil` for info-only toasts whose message has
    /// nothing to reverse (e.g. "Not enough room to split"); the
    /// view hides the Undo button in that case.
    let undo: (() -> Void)?
    /// What Undo takes back, for its tooltip and VoiceOver, where that is
    /// more than "Undo" says (`ToastKind.undoLabel`); `nil` for "Undo".
    var undoLabel: LocalizedStringResource?
    /// Seconds before the toast auto-dismisses. 5s matches macOS
    /// Mail's "deleted message" undo window.
    var lifetimeSeconds: Double = 5.0

    /// How many times `lifetimeSeconds` a toast stays while VoiceOver is
    /// on: long enough to hear its announcement, then find its Undo.
    static let voiceOverLifetimeScale = 3.0
}

extension ToastItem {
    /// A supervision toast that reports news from elsewhere, with no Undo.
    init(_ kind: ToastKind) {
        assert(!kind.offersUndo, "\(kind) offers Undo; pass the action that takes it back")
        self.init(message: .localized(kind.message), undo: nil)
    }

    /// A supervision toast that can be taken back: `undo` is required, so a
    /// kind that promises Undo always has one.
    init(_ kind: ToastKind, id: UUID = UUID(), undo: @escaping () -> Void) {
        assert(kind.offersUndo, "\(kind) is news from elsewhere and offers no Undo")
        self.init(id: id, message: .localized(kind.message), undo: undo, undoLabel: kind.undoLabel)
    }
}
