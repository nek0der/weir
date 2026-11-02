// DebouncedSave.swift
// Weir — one store's pending save: replaced by each new one, run once the changes stop or the burst has waited long enough.

import Foundation

/// This is the save a store has scheduled and not yet run. It coalesces a
/// burst of changes into one write `PersistenceTiming.coalescingMs` after the last,
/// and no later than `PersistenceTiming.coalescingMaxWait` after the first:
/// a store whose changes never stop (a title an agent keeps rewriting)
/// would otherwise never write, and a crash would lose everything since
/// the last quiet moment. Each store owns one, so canceling it at quit or
/// before a write of its own touches only that store's save.
///
/// We share only the timer here. What a save writes, when its snapshot is
/// taken, the serial queue it writes on, and the synchronous flush stay in
/// each store, because those differ: most stores take the snapshot when
/// they schedule, while the session store also reads its migration state
/// when the save runs.
@MainActor
final class DebouncedSave {
    /// The latest save scheduled in this burst. Optional because no save may
    /// be waiting: none was scheduled yet, the last one ran, or it was
    /// canceled.
    private var latest: (@MainActor () -> Void)?
    /// These cancel the two timers of the burst, the one each change puts
    /// off and the one its first change set. Optional for the same reasons
    /// as `latest`.
    private var cancelQuiet: (@MainActor () -> Void)?
    private var cancelDeadline: (@MainActor () -> Void)?
    private var hasScheduled = false
    private let delay: Duration
    private let maxWait: Duration
    private let timer: HoverDelayTimer

    init(
        delay: Duration = .milliseconds(PersistenceTiming.coalescingMs),
        maxWait: Duration = PersistenceTiming.coalescingMaxWait,
        timer: HoverDelayTimer = .live
    ) {
        self.delay = delay
        self.maxWait = maxWait
        self.timer = timer
    }

    /// Whether a save was scheduled and not canceled since. It stays true
    /// after that save has run, as the stores' own work items did, so a
    /// store's synchronous flush still writes its latest state once more
    /// through its queue rather than trust a write that may be in flight.
    var hasPending: Bool {
        hasScheduled
    }

    /// Replaces any pending save with `run`, called on the main actor once
    /// `delay` passes without another call, or once `maxWait` has passed
    /// since the first call of the burst, whichever comes first. `run`
    /// usually enqueues a write of a snapshot it captured on the store's
    /// serial queue.
    func schedule(_ run: @escaping @MainActor @Sendable () -> Void) {
        latest = run
        hasScheduled = true
        cancelQuiet?()
        cancelQuiet = timer.schedule(delay) { [weak self] in self?.runLatest() }
        if cancelDeadline == nil {
            cancelDeadline = timer.schedule(maxWait) { [weak self] in self?.runLatest() }
        }
    }

    /// Drops the pending save, if any, before it runs. It is for a store
    /// writing now on its own, or one that has stopped saving.
    func cancel() {
        endBurst()
        hasScheduled = false
    }

    /// Runs the burst's latest save once, whichever timer came first, and
    /// starts the next change on a burst of its own.
    private func runLatest() {
        let run = latest
        endBurst()
        run?()
    }

    private func endBurst() {
        cancelQuiet?()
        cancelDeadline?()
        cancelQuiet = nil
        cancelDeadline = nil
        latest = nil
    }
}
