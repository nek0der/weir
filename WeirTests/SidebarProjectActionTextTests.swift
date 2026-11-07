// SidebarProjectActionTextTests.swift
// Weir — the project header's operations on all of its worktrees, in English and Japanese.

import Foundation
import Testing
@testable import Weir

struct SidebarProjectActionTextTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test(arguments: [
        (SidebarProjectActionText.syncWorktrees, "Sync Worktrees", "ワークツリーを同期"),
        (SidebarProjectActionText.showHiddenWorktrees, "Show Hidden Worktrees", "非表示のワークツリーを表示"),
        (SidebarProjectActionText.removeMissingWorktrees, "Remove Missing Worktrees", "見つからないワークツリーをすべて外す")
    ])
    func projectWorktreeActions_haveTheirEnglishAndJapaneseTitles(
        title: LocalizedStringResource,
        english: String,
        japanese: String
    ) {
        #expect(title.resolved(in: Self.english) == english)
        #expect(title.resolved(in: Self.japanese) == japanese)
    }
}
