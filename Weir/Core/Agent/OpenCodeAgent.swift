// OpenCodeAgent.swift
// Weir — concrete `AgentSpec` for OpenCode: its `AgentKind` case and the `opencode --session` arguments.

import Foundation
import WeirDomain

enum OpenCodeAgent: AgentSpec {
    static var kind: AgentKind {
        .opencode
    }

    /// `opencode --session` with the explicit id rather than `--continue`: two
    /// panes in the same folder each want their own session.
    static func strictResumeArguments(sessionId: String) -> String {
        "opencode --session \(sessionId)"
    }
}
