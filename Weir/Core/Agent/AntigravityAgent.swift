// AntigravityAgent.swift
// Weir — concrete `AgentSpec` for the Antigravity CLI: its `AgentKind` case and the `agy --conversation` arguments.

import Foundation
import WeirDomain

enum AntigravityAgent: AgentSpec {
    static var kind: AgentKind {
        .antigravity
    }

    /// `agy --conversation` with the explicit id rather than `--continue`:
    /// two panes in the same folder each want their own conversation.
    static func strictResumeArguments(sessionId: String) -> String {
        "agy --conversation \(sessionId)"
    }
}
