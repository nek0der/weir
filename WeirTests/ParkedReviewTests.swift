// ParkedReviewTests.swift
// Weir — a project's review tab, kept while its window shows another project and given back as it was.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// A window switching to another project in place leaves its review tab with
/// the project it reads, whether or not a comment is being written in it, and
/// a window showing the project again takes it back as it was: its discards,
/// its comment, where it stood, how it was laid out, and what its view held.
/// No review of another project replaces it, and no comment kept for a
/// project is dropped for another.
@MainActor
struct ParkedReviewTests {
    typealias Fixture = ProjectWindowsFixture

    // MARK: - Kept by switching

    @Test func aParkedReview_comesBackWithItsProject_withItsDiscardedHunks() throws {
        let fixture = Fixture()
        let (tab, hunk) = try Fixture.reviewAndHunk()
        fixture.primary.review = tab
        fixture.primary.hunkDiscards[hunk] = Fixture.discarded

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review == nil)
        #expect(!fixture.primary.reviewPresentation.isPresented)
        let parked = try #require(fixture.registry.parkedReviews[fixture.a.id]?.tab)
        #expect(parked.review.opening == tab.opening)
        #expect(parked.session?.holdsComment != true)
        #expect(fixture.registry.reviewDiscards.hunkDiscards[hunk] == Fixture.discarded)

        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == true)
        #expect(fixture.primary.reviewPresentation.isPresented)
        #expect(!fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.primary.hunkDiscards[hunk] == Fixture.discarded)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func aParkedReview_comesBackWithItsComment_andItsDiscards() throws {
        let fixture = Fixture()
        let tab = try ProjectWindowsFixture.windowWritingAComment(fixture.primary)
        let hunk = try ProjectWindowsFixture.reviewAndHunk().hunk
        fixture.primary.hunkDiscards[hunk] = ProjectWindowsFixture.discarded
        let review = try #require(fixture.primary.reviewSession)
        let composer = review.composer

        fixture.choose(fixture.bTab, in: fixture.primary)
        // `b`'s own review opens and closes meanwhile.
        fixture.primary.review = try ProjectWindowsFixture.review()
        fixture.primary.letGoOfReview()
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        // The review the tab kept, with the comment as it was typed.
        #expect(fixture.primary.reviewSession === review)
        #expect(review.composer == composer)
        #expect(fixture.primary.hunkDiscards[hunk] == ProjectWindowsFixture.discarded)
    }

    @Test func aReviewWithACommentBeingWritten_isKeptForTheProjectLeft_andAnotherOpensInTheNext() async throws {
        let fixture = ActionStoresFixture()
        let window = fixture.window
        fixture.windows.connectProjectSwitching(of: fixture.session)
        let nextProject = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("next"))
        let nextTab = fixture.session.openTab(container: .project(nextProject.id), in: window.id, intent: .person, selects: false)
        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: window, stores: fixture.review)
        let opening = try #require(window.review?.opening)
        let firstSession = window.writeComment("First project's draft")
        let composer = firstSession.composer

        fixture.session.setActiveTab(nextTab.id, in: window.id, intent: .person)
        #expect(window.selection.shownProjectID == nextProject.id)
        #expect(window.review == nil)
        #expect(!window.reviewHasUnsavedComment)
        #expect(window.reviewSession == nil)

        await ReviewTabActions.open(.uncommitted, agentPaneID: nil, window: window, stores: fixture.review)

        #expect(window.review?.root == nextProject.rootURL.path)
        #expect(window.review?.opening != opening)
        #expect(window.review?.isShown == true)
        let nextSession = try #require(window.reviewSession)
        #expect(nextSession !== firstSession)
        #expect(nextSession.root.path == nextProject.rootURL.resolvingSymlinksInPath().path)
        #expect(!nextSession.holdsComment)
        let parked = try #require(fixture.windows.parkedReviews[fixture.project.id]?.tab)
        #expect(parked.review.opening == opening)
        #expect(parked.session === firstSession)
        #expect(parked.session?.composer == composer)
        #expect(fixture.windows.parkedReviews[nextProject.id] == nil)
    }

    @Test func aWindowClosedAfterSwitching_leavesTheReviewWithTheProjectItWasWrittenIn() throws {
        let fixture = Fixture()
        let closing = fixture.primary
        let survivor = try fixture.window(showing: fixture.c)
        let tab = try Fixture.windowWritingAComment(closing)
        let review = try #require(closing.reviewSession)
        let composer = review.composer
        fixture.choose(fixture.bTab, in: closing)

        fixture.registry.close(closing.id, in: fixture.session)

        #expect(fixture.registry.window(closing.id) == nil)
        #expect(fixture.session.selection(closing.id) == nil)
        #expect(fixture.registry.primary === survivor)
        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
        let parked = try #require(fixture.registry.parkedReviews[fixture.a.id]?.tab)
        #expect(parked.review.opening == tab.opening)
        #expect(parked.session === review)
        #expect(parked.session?.composer == composer)
    }

    @Test func aCommentKept_throughQuickSwitchesThereAndBack() throws {
        let fixture = Fixture()
        _ = try ProjectWindowsFixture.windowWritingAComment(fixture.primary)
        let review = try #require(fixture.primary.reviewSession)

        // A to B and back to A at once, twice.
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.choose(fixture.aTab, in: fixture.primary)
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.reviewSession === review)
        #expect(review.composer.text == "Why this?")
        #expect(fixture.primary.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func aParkedReviewsStack_releasesAndResumesWithTheSameReview() throws {
        let fixture = Fixture()
        fixture.primary.review = try ProjectWindowsFixture.review()
        let review = ProjectWindowState.reviewSession(root: "/repo")
        fixture.primary.reviewSession = review
        #expect(!review.stackLoader.isReleased)

        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.primary.reviewSession == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.session === review)
        #expect(review.stackLoader.isReleased)
        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.reviewSession === review)
        #expect(!review.stackLoader.isReleased)
    }

    @Test func aReviewParkedBySwitching_comesBackAsItWasLeft() throws {
        let fixture = Fixture()
        let window = fixture.primary
        var tab = try ProjectWindowsFixture.review()
        tab.isShown = false
        window.review = tab
        let read = ReviewTabModel.OutsideTurnsRead(opening: tab.opening, listReads: 2, counted: ["a.swift": "blob:1"], listed: ["a.swift"])
        window.reviewOutsideTurnsRead = read
        window.reviewPresentation.diffLayout = .sideBySide
        window.reviewPresentation.railWidth = 300
        var view = ReviewTabViewState()
        view.isTreeLayout = true
        view.hidesViewedFiles = true
        view.fileFilter = "src"
        view.collapsedSections = ["dir:src"]
        let checkedFileID = "unstaged:a.swift"
        view.openedViewedFiles.toggle(checkedFileID, isFolded: true, viewed: [checkedFileID: ReviewViewMark(added: 1, removed: 0)])
        view.search = ReviewSearch(query: "TODO", isPresented: true, index: 2)
        view.areEarlierCommentsExpanded = true
        window.reviewTabView = view

        fixture.choose(fixture.bTab, in: window)
        #expect(window.reviewTabView == ReviewTabViewState())
        // `b`'s review is read in its own way meanwhile.
        window.reviewPresentation.diffLayout = .unified
        window.reviewPresentation.railWidth = 200
        fixture.choose(fixture.aTab, in: window)

        // Behind as it was left, and kept by the switch that brought it back:
        // `ParkedReviewArrivalTests`.
        #expect(window.review?.opening == tab.opening)
        #expect(window.review?.isShown == false)
        #expect(window.reviewOutsideTurnsRead == read)
        #expect(window.reviewPresentation.diffLayout == .sideBySide)
        #expect(window.reviewPresentation.railWidth == 300)
        #expect(window.reviewTabView == view)
    }

    @Test func theBandOfATabThatCameBack_waitsAgainBeforeAKeyPressCounts() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let tab = try Fixture.review()
        window.review = tab
        let shown = try Self.band(of: tab)
        let clock = SuspendingClock()
        let initial = clock.now
        window.reviewBandGate.noteShown(shown, at: initial)
        #expect(window.reviewBandGate.decide(at: initial + PrimaryActionGate.settleTime) == shown.action)

        fixture.choose(fixture.bTab, in: window)
        fixture.choose(fixture.aTab, in: window)
        #expect(window.review?.opening == tab.opening)
        #expect(window.reviewBandGate.decide(at: clock.now + PrimaryActionGate.settleTime) == nil)

        let beforeDrawing = clock.now
        ReviewTabActions.noteBandShown(shown, of: tab.opening, window: window)
        let afterDrawing = clock.now

        #expect(window.reviewBandGate.decide(at: beforeDrawing) == nil)
        #expect(window.reviewBandGate.decide(at: afterDrawing + PrimaryActionGate.settleTime) == shown.action)
    }

    @Test func theBandOfTheTabLeft_doesNotSpeakForTheTabTaken() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let tab = try Fixture.review()
        window.review = tab
        fixture.choose(fixture.bTab, in: window)
        var left = try Fixture.review()
        left.selection = try .turn(TurnSummaryFixture.range(number: 9), prompt: TurnPrompt(head: nil))
        window.review = left

        fixture.choose(fixture.aTab, in: window)
        let arrived = try Self.band(of: tab)
        let departed = try Self.band(of: left)
        ReviewTabActions.noteBandShown(arrived, of: tab.opening, window: window)
        ReviewTabActions.noteBandShown(nil, of: left.opening, window: window)
        var afterDismissal = window.reviewBandGate
        #expect(afterDismissal.decide(at: SuspendingClock.now + PrimaryActionGate.settleTime) == arrived.action)

        ReviewTabActions.noteBandShown(departed, of: left.opening, window: window)
        #expect(window.reviewBandGate.decide(at: SuspendingClock.now + PrimaryActionGate.settleTime) == arrived.action)
    }

    private static func band(of tab: ReviewTabState) throws -> ReviewBandGate.Shown {
        guard case let .turns(range) = tab.scope else {
            Issue.record("Expected a turn range for the band.")
            throw CancellationError()
        }
        return ReviewBandGate.Shown(
            opening: tab.opening,
            selection: tab.selection,
            action: .throughTurn(ReviewTabTurn(id: range.endTurnID, number: range.lastNumber))
        )
    }

    // MARK: - Another project's review

    @Test func openingAReviewInAnotherProject_doesNotReplaceTheParkedOne() throws {
        let fixture = Fixture()
        let mine = try ProjectWindowsFixture.review()
        fixture.primary.review = mine
        fixture.choose(fixture.bTab, in: fixture.primary)

        // A review opens in `b`.
        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)
        #expect(fixture.primary.review == nil)
        let theirs = try ProjectWindowsFixture.review()
        fixture.primary.review = theirs

        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == mine.opening)
        fixture.choose(fixture.aTab, in: fixture.primary)
        #expect(fixture.primary.review?.opening == mine.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == theirs.opening)
        #expect(fixture.registry.parkedReviews[fixture.a.id] == nil)
    }

    @Test(arguments: [false, true])
    func removingAProject_releasesOnlyItsParkedReviewRange(isWritingAComment: Bool) throws {
        let fixture = Fixture()
        let removed = if isWritingAComment {
            try Fixture.windowWritingAComment(fixture.primary)
        } else {
            try Fixture.review()
        }
        fixture.primary.review = removed
        guard case let .turns(removedRange) = removed.scope else {
            Issue.record("Expected the removed project's turn range.")
            return
        }
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.primary.review == nil)
        #expect(fixture.registry.parkedReviews[fixture.a.id]?.tab?.review.opening == removed.opening)
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session) == [removedRange])

        var kept = try Fixture.review()
        let keptRange = try TurnSummaryFixture.range(number: 8)
        kept.selection = .turn(keptRange, prompt: TurnPrompt(head: nil))
        fixture.primary.review = kept
        fixture.choose(fixture.cTab, in: fixture.primary)
        #expect(fixture.primary.review == nil)
        #expect(Set(fixture.registry.reviewTurnRanges(in: fixture.session)) == [removedRange, keptRange])

        fixture.session.removeProject(fixture.a.id)
        fixture.registry.forgetProjectsGone(in: fixture.session)

        #expect(fixture.registry.parkedReviews[fixture.a.id] == nil)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session) == [keptRange])
        #expect(fixture.primary.review == nil)
    }

    // MARK: - Comments that meet

    /// A comment kept for `b` by a window that closed on it, and the primary
    /// on `b` with a comment of its own, in a review of a scratch pane: the
    /// primary does not take `b`'s tab as it arrives.
    private static func twoComments(_ fixture: Fixture) throws -> TwoComments {
        let other = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let kept = try ProjectWindowsFixture.windowWritingAComment(other)
        fixture.registry.close(other.id, in: fixture.session)
        let scratch = fixture.scratchTab()
        let pane = try #require(scratch.splitTree.allLeafIDs().first)
        let own = try ProjectWindowsFixture.windowWritingAComment(fixture.primary, agentPaneID: pane, isOfNoProject: true)
        fixture.choose(fixture.bTab, in: fixture.primary)
        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
        return TwoComments(kept: kept, own: own, scratch: scratch)
    }

    /// `b`'s kept comment, the primary's own, and the scratch tab of its pane.
    @MainActor
    private struct TwoComments {
        let kept: ReviewTabState
        let own: ReviewTabState
        let scratch: Tab
    }

    @Test func aWindowLeavingWithItsOwnComment_keepsIt_andTheProjectKeepsItsOwn() throws {
        let fixture = Fixture()
        let comments = try Self.twoComments(fixture)
        let (kept, own, scratch) = (comments.kept, comments.own, comments.scratch)
        // The scratch pane closes: the review keeps the owner it opened
        // with, the window, and goes with no project.
        fixture.session.closeTab(scratch.id)

        fixture.choose(fixture.aTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == own.opening)
        #expect(fixture.primary.reviewHasUnsavedComment)
        let parked = try #require(fixture.registry.parkedReviews[fixture.b.id])
        #expect(parked.tabs.map(\.review.opening) == [kept.opening])
        #expect(parked.tabs.map { $0.session?.holdsComment == true } == [true])
    }

    @Test func leavingAReviewWithAComment_takesTheOneTheNextProjectKept() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        let kept = try Fixture.windowWritingAComment(other)
        let keptSession = other.writeComment("Comment for B")
        let keptComposer = keptSession.composer
        fixture.registry.close(other.id, in: fixture.session)
        let mine = try Fixture.windowWritingAComment(fixture.primary)
        let mySession = fixture.primary.writeComment("Comment for A")
        let myComposer = mySession.composer

        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == kept.opening)
        #expect(fixture.primary.reviewSession === keptSession)
        #expect(fixture.primary.reviewSession?.composer == keptComposer)
        #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
        let parked = try #require(fixture.registry.parkedReviews[fixture.a.id]?.tab)
        #expect(parked.review.opening == mine.opening)
        #expect(parked.session === mySession)
        #expect(parked.session?.composer == myComposer)
    }

    @Test func twoCommentsThatMet_areBothKept_eachWhereItComesBack() throws {
        let fixture = Fixture()
        let comments = try Self.twoComments(fixture)
        let (kept, own) = (comments.kept, comments.own)
        let third = try fixture.window(showing: fixture.c)

        // The primary closes on `b`, with its own scratch pane's comment:
        // `b` keeps its tab, and the scratch row the primary's.
        fixture.registry.close(fixture.primary.id, in: fixture.session)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tabs.map(\.review.opening) == [kept.opening])
        #expect(fixture.registry.parkedScratchReview?.tabs.map(\.review.opening) == [own.opening])
        // Both kept out of the sweep while they wait.
        #expect(fixture.registry.reviewTurnRanges(in: fixture.session).count == 2)

        fixture.choose(fixture.bTab, in: third)
        #expect(third.review?.opening == kept.opening)
        #expect(third.reviewHasUnsavedComment)

        // That comment is done with, and the window goes to the scratch
        // row: the other comes, behind, with its comment.
        third.letGoOfReview()
        fixture.arriveAtTheScratchRow(third)

        #expect(third.review?.opening == own.opening)
        #expect(third.review?.isShown == false)
        #expect(third.reviewHasUnsavedComment)
        #expect(fixture.registry.parkedReviews.isEmpty)
        #expect(fixture.registry.parkedScratchReview == nil)
    }

    @Test func theTabsAProjectKeeps_neverDropOneWithAComment() throws {
        let fixture = Fixture()
        let window = fixture.primary
        func tab(hasComment: Bool) throws -> ParkedReview.Tab {
            window.review = try ProjectWindowsFixture.review()
            window.reviewSession = nil
            if hasComment {
                window.writeComment()
            }
            return try #require(ParkedReview.Tab(leftBy: window, kept: .always))
        }
        let plain = try tab(hasComment: false)
        let plainEarlier = try tab(hasComment: false)
        let written = try tab(hasComment: true)
        let writtenEarlier = try tab(hasComment: true)
        let openings = { (tabs: [ParkedReview.Tab]) in tabs.map(\.review.opening) }

        // The one left last, of two plain ones.
        #expect(openings(ParkedReview.tabs(plain, joining: [plainEarlier])) == [plain.review.opening])
        #expect(openings(ParkedReview.tabs(written, joining: [plainEarlier])) == [written.review.opening])
        #expect(openings(ParkedReview.tabs(plain, joining: [writtenEarlier])) == [writtenEarlier.review.opening])
        #expect(openings(ParkedReview.tabs(written, joining: [writtenEarlier]))
            == [written.review.opening, writtenEarlier.review.opening])
        #expect(openings(ParkedReview.tabs(nil, joining: [writtenEarlier])) == [writtenEarlier.review.opening])
        #expect(ParkedReview.tabs(nil, joining: []).isEmpty)
        // A closing window keeps a tab only with a comment; a scratch pane's
        // review none.
        window.letGoOfComment()
        #expect(ParkedReview.Tab(leftBy: window, kept: .withComment) == nil)
        window.writeComment()
        #expect(ParkedReview.Tab(leftBy: window, kept: .withComment) != nil)
        // A comment set aside in the banner counts until it is let go of.
        window.reviewSession?.setComposerAside()
        #expect(ParkedReview.Tab(leftBy: window, kept: .withComment)?.session?.holdsComment == true)
        #expect(ParkedReview.Tab(leftBy: window, kept: .none) == nil)
    }

    // MARK: - Arriving with a review of the window's own

    /// `b`'s tab, with a comment, kept as a window closed on it; the
    /// primary, on `a`, reviewing a scratch pane.
    private static func scratchReviewMeetsAKeptTab(_ fixture: Fixture, hasComment: Bool) throws -> ReviewTabState {
        let other = try fixture.window(showing: fixture.b)
        _ = try fixture.window(showing: fixture.c)
        let kept = try ProjectWindowsFixture.windowWritingAComment(other)
        fixture.registry.close(other.id, in: fixture.session)
        try fixture.reviewAScratchPane(hasComment: hasComment)
        return kept
    }

    @Test(arguments: [false, true])
    func arrivingWithAScratchReview_takesTheProjectsTabOnlyWithoutAHeldComment(hasComment: Bool) throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: hasComment)
        let own = try #require(fixture.primary.review)
        let ownSession = fixture.primary.reviewSession
        let ownComposer = ownSession?.composer
        let keptSession = try #require(fixture.registry.parkedReviews[fixture.b.id]?.tab?.session)
        let keptComposer = keptSession.composer
        #expect(fixture.primary.reviewHasUnsavedComment == hasComment)

        fixture.choose(fixture.bTab, in: fixture.primary)

        if hasComment {
            #expect(fixture.primary.review == own)
            #expect(fixture.primary.reviewSession === ownSession)
            #expect(fixture.primary.reviewSession?.composer == ownComposer)
            let parked = try #require(fixture.registry.parkedReviews[fixture.b.id]?.tab)
            #expect(parked.review.opening == kept.opening)
            #expect(parked.session === keptSession)
            #expect(parked.session?.composer == keptComposer)
        } else {
            #expect(fixture.primary.review?.opening == kept.opening)
            #expect(fixture.primary.reviewSession === keptSession)
            #expect(fixture.primary.reviewSession?.composer == keptComposer)
            #expect(fixture.primary.reviewHasUnsavedComment)
            #expect(fixture.registry.parkedReviews[fixture.b.id] == nil)
        }
        #expect(fixture.primary.hunkDiscards[Fixture.scratchHunk] == Fixture.discarded)
    }

    // MARK: - Opening in a project that keeps a tab

    @Test func openingAReview_takesTheProjectsTabOnlyAfterTheWindowLetsGoOfItsComment() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: true)
        fixture.choose(fixture.bTab, in: fixture.primary)
        let own = try #require(fixture.primary.review)
        let ownSession = try #require(fixture.primary.reviewSession)
        let ownComposer = ownSession.composer
        let keptSession = try #require(fixture.registry.parkedReviews[fixture.b.id]?.tab?.session)
        let keptComposer = keptSession.composer

        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)

        #expect(fixture.primary.review == own)
        #expect(fixture.primary.reviewSession === ownSession)
        #expect(fixture.primary.reviewSession?.composer == ownComposer)
        let parked = try #require(fixture.registry.parkedReviews[fixture.b.id]?.tab)
        #expect(parked.review.opening == kept.opening)
        #expect(parked.session === keptSession)
        #expect(parked.session?.composer == keptComposer)

        fixture.primary.letGoOfComment()
        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)

        #expect(fixture.primary.review?.opening == kept.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(fixture.primary.reviewSession === keptSession)
        #expect(fixture.primary.reviewSession?.composer == keptComposer)
        #expect(fixture.primary.hunkDiscards[Fixture.scratchHunk] == Fixture.discarded)
        #expect(fixture.registry.parkedReviews.isEmpty)
    }

    @Test func openingAReviewOnAScratchTab_takesOnlyTheScratchReview() throws {
        let fixture = Fixture()
        let kept = try Self.scratchReviewMeetsAKeptTab(fixture, hasComment: true)
        let keptSession = try #require(fixture.registry.parkedReviews[fixture.b.id]?.tab?.session)
        let scratchReview = try fixture.closeWritingAScratchComment(showing: fixture.c, onScratchRow: true)
        let scratchSession = try #require(fixture.registry.parkedScratchReview?.tab?.session)
        let scratchComposer = scratchSession.composer
        fixture.choose(fixture.bTab, in: fixture.primary)
        fixture.primary.letGoOfComment()
        let scratch = try #require(fixture.session.tabs.first { $0.container == .loose })
        fixture.choose(scratch, in: fixture.primary)
        #expect(fixture.primary.selection.shownProjectID == fixture.b.id)
        #expect(fixture.primary.selection.activeContainerID == .loose)
        #expect(fixture.primary.selection.activeTabID == scratch.id)

        fixture.registry.takeParkedReviewBeforeOpening(into: fixture.primary, in: fixture.session)

        #expect(fixture.primary.review?.opening == scratchReview.opening)
        #expect(fixture.primary.reviewSession === scratchSession)
        #expect(fixture.primary.reviewSession?.composer == scratchComposer)
        #expect(fixture.registry.parkedScratchReview == nil)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.review.opening == kept.opening)
        #expect(fixture.registry.parkedReviews[fixture.b.id]?.tab?.session === keptSession)
    }

    // MARK: - Closing

    @Test func aTabBehindAsItsWindowClosed_comesBackBehind() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)
        var tab = try ProjectWindowsFixture.windowWritingAComment(other)
        tab.isShown = false
        other.review = tab

        fixture.registry.close(other.id, in: fixture.session)
        fixture.choose(fixture.bTab, in: fixture.primary)

        #expect(fixture.primary.review?.opening == tab.opening)
        #expect(fixture.primary.review?.isShown == false)
        #expect(ReviewTabActions.rowChange(for: fixture.primary) == .keep)
        #expect(fixture.primary.reviewHasUnsavedComment)
    }

    // MARK: - A view that went

    @Test func aViewThatWent_readsNoScopeOfTheNextTab() {
        let first = UUID()
        let next = UUID()
        // Its task is canceled as it goes, whatever the window draws.
        #expect(!ReviewViewWork.goesOn(begunFor: first, drawing: first, isCancelled: true))
        // Its reads end with another tab drawn: that tab's scope is its own
        // review's.
        #expect(!ReviewViewWork.goesOn(begunFor: first, drawing: next, isCancelled: false))
        #expect(ReviewViewWork.goesOn(begunFor: first, drawing: first, isCancelled: false))
    }
}
