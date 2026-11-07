// AgentPassCoalescerTests.swift
// Weir — a burst of file events becomes one pass now and one pass later.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("AgentPassCoalescer")
struct AgentPassCoalescerTests {
    /// A clock the test advances by hand, so the leading edge and the window
    /// are exact rather than a race against the scheduler. `ManualTimer`
    /// steps the delayed passes the same way.
    @MainActor
    final class Clock {
        var now: TimeInterval = 100
    }

    @Test("requests inside the window fold into a single trailing pass")
    func burst_foldsIntoOneTrailingPass() {
        let clock = Clock()
        let timer = ManualTimer()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.125, now: { clock.now }, timer: timer.timer, run: { passes += 1 })

        coalescer.request()
        #expect(passes == 1, "the leading pass must run without waiting")
        for _ in 0..<3 {
            clock.now += 0.03125
            timer.advance(by: .microseconds(31250))
            coalescer.request()
        }
        #expect(passes == 1, "the burst must not run a pass per event")

        clock.now += 0.03025
        timer.advance(by: .microseconds(30250))
        #expect(passes == 1)
        clock.now += 0.001
        timer.advance(by: .milliseconds(1))
        #expect(passes == 2, "later events must not postpone the original deadline")
        clock.now += 0.02
        timer.advance(by: .milliseconds(20))
        #expect(passes == 2, "the burst owes only one trailing pass")
    }

    @Test("a pass another route ran cancels the trailing pass it was owed")
    func passByAnotherRoute_cancelsTheTrailingPass() {
        let clock = Clock()
        let timer = ManualTimer()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, timer: timer.timer, run: { passes += 1 })

        coalescer.request()
        clock.now += 0.005
        coalescer.request()
        #expect(passes == 1)

        // The sweep, say, ran a pass after the second event arrived: it read
        // everything that event was about, so nothing is owed any more.
        clock.now += 0.005
        coalescer.didRun()

        timer.advance(by: .milliseconds(20))
        #expect(passes == 1)
    }

    @Test("a pass the rules asked for later runs then, and a newer answer replaces it")
    func requestIn_runsLater_andTheLatestAnswerWins() {
        let clock = Clock()
        let timer = ManualTimer()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, timer: timer.timer, run: { passes += 1 })

        coalescer.request(in: .milliseconds(20))
        // A pass by another route reads what changed, but not the moment a
        // held notice is due, so it leaves the asked-for pass in place.
        coalescer.didRun()
        #expect(passes == 0)
        timer.advance(by: .milliseconds(19))
        #expect(passes == 0)
        timer.advance(by: .milliseconds(1))
        #expect(passes == 1)

        coalescer.request(in: .milliseconds(20))
        timer.advance(by: .milliseconds(10))
        coalescer.request(in: .milliseconds(30))
        timer.advance(by: .milliseconds(10))
        #expect(passes == 1, "the superseded deadline must not run")
        timer.advance(by: .milliseconds(19))
        #expect(passes == 1)
        timer.advance(by: .milliseconds(1))
        #expect(passes == 2)

        // The next answer holds nothing, so nothing is owed.
        coalescer.request(in: .milliseconds(20))
        coalescer.request(in: nil)
        timer.advance(by: .milliseconds(20))
        #expect(passes == 2)
    }

    /// The one case on the timer the app uses: the passes above run by hand.
    @Test("the app's timer runs a pass that is owed")
    func theLiveTimer_runsTheTrailingPass() async {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.02, now: { clock.now }, run: { passes += 1 })

        coalescer.request()
        coalescer.request()
        #expect(passes == 1)

        await pollUntil(interval: .milliseconds(5)) { passes == 2 }
        #expect(passes == 2)
    }

    @Test("a request at or after the window end runs at once again", arguments: [0.125, 1.0])
    func requestAfterTheWindow_runsImmediately(elapsed: TimeInterval) {
        let clock = Clock()
        var passes = 0
        let coalescer = AgentPassCoalescer(window: 0.125, now: { clock.now }, run: { passes += 1 })

        coalescer.request()
        clock.now += elapsed
        coalescer.request()

        #expect(passes == 2)
    }
}
