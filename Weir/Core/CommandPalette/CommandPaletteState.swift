// CommandPaletteState.swift
// Weir — transient state for the command palette overlay.

import Foundation
import Observation
import WeirDomain

@MainActor
@Observable
final class CommandPaletteState {
    var query: String = ""
    var selectedIndex: Int = 0
    /// Deferred initial query. Set before the view mounts so
    /// `onAppear` can apply it after the TextField is ready,
    /// avoiding the full-text-selection that comes from setting
    /// the value before mount.
    var initialQuery: String?
    var results: [ScoredItem] = []
    var allItems: [CommandPaletteItem] = []
    /// The language the palette's rows are resolved in, fixed for the
    /// palette's lifetime like `allItems`; see `CommandPaletteCatalog`.
    let locale: Locale
    /// The window the palette opened in. Its dropdown draws there and its
    /// chosen row runs there, whichever window the field was in.
    let windowID: WindowID

    init(locale: Locale, windowID: WindowID) {
        self.locale = locale
        self.windowID = windowID
    }

    struct ScoredItem: Identifiable, Equatable {
        let item: CommandPaletteItem
        let matchedIndices: [Int]
        let score: Int

        var id: String {
            item.id
        }
    }

    /// The active prefix mode, derived from the current query.
    var activePrefix: PalettePrefix? {
        PalettePrefix.from(query).prefix
    }

    /// Placeholder text for the search field, changes per mode.
    var placeholder: LocalizedStringResource {
        activePrefix?.placeholder ?? "Type a command or search…"
    }

    /// Single source of truth for filtering + ranking. Called on every
    /// query change and once at open time (with empty query).
    func applyFilter(query: String, frecencyStore: FrecencyStore?) {
        let (prefix, filterQuery) = PalettePrefix.from(query)

        // Help mode: show all available prefixes.
        if prefix == .help {
            results = PalettePrefix.allCases.map { mode in
                ScoredItem(
                    item: CommandPaletteItem(
                        id: "help.\(mode.character)",
                        category: .actions,
                        title: String(mode.character),
                        subtitle: mode.description.resolved(in: locale),
                        icon: "questionmark.circle",
                        shortcutDisplay: nil,
                        action: .insertPrefix(mode)
                    ),
                    matchedIndices: [],
                    score: 0
                )
            }
            selectedIndex = 0
            return
        }

        // Filter items by prefix category.
        let candidates: [CommandPaletteItem] = if let prefix {
            allItems.filter { prefix.matchesItem($0) }
        } else {
            allItems
        }

        if filterQuery.isEmpty {
            results = candidates
                .sorted { (frecencyStore?.score(for: $0.id) ?? 0) > (frecencyStore?.score(for: $1.id) ?? 0) }
                .map { ScoredItem(item: $0, matchedIndices: [], score: 0) }
        } else {
            results = candidates.compactMap { item -> ScoredItem? in
                let titleResult = FuzzyMatch.score(query: filterQuery, candidate: item.title)
                let aliasResult = item.searchAlias.flatMap {
                    FuzzyMatch.score(query: filterQuery, candidate: $0)
                }
                guard let best = [titleResult, aliasResult]
                    .compactMap(\.self)
                    .max(by: { $0.score < $1.score })
                else { return nil }
                let frecency = (frecencyStore?.score(for: item.id) ?? 0) * 10
                let combined = best.score + Int(frecency)
                // A score can be below zero (a long gap), so a missing alias
                // is no score at all rather than zero.
                let titleWonOrTied = titleResult.map { title in
                    aliasResult.map { title.score >= $0.score } ?? true
                } ?? false
                let indices = titleWonOrTied ? best.matchedIndices : []
                return ScoredItem(item: item, matchedIndices: indices, score: combined)
            }
            .sorted { $0.score > $1.score }
        }
        results = Self.inDisplayOrder(results)
        selectedIndex = 0
    }

    /// One category's run of `results`, as the dropdown heads and lists it.
    struct Section {
        let category: CommandPaletteCategory
        /// The index in `results` of the section's first row.
        let startIndex: Int
        let items: [ScoredItem]
    }

    /// `results` cut where the category changes. They are already in
    /// category order (`inDisplayOrder`), so a row's place here is its
    /// place in `results`, which Return runs by `selectedIndex`.
    var sections: [Section] {
        var sections: [Section] = []
        var start = 0
        while start < results.count {
            let category = results[start].item.category
            let end = results[start...].firstIndex { $0.item.category != category } ?? results.count
            sections.append(Section(category: category, startIndex: start, items: Array(results[start..<end])))
            start = end
        }
        return sections
    }

    /// The rows in the order the dropdown shows them: by category, and by
    /// rank within one. We keep this order in `results` itself, because the
    /// highlight and Return both go by an index into it, and a list drawn
    /// in another order runs a row that is not the highlighted one.
    static func inDisplayOrder(_ rows: [ScoredItem]) -> [ScoredItem] {
        rows.enumerated()
            .sorted { ($0.element.item.category, $0.offset) < ($1.element.item.category, $1.offset) }
            .map(\.element)
    }

    func moveSelection(up: Bool) {
        if up {
            selectedIndex = max(0, selectedIndex - 1)
        } else {
            selectedIndex = min(results.count - 1, selectedIndex + 1)
        }
    }
}
