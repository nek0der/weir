// ToastCenterTests.swift
// Weir — what keeps a toast past its lifetime, and which toast the palette's Undo takes back.

import Foundation
import Testing
import WeirDomain
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ToastCenterTests {
    private static let lifetime = 0.05

    private static func toast(id: UUID = UUID(), undo: @escaping () -> Void = {}) -> ToastItem {
        ToastItem(id: id, message: .verbatim("Marked as viewed."), undo: undo, lifetimeSeconds: lifetime)
    }

    /// Long enough for an unheld toast to have gone several times over.
    private static func outliveTheLifetime() async {
        try? await Task.sleep(for: .seconds(lifetime * 6))
    }

    @Test func aToastGoes_afterItsLifetime() async {
        let center = ToastCenter()
        let window = WindowID()
        center.show(Self.toast(), in: window)
        await pollUntil { center.current(in: window) == nil }
        #expect(center.current(in: window) == nil)
    }

    @Test func aHeldToast_staysPastItsLifetime_andGoesOnceLetGo() async {
        let center = ToastCenter()
        let window = WindowID()
        let toast = Self.toast()
        center.show(toast, in: window)
        center.holdDismiss(toast.id, in: window, reason: .pointer)
        await Self.outliveTheLifetime()
        #expect(center.current(in: window)?.id == toast.id)

        center.releaseDismiss(toast.id, in: window, reason: .pointer)
        #expect(!center.isHeld(toast.id, in: window))
        await pollUntil { center.current(in: window) == nil }
        #expect(center.current(in: window) == nil)
    }

    /// The pointer leaving does not let go of a toast the palette holds.
    @Test func aToastHeldForTwoReasons_staysUntilBothLetGo() async {
        let center = ToastCenter()
        let window = WindowID()
        let toast = Self.toast()
        center.show(toast, in: window)
        center.holdDismiss(toast.id, in: window, reason: .pointer)
        center.holdDismiss(toast.id, in: window, reason: .palette)
        center.releaseDismiss(toast.id, in: window, reason: .pointer)
        await Self.outliveTheLifetime()
        #expect(center.current(in: window)?.id == toast.id)
        center.releaseDismiss(toast.id, in: window, reason: .palette)
        await pollUntil { center.current(in: window) == nil }
        #expect(center.current(in: window) == nil)
    }

    /// A hold is the held toast's: the toast that replaces it runs its own
    /// lifetime, and the old toast's release does nothing to it.
    @Test func aHold_isTheHeldToastsOnly() async {
        let center = ToastCenter()
        let window = WindowID()
        let first = Self.toast()
        let second = Self.toast()
        center.show(first, in: window)
        center.holdDismiss(first.id, in: window, reason: .palette)
        center.show(second, in: window)
        #expect(!center.isHeld(second.id, in: window))
        center.holdDismiss(first.id, in: window, reason: .pointer)
        #expect(!center.isHeld(first.id, in: window), "a toast no longer shown takes no hold")
        await pollUntil { center.current(in: window) == nil }
        #expect(center.current(in: window) == nil)
    }

    @Test func aToastStaysLonger_whileTheScaleIsUp() async {
        let center = ToastCenter()
        center.lifetimeScale = { 20 }
        let window = WindowID()
        center.show(Self.toast(), in: window)
        await Self.outliveTheLifetime()
        #expect(center.current(in: window) != nil)
        center.dismiss(in: window)
    }

    /// The palette's row names the toast it was listed for; once another
    /// replaced it, the row takes nothing back.
    @Test func undoByID_takesBackThatToastAlone() {
        let center = ToastCenter()
        let window = WindowID()
        var undone: [String] = []
        let first = Self.toast { undone.append("first") }
        let second = Self.toast { undone.append("second") }
        center.show(first, in: window)
        center.show(second, in: window)
        center.undo(first.id, in: window)
        #expect(undone.isEmpty)
        #expect(center.current(in: window)?.id == second.id)

        center.undo(second.id, in: window)
        #expect(undone == ["second"])
        #expect(center.current(in: window) == nil)
    }

    @Test func dismissing_dropsTheHold() {
        let center = ToastCenter()
        let window = WindowID()
        let toast = Self.toast()
        center.show(toast, in: window)
        center.holdDismiss(toast.id, in: window, reason: .pointer)
        center.dismiss(in: window)
        #expect(!center.isHeld(toast.id, in: window))
    }

    /// VoiceOver's announcement names the palette only where there is an
    /// Undo to find there.
    @Test func theAnnouncement_namesThePalette_onlyForAToastWithUndo() {
        let english = Locale(identifier: "en")
        #expect(ToastAnnouncement.text(for: Self.toast(), locale: english) == "Marked as viewed. Undo is also in the command palette.")
        #expect(ToastAnnouncement.text(for: ToastItem(message: .verbatim("Copied."), undo: nil), locale: english) == "Copied.")
    }
}
