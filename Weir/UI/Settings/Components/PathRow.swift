// PathRow.swift
// Weir — one way to show a folder's path in a form row, choose it, and reveal it in Finder.

import SwiftUI

/// A folder path as every settings row shows it: the folder icon,
/// which reveals it in Finder, then the path with the home folder as `~`,
/// monospaced and cut in its middle with the whole path as the tooltip, and
/// "Choose…" where the path can be changed. A path that is not there says
/// so. The context menu reveals it or copies it. A folder yet to be made
/// (a new worktree's) reveals the nearest folder that is.
struct PathRow: View {
    let label: LocalizedStringResource
    /// Nil while none is chosen: the row then offers only "Choose…".
    let url: URL?
    /// Whether the folder is expected to exist now. A preview of where a
    /// new worktree will go is not, and is not called missing.
    var isExpectedToExist = true
    var onChoose: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: WeirLayout.Supervision.spaceS) {
                if let url {
                    Button {
                        FinderReveal.select(url)
                    } label: {
                        Image(systemName: MenuItemLabel.showInFinder.symbol)
                    }
                    .buttonStyle(.borderless)
                    .help(Text(MenuItemLabel.showInFinder.title))
                    .accessibilityLabel(Text(MenuItemLabel.showInFinder.title))
                    Text(verbatim: PathFormatting.abbreviateHome(url.path))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(Text(verbatim: url.path))
                    if isExpectedToExist, !FileManager.default.fileExists(atPath: url.path) {
                        Text("Not Found")
                            .foregroundStyle(SupervisionTokens.waitingText.color)
                    }
                }
                if let onChoose {
                    Button("Choose…", action: onChoose)
                }
            }
        } label: {
            Text(label)
        }
        .contextMenu {
            if let url {
                Button(MenuItemLabel.showInFinder.title) {
                    FinderReveal.select(url)
                }
                Button("Copy Path") {
                    SystemPasteboard.copy(url.path)
                }
            }
        }
    }
}
