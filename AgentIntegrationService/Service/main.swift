// main.swift
// Weir — authenticated LaunchAgent host for the Rust approval broker.

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
        Self.exchangeQueue.async {
            exchange.run()
        }
    }

    private static let exchangeQueue = DispatchQueue(
        label: "com.nekoder.weir.approval-exchange",
        qos: .userInitiated,
        attributes: .concurrent
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

private final class AgentIntegrationListenerDelegate: NSObject, NSXPCListenerDelegate {
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
                // with them withdrawn.
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

private final class AgentIntegrationServiceRuntime {
    private let requesterListener: NSXPCListener
    private let controllerListener: NSXPCListener
    private let requesterDelegate: AgentIntegrationListenerDelegate
    private let controllerDelegate: AgentIntegrationListenerDelegate

    init() throws {
        let service = try RustApprovalService(maximumRecords: AgentIntegrationConfiguration.maximumRecords)
        let serviceArtifact = try AgentIntegrationServiceArtifact.bundled(in: Bundle.main.bundleURL)
        requesterListener = NSXPCListener(
            machServiceName: AgentIntegrationConfiguration.requesterMachService
        )
        controllerListener = NSXPCListener(
            machServiceName: AgentIntegrationConfiguration.controllerMachService
        )
        requesterDelegate = AgentIntegrationListenerDelegate(
            role: .requester,
            service: service,
            serviceArtifact: serviceArtifact
        )
        controllerDelegate = AgentIntegrationListenerDelegate(
            role: .controller,
            service: service,
            serviceArtifact: serviceArtifact
        )

        // Foundation rejects mismatched peers before invoking either delegate,
        // so untrusted bytes never reach an exported object or the Rust decoder.
        try requesterListener.setConnectionCodeSigningRequirement(
            AgentIntegrationSigning.requirement(
                peerIdentifiers: AgentIntegrationConfiguration.requesterIdentifiers
            )
        )
        try controllerListener.setConnectionCodeSigningRequirement(
            AgentIntegrationSigning.requirement(
                peerIdentifiers: AgentIntegrationConfiguration.controllerIdentifiers
            )
        )
        requesterListener.delegate = requesterDelegate
        controllerListener.delegate = controllerDelegate
    }

    func run() -> Never {
        requesterListener.activate()
        controllerListener.activate()
        dispatchMain()
    }
}

do {
    try AgentIntegrationServiceRuntime().run()
} catch {
    FileHandle.standardError.write(Data("Agent Integration Service failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
