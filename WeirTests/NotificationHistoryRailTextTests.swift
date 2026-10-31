// NotificationHistoryRailTextTests.swift
// Weir — the history's bell shows a dot, and its count only in words.

import Foundation
import Testing
@testable import Weir

struct NotificationHistoryRailTextTests {
    private let english = Locale(identifier: "en")
    private let japanese = Locale(identifier: "ja")

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
}
