// TurnRecordCacheTests.swift
// Weir — which turn records a pass hands the projection, and what comes back.
//
// The projection keeps what it read of every turn, so the cache sends a
// record's content only when the file changed. Sending too little loses a
// turn's ending; sending everything every pass costs a little more for every
// turn the person has ever run.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Turn records")
struct TurnRecordCacheTests {
    private static let run = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1"
    private static let first = "00000000-0000-4000-8000-000000000001"
    private static let second = "00000000-0000-4000-8000-000000000002"

    private func source(_ state: URL) throws -> TurnRecordCache.Source {
        try TurnRecordCache.Source(
            provider: "claude",
            directory: AgentRecordFixtures.turns(in: state),
            suffix: AgentRecordFixtures.layout().turnRecordSuffix
        )
    }

    private struct ObservedFile: Decodable, Equatable, Sendable {
        let provider: String
        let name: String
        let content: String?

        init(_ file: AgentProjectionFile) {
            provider = file.provider
            name = file.name
            content = file.content
        }

        init(name: String, content: String? = nil) {
            provider = "claude"
            self.name = name
            self.content = content
        }
    }

    // MARK: - What a pass sends

    @Test func pastItsBudget_aPassSendsTheRestByName_andTheNextSendsIt() throws {
        try withTempDir { state in
            let first = try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let second = try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let firstContent = try String(contentsOf: first, encoding: .utf8)
            let secondContent = try String(contentsOf: second, encoding: .utf8)
            let cache = TurnRecordCache()
            let source = try source(state)

            let firstRead = cache.read([source], contentBudgetBytes: 1)
            #expect(!firstRead.isComplete)
            #expect(firstRead.files.map(ObservedFile.init) == [
                ObservedFile(name: Self.first, content: firstContent), ObservedFile(name: Self.second)
            ])
            cache.commit(firstRead)
            let unchanged = try #require(cache.unchanged())
            #expect(!unchanged.isComplete)
            #expect(unchanged.files.map(ObservedFile.init) == [ObservedFile(name: Self.first), ObservedFile(name: Self.second)])

