// ReviewScopeDraftTests.swift
// Weir — comments and read marks kept by the scope they belong to.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Review drafts by scope")
struct ReviewScopeDraftTests {
    /// One per test: the draft writer keeps its generations by root, and a
    /// test running beside another must not take its saves.
    private let root = URL(fileURLWithPath: "/tmp/weir-review-scopes-\(UUID().uuidString)")
    private static let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
    /// The layer of the per-pane "This turn" scope earlier builds had: only
    /// a legacy comment a saved draft holds is on it now.
    private static let turnFile = ReviewFile(path: "a.swift", layer: .turn, status: .modified)
    private static let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)

    private static func legacy(_ body: String, fingerprint: String = "f1", code: String = "new") -> ReviewComment {
        ReviewComment(
            file: turnFile,
            fingerprint: fingerprint,
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 1),
            code: code,
            body: body
        )
    }

    private func store(
        _ repository: FakeReviewRepository,
        drafts: RecordingReviewDraftStore = RecordingReviewDraftStore()
    ) -> ReviewSession {
        ReviewSession(root: root, git: repository, drafts: drafts)
    }

    @Test func aNewComment_belongsToTheScopeOnScreen() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.file)
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        let workingLine = try #require(store.diff?.lines.first { $0.isCommentable })
        try #require(store.add(lines: [workingLine], side: nil, body: "Working copy"))
        let working = try #require(store.shownComments.first)

        let range = try TurnSummaryFixture.range()
        repository.files = [Self.rangeFile]
        repository.diffs[Self.rangeFile.id] = try ReviewDiffFixture.diff(of: Self.rangeFile, fingerprint: "range")
        _ = await store.reload(scope: .turns(range), selectedFileID: Self.rangeFile.id)
        #expect(store.shownComments.isEmpty)
        let rangeLine = try #require(store.diff?.lines.first { $0.isCommentable })
        try #require(store.add(lines: [rangeLine], side: nil, body: "Fixed range"))
        let fixed = try #require(store.shownComments.first)

        #expect(working.id != fixed.id)
        #expect(working.scopeIDs == ["uncommitted"])
        #expect(fixed.scopeIDs == [range.scopeID])
        #expect(store.shownComments == [fixed])
        #expect(store.comments(inScope: "uncommitted") == [working])
        let saved = try #require(try drafts.load(root: root))
        #expect(saved.comments == [working, fixed])
        #expect(saved.ranges == [range])
    }

    @Test func legacyComment_movesOnlyByExplicitActionAfterRevalidation() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        // The worktree's a.swift today.
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let gone = Self.legacy("about code the range does not have", code: "gone")
        let current = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [gone, current]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()

        // Loading, listing, and opening the range move nothing.
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        #expect(store.legacyComments.count == 2)
        #expect(store.comments(inScope: range.scopeID).isEmpty)

        // Its code is not in the range: refused, and left where it was.
        await #expect(throws: ReviewError.legacyCodeNotFound) { try await store.moveLegacyComment(gone.id, to: .turns(range)) }
        #expect(store.legacyComments.count == 2)

        try await store.moveLegacyComment(current.id, to: .turns(range))

        let moved = try #require(store.comments(inScope: range.scopeID).first)
        #expect(moved.id == current.id)
        #expect(moved.file == rangeFile, "re-anchored on the range's file")
        #expect(moved.fingerprint == "range", "with the range's fingerprint, which inserts check from now on")
        #expect(moved.anchor.newLine == 1)
        #expect(store.legacyComments.map(\.id) == [gone.id])
        let saved = try #require(try drafts.load(root: root))
        #expect(saved.comments.map(\.id) == [current.id])
        #expect(saved.legacy?.map(\.id) == [gone.id])
        #expect(saved.ranges == [range], "the range a comment belongs to is kept with it")
    }

    @Test func aRangesComment_movesOnlyIfItsCodeIsStillInTheFile() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        // A later edit replaced the line the comment quotes.
        repository.sources[Self.file.id] = ["newer"]
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        await #expect(throws: ReviewError.legacyCodeMoved) { try await store.moveLegacyComment(comment.id, to: .turns(range)) }

        #expect(store.legacyComments.count == 1)
    }

    @Test(arguments: [false, true])
    func aLegacyCommentWhoseFileIsNotInTheScope_saysSo(_ hasOtherFile: Bool) async throws {
        let repository = FakeReviewRepository()
        let other = ReviewFile(path: "b.swift", layer: .turns, status: .modified)
        if hasOtherFile {
            repository.files = [other]
            repository.diffs[other.id] = try ReviewDiffFixture.diff(of: other, fingerprint: "range")
        }
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about a.swift")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        await #expect(throws: ReviewError.legacyFileNotInScope) { try await store.moveLegacyComment(comment.id, to: .turns(range)) }

        #expect(store.legacyComments == [comment])
        #expect(store.shownComments.isEmpty)
        #expect(try drafts.load(root: root)?.legacy == [comment])
    }

    @Test func aRangesComment_isInsertedOnlyWhileItsRangeAndTheCurrentCodeAgree() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(store.add(line: line, body: "Why?"))

        let comment = try #require(store.shownComments.first)
        #expect(try await store.insertable([comment]) == [comment])

        // The worktree moved on: the range's diff still matches, the code does not.
        repository.sources[Self.file.id] = ["something else"]
        await #expect(throws: ReviewError.changed) { try await store.insertable([comment]) }
        #expect(store.staleCommentIDs == [comment.id])
        #expect(store.shownComments == [comment])
        #expect(try drafts.load(root: root)?.comments == [comment])
    }

    enum FileChange: Sendable {
        case unchanged, stats, fingerprint
    }

    @Test(arguments: [FileChange.unchanged, .stats, .fingerprint])
    func addingTheNextTurn_bringsTheRangesCommentsAndStillValidMarks(_ change: FileChange) async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.stats[rangeFile.id] = ReviewFileStat(added: 1, removed: 1)
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        try #require(store.add(line: line, body: "Why?"))
        let comment = try #require(store.shownComments.first)
        store.setViewed(rangeFile.id, true)
        let mark = try #require(store.viewed[rangeFile.id])
        #expect(mark.fingerprint == "range")
        let extended = try #require(try range.extended(with: [TurnSummaryFixture.recordedTurn("T2", number: 2)]))

        try #require(store.carryRange(to: extended))
        #expect(store.carryRange(to: extended), "repeating the carry keeps one comment")
        #expect(store.viewedByScope[extended.scopeID] == [rangeFile.id: mark])
        if change == .stats {
            repository.stats[rangeFile.id] = ReviewFileStat(added: 2, removed: 1)
        } else if change == .fingerprint {
            repository.diffsByScope[extended.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "changed")]
        }
        _ = await store.reload(scope: .turns(extended), selectedFileID: rangeFile.id)
        store.rememberOpenFile(rangeFile.id)
        await store.flushNavigationSave()

        #expect(store.scope == .turns(extended), "the store reads the longer range")
        #expect(extended.numbers == 1...2)
        #expect(extended.scopeID != range.scopeID)
        var carried = comment
        carried.scopeIDs = [range.scopeID, extended.scopeID]
        #expect(store.shownComments == [carried])
        let kept = change == .unchanged ? [rangeFile.id: mark] : [:]
        #expect(store.viewed == kept)
        #expect(store.viewedByScope[range.scopeID] == [rangeFile.id: mark])
        let saved = try #require(try drafts.load(root: root))
        #expect(saved.comments == [carried])
        #expect(saved.ranges?.sorted { $0.scopeID < $1.scopeID } == [range, extended].sorted { $0.scopeID < $1.scopeID })
        #expect(saved.viewed[range.scopeID] == [rangeFile.id: mark])
        #expect((saved.viewed[extended.scopeID] ?? [:]) == kept)
    }

    @Test func aCommentInTwoRanges_isInsertedWhileTheRangeItQuotesStillHasItsDiff() async throws {
        // Written in T1's range, then carried into T1–T2 by "Add to range";
        // T2 changed the same file, so the longer range's diff differs.
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.sources[Self.file.id] = ["new"]
        let first = try TurnSummaryFixture.range()
        let longer = try #require(try first.extended(with: [TurnSummaryFixture.recordedTurn("T2", number: 2)]))
        repository.diffsByScope[first.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "first")]
        repository.diffsByScope[longer.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "longer")]
        let store = self.store(repository)
        _ = await store.reload(scope: .turns(first), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        store.add(line: line, body: "Why?")
        #expect(store.carryRange(to: longer))
        _ = await store.reload(scope: .turns(longer), selectedFileID: store.diff?.file.id)

        #expect(try await store.insertable(store.comments).count == 1)
        // The range it was written in vouches whichever range is tried first,
        // so losing the other one changes nothing.
        repository.missingRangeScopeIDs = [longer.scopeID]
        #expect(try await store.insertable(store.comments).count == 1)
        // The longer range's diff of the file is not the one the comment
        // quotes, so it cannot vouch alone: the comment is held back as stale
        // rather than failing the insert.
        repository.missingRangeScopeIDs = [first.scopeID]
        do {
            _ = try await store.insertable(store.comments)
            Issue.record("nothing is left to insert")
        } catch ReviewError.changed {
            #expect(store.staleCommentIDs == Set(store.comments.map(\.id)))
        }
    }

    @Test func openingOneRange_doesNotStaleAnotherRangesComment_onTheSamePath() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        let first = try TurnSummaryFixture.range()
        let second = try TurnSummaryFixture.range("T2", number: 2)
        repository.diffsByScope[first.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "first")]
        repository.diffsByScope[second.scopeID] = try [rangeFile.id: ReviewDiffFixture.diff(of: rangeFile, fingerprint: "second")]
        let store = self.store(repository)
        _ = await store.reload(scope: .turns(first), selectedFileID: rangeFile.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        try #require(store.add(line: line, body: "About the first range"))
        let comment = try #require(store.shownComments.first)
        #expect(comment.fingerprint == "first")

        _ = await store.reload(scope: .turns(second), selectedFileID: rangeFile.id)

        #expect(store.scope == .turns(second))
        #expect(store.diff?.fingerprint == "second")
        #expect(store.shownComments.isEmpty)
        #expect(store.staleCommentIDs.isEmpty)

        _ = await store.reload(scope: .turns(first), selectedFileID: rangeFile.id)
        #expect(store.diff?.fingerprint == "first")
        #expect(store.shownComments == [comment])
        #expect(store.staleCommentIDs.isEmpty)
    }

    @Test func aClassicTurnComment_movesIntoARange_throughTheStore() async throws {
        // Written in the per-pane "This turn" scope earlier builds had, which
        // no build offers now.
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        var classic = Self.legacy("written in This turn")
        classic.scopeIDs = ["turn:abc"]
        try drafts.save(ReviewDraft(comments: [classic]), root: root)
        let store = self.store(repository, drafts: drafts)
        #expect(store.legacyComments.map(\.id) == [classic.id])
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        try await store.moveLegacyComment(classic.id, to: .turns(range))

        #expect(store.legacyComments.isEmpty)
        let saved = try #require(try drafts.load(root: root))
        let moved = try #require(saved.comments.first)
        #expect(moved.id == classic.id)
        #expect(moved.body == classic.body)
        #expect(moved.file == rangeFile)
        #expect(moved.scopeIDs == [range.scopeID])
        #expect(moved.fingerprint == "range")
        #expect(saved.legacy == nil)
        #expect(saved.ranges == [range])
        let reopened = self.store(repository, drafts: drafts)
        _ = await reopened.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        #expect(reopened.shownComments == [moved])
        #expect(reopened.legacyComments.isEmpty)
    }

    @Test func aPathTheTargetListsTwice_whereBothWouldTakeTheComment_isRefused() async throws {
        let repository = FakeReviewRepository()
        let staged = ReviewFile(path: "a.swift", layer: .staged, status: .modified)
        let unstaged = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        repository.files = [staged, unstaged]
        repository.diffs[staged.id] = try ReviewDiffFixture.diff(of: staged, fingerprint: "s")
        repository.diffs[unstaged.id] = try ReviewDiffFixture.diff(of: unstaged, fingerprint: "u")
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("which one?")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)

        await #expect(throws: ReviewError.legacyCodeRepeated) { try await store.moveLegacyComment(comment.id, to: .uncommitted) }

        #expect(store.legacyComments.count == 1)
    }

    @Test func readMarks_areKeptByScopeEvenWhenRangesShareAFileID() async throws {
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        repository.stats[Self.file.id] = ReviewFileStat(added: 2, removed: 1)
        let store = self.store(repository)
        await store.refreshAsTheAppDoes()
        store.setViewed(Self.file.id, true)
        let workingMark = try #require(store.viewed[Self.file.id])

        repository.files = [Self.rangeFile]
        repository.stats[Self.rangeFile.id] = ReviewFileStat(added: 1, removed: 1)
        let first = try ReviewScope.turns(TurnSummaryFixture.range())
        let next = try ReviewScope.turns(TurnSummaryFixture.range("T2", number: 2))
        _ = await store.reload(scope: first, selectedFileID: nil)
        #expect(store.viewed.isEmpty)
        store.setViewed(Self.rangeFile.id, true)
        let rangeMark = try #require(store.viewed[Self.rangeFile.id])

        _ = await store.reload(scope: next, selectedFileID: nil)
        #expect(store.viewed.isEmpty)
        _ = await store.reload(scope: first, selectedFileID: nil)
        #expect(store.viewed == [Self.rangeFile.id: rangeMark])

        repository.files = [Self.file]
        _ = await store.reload(scope: .uncommitted, selectedFileID: nil)
        #expect(store.viewed == [Self.file.id: workingMark])
    }

    @Test func theMarksOfAScopeNoLongerOpen_goAfterTwoWeeks() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let twoWeeks: TimeInterval = 14 * 24 * 60 * 60
        let old = ReviewViewMark(added: 1, removed: 0, markedAt: now.addingTimeInterval(-twoWeeks - 1))
        let cutoff = ReviewViewMark(added: 1, removed: 0, markedAt: now.addingTimeInterval(-twoWeeks))
        let recent = ReviewViewMark(added: 1, removed: 0, markedAt: now.addingTimeInterval(-60))
        let undated = ReviewViewMark(added: 1, removed: 0)
        let marks = [
            "turn:old": ["turn:a": old, "turn:b": recent, "turn:c": undated],
            "turns:closed": ["turns:a": old, "turns:b": cutoff],
            "turns:open": ["turns:a": old],
            "uncommitted": ["unstaged:a": old],
            "branch:main": ["branch:a": old]
        ]

        let kept = ReviewDraftWriter.pruned(marks, open: ["turns:open"], now: now)

        #expect(kept == [
            "turn:old": ["turn:b": recent, "turn:c": undated],
            "turns:closed": ["turns:b": cutoff],
            "turns:open": ["turns:a": old],
            "uncommitted": ["unstaged:a": old],
            "branch:main": ["branch:a": old]
        ])
    }

    @Test func theOpenFileOfARangeNoLongerInUse_isNotKept() async throws {
        let repository = FakeReviewRepository()
        repository.files = [Self.rangeFile]
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        let first = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(first), selectedFileID: nil)
        store.rememberOpenFile(Self.rangeFile.id)
        await store.flushNavigationSave()
        #expect(try drafts.load(root: root)?.lastFileID == [first.scopeID: Self.rangeFile.id])

        let next = try TurnSummaryFixture.range("T2", number: 2)
        _ = await store.reload(scope: .turns(next), selectedFileID: nil)
        store.rememberOpenFile(Self.rangeFile.id)
        await store.flushNavigationSave()

        #expect(try drafts.load(root: root)?.lastFileID == [next.scopeID: Self.rangeFile.id])
    }

    @Test func aDraftThatCannotBeSaved_keepsTheReviewInMemory_andSaysSo() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.file)
        let drafts = RecordingReviewDraftStore()
        let kept = Self.legacy("Migrated comment")
        drafts.loadError = ReviewDraftLoadError.migratedWithoutCopy(ReviewDraft(legacy: [kept]))
        let store = ReviewSession(root: root, git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        await store.load(Self.file)

        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        #expect(store.add(line: line, body: "Why?"))
        store.rememberOpenFile(Self.file.id)
        await store.flushNavigationSave()

        #expect(store.legacyComments == [kept])
        #expect(store.shownComments.map(\.body) == ["Why?"])
        #expect(store.lastFileID == Self.file.id)
        #expect(drafts.saves == 0, "nothing written over the only copy")
        #expect(store.isSavingSuspended)
        #expect(store.errorMessage == DisplayText(error: ReviewError.draftNotSaved))
    }

    @Test func aDraftNeitherReadNorMovedAside_startsEmpty_andSaysBoth() async {
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        let drafts = RecordingReviewDraftStore()
        drafts.loadError = ReviewDraftLoadError.keptInPlace
        let store = ReviewSession(root: root, git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()

        store.setViewed(Self.file.id, true)

        #expect(store.comments.isEmpty)
        #expect(store.isSavingSuspended)
        #expect(store.errorMessage == DisplayText(error: ReviewError.draftUnreadableNotSaved))
        #expect(drafts.saves == 0)
    }

    @Test func aDraftChangedWhileGitChecked_movesNothing() async throws {
        let repository = try FakeReviewRepository.oneFile(Self.rangeFile)
        // The quoted code is still where it was, so only the edit stops the move.
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let moving = Self.legacy("to move")
        let other = Self.legacy("deleted meanwhile")
        try drafts.save(ReviewDraft(legacy: [moving, other]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try ReviewScope.turns(TurnSummaryFixture.range())
        _ = await store.reload(scope: range, selectedFileID: nil)
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate

        async let move: Void = store.moveLegacyComment(moving.id, to: range)
        defer { gate.open(with: []) }
        try await gate.waitUntilRequested()
        store.remove(other.id)
        gate.open(with: [Self.rangeFile])

        do {
            try await move
            Issue.record("the move went ahead over an edit")
        } catch ReviewError.checkInterrupted {
            // Expected: the reader edited the draft while Git ran.
        }
        #expect(store.legacyComments == [moving])
        #expect(store.shownComments.isEmpty)
        let saved = try #require(try drafts.load(root: root))
        #expect(saved.comments.isEmpty)
        #expect(saved.legacy == [moving])
    }

    private enum LegacyMoveNavigation: CaseIterable {
        case movesAway
        case returnsBeforeResult
        case returnsBeforeError
        case refreshesSameScope
    }

    @Test(arguments: LegacyMoveNavigation.allCases)
    private func aPendingLegacyMove_isCanceledByAScopeChange_andSurvivesASameScopeRefresh(
        _ navigation: LegacyMoveNavigation
    ) async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        let workingFile = FakeReviewRepository.unstagedFile
        repository.diffs[workingFile.id] = try ReviewDiffFixture.diff(of: workingFile, fingerprint: "worktree")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = ReviewSession(
            writer: ReviewDraftWriter(root: root, drafts: drafts),
            git: repository
        )
        let range = try TurnSummaryFixture.range()
        let originalScope = ReviewScope.turns(range)
        try #require(await store.reload(scope: originalScope, selectedFileID: rangeFile.id) == .applied(selectedFileID: rangeFile.id))
        let gate = Gate<[ReviewFile]>()
        repository.nextFilesGate = gate

        async let move: Void = store.moveLegacyComment(comment.id, to: originalScope)
        defer { gate.open(with: []) }
        try await gate.waitUntilRequested()
        if navigation != .refreshesSameScope {
            repository.files = [workingFile]
            try #require(await store.reload(scope: .uncommitted, selectedFileID: nil) == .applied(selectedFileID: workingFile.id))
        }
        if navigation != .movesAway {
            repository.files = [rangeFile]
            try #require(await store.reload(scope: originalScope, selectedFileID: rangeFile.id) == .applied(selectedFileID: rangeFile.id))
        }
        #expect(store.scope == (navigation == .movesAway ? .uncommitted : originalScope))
        gate.open(with: navigation == .returnsBeforeError ? [] : [rangeFile])

        if navigation == .refreshesSameScope {
            try await move
            let moved = try #require(store.comments(inScope: range.scopeID).first)
            #expect(moved.id == comment.id)
            #expect(moved.body == comment.body)
            #expect(moved.file == rangeFile)
            #expect(moved.fingerprint == "range")
            #expect(store.legacyComments.isEmpty)
            let saved = try #require(try drafts.load(root: root))
            #expect(saved.comments == [moved])
            #expect(saved.legacy == nil)
            return
        }

        do {
            try await move
            Issue.record("A scope change should have canceled the pending move.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(store.legacyComments == [comment])
        #expect(store.comments(inScope: range.scopeID).isEmpty)
        let saved = try #require(try drafts.load(root: root))
        #expect(saved.comments.isEmpty)
        #expect(saved.legacy == [comment])
        #expect(store.errorMessage == nil, "nothing for the banner: the reader moved on")
    }

    @Test func aCommentMovedIntoADiffNewerThanTheOneOnScreen_isMarkedStale() async throws {
        let repository = FakeReviewRepository()
        let rangeFile = ReviewFile(path: "a.swift", layer: .turns, status: .modified)
        repository.files = [rangeFile]
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "range")
        repository.sources[Self.file.id] = ["new"]
        let drafts = RecordingReviewDraftStore()
        let comment = Self.legacy("about this code")
        try drafts.save(ReviewDraft(legacy: [comment]), root: root)
        let store = self.store(repository, drafts: drafts)
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: rangeFile.id)
        // The file changed again after the review read it.
        repository.diffs[rangeFile.id] = try ReviewDiffFixture.diff(of: rangeFile, fingerprint: "later")

        try await store.moveLegacyComment(comment.id, to: .turns(range))

        let moved = try #require(store.comments(inScope: range.scopeID).first)
        #expect(moved.fingerprint == "later")
        #expect(store.staleCommentIDs.contains(moved.id), "drawn against a diff of another moment")
    }

    @Test func theFileLastOpen_isRememberedByScope() async throws {
        let repository = FakeReviewRepository()
        repository.files = [Self.file]
        let drafts = RecordingReviewDraftStore()
        let store = self.store(repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        store.rememberOpenFile(Self.file.id)
        await store.flushNavigationSave()

        repository.files = [Self.rangeFile]
        let range = try TurnSummaryFixture.range()
        _ = await store.reload(scope: .turns(range), selectedFileID: nil)

        #expect(store.lastFileID == nil)
        store.rememberOpenFile(Self.rangeFile.id)
        await store.flushNavigationSave()
        #expect(try drafts.load(root: root)?.lastFileID == ["uncommitted": Self.file.id, range.scopeID: Self.rangeFile.id])

        repository.files = [Self.file]
        _ = await store.reload(scope: .uncommitted, selectedFileID: nil)
        #expect(store.lastFileID == Self.file.id)
    }
}
