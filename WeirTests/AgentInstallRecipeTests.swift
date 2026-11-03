// AgentInstallRecipeTests.swift
// Weir — the variables a provider says it needs, against the ones the shim
// scripts read.
//
// A wrong name here does not fail: the agent starts, runs, and reports
// nothing, with no error on either side. So the names are pinned literally.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("AgentInstallRecipe")
struct AgentInstallRecipeTests {
    @Test("the resolved environment is the one the shims carried")
    func environment_matchesWhatTheShimsExported() {
        let state = URL(fileURLWithPath: "/states")
        let sessions = URL(fileURLWithPath: "/sessions")
        let cwd = URL(fileURLWithPath: "/cwd")

        let usage = URL(fileURLWithPath: "/usage")

        let claude = AgentProviderRegistry.environment(
            for: "claude", state: state, sessions: sessions, cwdEvents: cwd, usage: usage
        )
        #expect(claude["WEIR_AGENT_STATES_DIR"] == "/states")
        // The status line relay keeps the plan usage here (`PlanUsageStore`).
        #expect(claude["WEIR_USAGE_DIR"] == "/usage")
        #expect(claude["WEIR_SESSIONS_DIR"] == "/sessions")
        #expect(claude["WEIR_CWD_EVENTS_DIR"] == "/cwd")
        #expect(claude["WEIR_CLAUDE_HOOK_NAMESPACE"] == WeirPaths.bundleID)

        let codex = AgentProviderRegistry.environment(
            for: "codex", state: state, sessions: sessions, cwdEvents: nil, usage: usage
        )
        #expect(codex["WEIR_CODEX_AGENT_STATES_DIR"] == "/states")
        #expect(codex["WEIR_CODEX_SESSIONS_DIR"] == "/sessions")
        // Codex has no cwd events, so nothing claims to point at them.
        #expect(codex.values.contains("/cwd") == false)
        // Codex's usage is read from its app server, not written by a hook.
        #expect(codex.values.contains("/usage") == false)
    }

    /// The variables of `kind`'s recipe its shim reads before the agent
    /// starts, which a tmux session therefore never needs.
    private static func readBeforeStart(_ kind: AgentKind) -> Set<String> {
        switch kind {
        case .claude: ["WEIR_CLAUDE_HOOK_NAMESPACE"]
        case .codex: ["WEIR_CODEX_HOOK_ARGS"]
        case .antigravity, .opencode: []
        }
    }

    /// A variable a shim does not hand to tmux takes the server's value, and a
    /// Dev agent on a Release server would then write into Release's folders.
    /// A shim that never hosts its agent in tmux names no such list.
    @Test(
        "a tmux-hosted agent gets every variable its recipe exports",
        .disabled(if: !RepoFixture.hasLocalRepo),
        arguments: AgentKind.allCases
    )
    func hostedEnvironment_coversTheRecipe(kind: AgentKind) throws {
        let root = try #require(RepoFixture.weirRoot)
        let script = try String(
            contentsOf: root.appending(path: "Weir/Resources/\(AgentShimLocator(kind).shimDirectoryName)/\(kind.launchCommand)"),
            encoding: .utf8
        )
        let recipe = try #require(AgentProviderRegistry.recipes[kind.rawValue])
        let names = recipe.environment.map(\.name)
        #expect(!names.isEmpty)
        guard let line = script.split(separator: "\n").first(where: { $0.hasPrefix("hosted_env_names=") }) else {
            #expect(!script.contains("weir_exec_agent"), "a shim that hands off to tmux names what the session gets")
            return
        }
        let hosted = Set(
            line.dropFirst("hosted_env_names=".count)
                .trimmingCharacters(in: ["\""])
                .split(separator: " ")
                .map(String.init)
        )
        #expect(Set(names).subtracting(Self.readBeforeStart(kind)).subtracting(hosted).isEmpty)
    }

