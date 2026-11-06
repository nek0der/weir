// DebouncedSaveTests.swift
// Weir — a store's pending save: coalesced, canceled, and what it says is pending.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("DebouncedSave")
struct DebouncedSaveTests {
    /// Counts runs on the main actor. It is a class so the scheduled
    /// closures can share it.
    @MainActor
    private final class Runs {
        var labels: [String] = []
    }

    @Test func schedule_burst_runsOnlyTheLast_onceTheChangesStop() {
        let timer = ManualTimer()
        let save = DebouncedSave(delay: .milliseconds(20), timer: timer.timer)
        let runs = Runs()

        save.schedule { runs.labels.append("first") }
        timer.advance(by: .milliseconds(10))
        save.schedule { runs.labels.append("second") }
        #expect(save.hasUnflushedChanges)

        timer.advance(by: .milliseconds(19))
        #expect(runs.labels.isEmpty, "the second change put the save off")
        timer.advance(by: .milliseconds(1))
        #expect(runs.labels == ["second"])
    }

    @Test func cancel_dropsThePendingSave() {
        let timer = ManualTimer()
        let save = DebouncedSave(delay: .milliseconds(20), timer: timer.timer)
        let runs = Runs()

        save.schedule { runs.labels.append("canceled") }
        save.cancel()

        #expect(!save.hasUnflushedChanges)
        timer.advance(by: .milliseconds(20))
        #expect(runs.labels.isEmpty)
    }

    @Test func hasUnflushedChanges_staysTrueOnceTheSaveHasRun() {
        // A store's flush writes again after a save that ran, as it did
        // before the timer was shared.
        let timer = ManualTimer()
        let save = DebouncedSave(delay: .milliseconds(10), timer: timer.timer)
        let runs = Runs()
        #expect(!save.hasUnflushedChanges)

        save.schedule { runs.labels.append("ran") }
        timer.advance(by: .milliseconds(10))

        #expect(runs.labels == ["ran"])
        #expect(save.hasUnflushedChanges)
    }

    @Test func schedule_changesThatNeverStop_stillSaveOnceTheBurstHasWaitedTheMaximum() {
        let timer = ManualTimer()
        let save = DebouncedSave(delay: .milliseconds(20), maxWait: .milliseconds(100), timer: timer.timer)
        let runs = Runs()

        // A change every 10 ms puts the quiet delay off forever.
        for index in 0..<10 {
            save.schedule { runs.labels.append("change \(index)") }
            timer.advance(by: .milliseconds(10))
        }
        #expect(runs.labels == ["change 9"], "the latest change saved at the deadline")

        // The next change starts a burst of its own, with a deadline of its own.
        save.schedule { runs.labels.append("after") }
        timer.advance(by: .milliseconds(20))
        #expect(runs.labels == ["change 9", "after"])
        timer.advance(by: .milliseconds(100))
        #expect(runs.labels == ["change 9", "after"], "a save runs once, whichever timer comes first")
    }

    @Test func cancel_dropsTheBurstsDeadlineToo() {
        let timer = ManualTimer()
        let save = DebouncedSave(delay: .milliseconds(20), maxWait: .milliseconds(100), timer: timer.timer)
        let runs = Runs()

        save.schedule { runs.labels.append("canceled") }
        timer.advance(by: .milliseconds(10))
        save.cancel()
        timer.advance(by: .milliseconds(100))

        #expect(runs.labels.isEmpty)
    }
}
