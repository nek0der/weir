// KeyboardShortcutCatalogTests.swift
// Weir — shortcut sheet categories, effective bindings, and search.

import Foundation
import Testing
@testable import Weir

@Suite("KeyboardShortcutCatalog")
@MainActor
struct KeyboardShortcutCatalogTests {

    private func sections(
        keyboard: KeyboardSettings = KeyboardSettings(),
        quickTerminalHotKey: StoredShortcut? = nil,
        locale: Locale = Locale(identifier: "en")
    ) -> [KeyboardShortcutSection] {
        KeyboardShortcutCatalog.sections(keyboard: keyboard, quickTerminalHotKey: quickTerminalHotKey, locale: locale)
    }

    private func entries(_ sections: [KeyboardShortcutSection]) -> [KeyboardShortcutEntry] {
        sections.flatMap(\.entries)
    }

    @Test("Every action with keys appears exactly once, and one without none")
    func sections_coverEveryAction() {
        let defaults = entries(sections()).map(\.id)
        #expect(defaults.contains("action.newWindow"))
        #expect(defaults.contains("action.newWorktree"))
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWindow)
        keyboard.setOverride(StoredShortcut(key: "n", modifiers: [.command]), for: .newTab)
        keyboard = keyboard.normalizedForTest().keyboard
        let rows = entries(sections(keyboard: keyboard))
        let ids = rows.map(\.id)
        #expect(!ids.contains("action.newWindow"))
        #expect(!ids.contains("action.newWorktree"))
        #expect(rows.filter { $0.id == "action.newTab" }.map(\.tokens) == [["⌘", "N"]])
        for action in WeirShortcutAction.allCases {
            let expected = keyboard.shortcut(for: action) == nil ? 0 : 1
            #expect(ids.filter { $0 == "action.\(action.rawValue)" }.count == expected, "\(action.rawValue)")
        }
    }

    @Test("Sections follow category order and never render empty")
    func sections_orderAndNonEmpty() {
        let categories: [WeirShortcutCategory] = [.file, .view, .navigation, .splits, .search, .terminal, .font, .help]
        let expected = categories.map { "category.\($0.rawValue)" }
            + ["fixed.review", "fixed.window", "fixed.tabsAndWorktrees", "fixed.app"]
        let all = sections()
        #expect(all.map(\.id) == expected)
        #expect(all.allSatisfy { !$0.entries.isEmpty })

        var keyboard = KeyboardSettings()
        for action in WeirShortcutAction.allCases where action.category == .help {
            keyboard.unassign(action)
        }
        let withoutHelp = sections(keyboard: keyboard)
        #expect(withoutHelp.map(\.id) == expected.filter { $0 != "category.\(WeirShortcutCategory.help.rawValue)" })
        #expect(withoutHelp.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("A user override shows the rebound keys, not the default")
    func sections_reflectOverride() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = StoredShortcut(key: "n", modifiers: [.command, .control])
        let row = entries(sections(keyboard: keyboard)).first { $0.id == "action.newTab" }
        #expect(row?.tokens == ["⌃", "⌘", "N"])
    }

    @Test func theSheet_listsTheCommandClick_inAWindowSection() throws {
        let window = try #require(sections(locale: Locale(identifier: "ja")).first { $0.id == "fixed.window" })
        // ⌘-click has no key to bind, so the sheet is where it is found.
        #expect(window.title == "ウインドウ")
        #expect(window.entries.map(\.title) == ["新規ウインドウで開く"])
        #expect(window.entries.map(\.tokens) == [["⌘", "クリック"]])
        #expect(window.entries.first?.searchAliases.contains("Open in New Window") == true)
        let english = try #require(sections().first { $0.id == "fixed.window" })
        #expect(english.title == "Window")
        #expect(english.entries.map(\.tokens) == [["⌘", "Click"]])
    }

    @Test func theSheet_listsNumberJumps_forcedNewline_andSettings() throws {
        let numbers = try #require(sections(locale: Locale(identifier: "ja")).first { $0.id == "fixed.tabsAndWorktrees" })
        // ⌃⌘1–9 goes to the nth working worktree the sidebar shows.
        #expect(numbers.title == "タブとワークツリー")
        #expect(numbers.entries.map(\.id) == ["fixed.goToTab", "fixed.goToWorktree"])
        #expect(numbers.entries.map(\.title) == ["タブ 1〜9 へ移動", "ワークツリー 1〜9 へ移動"])
        #expect(numbers.entries.map(\.tokens) == [["⌘", "1–9"], ["⌃", "⌘", "1–9"]])
        #expect(numbers.entries.last?.searchAliases.contains("Go to Worktree 1–9") == true)
        // ⌘[ ⌘] are listed under the same word.
        let navigation = try #require(sections().first { $0.id == "category.\(WeirShortcutCategory.navigation.rawValue)" })
        let titles = navigation.entries.map(\.title)
        #expect(titles.contains("Next Worktree"))
        #expect(titles.contains("Previous Worktree"))

        let terminal = try #require(sections().first { $0.id == "category.\(WeirShortcutCategory.terminal.rawValue)" })
        let newline = try #require(terminal.entries.first { $0.id == "fixed.insertNewline" })
        #expect(newline.title == "Insert Newline")
        #expect(newline.tokens == ["⇧", "⏎"])

        let app = try #require(sections().first { $0.id == "fixed.app" })
        #expect(app.entries.map(\.id) == ["fixed.settings"])
        #expect(app.entries.map(\.tokens) == [["⌘", ","]])
    }

    @Test("The palette's restore entry is listed under the palette's keys")
    func sections_listThePalettesRestoreEntry() throws {
        let view = try #require(sections(locale: Locale(identifier: "ja"))
            .first { $0.id == "category.\(WeirShortcutCategory.view.rawValue)" })
        let restore = try #require(view.entries.first { $0.id == "palette.restoreTurn" })
        #expect(restore.title == "このターンの前にコードを復元…")
        #expect(restore.tokens == ["⇧", "⌘", "P"])

        var keyboard = KeyboardSettings()
        keyboard.setOverride(StoredShortcut(key: "u", modifiers: [.control, .option]), for: .commandPalette)
        let rebound = entries(sections(keyboard: keyboard)).filter { $0.id == "palette.restoreTurn" }
        #expect(rebound.map(\.tokens) == [["⌃", "⌥", "U"]])
        keyboard.unassign(.commandPalette)
        #expect(!entries(sections(keyboard: keyboard)).contains { $0.id == "palette.restoreTurn" })
    }

    private struct ReviewShortcut {
        let id: String
        let tokens: [String]
        let character: String
        let action: ReviewTableKey
    }

    @Test func reviewRows_nameTheKeysAndActionsTheDiffUses() throws {
        let review = try #require(sections(locale: Locale(identifier: "ja")).first { $0.id == "fixed.review" })
        #expect(review.title == "レビュー")
        let keys: [ReviewShortcut] = [
            .init(id: "nextLine", tokens: ["J"], character: "j", action: .nextLine),
            .init(id: "previousLine", tokens: ["K"], character: "k", action: .previousLine),
            .init(id: "extendDown", tokens: ["⇧", "J"], character: "J", action: .extendNextLine),
            .init(id: "extendUp", tokens: ["⇧", "K"], character: "K", action: .extendPreviousLine),
            .init(id: "nextHunk", tokens: ["]"], character: "]", action: .nextHunk),
            .init(id: "previousHunk", tokens: ["["], character: "[", action: .previousHunk),
            .init(id: "oldSide", tokens: ["H"], character: "h", action: .oldSide),
            .init(id: "newSide", tokens: ["L"], character: "l", action: .newSide),
            .init(id: "nextFile", tokens: ["N"], character: "n", action: .nextFile),
            .init(id: "previousFile", tokens: ["P"], character: "p", action: .previousFile),
            .init(id: "comment", tokens: ["C"], character: "c", action: .comment),
            .init(id: "viewed", tokens: ["V"], character: "v", action: .markViewed),
            .init(id: "open", tokens: ["O"], character: "o", action: .openInEditor)
        ]
        #expect(review.entries.map(\.id) == keys.map { "review.\($0.id)" })
        #expect(review.entries.map(\.tokens) == keys.map(\.tokens))
        #expect(Set(ReviewTableKey.byCharacter.keys) == Set(keys.map(\.character)))
        for key in keys {
            #expect(ReviewTableKey.byCharacter[key.character] == key.action)
        }

        let nextHunk = try #require(review.entries.first { $0.id == "review.nextHunk" })
        #expect(nextHunk.title == "次のハンク")
        #expect(nextHunk.searchAliases.contains("Next Hunk"))
    }

    @Test("Quick terminal hotkey is listed only when one is set")
    func sections_quickTerminalHotKey() throws {
        #expect(!sections().contains { $0.id == "fixed.systemWide" })
        let hotKey = StoredShortcut(key: "`", modifiers: [.control])
        let system = try #require(sections(quickTerminalHotKey: hotKey).last)
        #expect(system.id == "fixed.systemWide")
        #expect(system.title == "System-wide")
        #expect(system.entries.map(\.id) == ["fixed.quickTerminal"])
        #expect(system.entries.map(\.tokens) == [["⌃", "`"]])
    }

    @Test("Search matches the label and drops sections left empty")
    func filter_matchesLabel() {
        let filtered = KeyboardShortcutCatalog.filter(sections(), query: "split right")
        #expect(filtered.count == 1)
        #expect(filtered.first?.entries.map(\.id) == ["action.splitRight"])
    }

    @Test("Search matches the glyph form in HIG order and with ⌘ first")
    func filter_matchesGlyphs() {
        for query in ["⇧⌘T", "⌘⇧T"] {
            let filtered = KeyboardShortcutCatalog.filter(sections(), query: query)
            let ids = entries(filtered).map(\.id)
            #expect(ids == ["action.reopenClosedTab"], "query \(query)")
        }
    }

    @Test("Empty or whitespace query returns everything")
    func filter_emptyQuery() {
        let all = sections()
        #expect(KeyboardShortcutCatalog.filter(all, query: "") == all)
        #expect(KeyboardShortcutCatalog.filter(all, query: " \t\n ") == all)
    }

    @Test("No match yields no sections rather than bare headers")
    func filter_noMatch() {
        #expect(KeyboardShortcutCatalog.filter(sections(), query: "zzzzqqqq").isEmpty)
    }

    @Test func newWindow_hasControlCommandN_inTheFileSection() throws {
        // ⌘N is New Worktree… and ⇧⌘N the notification history.
        #expect(WeirShortcutAction.newWindow.defaultShortcut == StoredShortcut(key: "n", modifiers: [.command, .control]))
        #expect(WeirShortcutAction.newWindow.category == .file)
        #expect(WeirShortcutAction.newWindow.ghosttyAction == nil)
        let file = try #require(sections().first { $0.id == "category.\(WeirShortcutCategory.file.rawValue)" })
        #expect(file.entries.filter { $0.id == "action.newWindow" }.map(\.tokens) == [["⌃", "⌘", "N"]])
        // No other action's default shares the keys.
        let others = WeirShortcutAction.allCases.filter { $0 != .newWindow }.compactMap(\.defaultShortcut)
        #expect(!others.contains(StoredShortcut(key: "n", modifiers: [.command, .control])))
    }
}
