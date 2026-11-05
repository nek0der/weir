// CodexHookInstaller.swift
// Weir — installs our lifecycle hooks into Codex.
//
// The hooks ride on the `codex` shim's command line as `-c` overrides,
// trust and all (`CodexHookInjection`). Codex reports those under a
// `sessionFlags` source of their own, so they sit alongside whatever the
// user has configured rather than replacing it. Nothing is read from or
// written to the user's own `~/.codex/config.toml`: trust tables an earlier
// build left there hold only stale hashes, and the flags' trust takes
// precedence over them.

import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("codex.hook.installer")

@MainActor
final class CodexHookInstaller {
    /// Singleton-style shared instance; WeirApp owns it via env.
    static let shared = CodexHookInstaller()

    /// Bundled `codex-shim/weir-hook` script path. `nil` when running
    /// from a test bundle without the resource — in that case no hooks are
    /// installed.
    let hookScriptURL: URL?

    /// Bundled `codex-shim/weir-pretool-worktree-hook` path. `nil` when
    /// missing; the lifecycle hook alone still works, only the second
    /// `PreToolUse` handler goes away.
    let worktreeHookScriptURL: URL?

    /// Bundled signed requester. It authenticates the running service and
    /// verifies its artifact identity on every request; when unavailable it
    /// publishes the lifecycle fallback and emits no approval decision.
    let approvalHelperURL: URL?

    /// Separator for `WEIR_CODEX_HOOK_ARGS`. Newline because every
    /// fragment we generate is single-line, and the shim can split on it
    /// with nothing but `IFS`.
    nonisolated static let argumentSeparator = "\n"

    init(
        hookScriptURL: URL? = nil,
        worktreeHookScriptURL: URL? = nil,
        approvalHelperURL: URL? = nil
    ) {
        self.hookScriptURL = hookScriptURL ?? CodexHookInstaller.bundledHookScript()
        self.worktreeHookScriptURL = worktreeHookScriptURL
            ?? CodexHookInstaller.bundledWorktreeHookScript()
        self.approvalHelperURL = approvalHelperURL
            ?? CodexHookInstaller.bundledHookHelper()
    }

    // MARK: - Environment

    /// The Codex-specific half of a pane's environment: where the receiver
    /// writes, and the flags the shim splices into its own invocation.
    /// Empty when we have no receiver to point at — the caller treats that
    /// as "no Codex integration this pane". When the run may not write the
    /// person's files (demo mode) the directories and the flags are exported
    /// empty, so neither an inherited value nor our hook writes a record;
    /// `AgentProviderRegistry.environment` says why they are named at all.
    func environment(writesRecords: Bool) -> [String: String] {
        guard let lifecycleCommand else {
            return writesRecords ? [:] : Self.blankRecordDirectories()
        }
        // The variable names come from the provider's install recipe and the
        // directories from its descriptor, so the receiver writes exactly
        // where the projection reads. Only the hook arguments are assembled
        // here, because only here is the installed hook's path known.
        var env: [String: String] = [:]
        if let directories = AgentProviderRegistry.directories(
            under: WeirPaths.applicationSupportDirectory()
        )[AgentKind.codex.rawValue] {
            env = AgentProviderRegistry.environment(
                for: AgentKind.codex.rawValue,
                state: directories.state,
                sessions: directories.sessions,
                cwdEvents: directories.cwdEvents,
                writesRecords: writesRecords
            )
        } else {
            // Without a descriptor we have no name for the directories, and
            // the projection reads none either, so guessing one would only
            // scatter records nobody collects.
            log.error("codex provider directories unavailable; exporting no record directories")
        }
        if let variable = AgentProviderRegistry.hookArgumentsVariable(for: AgentKind.codex.rawValue) {
            let arguments = CodexHookInjection.arguments(
                lifecycleCommand: lifecycleCommand,
                worktreeCommand: worktreeCommand,
                approvalCommand: approvalCommand
            )
            env[variable] = writesRecords ? arguments.joined(separator: CodexHookInstaller.argumentSeparator) : ""
        } else {
            // The shim splices these flags into its own invocation; under a
            // name we invented it would read none of them, which is the same
            // as installing no hooks at all.
            log.error("codex recipe names no hook arguments variable; installing no hook flags")
        }
        return env
    }

    /// The record directories named and empty, for a demo pane with no hook
    /// to point at: an inherited value would otherwise still reach a hook
    /// that another build installed.
    private static func blankRecordDirectories() -> [String: String] {
        guard let directories = AgentProviderRegistry.directories(
            under: WeirPaths.applicationSupportDirectory()
        )[AgentKind.codex.rawValue] else { return [:] }
        return AgentProviderRegistry.environment(
            for: AgentKind.codex.rawValue,
            state: directories.state,
            sessions: directories.sessions,
            cwdEvents: directories.cwdEvents,
            writesRecords: false
        )
    }

    // MARK: - Commands

    /// Codex passes each `command` to `sh -c`, so the path is quoted here
    /// rather than relying on the caller. Symlinks are resolved because
    /// the string is hashed and Codex compares against the resolved form.
    private var lifecycleCommand: String? {
        hookScriptURL.map { Self.shellCommand(for: $0) }
    }

    private var worktreeCommand: String? {
        worktreeHookScriptURL.map { Self.shellCommand(for: $0) }
    }

    private var approvalCommand: String? {
        guard let helper = approvalHelperURL else { return nil }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return Self.executableCommand(for: helper) + " permission-request codex"
    }

    private static func shellCommand(for url: URL) -> String {
        "/bin/sh " + executableCommand(for: url)
    }

    static func executableCommand(for url: URL) -> String {
        ShellQuote.single(url.resolvingSymlinksInPath().path)
    }

    static func bundledHookScript() -> URL? {
        bundledScript(named: AgentCatalog.shimMarker)
    }

    static func bundledWorktreeHookScript() -> URL? {
        bundledScript(named: "weir-pretool-worktree-hook")
    }

    /// Says in the log, at launch, when the bundle has no Hook Helper. Every
    /// hook wrapper execs it and nothing else, so without it no agent's turns
    /// are recorded: each hook call fails in the agent's pane, and this is
    /// where the logs say why.
    static func reportMissingHookHelper() {
        guard bundledHookHelper() == nil else { return }
        log.fault("AgentIntegrationHookHelper missing from the bundle; agent hooks will fail and record nothing")
    }

    /// The signed Hook Helper beside the app's executable, which both
    /// providers' hook wrappers exec and Codex calls for an approval; `nil`
    /// when the bundle lacks it.
    static func bundledHookHelper() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent()
            .appendingPathComponent(AgentIntegrationConfiguration.hookHelperExecutableName)
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// `name` in Codex's bundled shim folder, the one a pane's `PATH` leads
    /// with (`AgentShimLocator`).
    private static func bundledScript(named name: String) -> URL? {
        guard let shim = AgentShimLocator(.codex).shimDirectoryURL else { return nil }
        let url = shim.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
