// AgentStateMark.swift
// Weir — the glyph that says what an agent in a pane is doing.
//
// The pane headers draw the state with the one state glyph the sidebar, the
// lists, and the menu bar share, so a state is the same icon wherever it
// shows. This view keeps the hover text and the spoken label beside it.

import SwiftUI

struct AgentStateMark: View {
    let kind: StateGlyph.Kind
    /// Hover text, which a header builds from the state's name and what
    /// the agent is doing. It is also the spoken label; without it the
    /// mark says the state's name alone.
    var tooltip: String?

    @Environment(\.locale) private var locale

    var body: some View {
        let label = tooltip ?? kind.name.resolved(in: locale)
        // One slot wide (`WeirLayout.stateMarkSlot`), like the prompt cache
        // clock beside it.
        StateGlyph(kind: kind)
            .frame(width: WeirLayout.stateMarkSlot, height: WeirLayout.stateMarkSlot)
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }
}
