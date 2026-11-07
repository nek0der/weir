// StopLedgerStoreTests.swift
// Weir — a stop that exists at quit exists after the relaunch: stops.json.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// The stops kept across launches (`StopLedgerStore`). The ledger's own
/// rules are in `StopLedgerTests`; here what the store adds: the file, and
/// the clock a resume runs against.
@MainActor
struct StopLedgerStoreTests: StopLedgerFixture {
    /// A stop that exists at quit exists after the relaunch: the run
    /// that died was retired with its record, so the file is all that says
    /// the pane holds a conversation that stopped. It offers the same
    /// resume and a new conversation as before the quit.
    @Test func aStop_staysAcrossALaunch_withItsSessionAndFolder() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let (session, project) = WorkspaceSessionFixture.withProject()
            let tab = session.openTab(container: .project(project.id))
            let pane = try #require(tab.splitTree.allLeafIDs().first)
            let exited = Self.run("a", .error, at: 0, pane: pane, turn: "t1")
            _ = store.update(runtimes: [exited], paneExists: Self.always, cwd: { _ in "/tmp/repo" })
            let id = StopLedger.itemID(of: exited)
            // The run's record is retired: the stop is the ledger's alone.
            _ = store.update(runtimes: [], paneExists: Self.always)
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let record = try #require(relaunched.ledger.record(id))
            #expect(record.runtimeID == "a")
            #expect(record.paneID == pane)
            #expect(record.provider == .claude)
            #expect(record.sessionID == Self.sessionID)
            #expect(record.cwd == "/tmp/repo")
            #expect(record.conversation == Self.conversation)
            #expect(record.turnID == TurnID("t1"))
            #expect(record.reason == .error("overloaded"))
            #expect(record.stoppedAt == Self.start)
            #expect(record.resume == StopLedger.Resume.none)
            // Listed from the file, with nothing reporting it.
            _ = relaunched.update(runtimes: [], paneExists: Self.always)
            #expect(relaunched.retained(besides: [], session: session) == [.init(
                itemID: id, runtimeID: "a", provider: .claude, paneID: pane, tabID: tab.id, projectID: project.id,
                reason: .error("overloaded"), stoppedAt: Self.start
            )])
            #expect(StopResumeRules.offer(record: record, job: .shell, hasDraft: false) == .available)
            #expect(StopResumeRules.command(for: record) == "cd '/tmp/repo' && claude --resume \(Self.sessionID)")
            #expect(StopResumeRules.newConversationCommand(for: record) == "cd '/tmp/repo' && claude")
        }
    }

    /// The ways a stop ends are kept too: one the person moved on from
    /// stays dismissed when its run still says error after the relaunch,
    /// and one whose pane the session did not restore ends at the first
    /// look. A resume on its way at quit is no longer on its way: the
    /// shell it was typed into went with the launch, so the stop offers
    /// the resume afresh; a resume that had failed still says so.
    @Test func aStopsEnd_andItsResume_areKeptAcrossALaunch() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let gonePane = UUID()
            let dismissedRun = Self.run("dismissed", .error, at: 0, episode: "1", pane: UUID(), sessionID: "s-dismissed")
            let resumingRun = Self.run("resuming", .error, at: 1, episode: "1", pane: gonePane, sessionID: "s-resuming")
            let failedRun = Self.run("failed", .error, at: 2, episode: "1", sessionID: "s-failed")
            _ = store.update(runtimes: [dismissedRun, resumingRun, failedRun], paneExists: Self.always)
            let dismissed = StopLedger.itemID(of: dismissedRun)
            let resuming = StopLedger.itemID(of: resumingRun)
            let failed = StopLedger.itemID(of: failedRun)
            store.dismiss(dismissed)
            store.markResuming(resuming, window: WindowID(), now: Self.start.addingTimeInterval(10))
            store.markResuming(failed, window: nil, now: Self.start.addingTimeInterval(10))
            let returned = store.resumeCommandFinished(
                inPane: Self.pane, exitCode: 1, durationNs: 1, now: Self.start.addingTimeInterval(12)
            )
            #expect(returned == .failed(failed))
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.dismissed == [dismissed])
            #expect(relaunched.ledger.record(resuming)?.resume == StopLedger.Resume.none)
            #expect(relaunched.ledger.record(failed)?.resume == .failed)
            #expect(!relaunched.hasResumeClock)
            // The dismissed run still in error lists nothing; the pane the
            // session did not bring back takes its stop with it.
            _ = relaunched.update(runtimes: [dismissedRun], paneExists: { $0 != gonePane })
            #expect(relaunched.ledger.record(dismissed) == nil)
            #expect(relaunched.ledger.dismissed == [dismissed])
            #expect(relaunched.ledger.record(resuming) == nil)
            #expect(relaunched.ledger.retained(besides: [dismissedRun]).map(\.itemID) == [failed])
            // The ends are saved too; written before the folder goes.
            relaunched.flushSynchronously()
            let reopened = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(Set(reopened.ledger.records.keys) == [failed])
            #expect(reopened.ledger.record(failed)?.resume == .failed)
            #expect(reopened.ledger.dismissed == [dismissed])
        }
    }

    /// A stop that ended is gone from the file as well, and the debounced
    /// save lands without a flush, as the app relies on between launches.
    @Test func aStopThatEnded_leavesTheFile() async throws {
        try await withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let first = Self.run("a", .error)
            let other = Self.otherStop
            let id = StopLedger.itemID(of: first)
            let otherID = StopLedger.itemID(of: other)
            _ = store.update(runtimes: [first, other], paneExists: Self.always)
            // The file itself is the signal. The deadline is only for a save
            // that never comes: the save waits on the main queue, which a
            // parallel run can stall.
            await pollUntil(timeout: .seconds(30), interval: .milliseconds(20)) {
                StopLedgerStore(directory: dir, resumeTimeout: .seconds(30)).ledger.record(id) != nil
            }
            let written = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            try #require(Set(written.ledger.records.keys) == [id, otherID])

            // The conversation came back: the stop ends, on disk too.
            _ = store.update(runtimes: [Self.run("b", .running, at: 30)], paneExists: Self.always)
            store.flushSynchronously()
            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(Set(relaunched.ledger.records.keys) == [otherID])
        }
    }

    private static var otherStop: RuntimeFact {
        run(
            "other",
            .error,
            pane: UUID(),
            conversation: .init(provider: .claude, conversationID: "other", isFallback: false),
            sessionID: "other-session"
        )
    }

    /// Quit must supersede an older queued snapshot even when the current
    /// ledger has returned to its previously persisted contents.
    @Test func aStopThatEndedWhileItsWriteWasUnderWay_isNotLeftByTheFlush() async throws {
        try await withTempDir { dir in
            let queue = DispatchQueue(label: "com.nekoder.weir.stop-ledger.test")
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30), saveQueue: queue)
            let other = Self.otherStop
            let otherID = StopLedger.itemID(of: other)
            _ = store.update(runtimes: [other], paneExists: Self.always)
            store.flushSynchronously()
            let oldBytes = try Data(contentsOf: dir.appendingPathComponent("stops.json"))

            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let blocked = Recorded(false)
            queue.async {
                blocked.value = true
                _ = gate.wait(timeout: .now() + 10)
            }
            await pollUntil { blocked.value }
            try #require(blocked.value)

            let stopped = Self.run("a", .error)
            _ = store.update(runtimes: [stopped], paneExists: Self.always)
            await pollUntil(timeout: .seconds(5)) { store.hasWriteUnderWay }
            try #require(store.hasWriteUnderWay)
            #expect(try Data(contentsOf: dir.appendingPathComponent("stops.json")) == oldBytes)

            _ = store.update(runtimes: [Self.run("b", .running, at: 30)], paneExists: Self.always)
            try #require(Set(store.ledger.records.keys) == [otherID])
            gate.signal()
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(Set(relaunched.ledger.records.keys) == [otherID])
        }
    }

    @Test(arguments: [false, true])
    func aPartlyUnreadableFile_readsValidEntries_andRespectsItsVersion(isFuture: Bool) throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir)
            let readable = Self.run("readable", .error)
            let dismissedRun = Self.otherStop
            let kept = StopLedger.itemID(of: readable)
            let dismissed = StopLedger.itemID(of: dismissedRun)
            _ = store.update(runtimes: [readable, dismissedRun], paneExists: Self.always)
            store.dismiss(dismissed)
            store.flushSynchronously()

            let file = dir.appendingPathComponent("stops.json")
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var records = try #require(object["records"] as? [[String: Any]])
            try #require(records.count == 1)
            var unknown = records[0]
            unknown["reason"] = ["kind": "unrecognized"]
            records.insert(unknown, at: 0)
            object["records"] = records
            let dismissals = try #require(object["dismissed"] as? [Any])
            try #require(dismissals.count == 1)
            object["dismissed"] = [NSNull()] + dismissals
            object["schemaVersion"] = isFuture ? 2 : 1
            let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try original.write(to: file)

            let reopened = StopLedgerStore(directory: dir)
            try #require(Set(reopened.ledger.records.keys) == [kept])
            #expect(reopened.ledger.dismissed == [dismissed])
            reopened.dismiss(kept)
            #expect(reopened.ledger.dismissed == [dismissed, kept])
            reopened.flushSynchronously()
            if isFuture {
                #expect(try Data(contentsOf: file) == original)
            } else {
                let repaired = StopLedgerStore(directory: dir)
                #expect(repaired.ledger.records.isEmpty)
                #expect(repaired.ledger.dismissed == [dismissed, kept])
            }
        }
    }

    @Test(arguments: [false, true])
    func aStoreThatWritesNoFiles_usesOnlyItsInMemoryLedger(hasExistingFile: Bool) throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("stops.json")
            var original: Data?
            if hasExistingFile {
                let seed = StopLedgerStore(directory: dir)
                _ = seed.update(runtimes: [Self.otherStop], paneExists: Self.always)
                seed.flushSynchronously()
                try #require(StopLedgerStore(directory: dir).ledger.records.count == 1)
                original = try Data(contentsOf: file)
            }
            let store = StopLedgerStore(directory: dir, writesFiles: false)
            #expect(store.ledger.records.isEmpty)
            let run = Self.run("local", .error)
            _ = store.update(runtimes: [run], paneExists: Self.always)
            #expect(Set(store.ledger.records.keys) == [StopLedger.itemID(of: run)])
            store.flushSynchronously()
            if let original {
                #expect(try Data(contentsOf: file) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    /// A restored stop is reused while launch resumes it. Either outcome
    /// is observed from the same persisted setup.
    @Test(arguments: [false, true])
    func aStopKeptFromTheLastLaunch_isTheLaunchResumesToResume_notASecondOne(comesBack: Bool) throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir)
            let limited = Self.run("a", .error)
            let independent = Self.run(
                "other", .error, pane: Self.pane,
                conversation: .init(provider: .claude, conversationID: "other", isFallback: false), sessionID: "other-session"
            )
            let otherID = StopLedger.itemID(of: independent)
            _ = store.update(runtimes: [limited, independent], paneExists: Self.always, cwd: { _ in "/tmp/repo" })
            let kept = StopLedger.itemID(of: limited)
            store.flushSynchronously()

            let relaunched = StopLedgerStore(directory: dir)
            try #require(Set(relaunched.ledger.records.keys) == [kept, otherID])
            let typedAt = Self.start.addingTimeInterval(100)
            relaunched.markResumingAtLaunch(
                paneID: Self.pane, provider: .claude, sessionID: Self.sessionID, cwd: "/tmp/repo", now: typedAt
            )
            let taken = try #require(relaunched.ledger.record(kept))
            #expect(taken.resume == .resuming(since: typedAt, window: nil))
            #expect(StopResumeRules.offer(record: taken, job: .shell, hasDraft: false) == .resuming)
            #expect(Set(relaunched.ledger.records.keys) == [kept, otherID])
            #expect(relaunched.ledger.record(otherID)?.resume == StopLedger.Resume.none)

            let launchStop = StopLedger.launchResumeItemID(paneID: Self.pane, sessionID: Self.sessionID)
            if comesBack {
                let returning = Self.run("returning", .running, at: 200)
                _ = relaunched.update(runtimes: [returning, independent], paneExists: Self.always)
                #expect(Set(relaunched.ledger.records.keys) == [otherID])
            } else {
                let failed = relaunched.resumeCommandFinished(
                    inPane: Self.pane, exitCode: 1, durationNs: 1, now: typedAt.addingTimeInterval(2)
                )
                #expect(failed == .failed(launchStop))
                #expect(Set(relaunched.ledger.records.keys) == [launchStop, otherID])
                #expect(relaunched.ledger.record(launchStop)?.reason == .notResumedAtLaunch)
                #expect(relaunched.ledger.record(launchStop)?.cwd == "/tmp/repo")
            }
            #expect(relaunched.ledger.launchResumes.isEmpty)
            #expect(!relaunched.hasResumeClock)
            relaunched.flushSynchronously()
            let reopened = StopLedgerStore(directory: dir)
            let expected: Set<AttentionItemID> = comesBack ? [otherID] : [launchStop, otherID]
            #expect(Set(reopened.ledger.records.keys) == expected)
            #expect(reopened.ledger.launchResumes.isEmpty)
        }
    }

    /// A launch whose session did not come back from its file has no
    /// panes for the stops to be in, through no doing of the person's:
    /// they are kept, in memory and in the file, for the launch that
    /// restores the session, rather than written away as pane-less.
    @Test func aLaunchWithoutItsSession_keepsTheStops_andTheirFile() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
            let id = StopLedger.itemID(of: Self.run("a", .error))
            store.flushSynchronously()

            let broken = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            broken.keepsStopsWithoutPanes = true
            _ = broken.update(runtimes: [], paneExists: { _ in false })
            #expect(broken.ledger.record(id) != nil)
            broken.flushSynchronously()

            let restored = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(restored.ledger.record(id) != nil)
            // With the session back, a pane that is gone ends its stop as before.
            _ = restored.update(runtimes: [], paneExists: { _ in false })
            #expect(restored.ledger.record(id) == nil)
            restored.flushSynchronously()
            #expect(StopLedgerStore(directory: dir).ledger.record(id) == nil)
        }
    }

    /// Makes `dir` read-only, as a managed or restored Mac can leave it, so
    /// no write of the file lands there; or writable again.
    private static func setWritable(_ dir: URL, _ isWritable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: isWritable ? 0o700 : 0o500], ofItemAtPath: dir.path)
    }

    /// A write that failed is not taken for written: the flush at quit
    /// writes the same stops once the file can be written.
    @Test(.enabled(if: geteuid() != 0))
    func aFailedWrite_isWrittenByTheFlushAtQuit() throws {
        try withTempDir { dir in
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30), retryDelay: .seconds(60))
            try Self.setWritable(dir, false)
            defer { try? Self.setWritable(dir, true) }
            let stopped = Self.run("a", .error)
            _ = store.update(runtimes: [stopped], paneExists: Self.always)
            store.flushSynchronously()
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("stops.json").path))
            try Self.setWritable(dir, true)
            store.flushSynchronously()
            let relaunched = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            #expect(relaunched.ledger.record(StopLedger.itemID(of: stopped)) != nil)
        }
    }

    /// A write that failed on its own (no quit to flush it) is tried
    /// again, and lands once the file can be written.
    @Test(.enabled(if: geteuid() != 0), arguments: [false, true])
    func aFailedWrite_isTriedAgain(changesWhileQueued: Bool) async throws {
        try await withTempDir { dir in
            let queue = DispatchQueue(label: "com.nekoder.weir.stop-ledger.retry-test")
            let gate = DispatchSemaphore(value: 0)
            try Self.setWritable(dir, false)
            defer { try? Self.setWritable(dir, true) }
            defer { gate.signal() }
            let blocked = Recorded(false)
            queue.async {
                blocked.value = true
                _ = gate.wait(timeout: .now() + 10)
            }
            await pollUntil { blocked.value }
            try #require(blocked.value)
            let store = StopLedgerStore(
                directory: dir, resumeTimeout: .seconds(30), retryDelay: .milliseconds(100), saveQueue: queue
            )
            let stopped = Self.run("a", .error)
            _ = store.update(runtimes: [stopped], paneExists: Self.always)
            // Past the coalescing delay the first write goes to the queue;
            // let it land, and fail.
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { store.hasWriteUnderWay }
            try #require(store.hasWriteUnderWay)
            let other = Self.otherStop
            if changesWhileQueued {
                store.dismiss(StopLedger.itemID(of: stopped))
                _ = store.update(runtimes: [other], paneExists: Self.always)
            }
            gate.signal()
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { !store.hasWriteUnderWay }
            try #require(!store.hasWriteUnderWay)
            let file = dir.appendingPathComponent("stops.json")
            try #require(!FileManager.default.fileExists(atPath: file.path))
            try Self.setWritable(dir, true)
            let expected = StopLedger.itemID(of: changesWhileQueued ? other : stopped)
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                StopLedgerStore(directory: dir).ledger.record(expected) != nil
            }
            let relaunched = StopLedgerStore(directory: dir)
            #expect(Set(relaunched.ledger.records.keys) == [expected])
        }
    }

}

