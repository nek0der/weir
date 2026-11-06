// AgentIntegrationListener.swift
// Weir — the service's XPC listener delegate and the connections it exports.

import Foundation

private final class AgentIntegrationConnection: NSObject, AgentIntegrationXPCProtocol {
    private let role: AgentIntegrationRole
    /// The requester run this connection's session was created for; `nil` for
    /// the controller, which asks for nothing.
    let runID: UUID?
    private let session: RustApprovalSession
    private let serviceArtifact: AgentIntegrationServiceArtifact

    init(
        role: AgentIntegrationRole,
        service: RustApprovalService,
        serviceArtifact: AgentIntegrationServiceArtifact
    ) throws {
        self.role = role
        self.serviceArtifact = serviceArtifact
        switch role {
        case .requester:
            let runID = UUID()
            self.runID = runID
            self.session = try service.requesterSession(runID: runID)
        case .controller:
            self.runID = nil
            self.session = try service.controllerSession()
        }
    }

    func openSession(withReply reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let response = AgentIntegrationSessionBootstrap(
                role: role,
                runID: runID,
                serviceProcessID: ProcessInfo.processInfo.processIdentifier,
                serviceArtifact: serviceArtifact
            )
            try reply(JSONEncoder().encode(response), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func exchange(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard request.count <= AgentIntegrationConfiguration.maximumXPCRequestBytes else {
            reply(nil, AgentIntegrationError.invalidArguments(
                "The request exceeds the XPC size limit."
            ) as NSError)
            return
        }
        // Off the connection's own queue. NSXPCConnection delivers a
        // connection's messages and its invalidation on one serial queue,
        // and a requester's `approval.wait` blocks for up to its whole
        // deadline: run there, it would hold back the withdrawal that the
        // invalidation exists for (`shouldAcceptNewConnection`).
        let exchange = PendingExchange(session: session, request: request, reply: reply)
        guard runID != nil else {
            // The controller's longest wait is a minute-long subscribe, and
            // the queue stays concurrent so a resolve on another connection
            // never waits behind it.
            Self.exchangeQueue.async {
                exchange.run()
            }
            return
        }
        // A requester's wait gets a thread of its own. On a dispatch queue,
        // enough hooks waiting at once would use up the workers the
        // controller's exchanges need too. Admitted before the thread
        // starts, so a flood is refused rather than met with threads; a
        // refused helper leaves the request to the agent's own prompt.
        guard Self.requesterThreads.admit() else {
            reply(nil, AgentIntegrationError.requestFailed("The approval service is busy.") as NSError)
            return
        }
        let thread = Thread {
            exchange.run()
            Self.requesterThreads.release()
        }
        thread.name = "com.nekoder.weir.approval-requester"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private static let exchangeQueue = DispatchQueue(
        label: "com.nekoder.weir.approval-exchange",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Twice the broker's records: every record pending with its wait, and
    /// as many short exchanges besides.
    private static let requesterThreads = ThreadAdmission(
        limit: 2 * AgentIntegrationConfiguration.maximumRecords
    )
}

/// One exchange carried off the connection's queue.
///
/// `@unchecked Sendable` because XPC's reply block is not marked `Sendable`.
/// It is safe: an XPC reply block may be called from any thread, once. The
/// session's own conformance carries its safety argument
/// (`RustApprovalSession`).
private struct PendingExchange: @unchecked Sendable {
    let session: RustApprovalSession
    let request: Data
    let reply: (Data?, NSError?) -> Void

    func run() {
        do {
            try reply(session.exchange(request), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}

/// Accepts one role's connections, giving each its own session, and
/// withdraws a requester's requests when its connection goes. Kept apart
/// from `main.swift` so the app's tests can run it behind an anonymous
/// listener (`AgentIntegrationListenerTests`).
final class AgentIntegrationListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let role: AgentIntegrationRole
    private let service: RustApprovalService
    private let serviceArtifact: AgentIntegrationServiceArtifact

    init(
        role: AgentIntegrationRole,
        service: RustApprovalService,
        serviceArtifact: AgentIntegrationServiceArtifact
    ) {
        self.role = role
        self.service = service
        self.serviceArtifact = serviceArtifact
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            let exportedObject = try AgentIntegrationConnection(
                role: role,
                service: service,
                serviceArtifact: serviceArtifact
            )
            connection.exportedInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
            connection.exportedObject = exportedObject
            if let runID = exportedObject.runID {
                // A hook helper holds its connection for as long as it waits,
                // so a connection gone means the hook stopped: Claude sends it
                // SIGTERM when its own dialog is answered No or Esc, and Codex
                // ends it on Esc or Ctrl-C without a signal it could catch.
                // Its requests are withdrawn so no card offers an answer that
                // can no longer arrive. A wait still blocked on this run wakes
                // with them withdrawn. A submit still on its way, on its own
                // thread, is refused when it lands: the exchange keeps the
                // run's session open until then (`PendingExchange`), and the
                // broker refuses a withdrawn run while a session of it is open.
                connection.invalidationHandler = { [service] in
                    try? service.withdrawRequester(runID: runID)
                }
            }
            connection.activate()
            return true
        } catch {
            return false
        }
    }
}
