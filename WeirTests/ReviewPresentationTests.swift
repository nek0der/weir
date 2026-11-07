// ReviewPresentationTests.swift
// Weir — which review is open, and which pane its feedback goes to.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("Review presentation")
struct ReviewPresentationTests {
    private static let directory = URL(fileURLWithPath: "/tmp/review")

    /// The review writes to the pane it was opened from until the reader
    /// names another. Reopening the same repository starts a fresh
    /// destination and scope while preserving the window's layout.
    @Test func reopeningReview_resetsTheDestinationAndScope_butKeepsWindowLayout() throws {
        let presentation = ReviewPresentation()
        let opened = UUID()
        let chosen = UUID()
        let reopened = UUID()
        let scope = try ReviewScope.turns(TurnSummaryFixture.range(number: 1))
        presentation.diffLayout = .sideBySide
        presentation.railWidth = 300

        presentation.open(Self.directory, originPaneID: opened, initialScope: scope)
        let firstOpening = try #require(presentation.opening)
        #expect(presentation.directory == Self.directory)
        #expect(presentation.isPresented)
        #expect(presentation.originPaneID == opened)
        #expect(presentation.requestedScope == scope)

        presentation.pinDestination(to: chosen)
        #expect(presentation.originPaneID == chosen)

        presentation.close()
        #expect(presentation.directory == nil)
        #expect(!presentation.isPresented)
        #expect(presentation.originPaneID == nil)
        #expect(presentation.requestedScope == nil)
        #expect(presentation.opening == nil)

        presentation.open(Self.directory, originPaneID: reopened)
        #expect(presentation.originPaneID == reopened)
        let nextOpening = try #require(presentation.opening)
        #expect(nextOpening != firstOpening)
        #expect(presentation.diffLayout == .sideBySide)
        #expect(presentation.railWidth == 300)
    }

    /// A request for the review already open changes its scope and pane,
    /// and is the same opening.
    @Test func aRequestForTheOpenRoot_changesTheScopeWithoutReopening() throws {
        let presentation = ReviewPresentation()
        let firstPane = UUID()
        let turnPane = UUID()
        let scope = try ReviewScope.turns(TurnSummaryFixture.range(number: 1))
        presentation.open(Self.directory, originPaneID: firstPane)
        let opening = try #require(presentation.opening)
        let initialRequest = presentation.scopeRequestID

        presentation.open(Self.directory, originPaneID: turnPane, initialScope: scope)

        #expect(presentation.opening == opening)
        #expect(presentation.originPaneID == turnPane)
        #expect(presentation.requestedScope == scope)
        let firstRequest = presentation.scopeRequestID
        #expect(firstRequest != initialRequest)

        presentation.open(Self.directory, originPaneID: turnPane, initialScope: scope)

        #expect(presentation.opening == opening)
        #expect(presentation.requestedScope == scope)
        #expect(presentation.scopeRequestID != firstRequest)
    }
}
