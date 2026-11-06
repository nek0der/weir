// main.swift
// Weir — authenticated LaunchAgent host for the Rust approval broker.

import Foundation

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
