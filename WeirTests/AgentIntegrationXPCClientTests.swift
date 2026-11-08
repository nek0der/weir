// AgentIntegrationXPCClientTests.swift
// Weir — invalidating the client ends a blocked call and fails any later one at once.

import Foundation
import Testing
@testable import Weir

struct AgentIntegrationXPCClientTests {
    @Test(.timeLimit(.minutes(1)), arguments: Call.allCases)
    func invalidate_releasesABlockedCallSynchronously(_ operation: Call) async throws {
        let service = HeldXPCService(holding: .everything)
        let wait = HeldReplyWait()
        let client = try service.client(timeoutSeconds: 30, waitForReply: wait.wait)
        defer { client.invalidate() }
        let call = Task {
            await OffPoolWork.run {
                Result {
                    switch operation {
                    case .openSession: _ = try client.openSession()
                    case .exchange: _ = try client.exchange(Data("{}".utf8))
                    }
                }
            }
        }
        await service.waitUntilHeld()
        await wait.waitUntilWaiting()
        client.invalidate()
        // A signal present before the waiter resumes is a stronger guarantee
        // than waking within one second, without counting thread scheduling.
        let wasReleased = wait.releaseAfterCheckingSignal()
        let result = await call.value
        try #require(service.heldCount == 1)
        #expect(wasReleased)
        let error = #expect(throws: AgentIntegrationError.self) {
            try result.get()
        }
        guard case let .requestFailed(reason) = error else {
            Issue.record("expected invalidation to fail the pending call, got \(String(describing: error))")
            return
        }
        #expect(reason == "The connection was invalidated.")
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidate_releasesEveryBlockedCallOnTheConnection() async throws {
        let service = HeldXPCService(holding: .everything)
        let waits = [HeldReplyWait(), HeldReplyWait()]
        let next = Recorded(0)
        let client = try service.client(timeoutSeconds: 30) { semaphore, seconds in
            var index = 0
            next.update {
                index = $0
                $0 += 1
            }
            return waits[index].wait(semaphore, seconds: seconds)
        }
        defer { client.invalidate() }
        let calls = Call.allCases.map { operation in
            Task {
                await OffPoolWork.run {
                    Result {
                        switch operation {
                        case .openSession: _ = try client.openSession()
                        case .exchange: _ = try client.exchange(Data("{}".utf8))
                        }
                    }
                }
            }
        }
        await service.waitUntilHeld(2)
        for wait in waits {
            await wait.waitUntilWaiting()
        }
        client.invalidate()
        for wait in waits {
            #expect(wait.releaseAfterCheckingSignal())
        }
        for call in calls {
            let result = await call.value
            let error = #expect(throws: AgentIntegrationError.self) { try result.get() }
            guard case let .requestFailed(reason) = error else {
                Issue.record("Expected invalidation to release every pending call")
                continue
            }
            #expect(reason == "The connection was invalidated.")
        }
        #expect(service.heldCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidate_keepsAReplyThatAlreadyArrived() async throws {
        let artifact = try AgentIntegrationServiceArtifact.bundled(in: Bundle.main.bundleURL)
        let service = HeldXPCService(holding: .afterOpening(artifact))
        let wait = HeldCompletedReplyWait()
        let client = try service.client(timeoutSeconds: 30, waitForReply: wait.wait)
        defer { client.invalidate() }
        let call = Task { await OffPoolWork.run { Result { try client.openSession() } } }
        await wait.waitUntilReady()
        client.invalidate()
        wait.release()
        let result = await call.value
        let bootstrap = try result.get()
        #expect(bootstrap.role == .controller)
        #expect(bootstrap.serviceArtifact == artifact)
    }

    enum Call: CaseIterable, Sendable {
        case openSession
        case exchange
    }

    /// A later call is refused by the client without waiting for an XPC reply.
    @Test(.timeLimit(.minutes(1)), arguments: Call.allCases)
    func invalidate_refusesLaterCallsLocally(_ call: Call) throws {
        let service = HeldXPCService(holding: .everything)
        let waits = Recorded(0)
        let client = try service.client(timeoutSeconds: 30) { _, _ in
            waits.update { $0 += 1 }
            return .timedOut
        }
        client.invalidate()

        let error = #expect(throws: AgentIntegrationError.self) {
            switch call {
            case .openSession:
                _ = try client.openSession()
            case .exchange:
                _ = try client.exchange(Data("{}".utf8))
            }
        }
        guard case let .requestFailed(reason) = error else {
            Issue.record("Expected local invalidation refusal, got \(String(describing: error))")
            return
        }
        #expect(reason == "The connection was invalidated.")
        #expect(waits.value == 0)
        #expect(service.heldCount == 0)
    }
}
