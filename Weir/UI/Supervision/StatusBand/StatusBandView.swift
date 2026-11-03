// StatusBandView.swift
// Weir — the 26pt band along the window's bottom: where the pane in use is, and what runs in it.

import SwiftUI

/// Display only. It stands on the window's ground, under the
/// surfaces, whose lower edges set it apart. When the two sides do not
/// fit, the path before the pane gives way first and loses its left end.
/// The pane's own name stands apart from it and gives way only with the
/// details, among which the folder loses its middle first, so a long
/// folder cannot take the whole band.
struct StatusBandView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionState.self) private var attention
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.locale) private var locale

    var body: some View {
        let model = StatusBandModel(
            StatusBandModel.input(
                session: session,
                window: window,
                attention: attention,
                gridSize: gridSize(ofPane:),
                locale: locale
            ),
            locale: locale
        )
        // One stack, so the priorities rank the leading path, the pane's
        // name, and the details against each other.
        HStack(spacing: 0) {
            if model.crumbs.count > 1 {
                // Cut down to its floor, then gone with the separator after
                // it, rather than left as one letter that reads like a name.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        IdealWidthCap(maxIdealWidth: WeirLayout.Supervision.statusBandLeadingPathMinWidth) {
                            Text(Self.path(model.crumbs.dropLast()))
                                .lineLimit(1)
                                .supervisionTruncation(.breadcrumb)
                        }
                        Text(verbatim: StatusBandModel.crumbSeparator)
                            .fixedSize()
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            Text(Self.path(model.crumbs.suffix(1)))
                .lineLimit(1)
                .supervisionTruncation(.name)
                .layoutPriority(1)
            Spacer(minLength: WeirLayout.Supervision.statusBandSpacing * 2)
            // Each fact on its own, set apart by space rather than dots.
            HStack(spacing: WeirLayout.Supervision.statusBandSpacing) {
                ForEach(Array(model.details.enumerated()), id: \.offset) { _, detail in
                    Text(verbatim: detail.text)
                        .font(detail.isFolder ? .supervisionCode(beside: Self.size) : .supervision(Self.size))
                        .lineLimit(1)
                        .supervisionTruncation(detail.isFolder ? .path : .name)
                        .layoutPriority(detail.isFolder ? 0 : 1)
                }
            }
            .layoutPriority(1)
        }
        .font(.supervision(Self.size))
        .foregroundStyle(SupervisionTokens.muted.color)
        .padding(.horizontal, WeirLayout.Supervision.statusBandInset)
        .frame(height: WeirLayout.Supervision.statusBarHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.spokenLabel))
    }

    /// The band's words.
    private static let size = WeirFont.Supervision.Size.meta

    /// Steps of the path as one line, so they are cut as one: the branch or
    /// folder in the code face, as everywhere a name Git gave is drawn.
    private static func path(_ crumbs: some Collection<StatusBandModel.Crumb>) -> AttributedString {
        crumbs.enumerated().reduce(into: AttributedString()) { line, entry in
            if entry.offset > 0 {
                line += AttributedString(StatusBandModel.crumbSeparator)
            }
            var crumb = AttributedString(entry.element.text)
            if entry.element.isCode {
                crumb.font = .supervisionCode(beside: size)
            }
            line += crumb
        }
    }

    /// Read live from the pane's surface. Reading the two counters first is
    /// what draws the band again when a resize or a font change moves the
    /// grid, since the surface itself is not observed.
    private func gridSize(ofPane paneID: UUID) -> TerminalGridSize? {
        _ = session.terminalGridGeneration
        _ = session.cellSizeGeneration
        return registry.view(for: paneID)?.gridSize
    }
}
