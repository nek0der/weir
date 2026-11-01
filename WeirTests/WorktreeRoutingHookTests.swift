// WorktreeRoutingHookTests.swift
// Weir — runs the bundled Hook Helper against a routing file the
// application itself wrote.
//
// The routing file is parsed by hand in another language, and both sides
// already pin the key names they expect: this suite writes the file through
// the production path and hands those exact bytes to the real helper, so a
// key that only one side renamed fails here instead of in a user's
// repository.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(
    "Worktree routing hook",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host")
)
struct WorktreeRoutingHookTests {
    /// A scratch root holding the repository and the support directory the
    /// routing file is written into. The worktree lands beside the
    /// repository, so the root has to contain both.
    private struct Scratch {
        let root: URL
        let repo: URL
        let support: URL

        static func make() async throws -> Scratch {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("weir-routing-\(UUID().uuidString)")
            let repo = root.appendingPathComponent("repo")
            let support = root.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: support.appendingPathComponent("agent-states"),
                withIntermediateDirectories: true
            )
            try await TempGitRepo.initialize(repo)
            try await TempGitRepo.git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
            return Scratch(root: root, repo: repo, support: support)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Saves a session holding one project, which is what puts the routing
    /// file on disk. Going through the store rather than the encoder is the
    /// point: it is the path the running application takes.
    private func writeRouting(_ scratch: Scratch, routeClaude: Bool) {
        let project = Project(
            id: UUID(),
            name: "repo",
            rootURL: scratch.repo,
            worktrees: [],
            worktreePlacement: .siblingPrefixed,
            bootstrap: [.shorthand("touch bootstrapped.txt")],
            routeClaudeWorktrees: routeClaude,
            routeCodexWorktrees: true
        )
        SessionStore(directory: scratch.support).saveSynchronously(SessionSnapshot(
            projects: [project],
            tabs: []
        ))
    }

    /// How the hook is started: the helper itself, or a wrapper that execs it.
    private struct HookCommand {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// Runs `hook` with a payload for `event` and `command` on stdin, and
    /// answers what it printed. Given thirty seconds, the bootstrap command
    /// included: a helper that hangs fails its test rather than holding the run.
    private func call(_ hook: HookCommand, _ scratch: Scratch, event: String, command: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event,
            "tool_name": "Bash",
            "cwd": scratch.repo.path,
            "tool_input": ["command": command]
        ])
        let process = Process()
        process.executableURL = hook.executable
        process.arguments = hook.arguments
        process.environment = IsolatedProcessEnvironment.make(hook.environment.merging([
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": scratch.root.path,
            "WEIR_PANE_ID": UUID().uuidString,
            "WEIR_TURN_SNAPSHOT": "0"
        ]) { own, _ in own })
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: payload)
        try stdin.fileHandleForWriting.close()
        #expect(process.waitUntilExit(within: 30), "the hook did not exit within thirty seconds")
        #expect(process.terminationStatus == 0, "a hook that stops the tool is no route")
        return String(bytes: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// The command `hook` gives the tool in place of the agent's, `nil` when
    /// it lets the agent's run.
    private func reroutedCommand(_ hook: HookCommand, _ scratch: Scratch, branch: String) throws -> String? {
        let reply = try call(hook, scratch, event: "PreToolUse", command: "git worktree add -b \(branch) ../elsewhere")
        guard !reply.isEmpty else { return nil }
        let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        let input = try #require(output["updatedInput"] as? [String: Any])
        return try #require(input["command"] as? String)
    }

    /// What the provider does with a routed command the person allowed: runs
    /// it, then calls the hook again.
    private func route(_ hook: HookCommand, _ scratch: Scratch, branch: String) async throws {
        let command = try #require(try reroutedCommand(hook, scratch, branch: branch))
        let arguments = Array(command.split(separator: " ").dropFirst().map(String.init))
        try await TempGitRepo.git(arguments, in: scratch.repo)
        _ = try call(hook, scratch, event: "PostToolUse", command: command)
    }

    /// The helper itself, as Claude's hook.
    private func helperHook(_ scratch: Scratch) throws -> HookCommand {
        // Bound first: assigned straight to the optional property, the
        // requirement type-checks against `URL?` and never fails.
        let helper = try #require(HookHelperFixture.helperURL)
        return HookCommand(executable: helper, arguments: ["hook", "claude", "worktree"], environment: [
            "WEIR_AGENT_STATES_DIR": scratch.support.appendingPathComponent("agent-states").path,
            "WEIR_SESSIONS_DIR": scratch.support.appendingPathComponent("sessions").path
        ])
    }

    /// The wrapper the provider calls, which execs the helper.
    private func wrapperHook(_ scratch: Scratch, provider: String) throws -> HookCommand {
        let root = try #require(RepoFixture.weirRoot)
        let helper = try #require(HookHelperFixture.helperURL)
        let prefix = provider == "claude" ? "WEIR" : "WEIR_CODEX"
        let wrapper = root.appendingPathComponent("Weir/Resources/\(provider)-shim/weir-pretool-worktree-hook")
        return HookCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [wrapper.path], environment: [
            "WEIR_HOOK_HELPER": helper.path,
            "\(prefix)_AGENT_STATES_DIR": states(scratch, provider: provider).path,
            "\(prefix)_SESSIONS_DIR": scratch.support.appendingPathComponent("sessions").path
        ])
    }

