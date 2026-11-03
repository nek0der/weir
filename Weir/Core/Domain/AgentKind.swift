// AgentKind.swift
// Weir — identifier for which AI agent is driving a pane. Lives next to
// `AgentState` because anywhere we surface "which agent finished /
// is waiting", we need both pieces together.

import Foundation

package enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claude
    case codex
    case antigravity
    case opencode

    /// What a pane types to start the agent. The name resolves to Weir's
    /// shim on the pane's `PATH`, which installs the hooks and finds the
    /// real binary.
    package var launchCommand: String {
        switch self {
        case .claude, .codex, .opencode: rawValue
        case .antigravity: "agy"
        }
    }

    /// The arguments that resume one of the agent's sessions, which "Resume
    /// Same Conversation" and the resume at app launch both type into the
    /// pane's shell: the session's resume alone, with no fresh start after
    /// it and its errors left on screen, so a failure is the person's to read
    /// rather than a new conversation in its place. Each names the session by
    /// its id rather than "the latest", because several panes in one folder
    /// each want their own conversation, and `--continue` or `--last` would
    /// collapse them into one. The caller checks the id
    /// (`AgentKind.strictResumeCommand`).
    package func strictResumeArguments(sessionId: String) -> String {
        switch self {
        case .claude: "claude --resume \(sessionId)"
        case .codex: "codex resume \(sessionId)"
        case .antigravity: "agy --conversation \(sessionId)"
        case .opencode: "opencode --session \(sessionId)"
        }
    }
}
