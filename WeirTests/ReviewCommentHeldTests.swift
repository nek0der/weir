// ReviewCommentHeldTests.swift
// Weir — a comment being written as the diff, the tab's place, and its owner change under it.

import Foundation
import Testing
@testable import Weir

/// The rules a comment being written in a review follows, whether the review
/// stayed open or came back with its tab: it follows its code, it is set
/// aside in the banner where it cannot, and nothing drops it unseen; the
/// tab that brought it back is not closed by the switch; the owner of a
/// review is the one it was last opened from.
@MainActor
struct ReviewCommentHeldTests {
    typealias Fixture = ProjectWindowsFixture

    private static let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
    private static let other = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)

    // MARK: - The switch that brings a tab back

    @Test func theRowRule_keepsAnArrival_putsAHeldCommentBehind_andClosesTheRest() {
        #expect(ReviewTabActions.rowChange(hasReview: false, isArrival: false, holdsComment: false) == .keep)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: true, holdsComment: false) == .keep)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: true, holdsComment: true) == .keep)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: false, holdsComment: true) == .putBehind)
        #expect(ReviewTabActions.rowChange(hasReview: true, isArrival: false, holdsComment: false) == .close)
    }

    @Test func aTabBroughtBackBehind_isNotClosedByTheSwitch_butByTheNextMove() throws {
        let fixture = Fixture()
        var tab = try ProjectWindowsFixture.review()
        tab.isShown = false
        fixture.primary.review = tab

        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        // The row the switch lands on is the arrival.
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        // The person moves on: the usual rule, with nothing held.
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .close)
    }

    // MARK: - The diff changing under a comment

    private static let written = "@@ -1,2 +1,3 @@\n keep\n+let added = 1\n tail"
    private static let moved = "@@ -1,3 +1,4 @@\n head\n keep\n+let added = 1\n tail"

    @Test func aQuoteNeverSpansTwoChangedBlocks_inAColumn() throws {
        let patch = "@@ -1,2 +1,2 @@\n-old1\n+new1\n }\n@@ -20,2 +20,2 @@\n }\n-old2\n+new2"
        let diff = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f", patch: patch)
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f0",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            side: .new,
            code: "}\n}",
            codeMarkers: "  ",
            body: "Why?"
        )

        #expect(ReviewCommentRelocation.placement(of: comment, in: diff, scopeID: "s") == .notFound)
    }

    @Test func aLargeRun_followsOnlyWhenItsWholeQuoteMatches() throws {
        let lines = (0..<120).map { "+let value\($0) = \"\(String(repeating: "x", count: 40))\"" }
        let old = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f1",
            patch: "@@ -1,1 +1,121 @@\n keep\n" + lines.joined(separator: "\n")
        )
        let new = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,2 +1,122 @@\n head\n keep\n" + lines.joined(separator: "\n")
        )
        let composer = try ReviewDiffFixture.composer(on: old)
        let added = new.lines.filter { $0.kind == .added }
        try #require(added.count == 120)

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("Expected the complete quote to follow.")
            return
        }
        #expect(moved.startLineID == added.first?.id)
        #expect(moved.lineID == added.last?.id)
        #expect(moved.text == composer.text)
        #expect(moved.side == composer.side)

        var altered = lines
        altered[110] = "+let changed = 0"
        let partialMatch = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f3",
            patch: "@@ -1,2 +1,122 @@\n head\n keep\n" + altered.joined(separator: "\n")
        )
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: partialMatch) == .setAside)
    }

    @Test func aLineLongerThanTheExcerpt_mustMatchThroughItsEnd() throws {
        let long = String(repeating: "y", count: 3000)
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: "@@ -1,1 +1,2 @@\n keep\n+\(long)")
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: "@@ -1,2 +1,3 @@\n head\n keep\n+\(long)")
        let composer = try ReviewDiffFixture.composer(on: old)

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("not moved")
            return
        }
        let added = try #require(new.lines.first { $0.kind == .added })
        #expect(moved.startLineID == added.id)
        #expect(moved.lineID == added.id)
        #expect(moved.text == composer.text)

        let differentSuffix = long.dropLast() + "z"
        let partialMatch = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f3",
            patch: "@@ -1,2 +1,3 @@\n head\n keep\n+\(differentSuffix)"
        )
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: partialMatch) == .setAside)
    }

    @Test func aCommentOnRemovedLinesOnly_follows_inTheUnifiedLayoutAndTheOldColumn() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: "@@ -1,3 +1,1 @@\n keep\n-gone one\n-gone two")
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: "@@ -1,4 +1,2 @@\n head\n keep\n-gone one\n-gone two")
        let removed = new.lines.filter { $0.kind == .removed }
        for side in [ReviewSide?.none, .old] {
            let composer = try ReviewDiffFixture.composer(on: old, side: side) { $0.kind == .removed }
            guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
                Issue.record("not moved in \(String(describing: side))")
                continue
            }
            #expect(moved.startLineID == removed.first?.id)
            #expect(moved.lineID == removed.last?.id)
        }
    }

    @Test func aSavedCommentEditOnAChangedDiff_closesIfUnchangedOrSetsAsideNewText() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        let line = try #require(old.lines.first { $0.kind == .added })
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: line.id, oldLine: nil, newLine: line.newLine),
            code: line.text,
            codeMarkers: "+",
            body: "Was"
        )
        var composer = ReviewComposerState()
        composer.edit(comment)

        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: new, editedBody: "Was") == .closed)
        composer.text = "Was, and now"
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: new, editedBody: "Was") == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: new) == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: old, editedBody: "Was") == .kept)
    }

    @Test func aCommentFollowsItsCode_asTheDiffChangesUnderIt() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        let composer = try ReviewDiffFixture.composer(on: old)
        let line = try #require(new.lines.first { $0.kind == .added })

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("not moved")
            return
        }
        #expect(moved.startLineID == line.id)
        #expect(moved.lineID == line.id)
        #expect(moved.text == "Why this?")
        #expect(line.id != composer.lineID)
        // The same diff, or nothing typed: nothing to do.
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: old) == .kept)
        #expect(ReviewComposerFollow.outcome(of: ReviewComposerState(), from: old, to: new) == .kept)
    }

    @Test func aCommentWhoseCodeWent_isSetAside() throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let composer = try ReviewDiffFixture.composer(on: old)
        let changed = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: "@@ -1,2 +1,3 @@\n keep\n+let added = 2\n tail")
        let twice = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f3",
            patch: "@@ -1,2 +1,4 @@\n keep\n+let added = 1\n+let added = 1\n tail"
        )
        let other = try ReviewDiffFixture.diff(
            of: Self.other,
            fingerprint: "f1",
            patch: Self.written
        )

        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: changed) == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: twice) == .setAside)
        // The same code in another file is not where it was written.
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: other) == .setAside)
        #expect(ReviewComposerFollow.outcome(of: composer, from: old, to: nil) == .setAside)
    }

    @Test(arguments: [ReviewSide.new, .old])
    func aCommentInOneColumn_followsItsLinesAcrossTheOtherColumns(side: ReviewSide) throws {
        let patch = "@@ -1,3 +1,3 @@\n keep\n-old line\n+new line\n tail"
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: patch)
        let new = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,4 +1,4 @@\n head\n keep\n-old line\n+new line\n tail"
        )
        let changedKind: ReviewLine.Kind = side == .new ? .added : .removed
        let composer = try ReviewDiffFixture.composer(on: old, side: side) { $0.text == "keep" || $0.kind == changedKind }
        let keep = try #require(new.lines.first { $0.text == "keep" })
        let changed = try #require(new.lines.first { $0.kind == changedKind })

        guard case let .moved(moved) = ReviewComposerFollow.outcome(of: composer, from: old, to: new) else {
            Issue.record("Expected the quote to follow its column.")
            return
        }
        #expect(moved.startLineID == keep.id)
        #expect(moved.lineID == changed.id)
        #expect(moved.side == side)
        #expect(moved.text == composer.text)
    }

    @Test func aCommentFromAnEarlierReview_inOneColumn_movesAcrossTheOtherColumns() throws {
        let new = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,4 +1,4 @@\n head\n keep\n-old line\n+new line\n tail"
        )
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f1",
            anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            side: .new,
            code: "keep\nnew line",
            codeMarkers: " +",
            body: "Why?"
        )

        guard case let .placed(placed) = ReviewCommentRelocation.placement(of: comment, in: new, scopeID: "s") else {
            Issue.record("not placed")
            return
        }
        #expect(placed.lineID == new.lines.first { $0.text == "keep" }?.id)
        #expect(placed.lastLineID == new.lines.first { $0.kind == .added }?.id)
    }

    /// A review of `a.swift` reading `diff` as its open file.
    private static func review(reading diff: ReviewDiff) async throws -> (ReviewSession, FakeReviewRepository) {
        let repository = FakeReviewRepository()
        repository.files = [file]
        repository.diffs[file.id] = diff
        let review = ReviewSession(
            writer: ReviewDraftWriter(
                root: URL(fileURLWithPath: "/tmp/weir-held-\(UUID().uuidString)"),
                drafts: RecordingReviewDraftStore()
            ),
            git: repository
        )
        _ = await review.reload(scope: .uncommitted, selectedFileID: nil)
        #expect(review.diff?.fingerprint == diff.fingerprint)
        return (review, repository)
    }

    @Test func aReviewReadAgain_movesItsCommentWithTheCode() async throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let (review, repository) = try await Self.review(reading: old)
        review.composer = try ReviewDiffFixture.composer(on: old)
        let new = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f2", patch: Self.moved)
        repository.diffs[Self.file.id] = new

        // The same read whether the review stayed open or its tab came back.
        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)

        let line = try #require(new.lines.first { $0.kind == .added })
        #expect(review.composer.startLineID == line.id)
        #expect(review.composer.text == "Why this?")
        #expect(review.unplacedComment == nil)
    }

    @Test func aReviewReadAgain_setsAsideACommentWhoseCodeWent() async throws {
        let old = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "f1", patch: Self.written)
        let (review, repository) = try await Self.review(reading: old)
        review.composer = try ReviewDiffFixture.composer(on: old)
        repository.diffs[Self.file.id] = try ReviewDiffFixture.diff(
            of: Self.file,
            fingerprint: "f2",
            patch: "@@ -1,2 +1,3 @@\n keep\n+let added = 2\n tail"
        )

        _ = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)

        #expect(!review.composer.isOpen)
        #expect(review.unplacedComment == "Why this?")
        // Held until it is copied or thrown away.
        #expect(review.holdsComment)
        review.unplacedComment = nil
        #expect(!review.holdsComment)
    }

    /// A review of `a.swift` and `b.swift`, read with `a.swift` open, from
    /// a repository that answers the stack as well as the review.
    private static func review(_ diffs: [ReviewDiff]) async throws -> (ReviewSession, StackReviewRepository) {
        let repository = StackReviewRepository(files: [file, other], diffs: diffs)
        let review = ReviewSession(
            writer: ReviewDraftWriter(
                root: URL(fileURLWithPath: "/tmp/weir-held-\(UUID().uuidString)"),
                drafts: RecordingReviewDraftStore()
            ),
            git: repository
        )
        review.stackLoader.publishInterval = .zero
        let result = await review.reload(scope: .uncommitted, selectedFileID: file.id)
        try #require(result == .applied(selectedFileID: file.id))
        try #require(review.diff?.file.id == file.id)
        return (review, repository)
    }

    @Test(arguments: [false, true])
    func anotherFileOpened_setsTheCommentAside_forFreshAndStackedDiffs(usesStack: Bool) async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, repository) = try await Self.review([mine, theirs])
        defer { review.releaseStack() }
        review.composer = try ReviewDiffFixture.composer(on: mine)

        if usesStack {
            try await Self.loadOtherFile(in: review, fingerprint: "b")
            let reads = repository.diffReadIDs
            try #require(review.openFromStack(Self.other) != nil)
            #expect(repository.diffReadIDs == reads)
        } else {
            await review.load(Self.other)
            #expect(repository.diffReadIDs == [Self.file.id, Self.other.id])
        }

        #expect(review.diff?.file.id == Self.other.id)
        #expect(review.diff?.fingerprint == "b")
        #expect(review.unplacedComment == "Why this?")
        #expect(!review.composer.isOpen)
    }

    @Test func aReviewReadAgainOnTheSameDiff_keepsTheComment() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let (review, repository) = try await Self.review([mine])
        let composer = try ReviewDiffFixture.composer(on: mine)
        review.composer = composer
        let reads = repository.diffReadIDs

        let result = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)

        #expect(result == .applied(selectedFileID: Self.file.id))
        #expect(repository.diffReadIDs == reads + [Self.file.id])
        #expect(review.diff?.fingerprint == "a")
        #expect(review.composer == composer)
        #expect(review.unplacedComment == nil)
    }

    @Test func aCheckedOpenFile_isDrawnWhole_whileItsComposerIsOpen_andStillSaysItIsChecked() throws {
        #expect(ReviewStackBuilder.unfolded(openFileID: nil, isComposerOpen: true).isEmpty)
        let diff = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let composerLine = try #require(diff.lines.first { $0.kind == .added })
        for isComposerOpen in [false, true] {
            var input = ReviewStackBuilder.Input(files: [Self.file], slots: [Self.file.id: 0])
            input.viewed = [Self.file.id]
            input.unfolded = ReviewStackBuilder.unfolded(openFileID: Self.file.id, isComposerOpen: isComposerOpen)
            input.open = diff
            input.openRows = ReviewRowBuilder.rows(
                expanded: diff, comments: [], composerLineID: isComposerOpen ? composerLine.id : nil
            )
            let drawn = ReviewStackBuilder.build(input) { _, _, _ in
                Issue.record("The open file must not use the closed-file builder.")
                return ReviewStackPiece(rows: [])
            }
            let first = try #require(drawn.rows.first)
            guard case let .file(header) = first.kind else {
                Issue.record("Expected the file header as the first row.")
                continue
            }
            #expect(header.file == Self.file)
            #expect(header.isViewed)
            #expect(header.isFolded == !isComposerOpen)
            let expected: [ReviewRow.Kind] = isComposerOpen
                ? diff.lines.flatMap { line -> [ReviewRow.Kind] in
                    if line.kind == .hunk {
                        return [.hunk(line)]
                    }
                    return line.id == composerLine.id ? [.code(line), .composer(line)] : [.code(line)]
                }
                : []
            #expect(drawn.rows.dropFirst().map(\.kind) == expected)
        }
    }

    // MARK: - What holds the tab, and what it says

    @Test func closeAsked_refusesWhileACommentIsHeld_andClosesAfterItIsCleared() throws {
        let fixture = ActionStoresFixture()
        let window = fixture.window
        let tab = try Fixture.review()
        window.review = tab
        let stores = fixture.review
        let visibility = PaneVisibilityReporter(windowID: window.id, registry: fixture.windows)
        defer { stores.toasts.dismiss(in: window.id) }
        #expect(ReviewTabActions.heldCommentRefusal(window) == nil)
        let review = window.writeComment()
        let composer = review.composer

        ReviewTabActions.closeAsked(window: window, stores: stores, paneVisibility: visibility)
        #expect(ReviewTabActions.heldCommentRefusal(window) == .unsavedComment)
        #expect(window.review?.opening == tab.opening)
        #expect(window.reviewSession === review)
        #expect(review.composer == composer)
        #expect(stores.toasts.current(in: window.id)?.message == DisplayText(error: ReviewError.unsavedComment))
        #expect(Set(stores.toasts.items.keys) == [window.id])

        review.setComposerAside()
        ReviewTabActions.closeAsked(window: window, stores: stores, paneVisibility: visibility)
        #expect(ReviewTabActions.heldCommentRefusal(window) == .unplacedCommentHeld)
        #expect(window.review?.opening == tab.opening)
        #expect(window.reviewSession === review)
        #expect(review.unplacedComment == "Why this?")
        #expect(window.reviewHasUnsavedComment)
        #expect(stores.toasts.current(in: window.id)?.message == DisplayText(error: ReviewError.unplacedCommentHeld))
        #expect(Set(stores.toasts.items.keys) == [window.id])

        stores.toasts.dismiss(in: window.id)
        review.unplacedComment = nil
        #expect(ReviewTabActions.heldCommentRefusal(window) == nil)
        #expect(!window.reviewHasUnsavedComment)
        ReviewTabActions.closeAsked(window: window, stores: stores, paneVisibility: visibility)
        #expect(window.review == nil)
        #expect(window.reviewSession == nil)
        #expect(stores.toasts.current(in: window.id) == nil)

        let ja = Locale(identifier: "ja")
        #expect(ReviewError.unplacedCommentHeld.message.resolved(in: ja) == "戻せなかったコメントを先にコピーするか破棄してください。")
        #expect(ReviewError.worktreeMoved.message.resolved(in: ja)
            == "このレビューのワークツリーは元の場所にありません。レビューを閉じて開き直してください。")
    }

    @Test func aSecondCommentSetAside_joinsTheFirst() throws {
        let fixture = Fixture()
        fixture.primary.review = try ProjectWindowsFixture.review()
        let review = fixture.primary.writeComment("First")
        review.setComposerAside()
        fixture.primary.writeComment("Second")

        review.setComposerAside()

        #expect(review.unplacedComment == "First\n\nSecond")
    }

    @Test func theUnplacedCommentCatalogMessage_isAvailableInEnglishAndJapanese() {
        let message = LocalizedStringResource(
            "The comment you were writing couldn’t be put back where it was. Copy it to write it again."
        )
        #expect(message.resolved(in: Locale(identifier: "en"))
            == "The comment you were writing couldn’t be put back where it was. Copy it to write it again.")
        #expect(message.resolved(in: Locale(identifier: "ja")) == "入力中のコメントを元の場所に戻せませんでした。コピーして書き直してください。")
    }

    // MARK: - A review that cannot open

    @Test func reviewPaneOpening_reportsTheFailureOrKeepsTheSameRoot() throws {
        let kept = ProjectWindowState.reviewSession(root: "/repo")
        kept.composer = try ReviewDiffFixture.composer(on: ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written))
        let composer = kept.composer

        guard case let .cannotOpen(failure) = ReviewPaneOpening.choose(kept: kept, resolved: .failure(ReviewError.gitFailed)) else {
            Issue.record("Expected the repository error.")
            return
        }
        #expect(failure == DisplayText(error: ReviewError.gitFailed))
        #expect(kept.composer == composer)

        guard case let .cannotOpen(moved) = ReviewPaneOpening.choose(
            kept: kept,
            resolved: .success(URL(fileURLWithPath: "/elsewhere"))
        ) else {
            Issue.record("Expected the different repository to be refused.")
            return
        }
        #expect(moved == DisplayText(error: ReviewError.worktreeMoved))
        #expect(kept.composer == composer)
        #expect(kept.unplacedComment == nil)

        guard case let .kept(drawn) = ReviewPaneOpening.choose(
            kept: kept,
            resolved: .success(URL(fileURLWithPath: "/repo/sub/../", isDirectory: true))
        ) else {
            Issue.record("Expected the same standardized repository to keep its review.")
            return
        }
        #expect(drawn === kept)
        #expect(drawn.composer == composer)
    }

    // MARK: - The owner

    @Test func theLatestOpeningFromAPane_decidesTheOwner() throws {
        var context = ReviewTabModel.Context(turns: [], isViewed: { _ in false }, branchBase: nil)
        let scratchPane = UUID()
        let projectPane = UUID()
        context.isAgentPaneOfNoProject = true
        let opened = try ReviewTabModel.open(.uncommitted, context, root: "/repo", agentPaneID: scratchPane, current: nil).get()
        #expect(opened.isOfNoProject)

        // The same worktree opened from no pane: the owner stays.
        context.isAgentPaneOfNoProject = false
        let again = try ReviewTabModel.open(.uncommitted, context, root: "/repo", agentPaneID: nil, current: opened).get()
        #expect(again.opening == opened.opening)
        #expect(again.isOfNoProject)

        // From a project's pane: the project's from now on, the same tab.
        let reopened = try ReviewTabModel.open(.uncommitted, context, root: "/repo", agentPaneID: projectPane, current: opened).get()
        #expect(reopened.opening == opened.opening)
        #expect(!reopened.isOfNoProject)
    }

    // MARK: - Composing over text

    private static func selection(_ start: Int, _ end: Int) -> ReviewSelection {
        var selection = ReviewSelection()
        selection.select(start)
        if end != start {
            selection.extend(to: end)
        }
        return selection
    }

    @Test func textBeingWritten_neverMovesToLinesItWasNotWrittenOn() {
        var composer = ReviewComposerState()
        composer.compose(start: 5, end: 6, side: nil)
        composer.text = "Why this?"
        let onComposer = Self.selection(5, 6)
        let elsewhere = Self.selection(20, 20)

        // A click elsewhere, then extending from there: it stays.
        #expect(ReviewComposerSelection.change(of: composer, holdsText: true, from: onComposer, to: elsewhere) == .keep)
        #expect(ReviewComposerSelection.change(of: composer, holdsText: true, from: elsewhere, to: Self.selection(20, 22)) == .keep)
        // Extending its own run carries it.
        #expect(ReviewComposerSelection.change(of: composer, holdsText: true, from: onComposer, to: Self.selection(5, 8)) == .retarget)
        // With nothing typed, a click elsewhere closes it, and extending carries it.
        composer.text = ""
        #expect(ReviewComposerSelection.change(of: composer, holdsText: false, from: onComposer, to: elsewhere) == .cancel)
        #expect(ReviewComposerSelection.change(of: composer, holdsText: false, from: onComposer, to: Self.selection(5, 8)) == .retarget)
    }

    @Test func theComposersRun_followsAnExtensionOfItsOwn_andNothingElse() {
        var composer = ReviewComposerState()
        composer.compose(start: 5, end: 6, side: nil)
        composer.text = "Why this?"

        // A second ⇧↓, then shrinking: each from the composer's own run.
        #expect(ReviewComposerSelection
            .change(of: composer, holdsText: true, from: Self.selection(5, 6), to: Self.selection(5, 7)) == .retarget)
        composer.retarget(start: 5, end: 7, side: nil)
        #expect(ReviewComposerSelection
            .change(of: composer, holdsText: true, from: Self.selection(5, 7), to: Self.selection(5, 8)) == .retarget)
        composer.retarget(start: 5, end: 8, side: nil)
        #expect(ReviewComposerSelection
            .change(of: composer, holdsText: true, from: Self.selection(5, 8), to: Self.selection(5, 6)) == .retarget)

        // From nothing selected to its own line, then extended from there.
        var single = ReviewComposerState()
        single.compose(start: 9, end: 9, side: nil)
        single.text = "Here"
        #expect(ReviewComposerSelection.change(of: single, holdsText: true, from: ReviewSelection(), to: Self.selection(9, 9)) == .keep)
        #expect(ReviewComposerSelection
            .change(of: single, holdsText: true, from: Self.selection(9, 9), to: Self.selection(9, 11)) == .retarget)

        // An edit with new text stays where its comment is.
        let comment = ReviewComment(
            file: Self.file,
            fingerprint: "f",
            anchor: ReviewAnchor(lineID: 5, oldLine: nil, newLine: 5),
            code: "x",
            body: "Was"
        )
        var edit = ReviewComposerState()
        edit.edit(comment)
        edit.text = "Was, and now"
        #expect(ReviewComposerSelection.change(of: edit, holdsText: true, from: Self.selection(5, 5), to: Self.selection(5, 7)) == .keep)

        // `c` on dragged text: the composer opened for the new run in the
        // same keystroke goes with it, with nothing typed yet.
        var opened = ReviewComposerState()
        opened.compose(start: 20, end: 22, side: nil)
        #expect(ReviewComposerSelection
            .change(of: opened, holdsText: false, from: Self.selection(5, 5), to: Self.selection(20, 22)) == .retarget)
    }

    @Test func anEditLeftAsItWas_holdsNothing() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let (review, _) = try await Self.review([mine])
        let line = try #require(review.diff?.lines.first { $0.isCommentable && $0.kind == .added })
        #expect(review.add(line: line, body: "Saved"))
        let comment = try #require(review.comments.first)
        review.composer.edit(comment)

        #expect(!review.composerHoldsUnsavedText)
        #expect(!review.holdsComment)
        review.composer.text = "Saved, and more"
        #expect(review.composerHoldsUnsavedText)
        // A new comment with text always holds.
        review.composer.compose(start: line.id, end: line.id, side: nil)
        review.composer.text = "New"
        #expect(review.composerHoldsUnsavedText)
    }

    @Test func aKeptTabWhoseCommentWentMeanwhile_givesWay() throws {
        let fixture = Fixture()
        let window = fixture.primary
        window.review = try ProjectWindowsFixture.review()
        window.writeComment()
        let wentMeanwhile = try #require(ParkedReview.Tab(leftBy: window, kept: .always))
        window.review = try ProjectWindowsFixture.review()
        window.reviewSession = nil
        window.writeComment()
        let written = try #require(ParkedReview.Tab(leftBy: window, kept: .always))
        // A read that ended while the tab was kept let its comment go.
        wentMeanwhile.session?.composer.cancel()

        #expect(ParkedReview.tabs(written, joining: [wentMeanwhile]).map(\.review.opening) == [written.review.opening])
    }

}