    private func states(_ scratch: Scratch, provider: String) -> URL {
        scratch.support.appendingPathComponent(provider == "claude" ? "agent-states" : "codex-agent-states")
    }

    /// The one worktree event in `states`, found by the names the application
    /// lists events by, or nil when there is not exactly one.
    private func event(in states: URL) throws -> [String: Any]? {
        let directory = try AgentRecordFixtures.worktreeEvents(in: states)
        let suffix = try AgentRecordFixtures.layout().worktreeEventSuffix
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let events = names.filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }
        guard let name = events.first, events.count == 1 else { return nil }
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test("the helper reads the file the application wrote")
    func routedProject_placesTheWorktreeAndRunsBootstrap() async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: true)

        let hook = try helperHook(scratch)
        let worktree = scratch.root.appendingPathComponent("repo-feature-alpha")

        try await route(hook, scratch, branch: "feature/alpha")

        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("bootstrapped.txt").path
        ))
        // The event is what refreshes the sidebar; one the application does
        // not list is a worktree it never shows.
        let event = try #require(try event(in: states(scratch, provider: "claude")))
        #expect(event["branch"] as? String == "feature/alpha")
    }

    /// `PreToolUse` runs ahead of the person's prompt: a "No" there must find
    /// nothing made and no step run.
    @Test("the helper makes nothing before the command runs")
    func routedProject_makesNothingBeforeTheCommandRuns() async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: true)

        #expect(try reroutedCommand(helperHook(scratch), scratch, branch: "feature/alpha") != nil)

        #expect(!FileManager.default.fileExists(
            atPath: scratch.root.appendingPathComponent("repo-feature-alpha").path
        ))
        #expect(try event(in: states(scratch, provider: "claude")) == nil)
    }

    @Test("branches with one last part get their own folders, where the sheet would put them")
    func branchesWithOneLastPart_getTheirOwnFolders() async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: true)

        let hook = try helperHook(scratch)
        for branch in ["feature/alpha", "fix/alpha"] {
            try await route(hook, scratch, branch: branch)
            let folder = "repo-\(BranchNameSuggester.folderLeaf(of: branch))"
            #expect(FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent(folder).path), "\(branch)")
        }
    }

    /// Each provider's wrapper names its own subcommand of the helper, so
    /// looking for each one's event by the names the application lists is
    /// what catches a wrapper that hands the helper the wrong provider.
    @Test("each provider's wrapper leaves its event where the application looks", arguments: ["claude", "codex"])
    func wrapper_writesTheEventTheApplicationReads(provider: String) async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: true)

        try await route(wrapperHook(scratch, provider: provider), scratch, branch: "feature/\(provider)")

        let event = try #require(try event(in: states(scratch, provider: provider)))
        #expect(event["event"] as? String == "WorktreeCreate")
        #expect(event["branch"] as? String == "feature/\(provider)")
    }

    @Test("turning the provider off in the application reaches the helper")
    func optedOutProject_passesTheCommandThrough() async throws {
        let scratch = try await Scratch.make()
        defer { scratch.cleanup() }
        writeRouting(scratch, routeClaude: false)

        // A provider missing from the map is routed, so a key only one side
        // renamed would fail open and silently ignore the opt-out.
        #expect(try reroutedCommand(helperHook(scratch), scratch, branch: "feature/beta") == nil)
        #expect(!FileManager.default.fileExists(
            atPath: scratch.root.appendingPathComponent("repo-beta").path
        ))
    }
}