            let secondRead = cache.read([source], contentBudgetBytes: 1)
            #expect(secondRead.isComplete)
            #expect(secondRead.files.map(ObservedFile.init) == [
                ObservedFile(name: Self.first), ObservedFile(name: Self.second, content: secondContent)
            ])
        }
    }

    /// A record too large for the bridge, sent, would fail every pass after
    /// it: a failed pass is tried again with the same content.
    @Test func aRecordTooLargeToSend_goesByName_andTheRestStillArrive() throws {
        try withTempDir { state in
            let large = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let small = try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let smallContent = try String(contentsOf: small, encoding: .utf8)
            let content = try String(contentsOf: large, encoding: .utf8)
            try (content + String(repeating: " ", count: 4096)).write(to: large, atomically: true, encoding: .utf8)
            let cache = TurnRecordCache()

            let read = try cache.read([source(state)], maxRecordBytes: 2048)
            #expect(read.files.map(ObservedFile.init) == [
                ObservedFile(name: Self.first), ObservedFile(name: Self.second, content: smallContent)
            ])
            #expect(read.oversized == [large.path])
            #expect(read.isComplete, "nothing is left for a pass that would only hold it back again")
            #expect(!read.hasUnreadRecord)
            cache.commit(read)

            let again = try cache.read([source(state)], maxRecordBytes: 2048)
            #expect(again.files.map(ObservedFile.init) == [ObservedFile(name: Self.first), ObservedFile(name: Self.second)])
            #expect(again.oversized == [large.path])
            #expect(cache.unchanged()?.oversized == [large.path])
            cache.commit(again)

            let replacement = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "failed", in: state
            )
            let replacementContent = try String(contentsOf: replacement, encoding: .utf8)
            let shrunk = try cache.read([source(state)], maxRecordBytes: 2048)
            #expect(shrunk.files.map(ObservedFile.init) == [
                ObservedFile(name: Self.first, content: replacementContent), ObservedFile(name: Self.second)
            ])
            #expect(shrunk.oversized.isEmpty)
        }
    }

    /// The bridge refuses an input over 16 MiB; one record past it used to be
    /// read whole and sent on every pass.
    @Test func aRecordPastTheBridgeLimit_keepsThePassUnderIt() throws {
        try withTempDir { state in
            let large = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let small = try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let oversized = String(repeating: "\u{1}", count: 3 * 1024 * 1024)
            try oversized.write(to: large, atomically: true, encoding: .utf8)
            #expect(oversized.utf8.count < TurnRecordCache.maxRecordBytes)

            var input = AgentProjectionInput()
            input.providers = AgentProviderRegistry.descriptors.filter { $0.key == "claude" }
            input.turnFiles = [AgentProjectionFile(provider: "claude", name: Self.first, content: oversized)]
            let encoder = JSONEncoder()
            let tooLarge = try encoder.encode(input)
            #expect(tooLarge.count > 16 * 1024 * 1024)

            let read = try TurnRecordCache().read([source(state)])
            let smallContent = try String(contentsOf: small, encoding: .utf8)
            #expect(read.oversized == [large.path])
            #expect(read.files.map(ObservedFile.init) == [
                ObservedFile(name: Self.first), ObservedFile(name: Self.second, content: smallContent)
            ])
            input.turnFiles = read.files
            let bytes = try encoder.encode(input)
            #expect(bytes.count < 16 * 1024 * 1024)
            let answer = try WeirProjectionBridge.Engine().pass(input: bytes, now: encoder.encode(AgentProjectionInstant.now()))
            let response = try JSONDecoder().decode(AgentProjectionResponse.self, from: answer.body)
            #expect(response.projection.conversations?.elements.flatMap(\.turns).map(\.turnID) == [TurnID(Self.second)])
        }
    }

    /// The budget counts content as encoded: escapes can take a record past
    /// the bridge's limit when its bytes alone are under it.
    @Test func encodedLength_isWhatJSONEncoderWrites() throws {
        let samples = ["", "plain", "a/b\\c\"d", "\n\t\r\u{8}\u{C}", "\u{1}\u{1F}\u{7F}", "日本語 é"]
        for sample in samples {
            let encoded = try JSONEncoder().encode([sample])
            // Less the brackets and the quotes.
            #expect(TurnRecordCache.encodedLength(of: sample) == encoded.count - 4, "\(sample.debugDescription)")
        }
    }

    @Test func aRecordIsSentOnce_untilItChanges() throws {
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()

            let firstRead = try cache.read([source(state)])
            #expect(firstRead.files.map(\.name) == [Self.first])
            #expect(firstRead.files.first?.content != nil)
            cache.commit(firstRead)

            let secondRead = try cache.read([source(state)])
            #expect(secondRead.files.map(\.name) == [Self.first], "still named, so the turn stays")
            #expect(secondRead.files.first?.content == nil)
            cache.commit(secondRead)

            // The hook ends the turn: a new file renamed over the old one.
            try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "failed", in: state
            )
            let thirdRead = try cache.read([source(state)])
            #expect(thirdRead.files.first?.content?.contains("failed") == true)
        }
    }

    @Test func aPassThatDoesNotLook_sendsEveryRecordByName() throws {
        // The sweep's pass: no directory read, and nothing the projection
        // holds is lost.
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))

            let unchanged = try #require(cache.unchanged())

            #expect(unchanged.files.map(\.name) == [Self.first, Self.second])
            #expect(unchanged.files.allSatisfy { $0.content == nil })
            cache.commit(unchanged)
            let next = try cache.read([source(state)])
            #expect(next.files.map(ObservedFile.init) == [ObservedFile(name: Self.first), ObservedFile(name: Self.second)])
        }
    }

    @Test func aListThatCannotStandInForTheDirectories_isNotOffered() throws {
        // Then the sweep's pass reads the directories after all.
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            #expect(cache.unchanged() == nil, "nothing committed yet")

            try cache.commit(cache.read([source(state)]))
            #expect(cache.unchanged() != nil)

            cache.forgetLastList()
            #expect(cache.unchanged() == nil, "a pass failed after reading")

        }
    }

    @Test func aLinkNamedLikeARecord_isNotRead() throws {
        try withTempDir { state in
            let target = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let link = try target.deletingLastPathComponent()
                .appendingPathComponent(Self.second + AgentRecordFixtures.layout().turnRecordSuffix)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(try TurnRecordCache().read([source(state)]).files.map(\.name) == [Self.first])
        }
    }

    /// The projection drops a turn whose name a pass leaves out, so a
    /// directory that could not be listed must not read as one emptied.
    @Test(.enabled(if: geteuid() != 0), arguments: [false, true])
    func aDirectoryThatCouldNotBeListed_keepsItsTurns_untilItCanBe(deniesAncestorSearch: Bool) throws {
        try withTempDir { state in
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))
            let directory = deniesAncestorSearch ? state : try source(state).directory
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

            let read = try cache.read([source(state)])
            #expect(read.files.map(\.name) == [Self.first, Self.second])
            #expect(read.files.allSatisfy { $0.content == nil }, "by name, which keeps what the projection read")
            #expect(read.hasUnreadRecord)
            cache.commit(read)
            #expect(cache.unchanged() == nil, "the next pass lists the directory again")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let recovered = try cache.read([source(state)])
            #expect(recovered.files.map(\.name) == [Self.first, Self.second])
            #expect(recovered.files.allSatisfy { $0.content == nil })
            #expect(!recovered.hasUnreadRecord)
            cache.commit(recovered)
            let unchanged = try #require(cache.unchanged())
            #expect(unchanged.files.map(\.name) == [Self.first, Self.second])
        }
    }

    /// An absent directory has no turns, including a removed link target.
    @Test(arguments: [false, true])
    func aMissingDirectory_hasNoTurns(removesLinkedDirectory: Bool) throws {
        try withTempDir { state in
            let cache = TurnRecordCache()
            if removesLinkedDirectory {
                try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
                let directory = try source(state).directory
                let target = state.appendingPathComponent("linked-turns")
                try FileManager.default.moveItem(at: directory, to: target)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
                let initial = try cache.read([source(state)])
                #expect(initial.files.map(\.name) == [Self.first])
                cache.commit(initial)
                try FileManager.default.removeItem(at: target)
            }
            let read = try cache.read([source(state)])
            #expect(read.files.isEmpty)
            #expect(!read.hasUnreadRecord)
        }
    }

    @Test func aRemovedRecord_isNoLongerSent() throws {
        try withTempDir { state in
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))
            try FileManager.default.removeItem(at: url)

            #expect(try cache.read([source(state)]).files.map(\.name) == [Self.second])
        }
    }

    @Test func aRecordReplacedWithTheSameSizeAndTime_isSentAgain() throws {
        // Only the inode tells this rewrite apart, as when a turn ends within
        // the clock tick it began in.
        try withTempDir { state in
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let cache = TurnRecordCache()
            try cache.commit(cache.read([source(state)]))
            let original = try String(contentsOf: url, encoding: .utf8)
            let replacement = original.replacingOccurrences(of: "\"s1\"", with: "\"s2\"")
            try #require(replacement != original)
            var before = stat()
            try #require(lstat(url.path, &before) == 0)
            let staging = url.deletingLastPathComponent().appendingPathComponent(".replacement")
            try replacement.write(to: staging, atomically: true, encoding: .utf8)
            let times = [before.st_atimespec, before.st_mtimespec]
            try #require(utimensat(AT_FDCWD, staging.path, times, 0) == 0)
            try #require(rename(staging.path, url.path) == 0)
            var after = stat()
            try #require(lstat(url.path, &after) == 0)
            try #require(before.st_size == after.st_size)
            try #require(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
            try #require(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            try #require(before.st_ino != after.st_ino)

            let reread = try cache.read([source(state)])
            #expect(reread.files.map(ObservedFile.init) == [ObservedFile(name: Self.first, content: replacement)])
        }
    }

    @Test(.enabled(if: geteuid() != 0))
    func aRecordThatCouldNotBeRead_isSentWhenItCanBe() throws {
        try withTempDir { state in
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            let cache = TurnRecordCache()
            let source = try source(state)
            cache.commit(cache.read([source]))
            let replacement = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "failed", in: state
            )
            let expected = try String(contentsOf: replacement, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            try #require(FileManager.default.contents(atPath: url.path) == nil)

            let unreadable = cache.read([source])
            #expect(unreadable.files.map(ObservedFile.init) == [ObservedFile(name: Self.first)])
            #expect(unreadable.hasUnreadRecord)
            cache.commit(unreadable)
            #expect(cache.unchanged() == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            let readable = cache.read([source])
            #expect(!readable.hasUnreadRecord)
            #expect(readable.files.map(ObservedFile.init) == [ObservedFile(name: Self.first, content: expected)])
        }
    }

    @Test func aFileInProgressOrOfAnotherKind_isNotARecord() throws {
        try withTempDir { state in
            let record = try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let content = try String(contentsOf: record, encoding: .utf8)
            let source = try source(state)
            try Data(content.utf8).write(to: source.directory.appendingPathComponent("." + Self.second + source.suffix))
            try Data(content.utf8).write(to: source.directory.appendingPathComponent("0123abcd.counter"))

            let read = TurnRecordCache().read([source])
            #expect(read.files.map(ObservedFile.init) == [ObservedFile(name: Self.first, content: content)])
        }
    }

    // MARK: - Reading what comes back

    @Test func aTurnFromANewerWriter_readsAsUnknown() throws {
        let json = #"""
        {"turnId":"T","conversation":{"provider":"claude","conversationId":"s","isFallback":false},
         "runId":"R","paneId":"P","displayNumber":3,"startedAt":"2026-10-12T00:00:00Z",
         "phase":"paused","changes":{"kind":"partial"},"hasPrompt":true}
        """#
        let turn = try JSONDecoder().decode(TurnSummary.self, from: Data(json.utf8))

        #expect(turn.phase == .unknown)
        #expect(turn.changes == .unknown)
        #expect(turn.displayNumber == 3)
    }

    @Test func aConversationOfAProviderThisBuildLacks_isDropped() throws {
        let json = #"""
        [{"key":{"provider":"gemini","conversationId":"g","isFallback":false},"turns":[]},
         {"key":{"provider":"claude","conversationId":"s","isFallback":false},"turns":[]}]
        """#
        let list = try JSONDecoder().decode(
            AgentProjectionLossyList<ConversationTurns>.self, from: Data(json.utf8)
        )

        #expect(list.elements.map(\.key.conversationID) == ["s"])
        #expect(list.skipped == 1)
    }

}

extension TurnRecordCacheTests {

    // MARK: - Through a pass

    enum FailurePoint: Equatable, Sendable {
        case pass, commit
    }

    private struct ObservedRun: Decodable {
        let revision: Int
    }

    private struct ObservedInput: Decodable, Sendable {
        let records: [ObservedFile]
        let turnFiles: [ObservedFile]

        var revision: Int? {
            guard let content = records.first?.content else { return nil }
            return try? JSONDecoder().decode(ObservedRun.self, from: Data(content.utf8)).revision
        }
    }

    private final class InspectingEngine: ProjectionPassing {
        let inputs = Recorded<[ObservedInput]>([])
        let commits = Recorded(0)
        let failure = Recorded<FailurePoint?>(nil)
        let release = DispatchSemaphore(value: 0)
        private let engine = WeirProjectionBridge.Engine()
        private let heldRevision: Int?

        init(heldRevision: Int? = nil) {
            self.heldRevision = heldRevision
        }

        func pass(input: Data, now: Data) throws -> WeirProjectionPass {
            let observed = try JSONDecoder().decode(ObservedInput.self, from: input)
            inputs.update { $0.append(observed) }
            if let heldRevision, observed.revision == heldRevision,
               release.wait(timeout: .now() + 10) != .success
            {
                throw WeirProjectionError.rust(-2)
            }
            if failure.value == .pass {
                throw WeirProjectionError.rust(-1)
            }
            return try engine.pass(input: input, now: now)
        }

        func commit(_ proposal: UInt64) throws {
            if failure.value == .commit {
                throw WeirProjectionError.rust(-1)
            }
            try engine.commit(proposal)
            commits.update { $0 += 1 }
        }

        func turnsTaken(change: Data, now: Data) throws -> Int {
            try engine.turnsTaken(change: change, now: now)
        }
    }

    private func adapter(
        state: URL,
        sessions: URL,
        engine: any ProjectionPassing = WeirProjectionBridge.Engine()
    ) -> AgentProjectionAdapter {
        ProjectionFixture.adapter(
            provider: "claude",
            state: state,
            sessions: sessions,
            resumeIntents: AgentResumeIntentStore(directory: state.deletingLastPathComponent()
                .appendingPathComponent("resume-intents", isDirectory: true)),
            processStatus: { _ in .alive },
            engine: engine
        )
    }

    private func writeRun(
        session: String,
        currentTurn: String?,
        state runState: String = "finished",
        revision: Int = 4,
        in state: URL
    ) throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        var record: [String: Any] = [
            "schemaVersion": 3,
            "paneId": UUID().uuidString,
            "runId": Self.run,
            "revision": revision,
            "state": runState,
            "updatedAt": "2026-10-12T00:01:30Z",
            "pid": "4242",
            "sessionId": session
        ]
        record["currentTurnId"] = currentTurn
        try JSONSerialization.data(withJSONObject: record)
            .write(to: state.appendingPathComponent(AgentRecordFixtures.recordFileName(Self.run)))
    }

    @Test func aPass_putsTheRecordedTurnsInTheHistory() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: Self.second, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, phase: "started",
                changes: #"{"kind":"pending"}"#, in: state
            )
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let adapter = adapter(state: state, sessions: sessions)

            adapter.bootstrap(into: session, attention: attention)

            let key = ConversationKey(provider: .claude, conversationID: "s1", isFallback: false)
            let turns = adapter.turnHistory.turns(of: key)
            #expect(turns.map(\.displayNumber) == [1, 2])
            // The first is still started behind a later one: overtaken, so
            // not running and not known.
            #expect(turns.first?.phase == .unknown)
            #expect(turns.first?.changes == .unavailable(reason: "endMissing"))
            #expect(turns.last?.changes == .changed(files: 2, added: 94, removed: 2))
            #expect(turns.last?.hasShellChanges == false)
            #expect(turns.last?.largeFilesSkipped == 0)
            let runtime = try #require(attention.allRuntimes.first)
            #expect(runtime.conversation == key)
            #expect(runtime.currentTurnID == TurnID(Self.second))
            #expect(adapter.turnHistory.turn(TurnID(Self.second))?.displayNumber == 2)
        }
    }

    @Test func aFileEventOutsideTheTurns_goesByTheLastList_andOneInsideListsThemAgain() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: AttentionState())
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)

            // A run record changed, or tmux, attention, or the sweep asked:
            // the turns are not listed again, and the ones known stay.
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(adapter.turnHistory.turn(TurnID(Self.second)) == nil)
            #expect(adapter.turnHistory.turn(TurnID(Self.first))?.displayNumber == 1)

            adapter.noteTurnsChanged()
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(adapter.turnHistory.turn(TurnID(Self.second))?.displayNumber == 2)
        }
    }

    @Test func aRecordWrittenBeforeTheWatchStarted_isListed() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let turnFolder = try source(state).directory
            let directories = AgentDirectories(state: state, sessions: sessions, cwdEvents: nil)
            for folder in [state, sessions, turnFolder] + [directories.worktreeEvents].compactMap(\.self) {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: AttentionState())
            #expect(adapter.turnHistory.turn(TurnID(Self.first)) == nil)
            // No run record means there is no periodic PID sweep to fill in
            // for the watcher's catch-up request.
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)

            adapter.startWatching()
            defer { adapter.stopWatching() }
            await pollUntil { adapter.turnHistory.turn(TurnID(Self.first)) != nil }
            await adapter.passesSettled()

            #expect(adapter.turnHistory.turn(TurnID(Self.first))?.displayNumber == 1)
        }
    }

    @Test(.enabled(if: geteuid() != 0))
    func aRecordThatCouldNotBeRead_isReadByTheNextPass_withoutItsDirectoryChanging() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let url = try AgentRecordFixtures.writeTurn(
                id: Self.first, number: 1, session: "s1", runID: Self.run, in: state
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            try #require(FileManager.default.contents(atPath: url.path) == nil)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: AttentionState())
            #expect(adapter.turnHistory.turn(TurnID(Self.first)) == nil)

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            adapter.requestPass()
            await adapter.passesSettled()

            #expect(adapter.turnHistory.turn(TurnID(Self.first))?.displayNumber == 1)
        }
    }

    @Test func theRecordsAreSentInNameOrder() throws {
        try withTempDir { state in
            let ids = (1...12).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
            for (index, id) in ids.reversed().enumerated() {
                try AgentRecordFixtures.writeTurn(id: id, number: index + 1, session: "s1", runID: Self.run, in: state)
            }
            #expect(try TurnRecordCache().read([source(state)]).files.map(\.name) == ids)
        }
    }

    @Test func aPassAskedForWhileOneRuns_runsAfterIt_andReadsWhatChanged() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let engine = InspectingEngine(heldRevision: 5)
            defer { engine.release.signal() }
            let adapter = adapter(state: state, sessions: sessions, engine: engine)
            adapter.bootstrap(into: session, attention: attention)

            try writeRun(session: "s1", currentTurn: nil, revision: 5, in: state)
            adapter.requestPass()
            await pollUntil { engine.inputs.value.map(\.revision) == [4, 5] }
            try #require(engine.inputs.value.map(\.revision) == [4, 5])
            try writeRun(session: "s1", currentTurn: nil, state: "running", revision: 6, in: state)
            adapter.requestPass()
            adapter.requestPass()
            #expect(engine.inputs.value.map(\.revision) == [4, 5])
            engine.release.signal()
            await adapter.passesSettled()

            #expect(engine.inputs.value.map(\.revision) == [4, 5, 6])
            #expect(engine.commits.value == 3)
            #expect(attention.allRuntimes.first?.badge.state == .running)
            #expect(adapter.lastFailure == nil)
        }
    }

    @Test func aPassRunInPlace_isNotUndoneByARequestedOneThatStartedBefore() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let engine = InspectingEngine(heldRevision: 5)
            defer { engine.release.signal() }
            let adapter = adapter(state: state, sessions: sessions, engine: engine)
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            adapter.bootstrap(into: session, attention: attention)

            try writeRun(session: "s1", currentTurn: nil, revision: 5, in: state)
            adapter.requestPass()
            await pollUntil { engine.inputs.value.map(\.revision) == [4, 5] }
            try #require(engine.inputs.value.map(\.revision) == [4, 5])
            #expect(engine.inputs.value.last?.turnFiles == [ObservedFile(name: Self.first)])
            try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            try writeRun(session: "s1", currentTurn: Self.second, state: "running", revision: 6, in: state)
            adapter.refresh()
            let key = ConversationKey(provider: .claude, conversationID: "s1", isFallback: false)
            let newer = adapter.turnHistory.turns(of: key)
            try #require(newer.map(\.turnID) == [TurnID(Self.first), TurnID(Self.second)])

            engine.release.signal()
            await adapter.passesSettled()

            #expect(engine.inputs.value.map(\.revision) == [4, 5, 6])
            #expect(engine.commits.value == 2)
            #expect(adapter.turnHistory.turns(of: key) == newer)
            #expect(attention.allRuntimes.first?.badge.state == .running)
            #expect(adapter.lastFailure == nil, "dropped without reporting a failure")
        }
    }

    @Test func aMarkSetWhileAPassRuns_isKept() async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let adapter = adapter(state: state, sessions: sessions)
            adapter.bootstrap(into: session, attention: attention)
            let runtime = try #require(attention.allRuntimes.first)

            // The pass reads the marks before the person views the run, here
            // by reading its notification (the run's pane is in no tab).
            adapter.requestPass()
            attention.markFinishedRuntimesViewed(matching: [runtime.id: [runtime.attentionEventToken]])
            await adapter.passesSettled()

            #expect(attention.viewedRuntimeTokens[runtime.id] == runtime.attentionEventToken)
            // The pass that change asks for keeps it, the run still being there.
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(attention.viewedRuntimeTokens[runtime.id] == runtime.attentionEventToken)
        }
    }

    @Test(arguments: [FailurePoint.pass, .commit])
    func aPassThatFailed_changesNothing_andTheNextOneCatchesUp(failsAt: FailurePoint) async throws {
        try await withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s1", currentTurn: nil, in: state)
            try AgentRecordFixtures.writeTurn(id: Self.first, number: 1, session: "s1", runID: Self.run, in: state)
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let attention = AttentionState()
            let engine = InspectingEngine()
            let adapter = adapter(state: state, sessions: sessions, engine: engine)
            adapter.bootstrap(into: session, attention: attention)
            let key = ConversationKey(provider: .claude, conversationID: "s1", isFallback: false)
            let baseline = adapter.turnHistory.turns(of: key)
            try #require(baseline.map(\.turnID) == [TurnID(Self.first)])

            engine.failure.value = failsAt
            let added = try AgentRecordFixtures.writeTurn(id: Self.second, number: 2, session: "s1", runID: Self.run, in: state)
            let addedContent = try String(contentsOf: added, encoding: .utf8)
            let expected = [ObservedFile(name: Self.first), ObservedFile(name: Self.second, content: addedContent)]
            try writeRun(session: "s1", currentTurn: nil, state: "running", revision: 5, in: state)
            adapter.noteTurnsChanged()
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(engine.inputs.value.map(\.revision) == [4, 5])
            #expect(engine.inputs.value.last?.turnFiles == expected)
            #expect(engine.commits.value == 1)
            #expect(adapter.lastFailure != nil)
            #expect(attention.allRuntimes.first?.badge.state == .finished)
            #expect(adapter.turnHistory.turns(of: key) == baseline)

            // No new turn-directory event is needed to send the content again.
            engine.failure.value = nil
            adapter.requestPass()
            await adapter.passesSettled()
            #expect(engine.inputs.value.map(\.revision) == [4, 5, 5])
            #expect(engine.inputs.value.last?.turnFiles == expected)
            #expect(engine.commits.value == 2)
            #expect(adapter.lastFailure == nil)
            #expect(attention.allRuntimes.first?.badge.state == .running)
            #expect(adapter.turnHistory.turns(of: key).map(\.turnID) == [TurnID(Self.first), TurnID(Self.second)])
        }
    }

    /// One pass over 200 turns in each of five conversations, read cold and
    /// then with nothing changed. The times are printed for a person to
    /// compare and not checked: a bound that fails cannot tell a regression
    /// from a slow machine. Off unless `WEIR_MEASURE=1` (`make test-measure`).
    @Test(.tags(.measurement), .enabled(if: ProcessInfo.processInfo.environment["WEIR_MEASURE"] == "1"))
    func aPassOverAThousandTurns_isTimed() throws {
        try withTempDir { root in
            let state = root.appendingPathComponent("agent-states", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try writeRun(session: "s0", currentTurn: nil, in: state)
            for conversation in 0..<5 {
                for number in 1...200 {
                    try AgentRecordFixtures.writeTurn(
                        id: UUID().uuidString, number: number, session: "s\(conversation)",
                        runID: Self.run, in: state
                    )
                }
            }
            let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
            let adapter = adapter(state: state, sessions: sessions)
            let clock = ContinuousClock()

            let cold = clock.measure { adapter.bootstrap(into: session, attention: AttentionState()) }
            let warm = clock.measure { adapter.refresh() }

            print("TurnRecordCacheTests: 1000 turns, cold pass \(cold), warm pass \(warm)")
            #expect(adapter.turnHistory.conversations.count == 5)
            #expect(adapter.turnHistory.conversations.values.allSatisfy { $0.count == 200 })
        }
    }
}
