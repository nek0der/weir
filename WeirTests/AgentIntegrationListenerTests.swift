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
    func aDroppedRequester_withdrawsItsRequestsOnly() async throws {
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
        defer {
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        let controller = try service.controllerSession()
        let epoch = try completeHello(on: controller)

        let dropped = try await submittedRequest(on: listener, epoch: epoch)
        defer { dropped.client.invalidate() }
        let kept = try await submittedRequest(on: listener, epoch: epoch)
        defer { kept.client.invalidate() }
        #expect(try status(of: dropped.key, on: controller, epoch: epoch) == "pending")
        let sequence = try sequence(on: controller, epoch: epoch)

        dropped.client.invalidate()

        // The withdrawal moves the broker's sequence, which ends the wait
        // at once; the bound only detects a missing withdrawal.
        let changed = try AgentIntegrationApprovalWire.object(from: controller.exchange(
            AgentIntegrationApprovalWire.subscribe(
                epoch: epoch,
                afterSequence: UInt64(sequence),
                maximumWaitMilliseconds: 30000
            )
        ))
        let body = try #require(changed["body"] as? [String: Any])
        let nextSequence = try #require(body["sequence"] as? Int)
        #expect(nextSequence > sequence)
        #expect(try status(of: dropped.key, on: controller, epoch: epoch) == "canceled")
        #expect(try status(of: kept.key, on: controller, epoch: epoch) == "pending")
        withExtendedLifetime(kept.client) {}
    }

    private struct Submitted {
        let client: Requester
        let key: (runID: UUID, requestID: UUID)
    }

    /// A requester connection with one pending request, as a hook helper
    /// holds while it waits.
    private func submittedRequest(on listener: NSXPCListener, epoch: UUID) async throws -> Submitted {
        let client = Requester(endpoint: listener.endpoint)
        var wasSubmitted = false
        defer {
            if !wasSubmitted {
                client.invalidate()
            }
        }
        let bootstrap = try await client.openSession()
        let runID = try #require(bootstrap.runID)
        let (hello, _) = try AgentIntegrationProbeWire.hello()
        _ = try await client.exchange(hello)
        let requestID = UUID()
        let submitted = try await AgentIntegrationApprovalWire.object(from: client.exchange(
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
        wasSubmitted = true
        return Submitted(client: client, key: (runID, requestID))
    }

    /// Uses XPC replies as events during setup. The listener's withdrawal
    /// contract does not include the synchronous client's five-second RPC
    /// timeout. Stream cancellation lets the suite limit end a missing reply.
    private final class Requester {
        private let connection: NSXPCConnection

        init(endpoint: NSXPCListenerEndpoint) {
            connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
            connection.activate()
        }

        func invalidate() {
            connection.invalidate()
        }

        func openSession() async throws -> AgentIntegrationSessionBootstrap {
            let data = try await call { proxy, reply in proxy.openSession(withReply: reply) }
            return try JSONDecoder().decode(AgentIntegrationSessionBootstrap.self, from: data)
        }

        func exchange(_ data: Data) async throws -> Data {
            try await call { proxy, reply in proxy.exchange(data, withReply: reply) }
        }

        private func call(
            _ send: (any AgentIntegrationXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
        ) async throws -> Data {
            let (responses, received) = AsyncThrowingStream<Data, any Error>.makeStream()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                received.finish(throwing: error)
            }) as? any AgentIntegrationXPCProtocol else {
                throw AgentIntegrationError.invalidResponse
            }
            send(proxy) { data, error in
                if let error {
                    received.finish(throwing: error)
                } else if let data {
                    received.yield(data)
                    received.finish()
                } else {
                    received.finish(throwing: AgentIntegrationError.invalidResponse)
                }
            }
            var iterator = responses.makeAsyncIterator()
            guard let response = try await iterator.next() else { throw CancellationError() }
            return response
        }
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
