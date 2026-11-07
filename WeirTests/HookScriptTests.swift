// HookScriptTests.swift
// Weir — runs each agent's `weir-hook` wrapper, and through it the Hook
// Helper, against the payloads that agent sends: the pid resolution, the
// event mapping, the prompt snapshot, and the files the app reads by name.

import Foundation
import Testing
@testable import Weir

struct HookRecipeEnvironmentTests {
    @Test func invalidRecipe_throwsBeforeBuildingTheEnvironment() {
        let directory = URL(fileURLWithPath: "/unused")
        let agent = HookAgent.claude
        let states = AgentInstallRecipe.Variable(name: "STATES", value: .stateDirectory)
        let sessions = AgentInstallRecipe.Variable(name: "SESSIONS", value: .sessionDirectory)
        let cases: [([AgentInstallRecipe.Variable], HookAgent.RecipeError)] = [
            ([], .missingVariable(provider: .claude, placeholder: .stateDirectory)),
            ([states], .missingVariable(provider: .claude, placeholder: .sessionDirectory)),
            (
                [states, sessions, .init(name: "", value: .cwdEventsDirectory)],
                .missingVariable(provider: .claude, placeholder: .cwdEventsDirectory)
            ),
            ([states, .init(name: "STATES", value: .sessionDirectory)], .duplicateVariable(provider: .claude, name: "STATES")),
            ([.init(name: "HOME", value: .stateDirectory), sessions], .duplicateVariable(provider: .claude, name: "HOME")),
            (
                [states, sessions, .init(name: "SESSIONS", value: .cwdEventsDirectory)],
                .duplicateVariable(provider: .claude, name: "SESSIONS")
            )
        ]
        for (variables, expected) in cases {
            let error = #expect(throws: HookAgent.RecipeError.self) {
                _ = try agent.environment(in: directory, paneID: "pane", recipeVariables: variables)
            }
            #expect(error == expected)
        }
    }
}

@Suite(
    "Hook receiver",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(2))
)
struct HookScriptTests {
    private func runHooks(
        _ agent: HookAgent,
        _ payloads: [[String: Any]],
        extraEnvironment: [String: String] = [:],
        wrapper: URL? = nil,
        afterEach: ((URL, URL, String, Int) throws -> Void)? = nil,
        prepare: ((URL, URL, String) throws -> Void)? = nil
    ) throws -> [String: Any]? {
        try HookScriptHarness.runHooks(
            agent, payloads, extraEnvironment: extraEnvironment, wrapper: wrapper, afterEach: afterEach, prepare: prepare
        )
    }

    private func optionalText(_ record: [String: Any], _ key: String) -> String? {
        HookScriptHarness.optionalText(record, key)
    }

    // MARK: - Prompt snapshot

