// AgentIntegrationXPCClientTests.swift
// Weir — invalidating the client ends a blocked call and fails any later one at once.

import Foundation
import Testing
@testable import Weir

struct AgentIntegrationXPCClientTests {
    @Test(.timeLimit(.minutes(1)))
    func invalidate_endsABlockedCallWithinOneSecond() async throws {
        let service = HeldXPCService(holding: .everything)
        // Keep a missing invalidation callback within the suite's limit,
        // while distinguishing it from the one-second invalidation contract.
        let client = try service.client(timeoutSeconds: 30)
        defer { client.invalidate() }
        let clock = ContinuousClock()
        let call = Task {
            await OffPoolWork.run {
                let result = Result { try client.openSession() }
                return (result, clock.now)
            }
        }
        await pollUntil(timeout: .seconds(10)) { service.heldCount == 1 }
        do {
            try #require(service.heldCount == 1)
        } catch {
            client.invalidate()
            _ = await call.value
            throw error
        }

        let invalidatedAt = clock.now
        client.invalidate()
        let (result, finishedAt) = await call.value
        let error = #expect(throws: AgentIntegrationError.self) {
            try result.get()
        }
        guard case .requestFailed = error else {
            Issue.record("expected invalidation to fail the pending call, got \(String(describing: error))")
            return
        }
        #expect(invalidatedAt.duration(to: finishedAt) >= .zero)
        #expect(invalidatedAt.duration(to: finishedAt) < .seconds(1))
    }

    enum Call: CaseIterable, Sendable {
        case openSession
        case exchange
    }

    /// A later call is refused by the client without waiting for an XPC reply.
    @Test(.timeLimit(.minutes(1)), arguments: Call.allCases)
    func invalidate_refusesLaterCallsLocally(_ call: Call) throws {
        let service = HeldXPCService(holding: .everything)
        let client = try service.client(timeoutSeconds: 30)
        client.invalidate()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let error = #expect(throws: AgentIntegrationError.self) {
            switch call {
            case .openSession:
                _ = try client.openSession()
            case .exchange:
                _ = try client.exchange(Data("{}".utf8))
            }
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
        guard case let .requestFailed(reason) = error else {
            Issue.record("Expected local invalidation refusal, got \(String(describing: error))")
            return
        }
        #expect(reason == "The connection was invalidated.")
        #expect(service.heldCount == 0)
    }
}
