// ReviewContinuityTests.swift
// Weir — where the reader was survives closing review and opening it again: the file that was open, saved with the
// comments and never over an edit.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ReviewContinuityTests {
    /// Reopening review returns to the file that was being read, read from
    /// the list the new session is given. The remembered id is a hint: it
    /// only answers while the list still carries the file.
    @Test func reopeningTheReview_resumesTheFileThatWasOpen_untilItLeavesTheList() async {
        let root = URL(fileURLWithPath: "/tmp/weir-review-resume")
        let drafts = RecordingReviewDraftStore()
        let repository = FakeReviewRepository()
        let first = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let second = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        repository.files = [first, second]
        repository.diffs = [
            first.id: ReviewDiff(file: first, fingerprint: "a", lines: []),
            second.id: ReviewDiff(file: second, fingerprint: "b", lines: [])
        ]

        let store = ReviewSession(root: root, git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        // Nothing has been read yet, so there is nothing to resume to.
        #expect(store.resumeFile(in: store.scope, among: store.files) == nil)
        store.rememberOpenFile(second.id)
        await store.flushNavigationSave()
        #expect(store.errorMessage == nil)

        let reopened = ReviewSession(root: root, git: repository, drafts: drafts)
        #expect(await reopened.refreshAsTheAppDoes() == .applied(selectedFileID: second.id))
        #expect(reopened.resumeFile(in: reopened.scope, among: reopened.files) == second)
        #expect(reopened.diff?.file == second)

        // The worktree moves between readings. A remembered file that is no
        // longer changed hands the choice back to the first one.
        repository.files = [first]
        let moved = ReviewSession(root: root, git: repository, drafts: drafts)
        await moved.refreshAsTheAppDoes()
        #expect(moved.lastFileID == second.id)
        #expect(moved.resumeFile(in: moved.scope, among: moved.files) == nil)
    }

    /// The file remembered for one scope is not resumed in another, though it
    /// is in both lists.
    @Test func resumeFile_rememberedForOneScope_isNotResumedInAnother() async {
        let drafts = RecordingReviewDraftStore()
        let repository = FakeReviewRepository()
        let first = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let second = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        repository.files = [first, second]
        repository.diffs = [
            first.id: ReviewDiff(file: first, fingerprint: "a", lines: []),
            second.id: ReviewDiff(file: second, fingerprint: "b", lines: [])
        ]
        let store = ReviewSession(root: URL(fileURLWithPath: "/tmp/weir-review-resume-scope"), git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        store.rememberOpenFile(second.id)

        #expect(store.resumeFile(in: .uncommitted, among: [first, second]) == second)
        #expect(store.resumeFile(in: .branch(base: "main"), among: [first, second]) == nil)
    }

    @Test func aCommentAndTheFileOpenWhenItWasWritten_areSavedTogether() async throws {
        let repository = try FakeReviewRepository.oneFile()
        let file = FakeReviewRepository.unstagedFile
        let drafts = RecordingReviewDraftStore()
        let store = ReviewSession(root: URL(fileURLWithPath: "/tmp/weir-review-root"), git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        await store.load(file)
        store.rememberOpenFile(file.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        #expect(store.add(line: line, body: "Keep this comment."))
        await store.flushNavigationSave()
        let draft = try drafts.load(root: store.root)
        let saved = try #require(draft)
        #expect(saved.comments.count == 1)
        #expect(saved.lastFileID["uncommitted"] == file.id)
    }

    @Test func navigationQueuedAfterAnEditCannotOverwriteIt() async throws {
        let root = URL(fileURLWithPath: "/tmp/review-write-order")
        let drafts = RecordingReviewDraftStore()
        let writer = ReviewDraftWriteCoordinator.shared
        let generation = writer.beginNavigation(for: root)
        let committed = ReviewDraft(lastFileID: ["uncommitted": "newer"])
        try writer.save(committed, root: root, storage: drafts)
        let saved = try await writer.saveNavigation(
            ReviewDraft(lastFileID: ["uncommitted": "older"]),
            root: root,
            storage: drafts,
            generation: generation
        )
        #expect(!saved)
        let restored = try drafts.load(root: root)
        #expect(restored?.lastFileID["uncommitted"] == "newer")
    }

    @Test func deletingADraftCancelsDelayedNavigation() async throws {
        let repository = try FakeReviewRepository.oneFile()
        try await withTempDir { @Sendable directory in
            let store = await ReviewSession(root: directory, git: repository, drafts: FileReviewDraftStore(directory: directory))
            let draft = FileReviewDraftStore.url(root: directory, directory: directory)
            // Left alone, the delayed save writes the draft.
            await store.rememberOpenFile(FakeReviewRepository.unstagedFile.id)
            await store.flushNavigationSave()
            #expect(FileManager.default.fileExists(atPath: draft.path))

            await store.rememberOpenFile("another file")
            ReviewDraftWriter.removeDraft(root: directory, directory: directory)
            await store.flushNavigationSave()
            #expect(!FileManager.default.fileExists(atPath: draft.path))
        }
    }

    /// Quitting writes the file a review had open while its save still
    /// waits on the timer, which would not run again. It is written for a
    /// review already closed too, whose writer the waiting save holds.
    @Test func quitting_writesTheOpenFileStillWaitingOnItsTimer() {
        let root = URL(fileURLWithPath: "/tmp/weir-review-quit")
        let drafts = RecordingReviewDraftStore()
        let pool = ReviewDraftWriterPool(drafts: drafts, git: FakeReviewRepository())
        var writer: ReviewDraftWriter? = pool.writer(root: root)
        let scopeID = ReviewScope.uncommitted.scopeID
        writer?.rememberOpenFile("b.swift", in: scopeID) { _ in }
        writer = nil
        #expect(drafts.saves == 0, "still waiting on its timer")

        pool.flushNavigationSaves()

        #expect(drafts.saves == 1)
        #expect(ReviewDraftWriter(root: root, drafts: drafts).lastFileIDs[scopeID] == "b.swift")
    }

    /// A worktree deleted while its navigation save waits gets no draft
    /// back at quit: a new worktree at the same path would inherit it.
    @Test func quitting_afterTheWorktreeWasDeleted_writesNoDraft() throws {
        try withTempDir { dir in
            let root = URL(fileURLWithPath: "/tmp/weir-review-quit-deleted")
            let drafts = RecordingReviewDraftStore()
            let pool = ReviewDraftWriterPool(drafts: drafts, git: FakeReviewRepository())
            let writer = pool.writer(root: root)
            writer.rememberOpenFile("b.swift", in: ReviewScope.uncommitted.scopeID) { _ in }

            ReviewDraftWriter.removeDraft(root: root, directory: dir)
            pool.flushNavigationSaves()

            #expect(drafts.saves == 0)
        }
    }

    /// A navigation save that failed is tried once more at quit.
    @Test func quitting_triesAFailedNavigationSaveAgain() async {
        let root = URL(fileURLWithPath: "/tmp/weir-review-quit-retry")
        let drafts = RecordingReviewDraftStore()
        let pool = ReviewDraftWriterPool(drafts: drafts, git: FakeReviewRepository())
        let writer = pool.writer(root: root)
        drafts.isFailing = true
        writer.rememberOpenFile("b.swift", in: ReviewScope.uncommitted.scopeID) { _ in }
        await writer.flushNavigationSave()
        drafts.isFailing = false

        pool.flushNavigationSaves()

        #expect(ReviewDraftWriter(root: root, drafts: drafts).lastFileIDs[ReviewScope.uncommitted.scopeID] == "b.swift")
    }

    /// Nothing waiting, nothing written: a quit after the last save adds none.
    @Test func quitting_withNothingWaiting_writesNothing() async {
        let root = URL(fileURLWithPath: "/tmp/weir-review-quit-idle")
        let drafts = RecordingReviewDraftStore()
        let pool = ReviewDraftWriterPool(drafts: drafts, git: FakeReviewRepository())
        let writer = pool.writer(root: root)
        writer.rememberOpenFile("b.swift", in: ReviewScope.uncommitted.scopeID) { _ in }
        await writer.flushNavigationSave()
        #expect(drafts.saves == 1)

        pool.flushNavigationSaves()

        #expect(drafts.saves == 1)
    }
}