    @Test("captures an exact private prompt snapshot without changing the real index", arguments: HookAgent.allCases)
    func promptSnapshot_isPrivateAndSessionEndCleansIt(agent: HookAgent) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try repo.write("before prompt\n", to: "pending.txt")
        let status = try await repo.git(["status", "--porcelain"])
        let expectedRoot = try await repo.git(["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTree = try await scratchTree(in: repo.url)
        let indexURL = repo.url.appendingPathComponent(".git/index")
        let indexMTime = try #require(
            try (FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]) as? Date
        )
        let indexBytes = try Data(contentsOf: indexURL)
        let other = UUID().uuidString.lowercased()
        let otherRef = "refs/weir/turn/\(other)"
        let otherIndex = repo.url.appendingPathComponent(".git/weir/turn-\(other).index")
        let sentinel = Data("other pane".utf8)
        var baseTree = ""
        _ = try runHooks(
            agent,
            [
                agent.payload("UserPromptSubmit", extra: ["cwd": repo.url.path]),
                agent.payload("Stop", extra: ["cwd": repo.url.path]),
                agent.payload("SessionEnd", extra: ["cwd": repo.url.path, "reason": "other"])
            ],
            afterEach: { _, states, paneID, eventIndex in
                let snapshotKey = paneID.lowercased()
                let recordURL = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(paneID))
                let privateIndexURL = repo.url.appendingPathComponent(".git/weir/turn-\(snapshotKey).index")
                let readIndexURL = repo.url.appendingPathComponent(".git/weir/turn-\(snapshotKey).read.index")
                let paneRef = "refs/weir/turn/\(snapshotKey)"
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
                if eventIndex == 0 {
                    baseTree = try #require(record?["turnBaseTree"] as? String)
                    #expect(baseTree == expectedTree)
                    #expect(record?["turnRoot"] as? String == expectedRoot)
                    // The record holds the tree; the pane has no ref of its own.
                    #expect(try gitExitStatus(["show-ref", "--verify", "--quiet", paneRef], in: repo.url) == 1)
                    // A pane ref and a read index left in the repository,
                    // which SessionEnd removes along with the private index.
                    #expect(try gitExitStatus(["update-ref", paneRef, baseTree], in: repo.url) == 0)
                    // A capture's own scratch index goes with it; the shared one is what an
                    // earlier build left.
                    #expect(!FileManager.default.fileExists(atPath: privateIndexURL.path))
                    try Data().write(to: privateIndexURL)
                    try Data().write(to: readIndexURL)
                    try sentinel.write(to: otherIndex)
                    try #require(gitExitStatus(["update-ref", otherRef, baseTree], in: repo.url) == 0)
                } else if eventIndex == 1 {
                    #expect(record?["turnBaseTree"] as? String == baseTree)
                    #expect(record?["turnRoot"] as? String == expectedRoot)
                } else {
                    #expect(record?["turnBaseTree"] == nil)
                    #expect(try gitExitStatus(["show-ref", "--verify", "--quiet", paneRef], in: repo.url) == 1)
                    #expect(!FileManager.default.fileExists(atPath: privateIndexURL.path))
                    #expect(!FileManager.default.fileExists(atPath: readIndexURL.path))
                    #expect(try Data(contentsOf: otherIndex) == sentinel)
                    #expect(try GitProcess.runSync(["rev-parse", otherRef], cwd: repo.url).stdout
                        .trimmingCharacters(in: .whitespacesAndNewlines) == baseTree)
                }
            }
        )
        #expect(!baseTree.isEmpty)
        #expect(try Data(contentsOf: indexURL) == indexBytes)
        #expect(try await repo.git(["status", "--porcelain"]) == status)
        #expect(
            try (FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]) as? Date == indexMTime
        )
    }

    @Test("skips disabled, non-repository, and missing-Git snapshots", arguments: HookAgent.allCases)
    func promptSnapshot_skipConditionsOmitFields(agent: HookAgent) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let prompt = agent.payload("UserPromptSubmit", extra: ["cwd": repo.url.path])
        let metadata = repo.url.appendingPathComponent(".git/weir")
        try #require(!FileManager.default.fileExists(atPath: metadata.path))
        let disabled = try runHooks(agent, [prompt], extraEnvironment: ["WEIR_TURN_SNAPSHOT": "0"])
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        let outsideRepository = try withTempDir { directory in
            try #require(gitExitStatus(["rev-parse", "--show-toplevel"], in: directory) == 128)
            return try runHooks(agent, [agent.payload("UserPromptSubmit", extra: ["cwd": directory.path])])
        }
        let missingGit = try withTempDir { directory in
            let path = try pathWithoutGit(in: directory)
            let discovery = try TestProcess.run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "command -v git"],
                environment: IsolatedProcessEnvironment.make(["PATH": path])
            )
            try #require(discovery.ending == .exited && discovery.status != 0)
            return try runHooks(agent, [prompt], extraEnvironment: ["PATH": path])
        }
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        for optionalRecord in [disabled, outsideRepository, missingGit] {
            let record = try #require(optionalRecord)
            #expect(record["state"] as? String == "running")
            #expect(record["turnBaseTree"] == nil)
            #expect(record["turnRoot"] == nil)
        }
    }

    /// A nested directory and a linked worktree each use the Git directory
    /// resolved by Git itself, regardless of the payload's directory.
    @Test("writes a turn's scratch files only inside the repository's git directory", arguments: HookAgent.allCases)
    func promptSnapshot_staysInsideTheRepositoryGitDirectory(agent: HookAgent) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let nested = repo.url.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let linked = try await repo.addLinkedWorktree(branch: "linked")
        let mainGit = try await repo.git(["rev-parse", "--absolute-git-dir"])
        let linkedGit = try await TempGitRepo.git(["rev-parse", "--absolute-git-dir"], in: linked)
        try #require(linkedGit != mainGit)
        for cwd in [repo.url, nested, linked] {
            let root = try await TempGitRepo.git(["rev-parse", "--show-toplevel"], in: cwd)
            let gitDir = try await TempGitRepo.git(["rev-parse", "--absolute-git-dir"], in: cwd)
            let metadata = URL(fileURLWithPath: gitDir).appendingPathComponent("weir")
            let record = try #require(try runHooks(agent, [
                agent.payload("UserPromptSubmit", extra: ["cwd": cwd.path]),
                agent.payload("Stop", extra: ["cwd": cwd.path])
            ]))
            #expect(record["turnRoot"] as? String == root)
            #expect(record["turnBaseTree"] is String)
            #expect(FileManager.default.fileExists(atPath: metadata.path))
        }
        #expect(!FileManager.default.fileExists(atPath: repo.scratch.appendingPathComponent(".git").path))
        #expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path))
    }

    // MARK: - Pid

    enum PIDInput: CaseIterable, Sendable {
        case valid, malformed, hosted, absent, empty
    }

    @Test("records a valid exported pid only outside tmux", arguments: HookAgent.allCases, PIDInput.allCases)
    func exportedPid_requiresANumericValueOutsideTmux(agent: HookAgent, input: PIDInput) throws {
        var environment: [String: String] = [:]
        switch input {
        case .valid:
            environment[agent.pidVariable] = "424242"
        case .malformed:
            environment[agent.pidVariable] = "\" ,\"x\":1"
        case .hosted:
            environment = [agent.pidVariable: "424242", "TMUX": "/tmp/tmux-501/default,4242,0"]
        case .absent:
            break
        case .empty:
            environment[agent.pidVariable] = ""
        }
        let record = try #require(try runHooks(agent, agent.midTurn(), extraEnvironment: environment))
        #expect(record["state"] as? String == "running")
        if input == .valid {
            #expect(record["pid"] as? String == "424242")
        } else {
            #expect(record["pid"] == nil)
        }
    }

    /// The pid tests above are also satisfied by a walk that never matches
    /// anything, because nothing in the test host's ancestry carries the
    /// agent's name. Inside tmux the walk is the only source of the pid, so
    /// one test proves it finds something.
    @Test("walks up to an ancestor named after the agent when no pid was exported", arguments: HookAgent.allCases)
    func walk_findsTheAncestorNamedAfterTheAgent(agent: HookAgent) throws {
        try withTempDir { dir in
            let paneID = UUID().uuidString
            // `ps` reports the path a process was exec'd as rather than the
            // resolved one, so a symlink hands the walk an ancestor with the
            // name it looks for, and exercises the basename stripping at the
            // same time. A copy of `sh` would not work: macOS kills a
            // relocated system binary on launch (exit 137).
            let fakeAgent = dir.appendingPathComponent(agent.rawValue)
            try FileManager.default.createSymbolicLink(at: fakeAgent, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
            var environment = try agent.environment(in: dir, paneID: paneID)
            environment["WEIR_HOOK_HELPER"] = try #require(HookHelperFixture.helperURL).path
            // The trailing `true` keeps the shell from exec'ing the hook in
            // place, which would drop the agent-named process out of the very
            // chain the walk has to climb.
            let output = try HookScriptHarness.feed(
                agent.payload("SessionStart"),
                to: fakeAgent,
                arguments: ["-c", "/bin/sh '\(agent.wrapper().path)'; true"],
                environment: IsolatedProcessEnvironment.make(environment)
            )

            let url = try dir.appendingPathComponent("states/" + AgentRecordFixtures.recordFileName(paneID))
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(record?["pid"] as? String == String(output.pid))
        }
    }

    // MARK: - Tmux

    @Test("sets the hosted flag only inside tmux", arguments: HookAgent.allCases, [false, true])
    func tmuxHostedFlag_isTrueOrOmitted(agent: HookAgent, isHosted: Bool) throws {
        let environment = isHosted ? ["TMUX": "/tmp/tmux-501/weir,4242,0"] : [:]
        let record = try #require(try runHooks(agent, agent.midTurn(), extraEnvironment: environment))
        #expect(record["state"] as? String == "running")
        if isHosted {
            #expect(record["isTmuxHosted"] as? Bool == true)
        } else {
            #expect(record["isTmuxHosted"] == nil)
        }
    }

}

