// ReceiptRunsText.swift
// Weir — a line drawn run by run: its words, a receipt's additions and removals, a check's marks.

import SwiftUI

/// A line of `ReceiptRun`s in one text, so it is cut as one line.
/// No run's words are looked up again for translation: each run is already
/// in the person's language, and the pieces are joined through a key with
/// no words of its own (`%@%@`). The decision bar, the restore strip, and the
/// changes panel draw their runs here, so a count of lines or a failed
/// check reads the same wherever it is.
///
/// The line's own words (`plain`, and `emphasized` in semibold while
/// `showsEmphasis`) take `base`; quiet words are muted; additions and
/// removals take the diff colors; a failed check's ✗ is red; a quiet mark
/// (a check run on part of the suite) is a step quieter than muted.
struct ReceiptRunsText: View {
    let runs: [ReceiptRun]
    let size: WeirFont.Supervision.Size
    var base = SupervisionTokens.muted.color
    /// Off where the line reads evenly (the decision bar at rest).
    var showsEmphasis = true

    var body: some View {
        ReceiptRunRenderer.text(runs, size: size, style: .receipt(base: base, showsEmphasis: showsEmphasis))
    }
}

/// Turns `ReceiptRun`s into one line of text. `ReceiptRunsText` and the
/// notification history's rows both build their lines here, so a count of
/// lines or a failed check takes the same colors in either; what differs
/// between them is a named style rather than a second copy of the rule.
enum ReceiptRunRenderer {
    enum Style: Equatable {
        /// This is the receipt as the decision bar, the restore strip, and
        /// the changes panel draw it: the line's own words in `base`, and
        /// `emphasized` and emphasized counts in semibold while
        /// `showsEmphasis`.
        case receipt(base: ThemedStyle, showsEmphasis: Bool)
        /// These are the facts at the end of a notification's row: every word is
        /// muted and regular, so what the row is about stays what reads first;
        /// only the counts' diff colors and a failed check's red remain.
        case mutedFacts
    }

    /// The runs joined as `Text` pieces rather than an attributed string,
    /// whose color attribute takes only a `Color`: a piece's style follows
    /// the terminal theme as it is drawn (`ThemedStyle`).
    static func text(_ runs: [ReceiptRun], size: WeirFont.Supervision.Size, style: Style) -> Text {
        runs.reduce(Text(verbatim: "")) { line, run in
            Text("\(line)\(text(run, size: size, style: style))")
        }
    }

    private static func text(_ run: ReceiptRun, size: WeirFont.Supervision.Size, style: Style) -> Text {
        let (color, isSemibold) = appearance(of: run.role, style: style)
        // Figures keep one width, so counts that change do not shift what
        // follows them.
        return Text(verbatim: run.text)
            .foregroundStyle(color)
            .font(.supervision(size, weight: isSemibold ? .semibold : .regular).monospacedDigit())
    }

    /// Returns the color and weight a run of `role` takes in `style`.
    static func appearance(of role: ReceiptRun.Role, style: Style) -> (color: ThemedStyle, isSemibold: Bool) {
        switch style {
        case let .receipt(base, showsEmphasis):
            switch role {
            case .emphasized: (base, showsEmphasis)
            case .plain: (base, false)
            case .quiet: (SupervisionTokens.muted.color, false)
            case let .added(isEmphasized): (SupervisionTokens.added.color, isEmphasized && showsEmphasis)
            case let .removed(isEmphasized): (SupervisionTokens.removed.color, isEmphasized && showsEmphasis)
            case .failed: (SupervisionTokens.stoppedText.color, false)
            case .quietMark: (SupervisionTokens.closedMark.color, false)
            }
        case .mutedFacts:
            switch role {
            case .added: (SupervisionTokens.added.color, false)
            case .removed: (SupervisionTokens.removed.color, false)
            case .failed: (SupervisionTokens.stoppedText.color, false)
            case .emphasized, .plain, .quiet, .quietMark: (SupervisionTokens.muted.color, false)
            }
        }
    }
}
