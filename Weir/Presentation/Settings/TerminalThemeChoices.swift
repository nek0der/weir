// TerminalThemeChoices.swift
// Weir — the themes Settings offers for the light or the dark side of the terminal, in the order it lists them.

import Foundation
import WeirDomain

/// One row of a terminal theme picker after the default row.
struct TerminalThemeChoice: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A theme file the catalog found. `isNameShared` is true when
        /// another listed theme has the same name, so the row names its
        /// folder too.
        case theme(isNameShared: Bool)
        /// The current choice, which no folder holds now. Listed so the
        /// picker still shows what is chosen.
        case missing
    }

    var ref: TerminalThemeRef
    var kind: Kind

    var id: String {
        "\(ref.origin.rawValue)/\(ref.name)"
    }
}

/// Which themes a side's picker lists, and how a stored choice maps onto
/// them.
enum TerminalThemeChoices {
    /// The rows for `side` after the default row.
    ///
    /// A theme is listed on the side its background puts it. A file whose
    /// background could not be read is not listed: Weir uses a theme from
    /// outside the bundle only by that background, so choosing one would
    /// only fall back to the default. The bundled default for `side` is the
    /// default row and is not listed again. The current choice is always
    /// listed, even on the other side's list or when no folder has it; it
    /// is `.missing` only when the catalog was read and does not have it.
    /// `entries` is `nil` while the catalog has not been read.
    static func choices(
        entries: [TerminalThemeCatalog.Entry]?,
        side: TerminalThemeBrightness,
        selected: TerminalThemeRef?
    ) -> [TerminalThemeChoice] {
        let defaultRef = GhosttyConfigBridge.defaultThemeRef(for: side)
        let all = entries ?? []
        var listed = all.filter { entry in
            !isSame(entry.ref, defaultRef) && entry.brightness == side
        }
        if let selected, !isSame(selected, defaultRef), !listed.contains(where: { isSame($0.ref, selected) }),
           let entry = all.first(where: { isSame($0.ref, selected) })
        {
            listed.append(entry)
        }
        var nameCounts: [String: Int] = [:]
        for entry in listed {
            nameCounts[entry.ref.name, default: 0] += 1
        }
        var rows = listed
            .sorted { lhs, rhs in
                switch lhs.ref.name.localizedStandardCompare(rhs.ref.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: originOrder(lhs.ref.origin) < originOrder(rhs.ref.origin)
                }
            }
            .map { TerminalThemeChoice(ref: $0.ref, kind: .theme(isNameShared: nameCounts[$0.ref.name, default: 0] > 1)) }
        if let selected, !isSame(selected, defaultRef), !rows.contains(where: { isSame($0.ref, selected) }) {
            let plain = TerminalThemeRef(name: selected.name, origin: selected.origin)
            let kind: TerminalThemeChoice.Kind = entries == nil ? .theme(isNameShared: false) : .missing
            rows.insert(TerminalThemeChoice(ref: plain, kind: kind), at: 0)
        }
        return rows
    }

    /// The picker's tag for a stored choice: `nil` for no choice and for the
    /// bundled default named explicitly, else the ref with the same name and
    /// folder, without the fields a newer build stored on it, so it matches
    /// a listed row's tag.
    static func tag(for selected: TerminalThemeRef?, side: TerminalThemeBrightness) -> TerminalThemeRef? {
        guard let selected, !isSame(selected, GhosttyConfigBridge.defaultThemeRef(for: side)) else { return nil }
        return TerminalThemeRef(name: selected.name, origin: selected.origin)
    }

    /// Whether two refs name the same file. `==` also compares the fields a
    /// newer build stored, which do not change the file.
    static func isSame(_ lhs: TerminalThemeRef, _ rhs: TerminalThemeRef) -> Bool {
        lhs.name == rhs.name && lhs.origin == rhs.origin
    }

    private static func originOrder(_ origin: TerminalThemeOrigin) -> Int {
        TerminalThemeOrigin.allCases.firstIndex(of: origin) ?? 0
    }
}