extension HookScriptTests {

    // MARK: - Fixture recording

    /// Fixture recording has to keep the bytes the agent sent, not the
    /// helper's reading of them, so this compares the file against the stdin
    /// bytes rather than against the parsed record. The transcript copy is
    /// what the title rules are later replayed from.
    @Test("records raw payloads and the transcript when WEIR_HOOK_RECORD_DIR is set", arguments: HookAgent.allCases)
    func recordDirectory_keepsRawPayloadsInOrder(agent: HookAgent) throws {
        try withTempDir { dir in
            let recordDir = dir.appendingPathComponent("record")
            try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
            let transcript = dir.appendingPathComponent("transcript.jsonl")
            let transcriptBytes = Data("{\"type\":\"ai-title\",\"aiTitle\":\"Fixture\"}\n".utf8)
            try transcriptBytes.write(to: transcript)
            let start = agent.payload("SessionStart", extra: ["cwd": dir.path, "transcript_path": transcript.path])
            let ordered = try JSONSerialization.data(withJSONObject: start, options: [.prettyPrinted, .sortedKeys])
            let payloads = [
                Data("  \n".utf8) + ordered + Data("\n\n".utf8),
                Data(#"{ "prompt" : "count \"quoted\" \\ things", "hook_event_name": "UserPromptSubmit" }"#.utf8)
            ]
            let paneID = UUID().uuidString
            var environment = try agent.environment(in: dir, paneID: paneID)
            environment["WEIR_HOOK_RECORD_DIR"] = recordDir.path
            environment["WEIR_HOOK_HELPER"] = try #require(HookHelperFixture.helperURL).path
            let wrapper = try agent.wrapper()
            for payload in payloads {
                let output = try TestProcess.run(
                    URL(fileURLWithPath: "/bin/sh"), arguments: [wrapper.path],
                    environment: IsolatedProcessEnvironment.make(environment), stdin: payload, cwd: dir
                )
                try #require(output.ending == .exited && output.status == 0, "\(output.stderrText)")
            }

            let copied = [
                "0000-SessionStart.json": payloads[0],
                "0000-SessionStart.transcript.jsonl": transcriptBytes,
                "0001-UserPromptSubmit.json": payloads[1]
            ]
            let manager = FileManager.default
            #expect(try Set(manager.contentsOfDirectory(atPath: recordDir.path)) == Set(copied.keys))
            for (name, expected) in copied {
                let url = recordDir.appendingPathComponent(name)
                #expect(try Data(contentsOf: url) == expected)
                #expect(try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
            }
        }
    }

    @Test("leaves no recording behind when the directory does not exist", arguments: HookAgent.allCases)
    func recordDirectory_missing_isIgnored(agent: HookAgent) throws {
        try withTempDir { recordRoot in
            let missing = recordRoot.appendingPathComponent("absent")
            let record = try runHooks(agent, agent.midTurn(), extraEnvironment: ["WEIR_HOOK_RECORD_DIR": missing.path])
            #expect(record?["state"] as? String == "running")
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }

    // MARK: - Wrapper

    /// The wrapper in a bundle accepts only its adjacent helper, even
    /// when a working source-tree override is provided.
    @Test("fails loudly when the bundled helper is missing", arguments: HookAgent.allCases)
    func wrapper_withoutHelper_failsLoudly(agent: HookAgent) throws {
        try withTempDir { dir in
            let resources = dir.appendingPathComponent("Fixture.app/Contents/Resources")
            let shim = resources.appendingPathComponent("\(agent.rawValue)-shim")
            let common = resources.appendingPathComponent("agent-shim")
            let manager = FileManager.default
            try manager.createDirectory(at: shim, withIntermediateDirectories: true)
            try manager.createDirectory(at: common, withIntermediateDirectories: true)
            let source = try agent.wrapper()
            let wrapper = shim.appendingPathComponent("weir-hook")
            try manager.copyItem(at: source, to: wrapper)
            let sourceCommon = source.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("agent-shim/runtime-common.sh")
            try manager.copyItem(at: sourceCommon, to: common.appendingPathComponent("runtime-common.sh"))

            let helper = try #require(HookHelperFixture.helperURL)
            try #require(manager.isExecutableFile(atPath: helper.path))
            let missing = resources.deletingLastPathComponent().appendingPathComponent("MacOS/AgentIntegrationHookHelper")
            try #require(!manager.fileExists(atPath: missing.path))
            var environment = try agent.environment(in: dir, paneID: UUID().uuidString)
            environment["WEIR_HOOK_HELPER"] = helper.path
            let output = try HookScriptHarness.feed(
                agent.payload("SessionStart", extra: ["cwd": dir.path]),
                to: URL(fileURLWithPath: "/bin/sh"),
                arguments: [wrapper.path],
                environment: IsolatedProcessEnvironment.make(environment),
                cwd: dir
            )
            let pwd = try TestProcess.run(URL(fileURLWithPath: "/bin/pwd"), arguments: ["-P"], cwd: shim)
            try #require(pwd.ending == .exited && pwd.status == 0)
            let shellPath = pwd.stdoutText.trimmingCharacters(in: .newlines) + "/../../MacOS/AgentIntegrationHookHelper"
            #expect(output.status == 1)
            #expect(output.stdout.isEmpty)
            #expect(output
                .stderrText ==
                "Weir: the Hook Helper is missing at \(shellPath), so this agent's turns are not recorded. Reinstall Weir.\n")
            #expect(!manager.fileExists(atPath: dir.appendingPathComponent("states").path))
            #expect(!manager.fileExists(atPath: dir.appendingPathComponent("sessions").path))
        }
    }

    /// A record named by the pane id is what an older writer leaves, and it
    /// may still be running beside the new one; a run keyed by its run id
    /// writes its own file and leaves that one alone.
    @Test("leaves a record named by the pane id alone", arguments: HookAgent.allCases)
    func runRecord_leavesAPaneNamedRecordAlone(agent: HookAgent) throws {
        let runID = UUID().uuidString
        let sentinel = Data("another writer owns this file".utf8)
        var paneNamed: URL?
        let record = try runHooks(
            agent,
            [agent.payload("SessionStart")],
            extraEnvironment: ["WEIR_AGENT_RUN_ID": runID],
            afterEach: { _, _, _, _ in
                let contents = try paneNamed.map { try Data(contentsOf: $0) }
                #expect(contents == sentinel)
            },
            prepare: { _, states, paneID in
                try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
                let url = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(paneID))
                try sentinel.write(to: url)
                paneNamed = url
            }
        )
        #expect(record?["runId"] as? String == runID)
    }

}

