// PointerPressTrackerTests.swift
// Weir — the press a sidebar row shows: held inside the row and within the slop, and ended for good once past it.

import CoreGraphics
import Testing
@testable import Weir

struct PointerPressTrackerTests {
    @Test
    func pressInside_holdsUntilTheRelease() {
        var tracker = PointerPressTracker(slop: 3)
        #expect(tracker.press(at: CGPoint(x: 10, y: 10), isInside: true) == true)
        #expect(tracker.move(to: CGPoint(x: 12, y: 11)) == nil)
        #expect(tracker.isPressed)
        #expect(tracker.cancel() == false)
        #expect(!tracker.isPressed)
    }

    @Test
    func pressOutside_doesNotHold() {
        var tracker = PointerPressTracker(slop: 3)
        #expect(tracker.press(at: .zero, isInside: false) == nil)
        #expect(!tracker.isPressed)
        #expect(tracker.cancel() == nil)
    }

    @Test
    func pressThatMovesPastTheSlop_endsAndStaysEnded() {
        var tracker = PointerPressTracker(slop: 3)
        _ = tracker.press(at: .zero, isInside: true)
        #expect(tracker.move(to: CGPoint(x: 0, y: 3)) == false)
        #expect(tracker.move(to: CGPoint(x: 0, y: 1)) == nil)
        #expect(!tracker.isPressed)
    }

    @Test
    func pressElsewhere_endsTheHeldOne() {
        var tracker = PointerPressTracker(slop: 3)
        _ = tracker.press(at: .zero, isInside: true)
        #expect(tracker.press(at: CGPoint(x: 50, y: 50), isInside: false) == false)
    }
}
