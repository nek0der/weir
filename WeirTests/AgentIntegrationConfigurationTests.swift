// AgentIntegrationConfigurationTests.swift
// Weir — the bundled launch agent property list names what the code expects.

import Foundation
import Testing
@testable import Weir

struct AgentIntegrationConfigurationTests {
    /// The property list is the one `SMAppService` registers and launchd
    /// reads, while the code names the same job and services through
    /// `AgentIntegrationConfiguration`. Nothing else ties the two, so a
    /// rename in one would leave the app connecting to a service launchd
    /// never started.
    @Test func bundledPropertyList_namesTheConfiguredLabelAndServices() throws {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(AgentIntegrationConfiguration.plistName)
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist["Label"] as? String == AgentIntegrationConfiguration.launchAgentLabel)
        let services = try #require(plist["MachServices"] as? [String: Any])
        #expect(Set(services.keys) == [
            AgentIntegrationConfiguration.requesterMachService,
            AgentIntegrationConfiguration.controllerMachService
        ])
    }
}