extension HookScriptTests {

    // MARK: - Lifecycle

    @Test("replays a run's lifecycle transitions event by event", arguments: HookAgent.allCases)
    func lifecycle_replaysEachTransition(agent: HookAgent) throws {
        let steps = agent.lifecycle
        let oldTimestamp = "2000-01-01T00:00:00Z"
        var records: [[String: Any]] = []
        _ = try runHooks(agent, steps.map(\.payload), extraEnvironment: ["WEIR_TURN_SNAPSHOT": "0"]) { _, states, paneID, index in
            let url = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(paneID))
            var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            records.append(record)
            let next = index + 1
            if steps.indices.contains(next), steps[next].lastHookEvent == "session_started" {
                // A stale timestamp distinguishes reset from retention
                // even when both processes start in the same second.
                record["sessionStartedAt"] = oldTimestamp
                if steps[next].payload["source"] as? String == "compact" {
                    record["runStartedAt"] = oldTimestamp
                }
                try JSONSerialization.data(withJSONObject: record).write(to: url)
            }
        }

        try #require(records.count == steps.count)
        for (index, step) in steps.enumerated() {
            let record = records[index]
            let event = step.payload["hook_event_name"] as? String ?? ""
            #expect(record["schemaVersion"] as? Int == 3, "step \(index) \(event)")
            #expect(record["state"] as? String == step.state, "step \(index) \(event)")
            #expect(record["revision"] as? Int == index + 1, "step \(index) \(event)")
            #expect(record["stateEpisodeToken"] as? String == String(step.episodeToken), "step \(index) \(event)")
            #expect(record["lastHookEvent"] as? String == step.lastHookEvent, "step \(index) \(event)")
            if step.lastHookEvent == "session_started" {
                let started = try #require(optionalText(record, "sessionStartedAt"))
                #expect(started > oldTimestamp)
                if step.payload["source"] as? String == "compact" {
                    #expect(optionalText(record, "runStartedAt") == oldTimestamp)
                }
            }
            for (key, expected) in step.texts {
                #expect(optionalText(record, key) == expected, "step \(index) \(event): \(key)")
            }
        }
    }

    /// The events the agent is told to call us on are the list the helper
    /// has to keep up with. An event subscribed but never mapped leaves the
    /// pane frozen on its last state, and nothing else notices.
    @Test("every subscribed event maps to a lifecycle state", arguments: HookAgent.allCases)
    func subscribedEvents_allReachABranch(agent: HookAgent) throws {
        let events = try agent.lifecycleSubscriptions()
        #expect(events.sorted() == agent.neutralEvents.keys.sorted())
        for event in events {
            let record = try #require(try runHooks(agent, agent.midTurn() + [agent.payload(event, extra: agent.extras(for: event))]))
            let mapped = try #require(agent.neutralEvents[event], "no neutral event named for \(event)")
            #expect(record["lastHookEvent"] as? String == mapped)
            #expect(record["revision"] as? Int == 3)
            let state = switch mapped {
            case "session_started": "idle"
            case "session_ended": "unknown"
            case "compacting": "compacting"
            case "approval_requested", "waiting_for_input": "needsInput"
            case "turn_finished", "interrupted": "finished"
            case "failed": "error"
            default: "running"
            }
            #expect(record["state"] as? String == state, "\(event)")
        }
    }

    @Test("keeps one episode token across repeated waiting writes", arguments: HookAgent.allCases)
    func waitingEpisode_repeatedState_keepsToken(agent: HookAgent) throws {
        let prompt = agent.payload("UserPromptSubmit")
        let records = try HookScriptHarness.replayRecords(agent, [prompt, agent.waitingPayload, agent.waitingPayload, prompt])
        #expect(records.map { $0["state"] as? String } == ["running", "needsInput", "needsInput", "running"])
        #expect(records.map { $0["revision"] as? Int } == [1, 2, 3, 4])
        #expect(records.map { $0["stateEpisodeToken"] as? String } == ["1", "2", "2", "4"])
    }

    @Test("keys one invocation by run id and increments its revision", arguments: HookAgent.allCases, [false, true])
    func runIdentity_multipleEvents_shareOneOrderedRecord(agent: HookAgent, usesLink: Bool) throws {
        try withTempDir { dir in
            let wrapper = try agent.wrapper()
            let invoked = dir.appendingPathComponent("weir-hook")
            if usesLink {
                try FileManager.default.createSymbolicLink(at: invoked, withDestinationURL: wrapper)
            }
            let runID = UUID().uuidString
            let name = try AgentRecordFixtures.recordFileName(runID)
            var revisions: [Int] = []
            var episodes: [String] = []
            let record = try runHooks(
                agent, agent.midTurn(), extraEnvironment: ["WEIR_AGENT_RUN_ID": runID], wrapper: usesLink ? invoked : wrapper
            ) { _, states, paneID, event in
                let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: states.appendingPathComponent(name)))
                    as? [String: Any])
                #expect(record["runId"] as? String == runID)
                #expect(record["paneId"] as? String == paneID)
                #expect(record["state"] as? String == (event == 0 ? "idle" : "running"))
                let suffix = try #require(AgentProviderRegistry.recordLayout?.runRecordSuffix)
                let files = try FileManager.default.contentsOfDirectory(atPath: states.path).filter { $0.hasSuffix(suffix) }
                #expect(files == [name])
                try revisions.append(#require(record["revision"] as? Int))
                try episodes.append(#require(record["stateEpisodeToken"] as? String))
            }
            try #require(record != nil)
            #expect(revisions == [1, 2])
            #expect(episodes == ["1", "2"])
        }
    }

    // MARK: - Files the app reads by name

    /// The app finds a pane's resume hint by the name the Rust writer
    /// reports. The helper spells it itself, so reading the hint back by the
    /// reported name is what catches a writer that drifts.
    @Test("writes the resume hint under the name the app reads", arguments: HookAgent.allCases)
    func resumeHint_usesTheReportedName(agent: HookAgent) throws {
        try withTempDir { cwd in
            var read: AgentSessionHintFixture?
            let record = try #require(try runHooks(agent, [agent.payload("SessionStart", extra: ["cwd": cwd.path])]) { dir, _, paneID, _ in
                let sessions = dir.appendingPathComponent("sessions")
                let name = try AgentRecordFixtures.hintFileName(paneID)
                let url = sessions.appendingPathComponent(name)
                let hint = try PersistenceCoders.makeDecoder().decode(AgentSessionHintFixture.self, from: Data(contentsOf: url))
                #expect(hint.paneId == paneID)
                #expect(hint.schemaVersion == 1)
                #expect(hint.sessionId == agent.sessionID)
                #expect(hint.cwd == cwd.path)
                read = hint
            })
            let hint = try #require(read)
            #expect(record["sessionId"] as? String == hint.sessionId)
        }
    }

    // MARK: - Helpers

    /// The status `git` exits with in `directory`, for a test that asks only
    /// that. Synchronous, so it can run in the harness's `afterEach`; a run past
    /// its deadline throws.
    private func gitExitStatus(_ arguments: [String], in directory: URL) throws -> Int32 {
        try GitProcess.runSync(arguments, cwd: directory).exitCode
    }

    /// The tree `git add -A` would write for `repository`, built on a copy of
    /// its index so the real one is left untouched.
    private func scratchTree(in repository: URL) async throws -> String {
        try await withTempDir { directory in
            let index = directory.appendingPathComponent("index")
            try FileManager.default.copyItem(at: repository.appendingPathComponent(".git/index"), to: index)
            let environment = ["GIT_INDEX_FILE": index.path, "GIT_OPTIONAL_LOCKS": "0"]
            try await TempGitRepo.git(["add", "-A"], in: repository, environment: environment)
            return try await TempGitRepo.git(["write-tree"], in: repository, environment: environment)
        }
    }

    /// A PATH holding the tools the wrapper and helper use, without git.
    private func pathWithoutGit(in directory: URL) throws -> String {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for command in [
            "awk", "cat", "cp", "dirname", "grep", "head", "mkdir", "mv",
            "plutil", "ps", "readlink", "rm", "sed", "sleep", "tail", "tr"
        ] {
            let candidates = ["/usr/bin/\(command)", "/bin/\(command)", "/usr/sbin/\(command)"]
            guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent(command),
                withDestinationURL: URL(fileURLWithPath: source)
            )
        }
        return bin.path
    }
}

