// FullScreenEntryQueueTests.swift
// Weir — windows saved in full screen go back into it one at a time, and the line never stalls.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct FullScreenEntryQueueTests {
    private let first = WindowID()
    private let second = WindowID()
    private let third = WindowID()

    @Test func oneWindowGoesAtATime_theNextOnceItArrives() {
        var queue = FullScreenEntryQueue()
        let unrelated = WindowID()
        #expect(queue.isIdle)
        #expect(queue.attempt == 0)

        #expect(queue.add(first) == first)
        #expect(queue.add(second) == nil)
        #expect(queue.add(third) == nil)
        #expect(queue.entering == first)
        #expect(queue.waiting == [second, third])
        #expect(queue.attempt == 1)
        #expect(!queue.isIdle)
        queue.started(first)
        #expect(queue.hasStarted)
        let before = queue
        #expect(queue.settled(unrelated) == nil)
        #expect(queue == before)

        #expect(queue.settled(first) == second)
        #expect(queue.entering == second)
        #expect(queue.waiting == [third])
        #expect(queue.attempt == 2)
        #expect(!queue.hasStarted)
        #expect(queue.settled(second) == third)
        #expect(queue.entering == third)
        #expect(queue.waiting.isEmpty)
        #expect(queue.attempt == 3)
        #expect(queue.settled(third) == nil)
        #expect(queue.isIdle)
        #expect(queue.attempt == 3)
    }

    @Test func aRequestThatNeverBegan_letsTheNextGoInTime() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)

        #expect(queue.timedOut(first, attempt: queue.attempt) == second)

        // One that began is waited for, however long it takes.
        queue.started(second)
        #expect(queue.timedOut(second, attempt: queue.attempt) == nil)
        #expect(queue.entering == second)
    }

    @Test func aTimeLimitSetForAnEarlierRequest_leavesALaterOneOfTheSameWindow() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        let earlier = queue.attempt
        // Hidden and shown again before it began: asked a second time.
        _ = queue.withdraw(first)
        _ = queue.add(first)

        #expect(queue.timedOut(first, attempt: earlier) == nil)
        #expect(queue.entering == first)
        #expect(queue.timedOut(first, attempt: queue.attempt) == nil)
        #expect(queue.isIdle)
    }

    @Test func windowsNotInLine_changeNothing() {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)
        let before = queue

        queue.started(third)
        #expect(queue.timedOut(third, attempt: queue.attempt) == nil)
        #expect(queue.settled(third) == nil)
        #expect(queue == before)
    }

    enum HiddenPosition: Sendable, CaseIterable {
        case waiting, entering, started, absent
    }

    @Test(arguments: HiddenPosition.allCases)
    func hidingAWindowOnlyChangesItsOwnRequest(_ position: HiddenPosition) {
        var queue = FullScreenEntryQueue()
        _ = queue.add(first)
        _ = queue.add(second)
        let target: WindowID = switch position {
        case .waiting: second
        case .entering, .started: first
        case .absent: third
        }
        if position == .started {
            queue.started(first)
        }
        let before = queue
        let hidden = queue.withdraw(target)

        switch position {
        case .absent:
            #expect(!hidden.wasPending)
            #expect(hidden.next == nil)
            #expect(queue == before)
        case .waiting:
            #expect(hidden.wasPending)
            #expect(hidden.next == nil)
            #expect(queue.entering == first)
            #expect(queue.waiting.isEmpty)
            #expect(queue.attempt == before.attempt)
            #expect(queue.add(target) == nil)
            #expect(queue.waiting == [target])
            #expect(queue.settled(first) == target)
        case .entering, .started:
            #expect(hidden.wasPending)
            #expect(hidden.next == second)
            #expect(queue.entering == second)
            #expect(!queue.hasStarted)
            #expect(queue.attempt == before.attempt + 1)
            #expect(queue.timedOut(second, attempt: queue.attempt) == nil)
            #expect(queue.isIdle)
            #expect(queue.add(target) == target)
        }
        if position != .absent {
            #expect(queue.entering == target)
            #expect(queue.waiting.isEmpty)
            #expect(queue.settled(target) == nil)
            #expect(queue.isIdle)
        }
    }

    enum DeferredFront: Sendable, CaseIterable {
        case latest, hidden, passedOver
    }

    @Test(arguments: DeferredFront.allCases)
    func theWindowLastUsed_comesToTheFrontOnceTheLineIsDone(_ disposition: DeferredFront) {
        var queue = FullScreenEntryQueue()
        queue.raiseWhenDone(second)
        #expect(queue.takeFrontIfDone() == nil)
        #expect(queue.front == nil)

        _ = queue.add(first)
        queue.raiseWhenDone(second)
        queue.raiseWhenDone(third)
        #expect(queue.front == third)
        #expect(queue.takeFrontIfDone() == nil)
        switch disposition {
        case .latest: queue.shown(third)
        case .hidden: _ = queue.withdraw(third)
        case .passedOver: queue.shown(second)
        }

        _ = queue.settled(first)
        #expect(queue.takeFrontIfDone() == (disposition == .latest ? third : nil))
        #expect(queue.takeFrontIfDone() == nil)
        #expect(queue.front == nil)
    }

    @Test func aWindowAddedTwice_waitsOnce() {
        var queue = FullScreenEntryQueue()
        #expect(queue.add(first) == first)
        let attempt = queue.attempt
        #expect(queue.add(first) == nil)
        #expect(queue.attempt == attempt)
        #expect(queue.add(second) == nil)
        #expect(queue.add(second) == nil)
        #expect(queue.waiting == [second])
        #expect(queue.settled(first) == second)
        #expect(queue.attempt == attempt + 1)
        #expect(queue.settled(second) == nil)
        #expect(queue.isIdle)
    }
}
