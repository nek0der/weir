// AutomationProtocol.swift
// Weir — the messages of the agent verification channel (ADR 0005).

#if DEBUG && WEIR_AUTOMATION

    import Foundation

    /// The wire format: one JSON object per line each way. The first request on
    /// a connection is `hello`, which carries the run's token; nothing else is
    /// answered before it.
    enum AutomationProtocol {
        /// Sent by `hello` and checked by `scripts/check-release-archive.sh`,
        /// which fails a Release binary that contains it. Appears nowhere else,
        /// so its absence says the channel was compiled out.
        static let marker = "weir-automation-protocol/1"

        /// The longest request line we read. A prompt for `paste` fits; a line
        /// past this closes the connection rather than growing a buffer.
        static let maxMessageBytes = 64 * 1024

        /// How many connections one run serves at a time.
        static let maxConnections = 4

        /// The longest any request may wait, whatever its own timeout says.
        static let maxWait: Duration = .seconds(30)
    }

    /// A pane as the caller names it. With the run and the generation, a pane
    /// read before a relaunch, or before its view was made again, is refused
    /// rather than resolved to whatever now holds that ID.
    struct AutomationPaneRef: Codable, Equatable, Sendable {
        let run: String
        let id: UUID
        let generation: Int
    }

    /// What a typing request expects to find in the pane.
    struct AutomationExpectation: Codable, Equatable, Sendable {
        /// The name of the process in front of the pane (`opencode`, `claude`).
        let process: String
        /// The agent's session, when the caller knows it.
        let session: String?
    }

    /// The layers `open` can open. Each maps to what the app's own control for
    /// it does, not to a `WindowCommand` passed through.
    enum AutomationLayer: String, Codable, Sendable, CaseIterable {
        case needsAttention
        case allProjects
        case notificationHistory
        case keyboardShortcuts
        case planUsage
        case review
    }

    /// What holds a window's keyboard, as `state` reports it.
    enum AutomationKeyboardHolder: String, Codable, Sendable {
        /// A terminal pane, where Return runs code: keys go there through
        /// `typeLine`, `paste`, and `submit`, never posted (ADR 0006).
        case pane
        /// One of Weir's own controls: a dropdown, a sheet's field, the
        /// restore strip, a search field.
        case control
    }

    /// What `wait` waits for.
    enum AutomationOutcome: String, Codable, Sendable {
        /// The layer named by `layer` is open in `window`.
        case layerOpen
        /// A turn of the agent in `pane` has ended: one the wait saw running,
        /// whether it began before the wait or after, or one that started and
        /// ended between two looks. A turn that ended before the wait began
        /// does not count (`AutomationController.TurnWatch`).
        case turnEnded
    }

    struct AutomationRequest: Codable, Sendable {
        /// A case is added only as ADR 0005's "Adding an operation" says. The
        /// same pull request adds its handler in `AutomationController`, a
        /// subcommand in `scripts/weir-automation.py`, a check in
        /// `scripts/check-automation.py`, a test in `AutomationChannelTests`
        /// where the logic allows one, its row in the operations table of
        /// `docs/verification-channel.md`, and its use in the `verify-in-app`
        /// skill when agents need it.
        enum Operation: String, Codable, Sendable {
            case hello
            case state
            case open
            case typeLine
            case paste
            case submit
            case wait
            case capture
            case commands
            case command
            case setting
            case quit
            case focus
        }

        let id: String
        let op: Operation
        var token: String?
        var `protocol`: String?
        var window: UUID?
        var layer: AutomationLayer?
        var pane: AutomationPaneRef?
        var text: String?
        var submit: Bool?
        var expect: AutomationExpectation?
        var until: AutomationOutcome?
        var timeout: Double?
        /// `command`: a command palette row's ID (`shortcut.splitRight`,
        /// `settings.open`), or a keyboard shortcut action's name alone.
        var name: String?
        /// `setting`: the setting's key as `settings.json` writes it, with
        /// dots between levels (`font.family`).
        var key: String?
        /// `setting`: the value to set; without one, the setting is read.
        var value: WeirJSONValue?
        /// `quit`: end the run even while agents run in its panes.
        var force: Bool?
        /// `setting`: clear the setting back to unset (`value` cannot say
        /// that: JSON null and a missing value decode alike).
        var unset: Bool?
        /// `command`: run the row as ⌘Return commits it, which opens another
        /// project's row in a new window (`CommandPaletteExecution.opensInNewWindow`).
        var newWindow: Bool?
        /// `capture`: the Settings window rather than a project window.
        var settings: Bool?
    }

    struct AutomationReply: Codable, Sendable {
        enum Status: String, Codable, Sendable {
            case done
            case cancelled
            case failed
            case timedOut
            case notObservable
        }

        let id: String
        let status: Status
        var reason: String?
        var revision: Int?
        var state: AutomationSnapshot?
        /// `typeLine`: whether its Return was sent.
        var submitted: Bool?
        /// `capture`: the window server's number for the window, which
        /// `screencapture -l` takes.
        var windowNumber: Int?
        /// `commands`: what the window's command palette lists now.
        var commands: [AutomationCommandInfo]?
        /// `setting`: the setting's value after the request.
        var value: WeirJSONValue?

        static func failed(_ id: String, _ reason: String) -> AutomationReply {
            AutomationReply(id: id, status: .failed, reason: reason)
        }
    }

    /// One row of the command palette: the commands of the menus and the
    /// keyboard shortcuts, as the palette offers them in that window.
    struct AutomationCommandInfo: Codable, Equatable, Sendable {
        let id: String
        let title: String
        /// Whether the row can run now, as its menu item would be enabled.
        let isEnabled: Bool
    }

    /// What `state` returns: enough to name every target and to tell whether
    /// a request has had its effect.
    struct AutomationSnapshot: Codable, Equatable, Sendable {
        struct Window: Codable, Equatable, Sendable {
            let id: UUID
            let project: UUID?
            let isKey: Bool
            let isOnScreen: Bool
            let openLayers: [AutomationLayer]
            /// The title bar's or the pane strip's dropdown open in the
            /// window (`TitleBarMenuRequest.Menu`): `project`, `worktree`,
            /// `needsAttention`, `addTab`, or `openTabs`.
            let dropdown: String?
            /// Whether a sheet or an alert is attached to the window, as
            /// AppKit reports it: the new worktree sheet, project settings,
            /// the clipboard confirmation, or a confirmation. The channel
            /// cannot answer one, so a check that opened one says so.
            let hasSheet: Bool
            let isSidebarShown: Bool
            let areIconBarsHidden: Bool
            let isChangesPanelShown: Bool
            /// The window's review tab, shown or behind.
            let review: Review?
            /// What holds the window's keyboard, where a key posted to the
            /// run from outside lands (ADR 0006); left out when nothing does.
            let keyboard: Keyboard?
            let tabs: [Tab]
        }

        struct Keyboard: Codable, Equatable, Sendable {
            let kind: AutomationKeyboardHolder
            /// The pane, when `kind` is `pane`.
            let pane: UUID?
            /// The responder's type, to tell one control from another.
            let view: String
        }

        struct Review: Codable, Equatable, Sendable {
            /// The agent pane it reviews.
            let pane: UUID?
            /// What it compares (`ReviewScopeOption`): `unviewedTurns`,
            /// `worktreeUnviewedTurns`, `turn`, `incompleteTurn`,
            /// `uncommitted`, or `branch`.
            let scope: String
            let isShown: Bool
        }

        /// The Settings window, while it is open.
        struct Settings: Codable, Equatable, Sendable {
            /// The section it shows (`SettingsSection`).
            let section: String
        }

        struct Tab: Codable, Equatable, Sendable {
            let id: UUID
            let title: String
            let isSelected: Bool
            let panes: [Pane]
        }

        struct Pane: Codable, Equatable, Sendable {
            let ref: AutomationPaneRef
            let foregroundProcess: String?
            let agent: String?
            let agentState: String?
            let agentSession: String?
            let isMidTurn: Bool
            let hasUnsubmittedInput: Bool
            let isInTmux: Bool
            /// Whether keys from outside the channel would land here: the pane
            /// is its window's first responder (`focus` makes it so). The
            /// window's key state is not part of it: AppKit reports no key
            /// window while the app is behind others, and keys sent to the app
            /// still reach this pane.
            let hasKeyboard: Bool
        }

        struct Project: Codable, Equatable, Sendable {
            let id: UUID
            let name: String
            let path: String
        }

        let run: String
        let projects: [Project]
        let windows: [Window]
        let settings: Settings?
    }

#endif