    /// A pane's agent variables are merged locator by locator in `AgentKind`'s
    /// order and Codex's installer after them all, where it once came right
    /// after Codex's locator. That gives the same environment while no other
    /// recipe names a variable of Codex's.
    @Test("no other agent's recipe names a variable of Codex's")
    func codexRecipe_sharesNoVariable() throws {
        let codex = try Set(#require(AgentProviderRegistry.recipes["codex"]).environment.map(\.name))
        for kind in AgentKind.allCases where kind != .codex {
            let names = try Set(#require(AgentProviderRegistry.recipes[kind.rawValue]).environment.map(\.name))
            #expect(names.isDisjoint(with: codex), "\(kind)")
        }
    }

    @Test("only the provider whose hook takes arguments names a variable for them")
    func hookArgumentsVariable_isCodexOnly() {
        #expect(AgentProviderRegistry.hookArgumentsVariable(for: "codex") == "WEIR_CODEX_HOOK_ARGS")
        // Claude's hooks carry their arguments in the settings document, so
        // there is nothing for the installer to export.
        #expect(AgentProviderRegistry.hookArgumentsVariable(for: "claude") == nil)
        #expect(AgentProviderRegistry.hookArgumentsVariable(for: "gemini") == nil)
    }

    @Test("the record directories are the ones the installers used to carry")
    func directories_matchWhatTheInstallersDeclared() throws {
        let root = URL(fileURLWithPath: "/support")
        let directories = AgentProviderRegistry.directories(under: root)

        let claude = try #require(directories["claude"])
        #expect(claude.state == root.appendingPathComponent("agent-states", isDirectory: true))
        #expect(claude.sessions == root.appendingPathComponent("sessions", isDirectory: true))
        #expect(claude.cwdEvents == root.appendingPathComponent("cwd-events", isDirectory: true))

        let codex = try #require(directories["codex"])
        #expect(codex.state == root.appendingPathComponent("codex-agent-states", isDirectory: true))
        #expect(codex.sessions == root.appendingPathComponent("codex-sessions", isDirectory: true))
        // Codex reports no cwd changes, so there is no directory to watch.
        #expect(codex.cwdEvents == nil)
    }

    @Test("the codex installer exports the directories the projection reads")
    @MainActor
    func codexInstaller_environment_pointsAtTheProjectionDirectories() throws {
        let directories = try #require(
            AgentProviderRegistry.directories(under: WeirPaths.applicationSupportDirectory())["codex"]
        )
        let installer = CodexHookInstaller(
            hookScriptURL: URL(fileURLWithPath: "/tmp/weir-hook")
        )

        let environment = installer.environment(writesRecords: true)

        #expect(environment["WEIR_CODEX_AGENT_STATES_DIR"] == directories.state.path)
        #expect(environment["WEIR_CODEX_SESSIONS_DIR"] == directories.sessions.path)
        #expect(environment["WEIR_CODEX_HOOK_ARGS"]?.isEmpty == false)
    }

    @Test("the claude shim exports the directories the projection reads")
    func claudeShim_environment_pointsAtTheProjectionDirectories() throws {
        let directories = try #require(
            AgentProviderRegistry.directories(under: WeirPaths.applicationSupportDirectory())["claude"]
        )

        let environment = AgentShimLocator(.claude).environment(writesRecords: true)

        #expect(environment["WEIR_AGENT_STATES_DIR"] == directories.state.path)
        #expect(environment["WEIR_SESSIONS_DIR"] == directories.sessions.path)
        #expect(environment["WEIR_CWD_EVENTS_DIR"] == directories.cwdEvents?.path)
        // The running build's identity, which names the hook link.
        #expect(environment["WEIR_CLAUDE_HOOK_NAMESPACE"] == WeirPaths.bundleID)
    }

    @Test("a demo pane's Claude is told of no record directory")
    func claudeShim_environment_inDemoMode_blanksTheRecordDirectories() {
        // Named and empty, so a value inherited from the Weir pane that
        // launched the demo does not reach the hook; the namespace stays so
        // the shim keeps its links apart from that build's.
        let environment = AgentShimLocator(.claude).environment(writesRecords: false)

        #expect(environment["WEIR_AGENT_STATES_DIR"] == "")
        #expect(environment["WEIR_SESSIONS_DIR"] == "")
        #expect(environment["WEIR_CWD_EVENTS_DIR"] == "")
        #expect(environment["WEIR_CLAUDE_HOOK_NAMESPACE"] == WeirPaths.bundleID)
    }

    @Test("a demo pane's Codex is told of no record directory and no hook")
    @MainActor
    func codexInstaller_environment_inDemoMode_blanksTheRecordsAndTheHook() {
        let environment = CodexHookInstaller(hookScriptURL: URL(fileURLWithPath: "/tmp/weir-hook"))
            .environment(writesRecords: false)

        #expect(environment["WEIR_CODEX_AGENT_STATES_DIR"] == "")
        #expect(environment["WEIR_CODEX_SESSIONS_DIR"] == "")
        #expect(environment["WEIR_CODEX_HOOK_ARGS"] == "")
    }

    @Test("a provider this build does not have contributes nothing")
    func unknownProvider_yieldsNothing() {
        let environment = AgentProviderRegistry.environment(
            for: "gemini",
            state: URL(fileURLWithPath: "/states"),
            sessions: URL(fileURLWithPath: "/sessions"),
            cwdEvents: nil
        )
        #expect(environment.isEmpty)
    }
}
