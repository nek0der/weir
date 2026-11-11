// AgentResumeCommandBuilder.swift
// Weir — the commands that start or resume an agent in a pane, for any `AgentKind`.

import Foundation
import WeirDomain

/// The resume typed into a restored pane at launch: the session and the
/// command, so the stop ledger can watch the one the command resumes
/// (`StopLedgerStore.markResumingAtLaunch`).
struct AgentResume: Equatable, Sendable {
    let provider: AgentKind
    let sessionID: String
    let cwd: String?
    let command: String
}

enum AgentResumeCommandBuilder {
    /// Decide whether `paneID` inside `tab` should auto-launch a
    /// resumed `kind` session at surface-mount time. Returns the shell
    /// command to feed into `SurfaceView.initialCommand`, or `nil` if
    /// no auto-resume should fire.
    ///
    /// Conditions for a non-nil return:
    /// 1. `tab.agentSessions[kind][paneID]` is set with a
    ///    non-empty `sessionId`. Each split-leaf carries its own
    ///    session so two panes running the same agent concurrently
    ///    each resume independently.
    /// 2. The user / demo fixture hasn't already staged a command
    ///    for this pane in `tab.initialCommands` — that slot is the
    ///    explicit override and we never clobber it.
    /// 3. The projection named this provider in
    ///    `tab.agentResumeCandidates[paneID]`. Which provider yields when
    ///    two have a hint for one pane is a rule, and the rules live on the
    ///    other side of the boundary; this side only reads the answer.
    static func initialCommand(_ kind: AgentKind, for tab: Tab, paneID: UUID) -> String? {
        resume(kind, for: tab, paneID: paneID)?.command
    }

    /// `initialCommand`, with the session it resumes.
    static func resume(_ kind: AgentKind, for tab: Tab, paneID: UUID) -> AgentResume? {
        // An unresolved tmux restore hint is not permission to create a
        // duplicate native invocation while its original runtime survives.
        guard tab.tmuxBindings[paneID] == nil else { return nil }
        guard let info = tab.agentSessions[kind]?[paneID],
              !info.sessionId.isEmpty
        else {
            return nil
        }
        if let existing = tab.initialCommands[paneID], !existing.isEmpty {
            return nil
        }
        guard tab.agentResumeCandidates[paneID]?.contains(kind) == true,
              let command = resumeCommand(kind, sessionId: info.sessionId, cwd: info.cwd)
        else { return nil }
        return AgentResume(provider: kind, sessionID: info.sessionId, cwd: info.cwd, command: command)
    }

    /// The resume `paneID` runs: that of the first agent in `AgentKind`'s
    /// order that has one. We walk the cases rather than name them, so an
    /// agent added there is resumed too; the order is the one the chain
    /// always tried them in, Claude first.
    static func firstResume(for tab: Tab, paneID: UUID) -> AgentResume? {
        for kind in AgentKind.allCases {
            if let resume = resume(kind, for: tab, paneID: paneID) {
                return resume
            }
        }
        return nil
    }

    /// The strict resume (`AgentKind.strictResumeCommand`), as "Resume
    /// Same Conversation" types it: no fresh agent after a resume that
    /// fails, since a relaunch is no reason to start a new conversation in
    /// the old one's place; the failure stays on screen, and a
    /// new conversation is the person's own "Start New Conversation". `nil`
    /// for an id that is not a session's (the state file is read, not
    /// trusted) or a folder with a control character in its name, which the
    /// typed command would carry to the line editor as a key: no resume
    /// then, rather than one somewhere else.
    static func resumeCommand(_ kind: AgentKind, sessionId: String, cwd: String? = nil) -> String? {
        kind.strictResumeCommand(sessionId: sessionId, cwd: cwd)
    }
}

extension AgentKind {
    /// The agent started anew, in `cwd` when one is given: the command a
    /// stop's "Start New Conversation" types. Refused, as the resume
    /// is, for a folder with a control character in its name.
    func newConversationCommand(cwd: String?) -> String? {
        Self.typed(startCommand, in: cwd)
    }

    /// The strict resume of this agent, in `cwd` when one is known: the
    /// folder the conversation was in, which Claude requires and Codex
    /// would otherwise resume somewhere else. `&&`, so a folder that is
    /// gone starts nothing. `nil` for an id that is not a session's, or a
    /// folder with a control character in its name, which the typed
    /// command would carry to the line editor as a key.
    func strictResumeCommand(sessionId: String, cwd: String? = nil) -> String? {
        guard AgentSessionIDValidator.isStrictlyValid(sessionId) else { return nil }
        return Self.typed(strictResumeArguments(sessionId: sessionId), in: cwd)
    }

    /// `command` as a pane types it in `cwd`: after a quoted `cd` and `&&`
    /// when a folder is given, alone when none is. `nil` for a folder with a
    /// control character in its name, which the typed line would carry to
    /// the line editor as a key. Both commands go through here, so a new
    /// conversation and a resume refuse and quote a folder alike.
    private static func typed(_ command: String, in cwd: String?) -> String? {
        if let cwd, cwd.containsTypedControl {
            return nil
        }
        guard let cwd, !cwd.isEmpty else { return command }
        return "cd \(ShellQuote.single(cwd)) && \(command)"
    }
}
