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
    case kiro

    /// The agent's command name, which resolves to Weir's shim on the
    /// pane's `PATH`; the shim installs the hooks and finds the real binary.
    /// What Weir types to start a conversation is `startCommand`.
    package var launchCommand: String {
        switch self {
        case .claude, .codex, .opencode: rawValue
        case .antigravity: "agy"
        case .kiro: "kiro-cli"
        }
    }

    /// What Weir types to start a new conversation: the "+" menu, the
    /// palette, and "Start New Conversation". Kiro's hooks load only under
    /// its v3 engine, which a person who used Kiro 2 may not have chosen
    /// yet, so Weir's own launches ask for it; a `kiro-cli` the person types
    /// keeps Kiro's own choice.
    package var startCommand: String {
        switch self {
        case .claude, .codex, .antigravity, .opencode: launchCommand
        case .kiro: "kiro-cli --v3"
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
    /// (`AgentKind.strictResumeCommand`). The command is `launchCommand`, so
    /// the resume starts what a new conversation starts: the shim.
    package func strictResumeArguments(sessionId: String) -> String {
        "\(launchCommand) \(resumeOption) \(sessionId)"
    }

    /// The folder in the user's home a provider keeps its own files in when
    /// nothing moves it (`CODEX_HOME` and the like): its id behind a dot, as
    /// `ProviderDescriptor::default_home` names it on the Rust side. Taken
    /// by id, as the descriptors are keyed.
    package static func homeFolderName(ofProvider id: String) -> String {
        "." + id
    }

    /// `homeFolderName(ofProvider:)` for this kind.
    package var homeFolderName: String {
        Self.homeFolderName(ofProvider: rawValue)
    }

    /// What names the session to resume on the agent's command line.
    private var resumeOption: String {
        switch self {
        case .claude: "--resume"
        case .codex: "resume"
        case .antigravity: "--conversation"
        case .opencode: "--session"
        // We ask for v3 because Kiro loads our hooks only under that engine
        // (`startCommand`).
        case .kiro: "--v3 --resume-id"
        }
    }
}
