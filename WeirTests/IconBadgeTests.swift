// IconBadgeTests.swift
// Weir — what an icon control carries: a mark for a state, a count, or nothing.

import Foundation
import Testing
@testable import Weir

struct IconBadgeTests {
    @Test func state_marksOnlyWhatAsksSomethingOfThePerson() {
        #expect(IconBadge.state(of: .needsApproval) == .waiting)
        #expect(IconBadge.state(of: .needsAnswer) == .waiting)
        #expect(IconBadge.state(of: .needsResponse) == .waiting)
        #expect(IconBadge.state(of: .needsSignIn) == .waiting)
        #expect(IconBadge.state(of: .stopped) == .stopped)
        #expect(IconBadge.state(of: .unread) == .dot)
        #expect(IconBadge.state(of: .unreadWorkingAfterTurn) == .dot)
        #expect(IconBadge.state(of: .running) == nil)
        #expect(IconBadge.state(of: .idle) == nil)
        #expect(IconBadge.state(of: .workingAfterTurn) == nil)
        #expect(IconBadge.state(of: .unknown) == nil)
        #expect(IconBadge.state(of: .shell) == nil)
    }

    @Test func changesIcon_keepsItsCount_andNothingAtZero() {
        #expect(IconBadge.counting(0) == nil)
        #expect(IconBadge.counting(3) == .count(3))
        #expect(IconBadge.counting(3, tone: .blocking) == .count(3, tone: .blocking))
        #expect(IconBadge.counting(0, tone: .blocking) == nil)
        #expect(IconBadge.counting(120) == .count(120))
        #expect(IconBadge.text(for: 120) == "99+")
    }
}
