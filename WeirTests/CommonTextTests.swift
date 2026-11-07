// CommonTextTests.swift
// Weir — the words several surfaces share say the same thing in both languages.

import Foundation
import Testing
@testable import Weir

@Suite("Common text")
@MainActor
struct CommonTextTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")

    /// One "Retry" for every failed thing run again: the review's load said
    /// "Try Again", and a new worktree's stage had a key of its own.
    @Test func retry_isOneWordInBothLanguages() {
        #expect(CommonText.retry.resolved(in: en) == "Retry")
        #expect(CommonText.retry.resolved(in: ja) == "再試行")
    }

    @Test func close_andQuit_areTranslated() {
        #expect(CommonText.close.resolved(in: en) == "Close")
        #expect(CommonText.close.resolved(in: ja) == "閉じる")
        #expect(CommonText.quitApp.resolved(in: en) == "Quit Weir")
        #expect(CommonText.quitApp.resolved(in: ja) == "Weir を終了")
    }

    /// The find bar's match and the decision bar's item are counted alike,
    /// "3 / 10" in both, where the find bar once said "3/10" in English and
    /// "-/10" while no match was current.
    @Test func position_isSpacedInBothLanguages() {
        #expect(CommonText.position(3, of: 10).resolved(in: en) == "3 / 10")
        #expect(CommonText.position(3, of: 10).resolved(in: ja) == "3 / 10")
        #expect(CommonText.noPosition(of: 10).resolved(in: en) == "- / 10")
        #expect(CommonText.noPosition(of: 10).resolved(in: ja) == "- / 10")
    }

    /// The review's find bar counts its matches as the pane's does, where
    /// it once said "3/10".
    @Test func reviewFindBar_countsAsThePaneFindBarDoes() {
        let summary = ReviewFindBar.summary(isActive: true, hitCount: 10, position: 2)
        #expect(summary.resolved(in: en) == "3 / 10")
        #expect(summary.resolved(in: ja) == "3 / 10")
        #expect(summary.resolved(in: en) == CommonText.position(3, of: 10).resolved(in: en))
        #expect(ReviewFindBar.summary(isActive: false, hitCount: 10, position: 2).resolved(in: en).isEmpty)
        let empty = ReviewFindBar.summary(isActive: true, hitCount: 0, position: 0)
        #expect(empty.resolved(in: en) == "No matches")
        #expect(empty.resolved(in: ja) == "一致なし")
    }

    /// The new worktree sheet's row and the project settings' menu name one
    /// choice, so they are one resource with one translator comment.
    @Test func placement_isOneResourceForBothSheets() throws {
        let sheetLabel = try #require(NewSessionSheet.rowLabels.last)
        #expect(sheetLabel.key == ProjectSettingsText.placement.key)
        #expect(sheetLabel.resolved(in: en) == "Placement")
        #expect(sheetLabel.resolved(in: ja) == "場所")
    }

    /// Under a minute, the sidebar, Needs Attention, and the notification
    /// history say one word: "now", 「今」.
    @Test func underAMinute_isOneWordInEveryTimeColumn() {
        let arrived = Date(timeIntervalSinceReferenceDate: 0)
        let entry = NotificationEntry.test()
        for locale in [en, ja] {
            let word = CompactTimeText.now(locale: locale)
            #expect(SessionRowFactText.elapsed(since: arrived, now: arrived.addingTimeInterval(59), locale: locale) == word)
            #expect(NeedsAttentionRowView.waitLabel(arrivedAt: arrived, now: arrived.addingTimeInterval(59), locale: locale) == word)
            #expect(NeedsAttentionRowView.waitLabel(arrivedAt: arrived, now: arrived.addingTimeInterval(60), locale: locale) != word)
            let soon = entry.timestamp.addingTimeInterval(59)
            #expect(NotificationHistoryRowText.timeLabel(for: entry, now: soon, locale: locale) == word)
            let later = entry.timestamp.addingTimeInterval(60)
            #expect(NotificationHistoryRowText.timeLabel(for: entry, now: later, locale: locale) != word)
        }
        #expect(CompactTimeText.now(locale: en) == "now")
        #expect(CompactTimeText.now(locale: ja) == "今")
    }

    /// Needs Attention's wait rounds down, as the prompt cache's panel does:
    /// 4m 50s has not waited five minutes.
    @Test func needsAttentionWait_roundsDown() {
        let arrived = Date(timeIntervalSinceReferenceDate: 0)
        func wait(_ seconds: TimeInterval, _ locale: Locale) -> String {
            NeedsAttentionRowView.waitLabel(arrivedAt: arrived, now: arrived.addingTimeInterval(seconds), locale: locale)
        }
        #expect(wait(60, en) == "1m")
        #expect(wait(290, en) == "4m")
        #expect(wait(300, en) == "5m")
        #expect(wait(290, ja) == "4分")
        #expect(wait(300, ja) == "5分")
    }
}
