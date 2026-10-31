// RailBadgeTests.swift
// Weir — the history's bell shows a dot, the changes panel's icon a count.

import Foundation
import Testing
@testable import Weir

struct RailBadgeTests {
    private let english = Locale(identifier: "en")
    private let japanese = Locale(identifier: "ja")

    @Test func highlight_isOneButton_anOpenPanelBeforeScratchBeforeTheSidebar() {
        func of(
            sidebar: Bool = true,
            scratch: Bool = false,
            all: Bool = false,
            history: Bool = false,
            usage: Bool = false,
            update: Bool = false
        ) -> RailHighlight {
            RailHighlight.of(
                isSidebarPresented: sidebar,
                isOnScratch: scratch,
                isAllProjectsPresented: all,
                isHistoryPresented: history,
                isPlanUsagePresented: usage,
                isUpdatePresented: update
            )
        }
        #expect(of() == .sidebar)
        #expect(of(sidebar: false) == .none)
        #expect(of(update: true) == .update)
        #expect(of(scratch: true) == .scratch)
        #expect(of(scratch: true, all: true) == .allProjects)
        #expect(of(scratch: true, history: true) == .history)
        #expect(of(scratch: true, usage: true) == .planUsage)
    }

    @Test func state_marksOnlyWhatAsksSomethingOfThePerson() {
        #expect(RailBadge.state(of: .needsApproval) == .waiting)
        #expect(RailBadge.state(of: .needsAnswer) == .waiting)
        #expect(RailBadge.state(of: .needsResponse) == .waiting)
        #expect(RailBadge.state(of: .needsSignIn) == .waiting)
        #expect(RailBadge.state(of: .stopped) == .stopped)
        #expect(RailBadge.state(of: .unread) == .dot)
        #expect(RailBadge.state(of: .unreadWorkingAfterTurn) == .dot)
        #expect(RailBadge.state(of: .running) == nil)
        #expect(RailBadge.state(of: .idle) == nil)
        #expect(RailBadge.state(of: .workingAfterTurn) == nil)
        #expect(RailBadge.state(of: .unknown) == nil)
        #expect(RailBadge.state(of: .shell) == nil)
    }

    @Test func historyBell_withNothingUnread_carriesNoMarkAndSaysOnlyItsName() {
        #expect(NotificationHistoryRailText.badge(unread: 0) == nil)
        #expect(NotificationHistoryRailText.unreadCount(0, locale: english) == nil)
    }

    @Test func historyBell_withUnread_showsADot_andTheCountOnlyInWords() {
        #expect(NotificationHistoryRailText.badge(unread: 1) == .dot)
        #expect(NotificationHistoryRailText.badge(unread: 27) == .dot)

        #expect(NotificationHistoryRailText.unreadCount(27, locale: english) == "27 unread")
        #expect(NotificationHistoryRailText.unreadCount(27, locale: japanese) == "未読 27")
    }

    @Test func changesIcon_keepsItsCount_andNothingAtZero() {
        #expect(RailBadge.counting(0) == nil)
        #expect(RailBadge.counting(3) == .count(3))
        #expect(RailBadge.counting(3, tone: .blocking) == .count(3, tone: .blocking))
        #expect(RailBadge.counting(0, tone: .blocking) == nil)
        #expect(RailBadge.counting(120) == .count(120))
        #expect(RailBadge.text(for: 120) == "99+")
    }
}
