// AgentBrand.swift
// Weir — how each agent's badge looks: its letters, its fill, their color, and its edge.

import WeirDomain

/// Everything that tells one agent's badge from another's, in one value per
/// kind, so the letters a row's text gives (`SessionRowFactText.badge`) and
/// the colors the badge draws (`SessionAgentBadge`) cannot describe two
/// different agents.
/// The colors themselves stay in `SupervisionTokens`, beside the contrast
/// each is held to.
struct AgentBrand: Equatable, Sendable {
    /// What the badge is filled with.
    enum Fill: Equatable, Sendable {
        /// One color.
        case solid(ThemedColor)
        /// Antigravity's logo: its blue under the three colors along its
        /// top (`SessionAgentBadge.antigravityFill`).
        case antigravityMesh
    }

    /// A fixed two-letter abbreviation of the product's name, the same in
    /// every language.
    let letters: String
    let fill: Fill
    /// The letters' color on `fill`.
    let foreground: ThemedColor
    /// The edge inside the badge, for a fill whose contrast with a surface
    /// it sits on is under 3:1 (`SupervisionTokens.claudeEdge`); `nil` draws
    /// none.
    let edge: ThemedColor?

    static func of(_ kind: AgentKind) -> Self {
        switch kind {
        case .claude:
            Self(
                letters: "Cl",
                fill: .solid(SupervisionTokens.claude),
                foreground: SupervisionTokens.badgeForeground,
                edge: SupervisionTokens.claudeEdge
            )
        case .codex:
            Self(
                letters: "Cx",
                fill: .solid(SupervisionTokens.codex),
                foreground: SupervisionTokens.codexBadgeForeground,
                edge: SupervisionTokens.codexEdge
            )
        case .antigravity:
            Self(letters: "Ag", fill: .antigravityMesh, foreground: SupervisionTokens.badgeForeground, edge: nil)
        case .opencode:
            Self(
                letters: "Op",
                fill: .solid(SupervisionTokens.opencode),
                foreground: SupervisionTokens.badgeForeground,
                edge: SupervisionTokens.opencodeEdge
            )
        case .kiro:
            Self(
                letters: "Ki",
                fill: .solid(SupervisionTokens.kiro),
                foreground: SupervisionTokens.badgeForeground,
                edge: SupervisionTokens.kiroEdge
            )
        }
    }
}
