// AntigravityShimLocator.swift
// Weir — the in-bundle `antigravity-shim/` directory and the variables a pane's shell needs for it.

import Foundation
import WeirDomain

enum AntigravityShimLocator {
    /// `nil` when the bundle does not contain it (a unit-test target with no
    /// Resources phase). Callers treat `nil` as "skip injection".
    static var shimDirectoryURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("antigravity-shim", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The shim's directory, which `zdotdir/.zshrc` re-prepends after the
    /// person's own `.zshrc`, and the record directories its hook writes to.
    /// With `writesRecords` false (a demo) the directories are blank, and the
    /// shim then places no plugin and names no hook.
    static func environment(writesRecords: Bool) -> [String: String] {
        guard let shim = shimDirectoryURL else { return [:] }
        var environment = ["WEIR_ANTIGRAVITY_SHIM_DIR": shim.path]
        let kind = AgentKind.antigravity.rawValue
        if let directories = AgentProviderRegistry.directories(
            under: WeirPaths.applicationSupportDirectory()
        )[kind] {
            environment.merge(
                AgentProviderRegistry.environment(
                    for: kind,
                    state: directories.state,
                    sessions: directories.sessions,
                    cwdEvents: directories.cwdEvents,
                    writesRecords: writesRecords
                )
            ) { _, new in new }
        }
        return environment
    }
}