/// One event of a replayed run and the record it should leave.
private struct LifecycleStep {
    let payload: [String: Any]
    let state: String
    let lastHookEvent: String
    let episodeToken: Int
    /// Text fields the record should hold after this event; a nil value
    /// means the field is absent.
    var texts: [String: String?] = [:]
}

private extension HookAgent {
    /// A run that visits every state the agent's events lead to, ending in a
    /// SessionStart: a compaction mid-turn for Claude, a restart for Codex.
    var lifecycle: [LifecycleStep] {
        switch self {
        case .claude:
            [
                LifecycleStep(
                    payload: payload("SessionStart", extra: ["source": "startup", "session_title": "Opening title"]),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 1,
                    texts: ["providerSessionTitle": "Opening title"]
                ),
                // A later hook omits the SessionStart fields, and the title
                // carries over.
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Opening prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 2,
                    texts: [
                        "firstPrompt": "Opening prompt", "lastPrompt": "Opening prompt",
                        "providerSessionTitle": "Opening title"
                    ]
                ),
                LifecycleStep(
                    payload: payload("PreToolUse", extra: [
                        "tool_name": "AskUserQuestion",
                        "tool_input": ["questions": [["question": "Choose a branch"]]]
                    ]),
                    state: "needsInput", lastHookEvent: "waiting_for_input", episodeToken: 3
                ),
                LifecycleStep(
                    payload: payload("PreCompact"),
                    state: "compacting", lastHookEvent: "compacting", episodeToken: 4
                ),
                LifecycleStep(
                    payload: payload("Stop"),
                    state: "finished", lastHookEvent: "turn_finished", episodeToken: 5,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("StopFailure", extra: ["error": "overloaded"]),
                    state: "error", lastHookEvent: "failed", episodeToken: 6,
                    texts: ["runStartedAt": nil, "detail": "overloaded"]
                ),
                LifecycleStep(
                    payload: payload("SessionEnd", extra: ["reason": "other"]),
                    state: "unknown", lastHookEvent: "session_ended", episodeToken: 7,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("SessionStart", extra: ["source": "startup", "session_title": "Replacement title"]),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 8,
                    texts: [
                        "firstPrompt": nil, "providerGeneratedTitle": nil,
                        "providerSessionTitle": "Replacement title"
                    ]
                ),
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Second prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 9
                ),
                // A compaction mid-turn keeps the turn open (`lifecycle.rs`):
                // the state stays running, so the episode goes on with it, and
                // the title and the opening prompt carry across.
                LifecycleStep(
                    payload: payload("SessionStart", extra: ["source": "compact"]),
                    state: "running", lastHookEvent: "session_started", episodeToken: 9,
                    texts: ["firstPrompt": "Second prompt", "providerSessionTitle": "Replacement title"]
                )
            ]
        case .codex:
            [
                LifecycleStep(
                    payload: payload("SessionStart"),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 1
                ),
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Opening prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 2,
                    texts: ["firstPrompt": "Opening prompt", "lastPrompt": "Opening prompt"]
                ),
                LifecycleStep(
                    // Codex's request carries the tool and its input but no
                    // message, so the lifecycle words the wait: with no tool
                    // before it, by its default.
                    payload: payload("PermissionRequest", extra: [
                        "tool_name": "Bash",
                        "tool_input": ["command": "make test"]
                    ]),
                    state: "needsInput", lastHookEvent: "approval_requested", episodeToken: 3,
                    texts: ["detail": "permission"]
                ),
                LifecycleStep(
                    payload: payload("PreCompact"),
                    state: "compacting", lastHookEvent: "compacting", episodeToken: 4
                ),
                LifecycleStep(
                    payload: payload("Stop"),
                    state: "finished", lastHookEvent: "turn_finished", episodeToken: 5,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("SessionEnd", extra: ["reason": "other"]),
                    state: "unknown", lastHookEvent: "session_ended", episodeToken: 6,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("SessionStart"),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 7,
                    texts: ["firstPrompt": nil]
                ),
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Second prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 8
                ),
                // Codex sends no Stop for an interrupted turn, so Interrupt
                // ends it: the turn ended, only early.
                LifecycleStep(
                    payload: payload("Interrupt", extra: ["turn_id": "01a072a0-4bb0-7020-959e-40c97c391d17"]),
                    state: "finished", lastHookEvent: "interrupted", episodeToken: 9,
                    texts: ["runStartedAt": nil]
                ),
                // Codex does not mark SessionStart as compact; its compaction
                // boundary is the separate PreCompact/PostCompact pair.
                LifecycleStep(
                    payload: payload("SessionStart"),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 10,
                    texts: ["firstPrompt": nil]
                )
            ]
        }
    }

    /// The events the agent is told to call the hook on that end in a
    /// lifecycle state. Claude's come from `settings.template.json`, which the
    /// shim hands to `claude --settings`; `CwdChanged` writes a cwd event
    /// instead, `PermissionDenied` only the turn's record, `PostModelSwitch` only
    /// the session's model, and the approval
    /// and subagent hooks go elsewhere.
    func lifecycleSubscriptions() throws -> [String] {
        switch self {
        case .claude:
            let root = try #require(RepoFixture.weirRoot)
            let template = root.appendingPathComponent("rust/weir-provider-claude/resources/settings.template.json")
            let filled = try String(contentsOf: template, encoding: .utf8)
                .replacingOccurrences(of: "@@HOOK@@", with: "/hook")
                .replacingOccurrences(of: "@@WORKTREE_PRETOOL_HOOK@@", with: "/pretool")
                .replacingOccurrences(of: "@@APPROVAL_HELPER@@", with: "/approval-helper")
            let json = try JSONSerialization.jsonObject(with: Data(filled.utf8))
            let hooks = try #require((json as? [String: Any])?["hooks"] as? [String: Any])
            return hooks.keys.sorted().filter {
                !["CwdChanged", "PermissionDenied", "PermissionRequest", "PostModelSwitch", "SubagentStop"]
                    .contains($0)
            }
        case .codex:
            return CodexHookInjection.subscribedEvents.map(\.jsonKey)
        }
    }

    /// The provider-neutral event each subscribed hook records as
    /// `lastHookEvent` (each provider crate's normalization).
    var neutralEvents: [String: String] {
        switch self {
        case .claude:
            [
                "Elicitation": "waiting_for_input",
                "ElicitationResult": "tool_finished",
                "Notification": "approval_requested",
                "PostToolUse": "tool_finished",
                "PostToolUseFailure": "tool_finished",
                "PreCompact": "compacting",
                "PreToolUse": "tool_started",
                "SessionEnd": "session_ended",
                "SessionStart": "session_started",
                "Stop": "turn_finished",
                "StopFailure": "failed",
                "UserPromptSubmit": "prompt_submitted"
            ]
        case .codex:
            [
                "SessionStart": "session_started",
                "SessionEnd": "session_ended",
                "UserPromptSubmit": "prompt_submitted",
                "PreToolUse": "tool_started",
                "PostToolUse": "tool_finished",
                "PreCompact": "compacting",
                "PostCompact": "compaction_finished",
                "PermissionRequest": "approval_requested",
                "Interrupt": "interrupted",
                "Stop": "turn_finished"
            ]
        }
    }

    /// The fields an event needs before it reaches a state at all. A Claude
    /// `Notification` that is not a permission prompt is deliberately
    /// ignored, and its tool events key off the tool name.
    func extras(for event: String) -> [String: Any] {
        guard self == .claude else { return [:] }
        return switch event {
        case "Notification": ["notification_type": "permission_prompt", "message": "needs permission"]
        case "PreToolUse": ["tool_name": "Bash"]
        case "PostToolUse", "PostToolUseFailure": ["tool_name": "AskUserQuestion"]
        case "StopFailure": ["error": "overloaded"]
        case "SessionEnd": ["reason": "other"]
        default: [:]
        }
    }

    /// The event the agent sends while it waits for the person's permission.
    var waitingPayload: [String: Any] {
        switch self {
        case .claude: payload("Notification", extra: ["notification_type": "permission_prompt"])
        case .codex: payload("PermissionRequest")
        }
    }
}