extension StopLedgerStoreTests {

    // MARK: - The resume clock

    /// The resume brought the conversation back: its run reported, the stop
    /// ended as before, and the command's later return to the shell (the
    /// person quit the agent) finds no resume to fail.
    @Test(arguments: [false, true])
    func aResumeWhoseConversationCameBack_endsTheStop_andItsLaterExitTouchesNothing(sameRun: Bool) {
        let store = StopLedgerStore(resumeTimeout: .seconds(30))
        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let window = WindowID()
        store.markResuming(id, window: window, now: Self.start.addingTimeInterval(10))
        let returning = Self.run(sameRun ? "a" : "d", .idle, at: 30, episode: sameRun ? "2" : "1")
        let resumed = store.update(runtimes: [returning], paneExists: Self.always).resumed
        #expect(resumed == [.init(paneID: Self.pane, window: window)])
        #expect(store.ledger.records.isEmpty)
        #expect(!store.hasResumeClock)
        let exited = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 0, durationNs: 5_000_000_000, now: Self.start.addingTimeInterval(60)
        )
        #expect(exited == nil)
    }

    /// The command's start is its end less how long it ran: a command that
    /// returned at once began after the resume was typed, and fails it,
    /// taking its deadline along.
    @Test(arguments: [0, 1])
    func aShortResumeCommandFailsRegardlessOfExitCode(exitCode: Int) {
        let store = StopLedgerStore(resumeTimeout: .seconds(30))
        _ = store.update(runtimes: [Self.run("a", .error)], paneExists: Self.always)
        let id = StopLedger.itemID(of: Self.run("a", .error))
        let since = Self.start.addingTimeInterval(10)
        store.markResuming(id, window: nil, now: since)
        #expect(store.hasResumeClock)
        // A command that ran for 3 s and ended 1 s after the resume was
        // typed began before it: an earlier one.
        let earlier = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 0, durationNs: 3_000_000_000, now: since.addingTimeInterval(1)
        )
        #expect(earlier == nil)
        #expect(store.hasResumeClock)
        let quick = store.resumeCommandFinished(
            inPane: Self.pane, exitCode: exitCode, durationNs: 400_000_000, now: since.addingTimeInterval(1)
        )
        #expect(quick == .failed(id))
        #expect(store.ledger.record(id)?.resume == .failed)
        #expect(!store.hasResumeClock)
    }

    @Test func dismissingAStop_stopsItsResumeClock() {
        let store = StopLedgerStore(resumeTimeout: .seconds(30))
        let run = Self.run("a", .error)
        let id = StopLedger.itemID(of: run)
        _ = store.update(runtimes: [run], paneExists: Self.always)
        store.markResuming(id, window: nil)
        #expect(store.hasResumeClock)

        store.dismiss(id)

        #expect(!store.hasResumeClock)
        #expect(store.ledger.records.isEmpty)
    }

    @Test func refreshingOffers_replacesBlockersAndDropsDismissedStops() {
        let store = StopLedgerStore()
        let run = Self.run("a", .error)
        let other = Self.otherStop
        let id = StopLedger.itemID(of: run)
        let otherID = StopLedger.itemID(of: other)
        _ = store.update(runtimes: [run, other], paneExists: Self.always)

        store.refreshOffers { $0.itemID == id ? (.available, .draft) : (.available, nil) }
        #expect(store.offers == [id: .available, otherID: .available])
        #expect(store.startsNew == [otherID])
        #expect(store.newConversationBlockers == [id: .draft])
        store.refreshOffers { _ in (.available, nil) }
        #expect(store.startsNew == [id, otherID])
        #expect(store.newConversationBlockers.isEmpty)
        store.dismiss(id)

        store.refreshOffers { _ in (.available, nil) }

        #expect(store.offers == [otherID: .available])
        #expect(store.startsNew == [otherID])
        #expect(store.newConversationBlockers.isEmpty)
    }

    @Test func aResumeThatNeverComesBack_failsAfterItsTime() async {
        let store = StopLedgerStore(resumeTimeout: .milliseconds(50))
        let run = Self.run("a", .error)
        _ = store.update(runtimes: [run], paneExists: Self.always)
        let id = StopLedger.itemID(of: run)
        var callbacks: [StopLedger.Resume?] = []
        var clocks: [Bool] = []
        store.onResumeTimedOut = { [weak store] in
            callbacks.append(store?.ledger.record(id)?.resume)
            clocks.append(store?.hasResumeClock == true)
        }
        store.markResuming(id, window: nil)
        #expect(store.hasResumeClock)

        await pollUntil(timeout: .seconds(5)) { !callbacks.isEmpty }

        #expect(store.ledger.record(id)?.resume == .failed)
        #expect(callbacks == [.failed])
        #expect(clocks == [false])
    }

    @Test func aResumeCommandThatFinishes_discardsTheLateForegroundReply() async throws {
        let store = StopLedgerStore(resumeTimeout: .milliseconds(50))
        let run = Self.run("a", .error)
        _ = store.update(runtimes: [run], paneExists: Self.always)
        let id = StopLedger.itemID(of: run)
        let reply = Gate<Bool>()
        defer { reply.open(with: false) }
        let canceled = Recorded(false)
        store.isAgentInFront = { pane, provider in
            #expect(pane == Self.pane)
            #expect(provider == .claude)
            return await withTaskCancellationHandler {
                await reply.wait()
            } onCancel: {
                canceled.value = true
            }
        }
        let since = Self.start.addingTimeInterval(10)
        var timeoutNotices = 0
        store.onResumeTimedOut = { timeoutNotices += 1 }
        let clock = store.markResuming(id, window: nil, now: since)
        try await reply.waitUntilRequested()

        #expect(store.resumeCommandFinished(
            inPane: Self.pane, exitCode: 0, durationNs: 10, now: since.addingTimeInterval(1)
        ) == .failed(id))
        #expect(canceled.value)
        #expect(!store.hasResumeClock)
        #expect(store.ledger.record(id)?.resume == .failed)
        reply.open(with: false)
        await clock.value
        #expect(timeoutNotices == 0)
        #expect(!store.hasResumeClock)
        #expect(store.ledger.record(id)?.resume == .failed)
    }

    /// A folder that cannot be searched hides stops.json, which is not a
    /// launch with no stops: the file is kept as it is, nothing is written
    /// over it this launch, and the person is told.
    @Test(.enabled(if: geteuid() != 0))
    func stopsInAFolderThatCannotBeSearched_areNeverSavedOver() throws {
        try withTempDir { root in
            let dir = root.appendingPathComponent("support")
            let manager = FileManager.default
            try manager.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("stops.json")
            let earlier = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            _ = earlier.update(runtimes: [Self.run("a", .error, at: 0)], paneExists: Self.always)
            earlier.flushSynchronously()
            let original = try Data(contentsOf: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

            try #require(throws: (any Error).self) { try Data(contentsOf: file) }
            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            _ = store.update(runtimes: [Self.run("b", .error, at: 1)], paneExists: Self.always)
            store.flushSynchronously()

            #expect(try Data(contentsOf: file) == original)
            #expect(store.suspendedFile == file)
            #expect(try manager.contentsOfDirectory(atPath: dir.path) == ["stops.json"])
        }
    }

    /// Stops that do not decode are moved aside before anything saves, and
    /// saving goes on.
    @Test func stopsThatDoNotDecode_areMovedAside() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("stops.json")
            let garbled = Data(#"{ "records": "#.utf8)
            try garbled.write(to: file)

            let store = StopLedgerStore(directory: dir, resumeTimeout: .seconds(30))
            let replacement = Self.run("b", .error, at: 1)
            _ = store.update(runtimes: [replacement], paneExists: Self.always)
            store.flushSynchronously()

            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let aside = try #require(names.first { $0.hasPrefix("stops.json.bak-decode-failed-") })
            #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == garbled)
            #expect(store.suspendedFile == nil)
            #expect(Set(StopLedgerStore(directory: dir).ledger.records.keys) == [StopLedger.itemID(of: replacement)])
        }
    }
}
