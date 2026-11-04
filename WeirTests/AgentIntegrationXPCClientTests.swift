// AgentIntegrationXPCClientTests.swift
// Weir — invalidating the client ends a blocked call and fails any later one at once.

import Foundation
import Testing
@testable import Weir

struct AgentIntegrationXPCClientTests {
    @Test(.timeLimit(.minutes(1)))
    func invalidate_endsABlockedCallWithinOneSecond() async throws {
        let service = HeldXPCService(holding: .everything)
        let client = try service.client()
        let call = Task {
            try await OffPoolWork.run { try client.openSession() }
        }
        await pollUntil(timeout: .seconds(10)) { service.heldCount == 1 }
        #expect(service.heldCount == 1)

        let clock = ContinuousClock()
        let invalidatedAt = clock.now
        client.invalidate()
        await #expect(throws: AgentIntegrationError.self) {
            try await call.value
        }
        #expect(invalidatedAt.duration(to: clock.now) < .seconds(1))
    }

    /// The client answers a later call itself, without a round trip
    /// through XPC, so the call fails at once however busy the machine is
    /// and the service never sees it.
    @Test func invalidate_failsALaterCallAtOnce() throws {
        let service = HeldXPCService(holding: .everything)
        let client = try service.client()
        client.invalidate()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let error = #expect(throws: AgentIntegrationError.self) {
            try client.openSession()
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
        guard case .requestFailed = error else {
            Issue.record("Expected requestFailed, got \(String(describing: error))")
            return
        }
        #expect(service.heldCount == 0)
    }

    @Test func invalidate_failsALaterExchangeAtOnce() throws {
        let service = HeldXPCService(holding: .everything)
        let client = try service.client()
        client.invalidate()
        let clock = ContinuousClock()
        let startedAt = clock.now
        #expect(throws: AgentIntegrationError.self) {
            try client.exchange(Data("{}".utf8))
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
        #expect(service.heldCount == 0)
    }
}
