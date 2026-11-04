// AgentShimLocator.swift
// Weir — one agent's in-bundle shim directory and the variables a pane's shell needs for it.
//
// A `claude` (or `codex`, `agy`, `opencode`) typed in a Weir pane finds the
// shim first on the `PATH`, which installs the hooks and then runs the real
// agent; its hook writes into the record directories the provider's
// descriptor names, which these variables carry.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("agent.shim.locator")

struct AgentShimLocator {
    let kind: AgentKind

    init(_ kind: AgentKind) {
        self.kind = kind
    }

    /// The folder the bundle keeps the shim in, `<id>-shim`.
    var shimDirectoryName: String {
        "\(kind.rawValue)-shim"
    }

    /// Absolute path of the bundled shim directory, or `nil` when the bundle
    /// does not contain it (a unit-test target with no Resources phase).
    /// Callers treat `nil` as "skip injection".
    var shimDirectoryURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent(shimDirectoryName, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The variable the shim directory is exported in, which
    /// `zdotdir/.zshrc` reads to put the shim back at the front of the `PATH`
    /// after the person's own `.zshrc`; a line like
    /// `export PATH="/opt/homebrew/bin:$PATH"` there would otherwise bury it
    /// behind the real agent and the hooks would never load. Claude's was
    /// named before there was a second agent, and a shell started by an
    /// earlier build still reads it by that name (`legacyShimDirectoryVariable`).
    var shimDirectoryVariable: String {
        kind == Self.firstAgent ? Self.legacyShimDirectoryVariable : "WEIR_\(kind.rawValue.uppercased())_SHIM_DIR"
    }

    /// The agent Weir had before there was a second one, whose shim
    /// variable and record export keep the shape they had then.
    static let firstAgent = AgentKind.claude

    /// `firstAgent`'s shim variable, named before any other agent had one.
    static let legacyShimDirectoryVariable = "WEIR_SHIM_DIR"

    /// Whether this locator exports the agent's record directories: not
    /// when its recipe has the hook's own arguments (`hook_arguments`, only
    /// Codex's today). Those go out with the record directories from the
    /// installer that assembles them (`CodexHookInstaller`), which alone
    /// knows whether the hooks are installed; named without them, the
    /// directories would tell a hook another build installed where to write.
    var exportsRecordDirectories: Bool {
        Self.exportsRecordDirectories(kind, recipe: AgentProviderRegistry.recipes[kind.rawValue])
    }

    /// `exportsRecordDirectories` for `kind` with `recipe`. With no recipe
    /// to read (the bridge could not be decoded), the agents whose installer
    /// exported them before the recipe said so keep that answer, so their
    /// locator does not go on to look for directories and log that it found
    /// none.
    static func exportsRecordDirectories(_ kind: AgentKind, recipe: AgentInstallRecipe?) -> Bool {
        guard let recipe else { return !installerExportsWithoutRecipe.contains(kind) }
        return recipe.hookArgumentsVariable == nil
    }

    /// The agents whose installer exported the record directories when the
    /// recipe's hook arguments replaced a list of them. A fixed record of
    /// that time, not a list a new agent joins.
    static let installerExportsWithoutRecipe: Set<AgentKind> = [.codex]

    /// Whether the record directories are exported when the bundle has no
    /// shim. `firstAgent`'s always were, from before the other agents had
    /// shims; for the others the shim is what installs the hook that reads
    /// them, so without it there is nothing to tell.
    var exportsRecordsWithoutShim: Bool {
        kind == Self.firstAgent
    }

    /// The agent's half of a pane's environment: its shim directory and,
    /// where this locator owns them, its record directories. `PATH`,
    /// `ZDOTDIR` and `WEIR_PANE_ID` belong to every pane and live in
    /// `PaneShellEnvironment`.
    ///
    /// The variable names come from the provider's install recipe and the
    /// directories from its descriptor, so the receiver writes exactly where
    /// the projection reads. The bundle id among them keeps a Dev build from
    /// redirecting a Release session's live hook path or the reverse. When
    /// the run may not write the person's files (demo mode) the directories
    /// are exported empty; `AgentProviderRegistry.environment` says why.
    func environment(writesRecords: Bool) -> [String: String] {
        var environment: [String: String] = [:]
        if let shim = shimDirectoryURL {
            environment[shimDirectoryVariable] = shim.path
        } else if exportsRecordsWithoutShim {
            log.debug("\(shimDirectoryName, privacy: .public) not found in bundle; skipping shim dir export")
        } else {
            return [:]
        }
        guard exportsRecordDirectories else { return environment }
        guard let directories = AgentProviderRegistry.directories(
            under: WeirPaths.applicationSupportDirectory()
        )[kind.rawValue] else {
            // Without a descriptor we have no name for the directories, and
            // the projection reads none either, so guessing one would only
            // scatter records nobody collects.
            log.error("\(kind.rawValue, privacy: .public) provider directories unavailable; exporting no record directories")
            return environment
        }
        environment.merge(AgentProviderRegistry.environment(
            for: kind.rawValue,
            state: directories.state,
            sessions: directories.sessions,
            cwdEvents: directories.cwdEvents,
            writesRecords: writesRecords
        )) { _, recipe in recipe }
        return environment
    }

    /// The zsh startup-file forwarding directory, or `nil` when the bundle
    /// lacks it. Each file inside sources the person's own first, and
    /// `.zshrc` then puts the shims back at the front of the `PATH`. It stays
    /// in Claude's shim folder, where it began: a tmux server Weir started
    /// outlives an update, and the sessions it starts later take `ZDOTDIR`
    /// from it, so a folder that moved would leave their shells with no
    /// startup files. `nil` is defensive: a damaged bundle should still
    /// launch a usable shell.
    static var zdotdirURL: URL? {
        guard let shim = AgentShimLocator(.claude).shimDirectoryURL else { return nil }
        let url = shim.appendingPathComponent("zdotdir", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every agent's shim directory the bundle has, in `AgentKind`'s order:
    /// the order they lead the pane's `PATH` in, and the order `.zshrc`
    /// puts them back in, which leaves the last one first.
    static var shimDirectoryURLs: [URL] {
        AgentKind.allCases.compactMap { AgentShimLocator($0).shimDirectoryURL }
    }
}
