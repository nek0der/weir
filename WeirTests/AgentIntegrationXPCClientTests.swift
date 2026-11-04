// AgentIntegrationXPCClientTests.swift
// Weir — invalidating the client ends a call blocked on the service's reply.

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

    @Test func invalidate_failsALaterCallAtOnce() throws {
        let service = HeldXPCService(holding: .everything)
        let client = try service.client()
        client.invalidate()
        let clock = ContinuousClock()
        let startedAt = clock.now
        #expect(throws: AgentIntegrationError.self) {
            try client.openSession()
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }
}
