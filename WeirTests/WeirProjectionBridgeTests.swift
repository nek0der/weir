// WeirProjectionBridgeTests.swift
// Weir — the boundary itself: what crosses it and what comes back.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("WeirProjectionBridge")
struct WeirProjectionBridgeTests {
    @Test("the registry reports the providers this build has")
    func providers_areReported() throws {
        let body = try WeirProjectionBridge.providers()
        let registry = try AgentProviderDescriptor.registry(from: body)
        #expect(registry["claude"]?.stateDirectory == "agent-states")
        #expect(registry["codex"]?.stateDirectory == "codex-agent-states")
        #expect(Set(registry.keys) == Set(AgentKind.allCases.map(\.rawValue)))
        // The rules branch on capabilities, so the host must be able to read
        // them rather than holding a list of its own.
        #expect(registry["claude"]?.capabilities.contains("cache_window") == true)
        #expect(registry["codex"]?.capabilities.contains("cache_window") == false)
    }

    /// The host hands the descriptors back to the rules in every pass. A
    /// field the Swift type does not name would be dropped on the way and
    /// reach the rules as its default: an empty list of internal agent
    /// directories, say, which would quietly turn their guard off.
    @Test("the descriptors go back to the rules as the registry reported them")
    func providers_roundTripUnchanged() throws {
        let body = try WeirProjectionBridge.providers()
        let registry = try AgentProviderDescriptor.registry(from: body)
        /// A `null` and a missing key are the same `None` to the rules, and
        /// Swift leaves a `nil` out, so the nulls are not compared.
        func withoutNulls(_ data: Data) throws -> [String: NSDictionary] {
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
            return object.mapValues { NSDictionary(dictionary: $0.filter { !($0.value is NSNull) }) }
        }
        #expect(try withoutNulls(JSONEncoder().encode(registry)) == withoutNulls(body))
        #expect(registry["codex"]?.internalAgentDirectories.isEmpty == false)
    }

    @Test("the record layout crosses the boundary and is what the registry reads")
    func recordLayout_isReported() throws {
        let layout = try JSONDecoder().decode(
            AgentRecordLayout.self,
            from: WeirProjectionBridge.recordLayout()
        )
        #expect(layout.runRecordSuffix == ".state.json")
        #expect(layout.sessionHintSuffix == ".json")
        #expect(layout.cwdEventSuffix == ".cwd.json")
        #expect(layout.worktreeEventsDirectory == "worktree-events")
        #expect(layout.worktreeEventSuffix == ".json")
        #expect(layout.lockSuffix == ".flock")
        #expect(AgentProviderRegistry.recordLayout == layout)
    }

