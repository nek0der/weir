// HeldXPCService.swift
// Weir — an in-process approval service that holds its replies.

import Foundation
@testable import Weir

/// An anonymous XPC listener in the test's own process that speaks the
/// approval service's protocol and never answers what it holds, so a test
/// can stop a client in the middle of a blocking call and see what ends it.
///
/// `.everything` holds the session's open itself. `.afterOpening` opens a
/// controller session as the bundled service would, with the test host's
/// bundled artifact and a hello, answers the first snapshot with no
/// requests, and holds every exchange after that: the subscription.
///
/// `@unchecked Sendable`: `held` is read and written only under `lock`, and
/// the listener is set up once in `init`.
final class HeldXPCService: NSObject, NSXPCListenerDelegate, AgentIntegrationXPCProtocol, @unchecked Sendable {
    enum Holding {
        case everything
        case afterOpening(AgentIntegrationServiceArtifact)
    }

    private let holding: Holding
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var held: [(Data?, NSError?) -> Void] = []

    init(holding: Holding) {
        self.holding = holding
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    /// How many calls are waiting for a reply.
    var heldCount: Int {
        lock.withLock { held.count }
    }

    /// A client on a new connection to this listener.
    func client(timeoutSeconds: Int = 70) throws -> AgentIntegrationXPCClient {
        try AgentIntegrationXPCClient(
            connection: NSXPCConnection(listenerEndpoint: listener.endpoint),
            timeoutSeconds: timeoutSeconds
        )
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
        connection.exportedObject = self
        connection.activate()
        return true
    }

    func openSession(withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard case let .afterOpening(artifact) = holding else {
            hold(reply)
            return
        }
        let bootstrap = AgentIntegrationSessionBootstrap(
            role: .controller,
            runID: nil,
            serviceProcessID: ProcessInfo.processInfo.processIdentifier,
            serviceArtifact: artifact
        )
        reply(try? JSONEncoder().encode(bootstrap), nil)
    }

    func exchange(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard case .afterOpening = holding else {
            hold(reply)
            return
        }
        let answer: [String: Any]? = switch (try? AgentIntegrationApprovalWire.object(from: request))?["type"] as? String {
        case "hello":
            ["type": "hello.result", "service_epoch": UUID().uuidString]
        case "approval.snapshot":
            ["type": "approval.snapshot.result", "body": ["sequence": 0, "requests": [] as [Any]]]
        default:
            nil
        }
        guard let answer else {
            hold(reply)
            return
        }
        reply(try? JSONSerialization.data(withJSONObject: answer), nil)
    }

    private func hold(_ reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { held.append(reply) }
    }
}
