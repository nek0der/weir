// ReviewStackLoaderTests.swift
// Weir — reading the review tab's other files: one queue, a budget that never lets go of the screen, and what a read changes.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Review stack loader")
struct ReviewStackLoaderTests {
    private let root = URL(fileURLWithPath: "/tmp/weir-stack-loader-\(UUID().uuidString)")

    private static func files(_ count: Int, layer: ReviewLayer = .unstaged) -> [ReviewFile] {
        (0..<count).map { ReviewFile(path: "f\($0).swift", layer: layer, status: .modified) }
    }

    private static func diffs(_ files: [ReviewFile], lines: Int = 2) throws -> [ReviewDiff] {
        try files.map { try ReviewDiffFixture.rewritten($0, lines: lines) }
    }

    private static func requests(_ files: [ReviewFile]) -> [ReviewStackLoader.Request] {
        files.map { ReviewStackLoader.Request(file: $0, scope: .uncommitted) }
    }

    private func session(_ repository: StackReviewRepository) -> ReviewSession {
        ReviewSession(
            writer: ReviewDraftWriter(root: root, drafts: RecordingReviewDraftStore()),
            git: repository
        )
    }

    private static func requireCompletion(
        of task: Task<Void, Never>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let completed = Recorded(false)
        Task {
            await task.value
            completed.value = true
        }
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(5)) { completed.value }
        try #require(completed.value, "the task finished", sourceLocation: sourceLocation)
    }

    // MARK: - Released

    @Test func aReleasedStack_readsNothingUntilItIsDrawnAgain() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        let window = Set(files.map(\.id))
        loader.request(Self.requests(files), window: window)
        await pollUntilStackRead { loader.entries.count == files.count }
        try #require(Set(loader.entries.keys) == window)
        let ticket = loader.beginSearch()

        loader.release(listed: files)

        #expect(loader.entries.isEmpty)
        #expect(loader.isReleased)
        #expect(loader.searchCoverage == .none)
        let reads = repository.diffReads
        // What was worked out before, arriving after: a scroll, and Find's
        // estimate, old ticket and new.
        loader.request(Self.requests(files), window: [files[0].id])
        loader.requestAll(Self.requests(files), estimates: [:], ticket: ticket)
        loader.requestAll(Self.requests(files), estimates: [:], ticket: loader.beginSearch())
        #expect(loader.window == window)
        #expect(loader.searchCoverage == .none)
        #expect(loader.entries.isEmpty)

        // A read of the list that ends after the release lets nothing in.
        loader.retire(.anotherScope, listed: files)
        #expect(loader.isReleased)
        // The review is drawn again: reads follow.
        loader.resume()
        loader.request(Self.requests(files), window: window)
        await pollUntilStackRead { loader.entries.count == files.count }
        #expect(!loader.isReleased)
        #expect(Set(loader.entries.keys) == window)
        #expect(repository.diffReads == reads + files.count)
        #expect(repository.diffReadIDs.dropFirst(reads).sorted() == files.map(\.id).sorted())
    }

    @Test func aSessionKeptOffScreen_letsGoOfItsStack() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        session.stackLoader.request(Self.requests(files), window: Set(files.map(\.id)))
        await pollUntilStackRead { session.stackLoader.entries.count == files.count }
        try #require(Set(session.stackLoader.entries.keys) == Set(files.map(\.id)))

        session.releaseStack()

        #expect(session.stackLoader.entries.isEmpty)
        #expect(session.stackLoader.isReleased)
    }

    // MARK: - The queue

    @Test func reads_runFourAtATime_fromOneQueue() async throws {
        let files = Self.files(12)
        let gate = Gate<Void>()
        defer { gate.open() }
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files), readGate: gate)
        let loader = ReviewStackLoader(git: repository, root: root)
        let window = Set(files.map(\.id))

        // Asked twice, as a scroll asks on every event.
        loader.request(Self.requests(Array(files.prefix(6))), window: window)
        loader.request(Self.requests(files), window: window)
        await pollUntil { gate.requests >= 4 }
        try #require(gate.requests == 4)
        gate.open()
        await pollUntilStackRead { loader.entries.count == files.count }

        #expect(Set(loader.entries.keys) == window)
        #expect(repository.diffReadIDs.sorted() == files.map(\.id).sorted())
        #expect(repository.peak <= 4, "never more Git processes than the cap")
        #expect(repository.peak > 1, "and more than one")
        #expect(repository.diffReads == files.count, "each file read once")
    }

    @Test func reads_forAPreviousList_areDropped() async throws {
        let files = Self.files(3)
        let gate = Gate<Void>()
        defer { gate.open() }
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files), readGate: gate)
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.concurrency = 1
        loader.request(Self.requests(Array(files.prefix(2))), window: Set(files.map(\.id)))
        try await gate.waitUntilRequested()
        try #require(repository.diffReadIDs == [files[0].id])

        let retired = try #require(loader.retire(.anotherScope, listed: files))
        let retiredRevision = loader.revision
        gate.open()
        try await Self.requireCompletion(of: retired)

        #expect(loader.entries.isEmpty, "another range's diffs never land in this one")
        #expect(!loader.isWaitingToPublish(files[0].id))
        #expect(loader.revision == retiredRevision)
        #expect(repository.diffReadIDs == [files[0].id])
        let current = files[2]
        loader.request(Self.requests([current]), window: [current.id])
        await pollUntilStackRead { loader.entries[current.id]?.diff != nil }
        try #require(loader.entries[current.id]?.diff != nil)
        #expect(Set(loader.entries.keys) == [current.id])
        #expect(repository.diffReadIDs == [files[0].id, current.id])
    }

    @Test func aFileThatLeftTheWindow_isNotStarted() async throws {
        let files = Self.files(3)
        let gate = Gate<Void>()
        defer { gate.open() }
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files), readGate: gate)
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.concurrency = 1
        loader.request(Self.requests(files), window: Set(files.map(\.id)))
        try await gate.waitUntilRequested()
        try #require(repository.diffReadIDs == [files[0].id])

        // Reaching the last queued file establishes that the excluded files
        // ahead of it have been considered, without a wall-clock delay.
        loader.request([], window: [files[2].id])
        gate.open()
        await pollUntilStackRead { loader.entries[files[2].id] != nil }

        #expect(loader.entries[files[2].id] != nil)
        #expect(repository.diffReadIDs == [files[0].id, files[2].id])
    }

    @Test func theFirstResult_isPublishedAtOnce() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.publishInterval = .seconds(60)

        loader.request(Self.requests(files), window: [files[0].id])
        await pollUntil(timeout: .seconds(10), interval: .milliseconds(20)) { loader.entries[files[0].id] != nil }

        #expect(loader.entries[files[0].id]?.diff?.fingerprint == files[0].path, "not held for the interval")
    }

    // MARK: - The budget

    @Test func theBudget_neverLetsGoOfTheScreen_andLetsGoOfTheFarthestFirst() throws {
        let files = Self.files(5)
        let diffs = try Self.diffs(files, lines: 2)
        let loader = ReviewStackLoader(git: StackReviewRepository(files: files, diffs: diffs), root: root)
        loader.retire(.anotherScope, listed: files)
        loader.lineBudget = 20
        // f2 and f3 on screen.
        loader.request([], window: [files[2].id, files[3].id])

        for diff in diffs {
            loader.remember(diff, state: nil, serial: loader.beginRead(), scope: .uncommitted)
        }

        // Each diff is five lines: a hunk header and two of each kind.
        #expect(loader.entries[files[2].id] != nil && loader.entries[files[3].id] != nil, "the screen stays")
        #expect(loader.entries[files[4].id] != nil, "and the file just read")
        #expect(loader.entries[files[0].id] == nil, "the farthest goes first")
        #expect(loader.entries[files[1].id] != nil, "only one eviction was needed")

        loader.lineBudget = 12
        loader.remember(diffs[4], state: nil, serial: loader.beginRead(), scope: .uncommitted)
        #expect(loader.entries[files[1].id] == nil)

        // Over the budget with the screen alone, nothing on it goes.
        loader.lineBudget = 1
        loader.request([], window: Set(files.suffix(3).map(\.id)))
        loader.remember(diffs[4], state: nil, serial: loader.beginRead(), scope: .uncommitted)
        #expect(Set(loader.entries.keys) == Set(files.suffix(3).map(\.id)))
    }

    @Test func find_readsTheWholeRange_orSaysItSearchesWhatIsRead() async throws {
        let files = Self.files(4)
        let diffs = try Self.diffs(files)
        let scenarios: [(estimates: [Int], expectedIndices: [Int])] = [
            ([25, 25, 25, 25], [0, 1, 2, 3]),
            ([60, 50, 40, 1], [0, 2])
        ]
        for scenario in scenarios {
            let repository = StackReviewRepository(files: files, diffs: diffs)
            let loader = ReviewStackLoader(git: repository, root: root)
            loader.lineBudget = 100
            loader.requestAll(
                Self.requests(files),
                estimates: Dictionary(uniqueKeysWithValues: zip(files.map(\.id), scenario.estimates)),
                ticket: loader.beginSearch()
            )
            #expect(loader.searchCoverage == (scenario.expectedIndices.count == files.count ? .everyFile : .loadedFilesOnly))
            let expected = Set(scenario.expectedIndices.map { files[$0].id })
            await pollUntilStackRead { expected.isSubset(of: loader.entries.keys) }
            #expect(Set(loader.entries.keys) == expected)
            #expect(repository.diffReadIDs.sorted() == expected.sorted())

            loader.endSearch()
            #expect(loader.searchCoverage == .none)
        }
    }

    @Test func otherFilesHighlights_areFoundByTheirBand() {
        var highlights = ReviewIntralineHighlights(rangesByLineID: [5: [NSRange(location: 0, length: 1)]])
        highlights.bands[2] = [5: [NSRange(location: 1, length: 2)]]

        #expect(highlights[5] == [NSRange(location: 0, length: 1)])
        #expect(highlights[ReviewStackIDs.offset(forSlot: 2) + 5] == [NSRange(location: 1, length: 2)])
        #expect(highlights[ReviewStackIDs.offset(forSlot: 3) + 5].isEmpty)
    }

    // MARK: - The session

    @Test func theReview_keepsTheFilesItOpened() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let tab = session(repository)

        _ = await tab.reload(scope: .uncommitted, selectedFileID: nil)

        let opened = try #require(tab.diff)
        #expect(opened.file.id == files[0].id)
        #expect(Set(tab.stackLoader.entries.keys) == [files[0].id])
        let cached = try #require(tab.stackLoader.entries[files[0].id]?.diff)
        #expect(cached.file == opened.file)
        #expect(cached.fingerprint == opened.fingerprint)
        #expect(cached.lines == opened.lines)
    }

    @Test func aReadFile_opensWithoutGit_inEveryComparison() async throws {
        let range = try TurnSummaryFixture.range()
        let comparisons: [(ReviewScope, ReviewLayer)] = [
            (.uncommitted, .unstaged),
            (.branch(base: "main"), .branch),
            (.turns(range), .turns)
        ]
        for (scope, layer) in comparisons {
            let files = Self.files(2, layer: layer)
            let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
            let session = session(repository)
            _ = await session.reload(scope: scope, selectedFileID: files[0].id)
            session.loadStacked(window: files.map(\.id))
            await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
            // Changed since it was read: opening it still shows what was read.
            try repository.replace(ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "edited"))
            let reads = repository.diffReads

            #expect(session.openFromStack(files[1]) != nil, "\(scope.scopeID)")
            #expect(session.diff?.fingerprint == files[1].path, "never swapped without a word: the banner says it")
            #expect(!session.isLoading)
            #expect(repository.diffReads == reads)
        }
    }

    @Test func aFileReadBeforeARefresh_opensFromGit() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)

        #expect(session.stackLoader.stale.contains(files[1].id))
        #expect(session.openFromStack(files[1]) == nil, "drawn only until it is read again: `load` reads it")
        let current = try ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "after refresh")
        repository.replace(current)
        await session.load(files[1])
        #expect(session.diff?.file == files[1])
        #expect(session.diff?.fingerprint == "after refresh")
    }

    @Test func aRangeOfTurns_keepsWhatItReadAcrossARefresh() async throws {
        let files = Self.files(2, layer: .turns)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        let range = try TurnSummaryFixture.range()
        _ = await session.reload(scope: .turns(range), selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        let cached = try #require(session.stackLoader.entries[files[1].id]?.diff)
        let reads = repository.diffReadIDs.filter { $0 == files[1].id }
        _ = await session.reload(scope: .turns(range), selectedFileID: files[0].id)

        #expect(!session.stackLoader.needsDiff(files[1].id), "two trees cannot change: nothing to read again")
        let retained = try #require(session.stackLoader.entries[files[1].id]?.diff)
        #expect(retained.file == cached.file)
        #expect(retained.fingerprint == cached.fingerprint)
        #expect(retained.lines == cached.lines)
        #expect(repository.diffReadIDs.filter { $0 == files[1].id } == reads)
    }

    @Test func aReadFileThatChanged_raisesTheRefreshBanner() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        await session.detectChanges()
        #expect(!session.hasPendingChanges)

        repository.change(files[1].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "a file on screen but not open changed under the reader")
    }

    @Test func aReadFilesComments_areCheckedAgainstWhatWasRead() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[1].id)
        let line = try #require(session.diff?.lines.first { $0.kind == .added })
        #expect(session.add(line: line, body: "Why?"))
        let comment = try #require(session.comments.first)

        try repository.replace(ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "edited"))
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        let peerLine = try #require(session.diff?.lines.first { $0.kind == .added })
        #expect(session.add(line: peerLine, body: "Unchanged peer"))
        let peer = try #require(session.comments.first { $0.body == "Unchanged peer" })
        #expect(peer.id != comment.id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead {
            session.stackLoader.entries[files[1].id]?.diff?.fingerprint == "edited"
        }

        try #require(session.stackLoader.entries[files[1].id]?.diff?.fingerprint == "edited")
        #expect(session.staleCommentIDs == [comment.id], "written on code that has changed since")
    }

    // MARK: - The change check

    @Test func theChangeCheck_readsTheIndexOnceForEveryFile() async throws {
        let files = Self.files(10)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { files.allSatisfy { !session.stackLoader.needsDiff($0.id) } }
        try #require(Set(session.stackLoader.entries.keys) == Set(files.map(\.id)))
        let indexReads = repository.indexStateReads
        let fingerprints = repository.fingerprintCalls

        await session.detectChanges()

        #expect(repository.indexStateReads == indexReads + 1, "one read for nine files")
        #expect(repository.lastIndexReadPaths == Set(files.dropFirst().map(\.path)))
        #expect(repository.fingerprintCalls == fingerprints, "and none file by file")
        #expect(!session.hasPendingChanges)

        let last = try #require(files.last)
        repository.change(last.id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges)
        #expect(repository.fingerprintCalls == fingerprints)
    }

    @Test func aStagedAndAnUnstagedDiffOfOnePath_areWatchedApart() async throws {
        let staged = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let unstaged = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let other = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        let files = [other, staged, unstaged]
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: other.id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead {
            !session.stackLoader.needsDiff(staged.id) && !session.stackLoader.needsDiff(unstaged.id)
        }

        #expect(session.stackLoader.entries[staged.id] != nil && session.stackLoader.entries[unstaged.id] != nil)
        repository.touch("a.swift")
        await session.detectChanges()
        #expect(!session.hasPendingChanges, "the same content: a touch is no change")

        repository.stage("a.swift")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "staging changes both diffs of the path")

        let loader = session.stackLoader
        let refreshed = try #require(loader.entries[staged.id]?.diff)
        let state = try #require(await loader.takeState(of: staged, scope: .uncommitted))
        loader.remember(refreshed, state: state, serial: loader.beginRead(), scope: .uncommitted)
        #expect(await !loader.hasChangedFiles(excluding: unstaged.id, scope: .uncommitted))
        #expect(await loader.hasChangedFiles(excluding: staged.id, scope: .uncommitted))
    }

    @Test func aHeadThatMovedByItself_raisesTheBanner() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        repository.moveHead()
        await session.detectChanges()

        #expect(session.hasPendingChanges, "`reset --soft`: no file changed, every staged diff did")
    }

    @Test func aChangeDuringAHeldRead_isStillSeen() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        // An edit lands while the diff is being read.
        repository.onRead { file in repository.change(file.id, fingerprint: "edited") }
        loader.hold(true)
        loader.request(Self.requests(files), window: [files[0].id])
        // The read ends held, not published: wait for that, not for a time.
        await pollUntilStackRead { loader.isWaitingToPublish(files[0].id) }
        try #require(loader.isWaitingToPublish(files[0].id))
        repository.onRead(nil)
        loader.hold(false)

        #expect(loader.entries.count == 1)
        #expect(await loader.hasChangedFiles(excluding: nil, scope: .uncommitted), "what it was is taken before the read")
    }

    @Test func aStateThatCannotBeTaken_fallsBackToTheFingerprint() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        repository.failStateReads(true)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }

        await session.detectChanges()
        #expect(!session.hasPendingChanges, "not \"changed\" for good")

        repository.change(files[1].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "nor \"unchanged\" without asking: its diff says so")

        try repository.replace(ReviewDiffFixture.rewritten(files[1], lines: 2, fingerprint: "edited"))
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead {
            session.stackLoader.entries[files[1].id]?.diff?.fingerprint == "edited" && !session.stackLoader.needsDiff(files[1].id)
        }
        await session.detectChanges()
        #expect(!session.hasPendingChanges, "a refresh clears it")
    }

    @Test func anOlderRead_neverReplacesANewerOne() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        // We hold the loader, so the stack's read waits to be published
        // where the test can see it ended, rather than after a guess at how
        // long it takes.
        loader.hold(true)
        loader.request(Self.requests(files), window: [files[0].id])
        await pollUntilStackRead { loader.isWaitingToPublish(files[0].id) }
        try #require(loader.isWaitingToPublish(files[0].id))
        // The file is opened, and its own load is kept before the stack's
        // is published.
        let newer = try ReviewDiffFixture.rewritten(files[0], lines: 2, fingerprint: "newer")
        loader.remember(newer, state: nil, serial: loader.beginRead(), scope: .uncommitted)
        loader.hold(false)

        #expect(loader.entries[files[0].id]?.diff?.fingerprint == "newer", "the stack's read started first")
        let older = try ReviewDiffFixture.rewritten(files[0], lines: 2, fingerprint: "older")
        loader.remember(older, state: nil, serial: 0, scope: .uncommitted)
        #expect(loader.entries[files[0].id]?.diff?.fingerprint == "newer")
    }

    @Test func aRefresh_quietsTheBanner_forAFileOffScreen() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { files.allSatisfy { !session.stackLoader.needsDiff($0.id) } }
        // The reader scrolled back up: the last file is off screen.
        session.loadStacked(window: [files[0].id, files[1].id])

        repository.change(files[2].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges)

        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        await session.detectChanges()
        #expect(!session.hasPendingChanges, "the changed file is read again when the reader comes to it, not compared forever")
        #expect(session.stackLoader.entries[files[2].id] == nil)
        #expect(session.stackLoader.stale.contains(files[1].id), "on screen: drawn until it is read again")
    }

    // MARK: - Find's ticket

    @Test func aFindClosedBeforeItsEstimate_readsNothing() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.concurrency = 1
        let ticket = loader.beginSearch()
        loader.endSearch()

        // The estimate comes back after Esc. A subsequent on-screen read
        // gives the single queue a result past any stale request.
        loader.requestAll(Self.requests(Array(files.prefix(2))), estimates: [:], ticket: ticket)
        let visible = files[2]
        loader.request(Self.requests([visible]), window: Set(files.map(\.id)))
        await pollUntilStackRead { loader.entries[visible.id]?.diff != nil }
        try #require(loader.entries[visible.id]?.diff != nil)

        #expect(loader.searchCoverage == .none)
        #expect(repository.diffReadIDs == [visible.id])

        let earlier = Array(files.prefix(2))
        loader.requestAll(
            Self.requests(earlier),
            estimates: Dictionary(uniqueKeysWithValues: earlier.map { ($0.id, 1) }),
            ticket: loader.beginSearch()
        )
        await pollUntilStackRead { Set(loader.entries.keys) == Set(files.map(\.id)) }
        #expect(Set(loader.entries.keys) == Set(files.map(\.id)))
        #expect(loader.searchCoverage == .everyFile)
        #expect(repository.diffReadIDs == [visible.id] + earlier.map(\.id))
    }

    @Test func aFindOpenedAndClosedAtOnce_inTheSession_readsNothing() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        let opened = files[0]
        let searched = files[1]
        let visible = files[2]
        _ = await session.reload(scope: .uncommitted, selectedFileID: opened.id)
        try #require(session.diff?.file.id == opened.id)
        try #require(repository.diffReadIDs == [opened.id])
        let loader = session.stackLoader
        loader.concurrency = 1

        // Close Find on the same main-actor turn, before its estimate starts.
        let closing = session.loadStackForSearch([searched])
        loader.endSearch()
        try await Self.requireCompletion(of: closing)
        #expect(loader.searchCoverage == .none)

        // Let the same queue read a visible file after the estimate has returned.
        session.loadStacked(window: [visible.id])
        await pollUntilStackRead { loader.entries[visible.id]?.diff != nil }
        try #require(loader.entries[visible.id]?.diff != nil)
        #expect(loader.entries[searched.id] == nil)
        #expect(repository.diffReadIDs == [opened.id, visible.id])

        try await Self.requireCompletion(of: session.loadStackForSearch([searched]))
        #expect(loader.searchCoverage == .everyFile)
        await pollUntilStackRead { loader.entries[searched.id]?.diff != nil }
        #expect(loader.entries[searched.id]?.diff?.file.id == searched.id)
        #expect(repository.diffReadIDs == [opened.id, visible.id, searched.id])
    }

    // MARK: - The fingerprint fallback

    @Test func filesWithoutState_areAskedByFingerprint_aRoundAtATime() async throws {
        let files = Self.files(41)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        repository.failStateReads(true)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { files.allSatisfy { !session.stackLoader.needsDiff($0.id) } }
        try #require(Set(session.stackLoader.entries.keys) == Set(files.map(\.id)))
        // The last of the forty in the order the check walks them.
        let last = try #require(files.dropFirst().map(\.id).max())
        repository.change(last, fingerprint: "edited")

        let baselineReads = repository.fingerprintReadIDs.count
        let expected = files.dropFirst().map(\.id).sorted()
        await session.detectChanges()
        #expect(Array(repository.fingerprintReadIDs.dropFirst(baselineReads)) == Array(expected.prefix(ReviewStackLoader.fingerprintRound)))
        #expect(!session.hasPendingChanges, "not in the first round")

        await session.detectChanges()
        #expect(Array(repository.fingerprintReadIDs.dropFirst(baselineReads)) == expected)
        #expect(session.hasPendingChanges)
    }

    @Test func anIndexThatCannotBeReadAtTheCheck_fallsBackToTheFingerprints() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
        repository.failStateReads(true)

        await session.detectChanges()
        #expect(!session.hasPendingChanges)

        repository.change(files[1].id, fingerprint: "edited")
        await session.detectChanges()
        #expect(session.hasPendingChanges, "its diff says so")
    }

}