    @Test("an empty pass answers and commits")
    func emptyPass_answersAndCommits() throws {
        let engine = WeirProjectionBridge.Engine()
        let now = Data(#"{"wall":"2026-09-14T12:00:00Z","monotonicMs":0}"#.utf8)
        let input = try JSONEncoder().encode(AgentProjectionInput())
        let pass = try engine.pass(input: input, now: now)
        let response = try JSONDecoder().decode(AgentProjectionResponse.self, from: pass.body)
        #expect(response.projection.runtimes.isEmpty)
        try engine.commit(pass.proposal)
        // Committed already, so there is nothing by that number to keep.
        #expect(throws: WeirProjectionError.self) {
            try engine.commit(pass.proposal)
        }

        // Both clocks are required: the rules compare records against wall
        // time and age pending notifications against uptime, and guessing
        // either would make a retention rule depend on the wrong one.
        for envelope in [#"{"wall":"2026-09-14T12:00:00Z"}"#, #"{"monotonicMs":0}"#] {
            #expect(throws: WeirProjectionError.self) {
                try engine.pass(input: input, now: Data(envelope.utf8))
            }
        }
    }

    @Test("a finished turn's notice waits for the pass the rules ask for")
    func finishedNotice_isHeldUntilTheAskedForPass() throws {
        let pane = UUID()
        let engine = WeirProjectionBridge.Engine()
        var input = try ProjectionBridgeFixture.input()
        input.tabs = [AgentProjectionTabPanes(id: UUID(), panes: [pane])]
        input.pidStatus = ["4242": "alive"]
        func pass(_ state: String, revision: Int, at milliseconds: UInt64) throws -> AgentProjectionResponse {
            let record: [String: Any] = [
                "schemaVersion": 3,
                "paneId": pane.uuidString,
                "runId": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                "revision": revision,
                "stateEpisodeToken": "\(revision)",
                "state": state,
                "updatedAt": "2026-09-14T12:00:0\(revision)Z",
                "pid": "4242"
            ]
            input.records = try [ProjectionBridgeFixture.file(
                provider: "claude",
                name: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
                record: record
            )]
            let answer = try ProjectionBridgeFixture.pass(
                input,
                now: ProjectionBridgeFixture.now("2026-09-14T12:01:00Z", monotonicMs: milliseconds),
                engine: engine
            )
            try engine.commit(answer.proposal)
            return answer.response
        }
        func notices(_ response: AgentProjectionResponse) -> [AgentNotificationKind] {
            response.commands.compactMap {
                if case let .notify(payload) = $0.op {
                    payload.kind
                } else {
                    nil
                }
            }
        }

        _ = try pass("running", revision: 1, at: 0)
        // Nothing the host watches changes when the hold ends, so the rules
        // say when to look again. How long they hold is theirs
        // (`notifications.rs`); the host needs the delay to arrive, and the
        // notice to come on the pass it schedules.
        let finished = try pass("finished", revision: 2, at: 10)
        #expect(notices(finished).isEmpty)
        let delay = try #require(finished.projection.nextPassInMs)
        try #require(delay > 0)
        let early = try pass("finished", revision: 2, at: 10 + delay - 1)
        #expect(notices(early).isEmpty)
        #expect(early.projection.nextPassInMs == 1)

        let settled = try pass("finished", revision: 2, at: 10 + delay)
        #expect(notices(settled) == [.finished])
    }

    @Test("a tmux-hosted run reaches the pane the host says its endpoint is in")
    func tmuxEndpointKey_matchesWhatTheRulesBuild() throws {
        let pane = UUID()
        let socket = "/tmp/tmux-501/default"
        let record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": UUID().uuidString,
            "runId": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "revision": 4,
            "stateEpisodeToken": "4",
            "state": "running",
            "updatedAt": "2026-09-14T12:00:00Z",
            "pid": "4242",
            "tmuxSocketPath": socket,
            "tmuxPaneId": "%7",
            "tmuxServerPID": "42",
            "tmuxServerStartedAt": "100",
            "sessionId": "session-1"
        ]
        var input = try ProjectionBridgeFixture.input()
        input.records = try [ProjectionBridgeFixture.file(
            provider: "claude",
            name: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            record: record
        )]
        input.pidStatus = ["4242": "alive"]
        input.tabs = [AgentProjectionTabPanes(id: UUID(), panes: [pane])]
        // The host writes this key; the rules rebuild it from the record's own
        // socket, server, and pane. If the two spellings ever diverge the run
        // simply stops appearing, with nothing logged anywhere, so the
        // agreement is what this asserts.
        input.presence.attachments[
            AgentProjectionPresence.key(for: TmuxRuntimeEndpoint(
                socketPath: socket, serverPID: "42", serverStartedAt: "100", paneID: "%7"
            ))
        ] = [pane]

        let response = try ProjectionBridgeFixture.pass(
            input,
            now: ProjectionBridgeFixture.now("2026-09-14T12:01:00Z", monotonicMs: 60000)
        ).response

        #expect(response.projection.badgesByPane[pane]?["claude"]?.state == "running")
    }

    /// The host's reading of a symlinked default home reaches the rules
    /// under the key they read: a hint the memory agent left under the
    /// link's target is no session of the pane's with it, and is one
    /// without it.
    @Test("a resolved default home keeps the memory agent's hint from the pane")
    func resolvedHomes_reachTheRules() throws {
        let pane = UUID()
        let hint: [String: Any] = [
            "schemaVersion": 1,
            "paneId": pane.uuidString,
            "sessionId": "memory-thread",
            "cwd": "/Volumes/Dotfiles/.codex/memories",
            "updatedAt": "2026-09-14T12:00:00Z"
        ]
        var input = try ProjectionBridgeFixture.input()
        input.home = "/Users/me"
        input.sessionRecords = try [ProjectionBridgeFixture.file(provider: "codex", name: pane.uuidString, record: hint)]
        input.tabs = [AgentProjectionTabPanes(id: UUID(), panes: [pane])]
        func session(_ input: AgentProjectionInput) throws -> String? {
            let response = try ProjectionBridgeFixture.pass(
                input,
                now: ProjectionBridgeFixture.now("2026-09-14T12:01:00Z", monotonicMs: 60000)
            ).response
            // Keyed as the rules spell a pane, which is not `uuidString`'s case.
            return response.projection.sessions.first { UUID(uuidString: $0.key) == pane }?.value["codex"]?.sessionID
        }

        #expect(try session(input) == "memory-thread")
        input.resolvedHomes = ["codex": "/Volumes/Dotfiles/.codex"]
        #expect(try session(input) == nil)
    }

    /// The host reads a few run record fields itself (`AgentRunRecordFacts`).
    /// The Rust corpus records are what the hook writes, so a key renamed on
    /// that side fails here rather than reading as "no tmux pane".
    @Test("the facts the host reads come out of records the Rust side wrote", .disabled(if: !RepoFixture.hasLocalRepo))
    func runRecordFacts_readCorpusRecords() throws {
        let root = try #require(RepoFixture.weirRoot)
        func facts(_ scenario: String, _ name: String) throws -> AgentRunRecordFacts? {
            let url = root.appendingPathComponent("rust/fixtures/projection/\(scenario)/agent-states/\(name).state.json")
            let file = try AgentProjectionFile(
                provider: "claude",
                name: name,
                content: String(contentsOf: url, encoding: .utf8)
            )
            return file.recordFacts
        }
        let tmux = try #require(try facts("tmux-hosted", "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"))
        #expect(tmux.sessionID == "00000000-0000-4000-8000-000000000001")
        #expect(tmux.tmuxEndpoint == TmuxRuntimeEndpoint(
            socketPath: "/tmp/weir-corpus-socket",
            serverPID: "2147483647",
            serverStartedAt: "",
            paneID: "%3"
        ))
        let plain = try #require(try facts("orphan-dead-pid", "CCCCCCCC-3333-4333-8333-CCCCCCCCCCC3"))
        #expect(plain.pid == "9999")
        #expect(plain.tmuxEndpoint == nil)
    }

    /// The record comes from replaying a recorded Claude stop that left a
    /// shell running, so the count's spelling is checked from the payload
    /// through the rules to the badge the decision bar reads.
    @Test("the background work a recorded stop left reaches the badge", .disabled(if: !RepoFixture.hasLocalRepo))
    func backgroundWork_crossesFromACorpusRecord() throws {
        let root = try #require(RepoFixture.weirRoot)
        let name = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"
        let pane = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let url = root.appendingPathComponent("rust/fixtures/projection/background-task/agent-states/\(name).state.json")
        var input = try ProjectionBridgeFixture.input()
        input.records = try [AgentProjectionFile(provider: "claude", name: name, content: String(contentsOf: url, encoding: .utf8))]
        input.pidStatus = ["4242": "alive"]
        input.tabs = [AgentProjectionTabPanes(id: UUID(), panes: [pane])]

        let response = try ProjectionBridgeFixture.pass(
            input,
            now: ProjectionBridgeFixture.now("2026-10-28T12:10:00Z", monotonicMs: 600_000)
        ).response

        let badge = try #require(response.projection.badgesByPane[pane]?["claude"])
        #expect(badge.asAgentBadge.backgroundWork == BackgroundWork(shells: 1))
    }

    /// The record comes from replaying a recorded Codex turn run with an
    /// approval policy that never asks, so the model and the mode are
    /// checked from the payload through the rules to the badge the pane
    /// header reads.
    @Test("the model and permission mode a recorded turn said reach the badge", .disabled(if: !RepoFixture.hasLocalRepo))
    func sessionSettings_crossFromACorpusRecord() throws {
        let root = try #require(RepoFixture.weirRoot)
        let name = "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2"
        let pane = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let url = root.appendingPathComponent("rust/fixtures/projection/codex-turn/codex-agent-states/\(name).state.json")
        var input = try ProjectionBridgeFixture.input()
        input.records = try [AgentProjectionFile(provider: "codex", name: name, content: String(contentsOf: url, encoding: .utf8))]
        input.pidStatus = ["4242": "alive"]
        input.tabs = [AgentProjectionTabPanes(id: UUID(), panes: [pane])]

        let response = try ProjectionBridgeFixture.pass(
            input,
            now: ProjectionBridgeFixture.now("2026-09-14T12:10:00Z", monotonicMs: 600_000)
        ).response

        let badge = try #require(response.projection.badgesByPane[pane]?["codex"]).asAgentBadge
        #expect(badge.model == "gpt-5.6-sol")
        #expect(badge.agentPermissionMode == .bypassPermissions)
    }

    @Test("a field of an unexpected type reads as absent without hiding the others")
    func runRecordFacts_unexpectedTypeIsAbsent() throws {
        let facts = try #require(AgentRunRecordFacts(content: #"{"pid": 42, "sessionId": "S"}"#))
        #expect(facts.pid == nil)
        #expect(facts.sessionID == "S")
        #expect(AgentRunRecordFacts(content: "not json") == nil)
    }

    @Test func launchOrderDecodesWithoutLosingPrecision() throws {
        let data = Data(
            #"""
            {"state":"running","updatedAt":"2026-10-31T00:00:00Z",
             "runLaunchOrder":18446744073709551615,
             "parentRunID":"AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
             "runObservedOrder":18446744073709551614}
            """#
            .utf8
        )
        let badge = try JSONDecoder().decode(AgentProjectedBadge.self, from: data).asAgentBadge
        #expect(badge.runLaunchOrder == UInt64.max)
        let saved = try JSONDecoder().decode(AgentBadge.self, from: JSONEncoder().encode(badge))
        #expect(saved.runLaunchOrder == UInt64.max)
        #expect(saved.parentRunID == "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1")
        #expect(saved.runObservedOrder == UInt64.max - 1)
    }

    /// The rules read both clocks by these two names, and refuse an
    /// envelope without either (`emptyPass_answersAndCommits`).
    @Test("the clocks a pass reads cross as the two named fields")
    func instant_encodesBothClocks() throws {
        let encoded = try JSONEncoder().encode(AgentProjectionInstant(wall: "2026-09-14T12:00:00Z", monotonicMs: 42))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.count == 2)
        #expect(object["wall"] as? String == "2026-09-14T12:00:00Z")
        #expect(object["monotonicMs"] as? Int == 42)
    }

    /// One type carries a resume intent both ways, so the keys a pass is
    /// given are the keys its command is read with.
    @Test("A resume intent keeps its exact fields across the wire", arguments: [nil as String?, "owner"])
    func resumeIntent_roundTrips(ownerRunID: String?) throws {
        let intent = AgentResumeIntentPayload(
            runID: "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            paneID: UUID(),
            sessionID: "session-1",
            ownerRunID: ownerRunID,
            pid: "4242",
            createdAt: "2026-09-14T12:00:00Z"
        )
        let encoded = try JSONEncoder().encode(intent)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var expectedKeys: Set = ["runID", "paneID", "sessionID", "pid", "createdAt"]
        if ownerRunID != nil {
            expectedKeys.insert("ownerRunID")
        }
        #expect(Set(object.keys) == expectedKeys)
        #expect(object["runID"] as? String == "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1")
        #expect(object["paneID"] as? String == intent.paneID.uuidString)
        #expect(object["sessionID"] as? String == "session-1")
        #expect(object["ownerRunID"] as? String == ownerRunID)
        #expect(object["pid"] as? String == "4242")
        #expect(object["createdAt"] as? String == "2026-09-14T12:00:00Z")

        let decoded = try JSONDecoder().decode(AgentResumeIntentPayload.self, from: encoded)
        #expect(decoded.runID == intent.runID)
        #expect(decoded.paneID == intent.paneID)
        #expect(decoded.sessionID == intent.sessionID)
        #expect(decoded.ownerRunID == ownerRunID)
        #expect(decoded.pid == intent.pid)
        #expect(decoded.createdAt == intent.createdAt)
    }
}
