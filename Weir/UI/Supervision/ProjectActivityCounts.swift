// ProjectActivityCounts.swift
// Weir — compact project activity counts for project lists.

import SwiftUI

/// Project counts whose shapes identify attention and running without text chips.
struct ProjectActivityCounts: View {
    let attention: NeedsAttentionCountModel
    let running: Int

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        HStack(spacing: Layout.spaceS) {
            if attention.count > 0 {
                NeedsAttentionMark(model: attention)
            }
            if running > 0 {
                HStack(spacing: Layout.spaceSnug) {
                    RunningArc(size: Layout.sidebarHeaderMarkSize, isTurning: false)
                        .frame(width: Layout.sidebarHeaderMarkSize, height: Layout.sidebarHeaderMarkSize)
                    Text(verbatim: String(running))
                        .monospacedDigit()
                }
                .foregroundStyle(SupervisionTokens.muted.color)
            }
        }
        .font(.supervision(.meta))
        .fixedSize()
        // The owning row supplies the full counts and breakdown once.
        .accessibilityHidden(true)
    }
}