extension ReviewStackLoaderTests {

    // MARK: - Holding and in flight

    @Test func aReadWaitingToBePublished_isNotAskedForAgain() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.concurrency = 1
        loader.publishInterval = .seconds(60)
        let window = Set(files.map(\.id))
        let firstTwo = Self.requests(Array(files.prefix(2)))

        loader.request(firstTwo, window: window)
        await pollUntilStackRead { loader.isWaitingToPublish(files[1].id) }
        try #require(loader.entries[files[0].id]?.diff != nil && loader.isWaitingToPublish(files[1].id))

        loader.request(firstTwo, window: window)
        loader.request(Self.requests([files[2]]), window: window)
        // Once the later queued file finishes, the single reader must
        // already have considered any duplicate queued before it.
        await pollUntilStackRead { loader.isWaitingToPublish(files[2].id) }
        try #require(loader.isWaitingToPublish(files[2].id))
        #expect(repository.diffReadIDs == files.map(\.id))
    }

    @Test func aPublishingHold_keepsCompletedDiffsOffScreen() async throws {
        let files = Self.files(1)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.hold(true)
        let revision = loader.revision

        loader.request(Self.requests(files), window: [files[0].id])
        await pollUntilStackRead { loader.isWaitingToPublish(files[0].id) }
        try #require(loader.isWaitingToPublish(files[0].id))
        #expect(loader.entries.isEmpty)
        #expect(loader.revision == revision, "the rows under the composer stay as they are")

        loader.hold(false)
        #expect(loader.entries[files[0].id]?.diff?.fingerprint == files[0].path)
        #expect(!loader.isWaitingToPublish(files[0].id))
    }

    @Test func find_keepsItsCoverageAcrossARefresh_andAsksForTheNewList() async throws {
        let files = Self.files(4)
        let initial = Array(files.prefix(3))
        let updated = Array(files.suffix(3))
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let loader = ReviewStackLoader(git: repository, root: root)
        loader.retire(.anotherScope, listed: initial)
        loader.requestAll(Self.requests(initial), estimates: [:], ticket: loader.beginSearch())
        await pollUntilStackRead { loader.entries.count == initial.count }
        try #require(Set(loader.entries.keys) == Set(initial.map(\.id)))
        let readsBefore = repository.diffReadIDs.count

        loader.retire(.sameScope, listed: updated)
        #expect(loader.searchCoverage == .everyFile, "a same-scope refresh preserves the active search coverage")
        // As the review asks when the list is read again with Find open.
        loader.requestAll(Self.requests(updated), estimates: [:], ticket: loader.beginSearch())
        await pollUntilStackRead { updated.allSatisfy { !loader.needsDiff($0.id) } }

        #expect(Set(loader.entries.keys) == Set(updated.map(\.id)))
        #expect(repository.diffReadIDs.dropFirst(readsBefore).sorted() == updated.map(\.id).sorted())
    }

    @Test func theGutter_keepsTheWidestTheRangeNeeded() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        // The version the diff shows (its new side is "new 0", "new 1"),
        // and much more after it.
        repository.setSource(files[0].id, text: ["new 0", "new 1"] + (2..<12000).map { "line \($0)" })
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        #expect(session.stackLoader.highestLine == 12000, "the open file's whole content")

        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
        let generation = try #require(session.openFromStack(files[1]))
        await session.readSource(of: files[1], generation: generation)

        #expect(session.stackLoader.highestLine == 12000, "a short file does not narrow it")
    }

    @Test func contentThatIsNotTheDiffsVersion_isNotUnfolded() async throws {
        let files = Self.files(2)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: files[0].id)
        session.loadStacked(window: files.map(\.id))
        await pollUntilStackRead { !session.stackLoader.needsDiff(files[1].id) }
        // Newer than the diff, or the file as a clean filter does not show it.
        repository.setSource(files[1].id, lines: 4)

        let generation = try #require(session.openFromStack(files[1]))
        await session.readSource(of: files[1], generation: generation)

        #expect(session.source.isEmpty, "nothing of another version between the hunks")
        #expect(!session.hasPendingChanges, "whether the file changed is its fingerprint's to say")
    }

    // MARK: - Read marks against Git

    /// An untracked file marked in the single-file read keeps its mark when
    /// the stack reads it again, unchanged; only new content takes it off.
    /// The two reads are one fingerprint, the poll's included.
    @Test(.tags(.smoke)) func anUntrackedFilesMark_comesOffOnlyWhenItsContentChanges() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let manual = repo.url.appendingPathComponent("manual.swift")
        try Data("let handEdited = true\n".utf8).write(to: manual)
        try repo.write("let other = 1\n", to: "other.swift")
        let session = ReviewSession(
            writer: ReviewDraftWriter(root: repo.url, drafts: RecordingReviewDraftStore()),
            git: LiveReviewRepository()
        )
        let manualID = "untracked:manual.swift"
        let otherID = "untracked:other.swift"

        _ = await session.reload(scope: .uncommitted, selectedFileID: manualID)
        #expect(session.diff?.file.id == manualID)
        session.setViewed(manualID, true)
        let marked = try #require(session.viewed[manualID]?.fingerprint)
        let file = try #require(session.files.first { $0.id == manualID })
        #expect(try await LiveReviewRepository().fingerprint(file, root: repo.url, scope: .uncommitted) == marked)

        _ = await session.reload(scope: .uncommitted, selectedFileID: otherID)
        session.loadStacked(window: [manualID, otherID])
        await pollUntilStackRead { !session.stackLoader.needsDiff(manualID) }

        // Apart from the fingerprint, so a read that never ended does not read
        // as a read that failed.
        let entry = try #require(session.stackLoader.entries[manualID], "the read ended")
        #expect(entry.diff?.fingerprint == marked, "the stack reads what the open file read")
        #expect(session.viewed[manualID] != nil, "unchanged, so still read")

        try Data("let handEdited = true\nlet edited = 2\n".utf8).write(to: manual)
        _ = await session.reload(scope: .uncommitted, selectedFileID: otherID)
        session.loadStacked(window: [manualID, otherID])
        await pollUntilStackRead {
            session.stackLoader.entries[manualID]?.diff != nil && !session.stackLoader.needsDiff(manualID)
        }

        let changed = try #require(session.stackLoader.entries[manualID]?.diff)
        #expect(changed.fingerprint != marked)
        #expect(session.viewed[manualID] == nil, "new content to read")
    }

    // MARK: - The viewed line

    @Test func fileMarks_makeTheBandPrimary_beforeTheSeparateLineAdvance() async throws {
        let files = Self.files(3)
        let repository = try StackReviewRepository(files: files, diffs: Self.diffs(files))
        let session = session(repository)
        _ = await session.reload(scope: .uncommitted, selectedFileID: nil)
        let turns = try [5, 6, 7].map { number in
            try TurnSummaryFixture.turn(
                "T\(number)",
                changes: TurnSummaryFixture.changedFiles,
                number: number,
                endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", number), root: "/repo"),
                extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: "/repo"))
            )
        }
        // The viewed line, under T5.
        let lines = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
        lines.markViewed(through: turns[0], source: .decisionBar)
        let conversation = turns[0].conversation
        let line = lines.line(of: conversation)
        let context = ReviewTabModel.Context(turns: turns, isViewed: lines.isViewed, branchBase: "main")
        let tab = try ReviewTabModel.open(.unviewedTurns, context, root: "/repo", agentPaneID: UUID(), current: nil).get()

        try #require(Set(session.files.map(\.id)) == Set(files.map(\.id)))
        for file in session.files {
            session.setViewed(file.id, true)
        }

        #expect(Set(session.viewed.keys) == Set(files.map(\.id)))
        let status = ReviewTabModel.bandStatus(tab.selection, fileIDs: session.files.map(\.id), viewed: Set(session.viewed.keys))
        #expect(status == .allFilesViewed, "the band's button turns primary")
        #expect(lines.line(of: conversation) == line, "the line is where it was")
        #expect(!lines.isViewed(turns[1]))
        #expect(ReviewTabModel.markViewed(tab, context) == .throughTurn(ReviewTabTurn(id: TurnID("T7"), number: 7)))

        // Advance the separate viewed line through the proposed turn.
        lines.markViewed(through: turns[2], source: .decisionBar)
        #expect(ReviewTabModel.markViewed(tab, context) == nil)
    }
}
