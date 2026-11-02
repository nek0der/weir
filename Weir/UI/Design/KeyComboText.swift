// KeyComboText.swift
// Weir — a key combination ("⇧⌘P") as text, the one way any surface writes one.

import SwiftUI

/// A key combination shown by itself, as in a cap, at the end of a menu item,
/// or in a recorder. Every such surface draws it through this view, so two
/// combinations with as many keys are as wide wherever they appear. We leave
/// a key named inside a sentence ("Press ⌘W to close") in the sentence's
/// font, because a fixed-width run in the middle of words reads as an error.
///
/// We center each key in a cell of its own. A modifier's cell is as wide as
/// ⇧, the widest of the four, and the last key's cell is as wide as W. In SF
/// Pro alone "⌘W" is half again as wide as "⌘I", so a column of combinations
/// (the palette's rows, the shortcut settings) looked ragged. SF Mono made
/// them even, but it squeezed ⌘ and ⇧ into its narrow advance and they were
/// hard to read, so we keep SF Pro's glyphs and even out the cells instead.
/// A key wider than its cell (⏎, F12) widens the cell rather than being cut.
struct KeyComboText: View {
    let keys: String
    let size: CGFloat
    var weight: Font.Weight = .medium

    /// We size the cells by the widest modifier and the widest letter, so no
    /// common key overflows its cell and changes the combination's width.
    private static let modifierTemplate = "⇧"
    private static let keyTemplate = "W"
    private static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    init(_ keys: String, size: CGFloat, weight: Font.Weight = .medium) {
        self.keys = keys
        self.size = size
        self.weight = weight
    }

    init(_ keys: String, size: WeirFont.Supervision.Size, weight: Font.Weight = .medium) {
        self.init(keys, size: size.rawValue, weight: weight)
    }

    var body: some View {
        let modifierCount = keys.prefix(while: Self.modifiers.contains).count
        let key = String(keys.dropFirst(modifierCount))
        HStack(spacing: 0) {
            ForEach(Array(keys.prefix(modifierCount).enumerated()), id: \.offset) { _, modifier in
                cell(String(modifier), template: Self.modifierTemplate)
            }
            if !key.isEmpty {
                cell(key, template: Self.keyTemplate)
            }
        }
        .font(.system(size: size, weight: weight))
        .lineLimit(1)
        .fixedSize()
        // VoiceOver reads the combination as one name rather than stopping
        // on each cell.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys))
    }

    /// Centers `glyph` in a cell as wide as `template`. We lay the template
    /// under it hidden, so the cell takes the wider of the two and a long key
    /// is never clipped.
    private func cell(_ glyph: String, template: String) -> some View {
        ZStack {
            Text(verbatim: template).hidden()
            Text(verbatim: glyph)
        }
    }
}