extension ReviewCommentHeldTests {

    // MARK: - The stack of a review with a comment

    /// The hold a surface puts on `review`'s stack, as
    /// `ReviewWorkspaceView.holdStack` does.
    private static func hold(_ review: ReviewSession, isComposingInputMethodText: Bool) {
        review.stackLoader.hold(ReviewStackLoader.holdsPublishing(isComposingInputMethodText: isComposingInputMethodText))
    }

    private static func loadOtherFile(in review: ReviewSession, fingerprint: String) async throws {
        review.loadStacked(window: [file.id, other.id])
        await pollUntilStackRead {
            review.stackLoader.entries[Self.other.id]?.diff?.fingerprint == fingerprint
                && !review.stackLoader.stale.contains(Self.other.id)
        }
        try #require(review.stackLoader.entries[other.id]?.diff?.fingerprint == fingerprint)
        try #require(!review.stackLoader.stale.contains(other.id))
    }

    @Test func reloadingARestoredReview_readsItsOtherFilesAgainWithoutLosingItsDraft() async throws {
        let fixture = Fixture()
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, repository) = try await Self.review([mine, theirs])
        defer { review.releaseStack() }
        let window = fixture.primary
        window.review = try Fixture.review()
        window.reviewSession = review
        try await Self.loadOtherFile(in: review, fingerprint: "b")
        #expect(repository.diffReadIDs == [Self.file.id, Self.other.id])
        let composer = try ReviewDiffFixture.composer(on: mine)
        review.composer = composer
        Self.hold(review, isComposingInputMethodText: false)

