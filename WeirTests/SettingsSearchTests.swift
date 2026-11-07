// SettingsSearchTests.swift
// Weir — Settings search: its catalog of destinations, matching and ordering, and keyboard navigation.

import Foundation
import Testing
@testable import Weir

@Suite("SettingsSearchCatalog")
struct SettingsSearchCatalogTests {
    @Test("Every entry has a unique ID")
    func entries_haveUniqueIDs() {
        let ids = SettingsSearchCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Shortcut entries match the action inventory and reveal under Keyboard")
    func entries_includeEveryShortcutAction() {
        let entries = SettingsSearchCatalog.entries.filter { $0.id.hasPrefix("keyboard.shortcut.") }
        let expectedIDs = Set(WeirShortcutAction.allCases.map { "keyboard.shortcut.\($0.rawValue)" })
        #expect(Set(entries.map(\.id)) == expectedIDs)
        #expect(entries.count == expectedIDs.count)
        #expect(entries.allSatisfy { $0.section == .keyboard })
    }

    @Test("Entries cover every Settings category")
    func entries_coverEverySection() {
        let sections = Set(SettingsSearchCatalog.entries.map(\.section))
        #expect(sections == Set(SettingsSection.allCases))
    }

    @Test("Entries retain a stable order inside each category")
    func entries_haveUniqueOrdersWithinSections() {
        for section in SettingsSection.allCases {
            let orders = SettingsSearchCatalog.entries
                .filter { $0.section == section }
                .map(\.order)
            #expect(Set(orders).count == orders.count, "duplicate order in \(section.rawValue)")
        }
    }

    @Test("Major settings and actions reveal in their owning categories", arguments: [
        ("general.display-language", SettingsSection.general),
        ("appearance.theme", .appearance),
        ("font.family", .font),
        ("terminal.scrollback", .terminal),
        ("tabs-and-panes.minimum-pane-size", .tabsAndPanes),
        ("integrations.ghostty-config", .integrations),
        ("review.instructions", .review),
        ("advanced.restore-all-defaults", .advanced)
    ])
    func entries_includeMajorSettingsAndActions(id: String, section: SettingsSection) {
        #expect(SettingsSearchCatalog.entries.first { $0.id == id }?.section == section)
    }
}

@Suite("SettingsSearchIndex")
struct SettingsSearchIndexTests {
    private let english = Locale(identifier: "en")

    @Test("Blank queries have no results")
    func search_blankQuery_returnsNoResults() {
        let index = SettingsSearchIndex(locale: english)
        #expect(index.search(" \n\t ").isEmpty)
    }

    @Test("Localized labels, English fallback, and aliases find their destinations", arguments: [
        ("en", "scrollback", ["terminal.scrollback"]),
        ("ja", "スクロールバック", ["terminal.scrollback"]),
        ("ja", "cursor blink", ["terminal.cursor-blink"]),
        ("en", "json", ["advanced.reveal-settings-file"]),
        ("en", "Ghostty", ["integrations.ghostty-config"]),
        ("en", "tmux", ["integrations.tmux"]),
        ("en", "Retention", ["advanced.turn-retention-days", "advanced.turn-retention-turns"]),
        ("en", "Scratch directory", ["tabs-and-panes.default-working-directory"]),
        ("en", "Diff tool", ["review.external-diff-command"])
    ])
    func search_findsCatalogDestinations(locale: String, query: String, ids: [String]) {
        let index = SettingsSearchIndex(locale: Locale(identifier: locale))
        #expect(index.search(query).map(\.id) == ids)
    }

    @Test("Every token must match, and tokens can match different fields")
    func search_multipleTokens_requiresAllTokens() {
        let entries = [
            SettingsSearchEntry(id: "title-only", section: .general, groupTitle: "General", title: "Display", order: 0),
            SettingsSearchEntry(
                id: "alias-only",
                section: .general,
                groupTitle: "General",
                title: "Option",
                technicalAliases: ["tmux"],
                order: 1
            ),
            SettingsSearchEntry(
                id: "both",
                section: .general,
                groupTitle: "General",
                title: "Display",
                technicalAliases: ["tmux"],
                order: 2
            )
        ]
        let index = SettingsSearchIndex(entries: entries, locale: english)
        #expect(index.search("display tmux").map(\.id) == ["both"])
        #expect(index.search("cursor tmux").isEmpty)
    }

    @Test("Exact, prefix, substring, and keyword matches are ranked")
    func search_ranksMatchesByRelevance() {
        let entries = [
            SettingsSearchEntry(id: "keyword", section: .general, groupTitle: "General", title: "Option", keywords: ["display"], order: 0),
            SettingsSearchEntry(id: "substring", section: .general, groupTitle: "General", title: "Show display options", order: 1),
            SettingsSearchEntry(id: "prefix", section: .general, groupTitle: "General", title: "Display language", order: 2),
            SettingsSearchEntry(id: "exact", section: .general, groupTitle: "General", title: "Display", order: 3)
        ]
        let index = SettingsSearchIndex(entries: entries, locale: english)
        #expect(index.search("display").map(\.id) == ["exact", "prefix", "substring", "keyword"])
    }

    @Test("Category precedes relevance, then equal matches follow display order")
    func search_categoryOrder_matchesGroupedResults() {
        let entries = [
            SettingsSearchEntry(
                id: "terminal-exact",
                section: .terminal,
                groupTitle: "Terminal",
                title: "Match",
                order: 0
            ),
            SettingsSearchEntry(
                id: "general-later",
                section: .general,
                groupTitle: "General",
                title: "Item",
                keywords: ["match"],
                order: 2
            ),
            SettingsSearchEntry(
                id: "general-first",
                section: .general,
                groupTitle: "General",
                title: "Option",
                keywords: ["match"],
                order: 1
            )
        ]
        let index = SettingsSearchIndex(entries: entries, locale: english)
        #expect(index.search("match").map(\.id) == ["general-first", "general-later", "terminal-exact"])
    }
}

@Suite("SettingsSearchNavigation")
struct SettingsSearchNavigationTests {
    private let results = [
        SettingsSearchEntry(id: "first", section: .general, groupTitle: "General", title: "First", order: 0),
        SettingsSearchEntry(id: "second", section: .general, groupTitle: "General", title: "Second", order: 1),
        SettingsSearchEntry(id: "third", section: .general, groupTitle: "General", title: "Third", order: 2)
    ]

    @Test("Arrow selection moves, starts from an end, and clamps", arguments: [
        (nil as String?, 1, "first"),
        (nil, -1, "third"),
        ("missing", 1, "first"),
        ("missing", -1, "third"),
        ("first", 1, "second"),
        ("second", -1, "first"),
        ("second", 1, "third"),
        ("first", -1, "first"),
        ("third", 1, "third")
    ])
    func movedSelection_movesStartsAndClamps(selectedID: String?, delta: Int, expectedID: String) {
        #expect(SettingsSearchNavigation.movedSelection(from: selectedID, by: delta, in: results) == expectedID)
    }

    @Test("Arrow selection stays empty without results")
    func movedSelection_withoutResults_returnsNil() {
        #expect(SettingsSearchNavigation.movedSelection(from: "first", by: 1, in: []) == nil)
    }

    @Test("Submission uses the selection and otherwise falls back to the first result")
    func submittedEntry_usesSelectionOrFirst() {
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: "second", in: results)?.id == "second")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: nil, in: results)?.id == "first")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: "missing", in: results)?.id == "first")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: nil, in: []) == nil)
    }
}
