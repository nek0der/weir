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

    /// The registrar validates the service and the Hook Helper, the artifact
    /// hashes the service, and the Codex installer runs the Hook Helper, each
    /// by these names in this folder: the app the tests run in has both.
    @MainActor @Test func executables_areWhereTheConfigurationNamesThem() {
        let directory = AgentIntegrationConfiguration.executableDirectory(inApp: Bundle.main.bundleURL)
        #expect(directory == Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true))
        for name in [
            AgentIntegrationConfiguration.serviceExecutableName,
            AgentIntegrationConfiguration.hookHelperExecutableName
        ] {
            #expect(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(name).path), "\(name)")
        }
        #expect(AgentIntegrationConfiguration.serviceExecutableName == "AgentIntegrationService")
        #expect(AgentIntegrationConfiguration.hookHelperExecutableName == "AgentIntegrationHookHelper")
        #expect(CodexHookInstaller.bundledHookHelper()?.lastPathComponent == AgentIntegrationConfiguration.hookHelperExecutableName)
    }

    /// The Hook Helper's signing identifier is the first requester the
    /// service accepts, as the registrar validated it by before it had a name.
    @Test func hookHelperIdentifier_isTheFirstRequester() {
        #expect(AgentIntegrationConfiguration.requesterIdentifiers.first == AgentIntegrationConfiguration.hookHelperIdentifier)
        #expect(AgentIntegrationConfiguration.hookHelperIdentifier.hasPrefix("com.nekoder.weir.AgentIntegrationHookHelper"))
    }
}