        fixture.choose(fixture.bTab, in: window)
        #expect(window.reviewSession == nil)
        #expect(review.stackLoader.isReleased)
        #expect(review.stackLoader.entries.isEmpty)
        fixture.choose(fixture.aTab, in: window)
        #expect(window.reviewSession === review)
        #expect(!review.stackLoader.isReleased)
        #expect(review.composer == composer)

        // The returning surface requests the selected file and the visible stack.
        let reread = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b-returned", patch: Self.moved)
        repository.replace(reread)
        let result = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)
        try #require(result == .applied(selectedFileID: Self.file.id))
        Self.hold(review, isComposingInputMethodText: false)
        try await Self.loadOtherFile(in: review, fingerprint: "b-returned")

        #expect(repository.diffReadIDs == [Self.file.id, Self.other.id, Self.file.id, Self.other.id])
        #expect(review.composer == composer)
        #expect(review.unplacedComment == nil)
    }

    @Test func refreshWithACommentBeingWritten_readsTheOtherFilesAgain() async throws {
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let (review, repository) = try await Self.review([mine, theirs])
        defer { review.releaseStack() }
        try await Self.loadOtherFile(in: review, fingerprint: "b")
        #expect(repository.diffReadIDs == [Self.file.id, Self.other.id])
        let composer = try ReviewDiffFixture.composer(on: mine)
        review.composer = composer
        Self.hold(review, isComposingInputMethodText: false)

        let refreshed = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b-refreshed", patch: Self.moved)
        repository.replace(refreshed)
        let result = await review.reload(scope: .uncommitted, selectedFileID: Self.file.id)
        try #require(result == .applied(selectedFileID: Self.file.id))
        #expect(review.stackLoader.stale.contains(Self.other.id))
        #expect(review.stackLoader.entries[Self.other.id]?.diff?.fingerprint == "b")
        try await Self.loadOtherFile(in: review, fingerprint: "b-refreshed")

        #expect(repository.diffReadIDs == [Self.file.id, Self.other.id, Self.file.id, Self.other.id])
        #expect(review.composer == composer)
        #expect(review.unplacedComment == nil)
    }

    @Test func releasingAPublishHold_publishesTheCompletedReadWithoutReadingAgain() async throws {
        let diff = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b", patch: Self.written)
        let repository = StackReviewRepository(files: [Self.other], diffs: [diff])
        let loader = ReviewStackLoader(git: repository, root: WorkspaceSessionFixture.projectRootURL("held"))
        defer { loader.release(listed: [Self.other]) }
        loader.publishInterval = .zero
        loader.hold(true)
        let revision = loader.revision

        loader.request([ReviewStackLoader.Request(file: Self.other, scope: .uncommitted)], window: [Self.other.id])
        await pollUntilStackRead { loader.isWaitingToPublish(Self.other.id) }
        try #require(loader.isWaitingToPublish(Self.other.id))
        #expect(repository.diffReadIDs == [Self.other.id])
        #expect(loader.entries.isEmpty)
        #expect(loader.revision == revision)

        loader.hold(false)

        #expect(loader.entries[Self.other.id]?.diff?.fingerprint == "b")
        #expect(!loader.isWaitingToPublish(Self.other.id))
        #expect(loader.revision == revision + 1)
        #expect(repository.diffReadIDs == [Self.other.id])
    }

    @Test func resumingTheStack_discardsAnOldInputMethodHoldAndItsPendingRead() async throws {
        #expect(ReviewStackLoader.holdsPublishing(isComposingInputMethodText: true))
        #expect(!ReviewStackLoader.holdsPublishing(isComposingInputMethodText: false))
        let mine = try ReviewDiffFixture.diff(of: Self.file, fingerprint: "a", patch: Self.written)
        let theirs = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b-held", patch: Self.written)
        let (review, repository) = try await Self.review([mine, theirs])
        defer { review.releaseStack() }
        review.composer = try ReviewDiffFixture.composer(on: mine)
        Self.hold(review, isComposingInputMethodText: true)
        review.loadStacked(window: [Self.other.id])
        await pollUntilStackRead { review.stackLoader.isWaitingToPublish(Self.other.id) }
        try #require(review.stackLoader.isWaitingToPublish(Self.other.id))
        #expect(repository.diffReadIDs == [Self.file.id, Self.other.id])
        #expect(Set(review.stackLoader.entries.keys) == [Self.file.id])
        #expect(review.stackLoader.entries[Self.file.id]?.diff?.fingerprint == "a")

        review.releaseStack()
        #expect(review.stackLoader.isReleased)
        #expect(!review.stackLoader.isWaitingToPublish(Self.other.id))
        #expect(review.stackLoader.entries.isEmpty)
        let next = try ReviewDiffFixture.diff(of: Self.other, fingerprint: "b-resumed", patch: Self.moved)
        repository.replace(next)
        review.resumeStack()
        #expect(!review.stackLoader.isReleased)
        review.loadStacked(window: [Self.other.id])
        await pollUntilStackRead { review.stackLoader.entries[Self.other.id]?.diff?.fingerprint == "b-resumed" }
        try #require(review.stackLoader.entries[Self.other.id]?.diff?.fingerprint == "b-resumed")

        #expect(repository.diffReadIDs == [Self.file.id, Self.other.id, Self.other.id])
        #expect(!review.stackLoader.isWaitingToPublish(Self.other.id))
    }
}
