// AgentIntegrationListenerTests.swift
// Weir — the service's listener delegate behind an anonymous XPC listener.

import Foundation
import Testing
@testable import Weir

/// Runs the service's own listener delegate in the test process, so the
/// wiring between a dropped connection and the broker is tested end to end:
/// the delegate, the connection's invalidation handler, and the Rust
/// service it withdraws from.
struct AgentIntegrationListenerTests {
    @Test(.timeLimit(.minutes(1)))
    func aDroppedRequester_withdrawsItsRequestsOnly() throws {
        let service = try RustApprovalService(maximumRecords: 8)
        let listener = NSXPCListener.anonymous()
        let delegate = AgentIntegrationListenerDelegate(
            role: .requester,
            service: service,
            serviceArtifact: AgentIntegrationServiceArtifact(
                serviceExecutableSHA256: "service",
                launchAgentPropertyListSHA256: "property-list"
            )
        )
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: controller)

        let dropped = try submittedRequest(on: listener, epoch: epoch)
        let kept = try submittedRequest(on: listener, epoch: epoch)
        #expect(try status(of: dropped.key, on: controller, epoch: epoch) == "pending")
        let sequence = try sequence(on: controller, epoch: epoch)

        dropped.client.invalidate()

        // The withdrawal moves the broker's sequence, which ends the wait
        // at once; the minute is only there if it never comes.
        let changed = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.subscribe(
                epoch: epoch,
                afterSequence: UInt64(sequence),
                maximumWaitMilliseconds: 30000
            )
        ))
        let body = try #require(changed["body"] as? [String: Any])
        #expect(body["sequence"] as? Int != sequence)
        #expect(try status(of: dropped.key, on: controller, epoch: epoch) == "canceled")
        #expect(try status(of: kept.key, on: controller, epoch: epoch) == "pending")
        withExtendedLifetime(kept.client) {}
    }

    private struct Submitted {
        let client: AgentIntegrationXPCClient
        let key: (runID: UUID, requestID: UUID)
    }

    /// A requester connection with one pending request, as a hook helper
    /// holds while it waits.
    private func submittedRequest(on listener: NSXPCListener, epoch: UUID) throws -> Submitted {
        let client = try AgentIntegrationXPCClient(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        let runID = try #require(client.openSession().runID)
        let (hello, _) = try AgentIntegrationProbeWire.hello()
        _ = try client.exchange(hello)
        let requestID = UUID()
        let submitted = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.submit(
                epoch: epoch,
                submission: AgentIntegrationApprovalSubmission(
                    runID: runID, requestID: requestID, provider: "claude", sessionID: "session",
                    operationID: nil, toolName: "Bash", summary: nil, input: ["command": "ls"],
                    questions: nil, timeoutMilliseconds: 60000
                )
            )
        ))
        #expect(submitted["type"] as? String == "approval.result")
        return Submitted(client: client, key: (runID, requestID))
    }

    private func status(
        of key: (runID: UUID, requestID: UUID),
        on controller: RustApprovalSession,
        epoch: UUID
    ) throws -> String? {
        let response = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.get(epoch: epoch, runID: key.runID, requestID: key.requestID)
        ))
        let body = try #require(response["body"] as? [String: Any])
        return (body["state"] as? [String: Any])?["status"] as? String
    }

    private func sequence(on controller: RustApprovalSession, epoch: UUID) throws -> Int {
        let response = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.snapshot(epoch: epoch)
        ))
        let body = try #require(response["body"] as? [String: Any])
        return try #require(body["sequence"] as? Int)
    }

    private func completeHello(on session: RustApprovalSession) throws -> UUID {
        let (hello, _) = try AgentIntegrationProbeWire.hello()
        return try AgentIntegrationProbeWire.epoch(
            from: AgentIntegrationProbeWire.response(session.exchange(hello))
        )
    }
}
