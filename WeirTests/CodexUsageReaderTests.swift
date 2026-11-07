// CodexUsageReaderTests.swift
// Weir — asking Codex's app server for its usage: the exchange, and reading the answer through the Rust bridge.

import Foundation
import os
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Codex usage reader")
struct CodexUsageReaderTests {
    /// A stand-in for `codex app-server`: it reads the handshake and the
    /// request, answers the request, and leaves when its input closes, as the
    /// real server does.
    private static func fakeServer(answer: String) -> String {
        #"""
        #!/bin/sh
        read -r initialize
        read -r initialized
        read -r request
        echo '{"method":"configWarning","params":{}}'
        echo '{"id":1,"result":{}}'
        echo '{"id":2,"method":"probe","params":{}}'
        echo '{"id":2}'
        echo '\#(answer)'
        while read -r line; do :; done
        """#
    }

    @Test("asks for the rate limits after the handshake, one message per line")
    func requestLines_holdTheHandshakeAndTheRequest() throws {
        let text = try #require(String(bytes: CodexUsageReader.requestLines, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        let lines = try text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map { line in
            try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        #expect(lines.map { $0["method"] as? String } == ["initialize", "initialized", "account/rateLimits/read"])
        #expect(lines.map { $0["id"] as? Int } == [1, nil, 2])
        #expect(lines.map { $0["jsonrpc"] as? String } == ["2.0", "2.0", "2.0"])
    }

    @Test("knows the answer to the usage request from the rest of the stream")
    func isAnswer_matchesOnlyTheUsageRequest() {
        #expect(CodexUsageReader.isAnswer(Data(#"{"id":2,"result":{}}"#.utf8)))
        #expect(CodexUsageReader.isAnswer(Data(#"{"id":2,"error":{"code":1}}"#.utf8)))
        #expect(CodexUsageReader.isAnswer(Data(#"{"id":2,"result":null}"#.utf8)))
        #expect(CodexUsageReader.isAnswer(Data(#"{"id":2,"result":"value"}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":2,"method":"probe","params":{}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":2}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":2,"method":"probe","result":{}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":2,"result":{},"error":{"code":1}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":null,"result":{}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"id":1,"result":{}}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data(#"{"method":"configWarning"}"#.utf8)))
        #expect(!CodexUsageReader.isAnswer(Data("not json".utf8)))
    }

    @Test("skips other messages and returns the exact usage response", arguments: [
        #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}"#,
        #"{"id":2,"error":{"code":-32600,"message":"failed"}}"#
    ])
    func exchange_returnsTheAnswerLine(expected: String) async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable(Self.fakeServer(answer: expected), at: server)
            let answer = await CodexUsageReader.exchange(executable: server.path, path: ShimHarness.systemPath)
            let line = try #require(answer)
            #expect(line == Data(expected.utf8))
        }
    }

    @Test("gives up on a server that never answers")
    func exchange_timesOut() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable("#!/bin/sh\nwhile read -r line; do :; done\n", at: server)
            // The timer fires as soon as it is set, so the wait ends on the
            // timeout whatever the machine's load, and says what it was set for.
            let delays = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let answer = await CodexUsageReader.exchange(
                executable: server.path,
                path: ShimHarness.systemPath,
                timeout: .milliseconds(500)
            ) { delay, fire in
                delays.withLock { $0.append(delay) }
                fire()
            }
            #expect(answer == nil)
            #expect(delays.withLock { $0 } == [.milliseconds(500)], "the timeout given, not the default")
        }
    }

    /// The dispatch timer the app counts a timeout with is handed the delay
    /// in seconds with their fractions, not a whole number of them.
    @Test("a timeout's delay reaches the dispatch timer in seconds, fractions kept", arguments: [
        (Duration.milliseconds(500), 0.5),
        (.seconds(15), 15),
        (.seconds(2) + .milliseconds(250), 2.25)
    ])
    func seconds_keepTheDelaysFractions(delay: Duration, seconds: Double) {
        #expect(abs(CodexUsageReader.seconds(delay) - seconds) < 1e-9)
    }

    /// A server that ends before it reads anything: the requests meet a
    /// closed pipe, which must fail the write rather than end the app.
    @Test("comes back empty from a server that ends at once")
    func exchange_serverThatEndsAtOnce_returnsNothing() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable("#!/bin/sh\nexit 1\n", at: server)
            for _ in 0..<5 {
                let answer = await CodexUsageReader.exchange(executable: server.path, path: ShimHarness.systemPath)
                #expect(answer == nil)
            }
        }
    }

    /// The panel closing cancels the read at any moment, before the server
    /// starts as well as while it runs.
    @Test("ends cleanly whenever it is canceled")
    func exchange_canceled_endsCleanly() async throws {
        try await withTempDir { dir in
            let server = dir.appendingPathComponent("codex")
            try ShimHarness.writeExecutable("#!/bin/sh\nwhile read -r line; do :; done\n", at: server)
            let canceledBeforeStart = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await CodexUsageReader.exchange(executable: server.path, path: ShimHarness.systemPath)
            }
            #expect(await canceledBeforeStart.value == nil)

            let hasStarted = OSAllocatedUnfairLock(initialState: false)
            let didTimeOut = OSAllocatedUnfairLock(initialState: false)
            let canceledAfterStart = Task {
                await CodexUsageReader
                    .exchange(executable: server.path, path: ShimHarness.systemPath, timeout: .seconds(2)) { delay, fire in
                        hasStarted.withLock { $0 = true }
                        CodexUsageReader.dispatchTimer(delay) {
                            didTimeOut.withLock { $0 = true }
                            fire()
                        }
                    }
            }
            await pollUntil(interval: .milliseconds(10)) { hasStarted.withLock { $0 } }
            canceledAfterStart.cancel()
            #expect(await canceledAfterStart.value == nil)
            #expect(hasStarted.withLock { $0 })
            #expect(!didTimeOut.withLock { $0 })
        }
    }

    @Test("reads Codex's answer through its adapter, an error apart from no plan")
    func bridge_readsTheAnswer() throws {
        let answer = Data(#"""
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1793776116},
         "secondary":null,"planType":"prolite"}}}
        """#.utf8)
        guard case let .usage(usage) = try WeirUsageBridge.planUsageAnswer(provider: .codex, answer: answer) else {
            Issue.record("expected the usage")
            return
        }
        #expect(usage.windows == [
            PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_793_776_116))
        ])
        #expect(usage.resetCredits == nil)

        let noPlan = Data(#"{"id":2,"result":{"rateLimits":{"primary":null,"secondary":null}}}"#.utf8)
        #expect(try WeirUsageBridge.planUsageAnswer(provider: .codex, answer: noPlan) == .noPlan)
        let error = Data(#"{"id":2,"error":{"code":-32600,"message":"failed"}}"#.utf8)
        #expect(try WeirUsageBridge.planUsageAnswer(provider: .codex, answer: error) == .unreadable)
    }
}
