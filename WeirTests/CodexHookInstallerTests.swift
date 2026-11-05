// CodexHookInstallerTests.swift
// Weir — pins the hook commands the installer hands Codex: the approval
// helper runs directly rather than through a shell, and its trust travels
// in the same flags.

import Foundation
import Testing
@testable import Weir

@Suite("CodexHookInstaller")
@MainActor
struct CodexHookInstallerTests {
    @Test("executes the signed approval helper directly")
    func approvalHelperCommand_doesNotInvokeShellAsTheExecutable() {
        let command = CodexHookInstaller.executableCommand(
            for: URL(fileURLWithPath: "/Applications/Weir Dev.app/Contents/MacOS/AgentIntegrationHookHelper")
        )

        #expect(command == "'/Applications/Weir Dev.app/Contents/MacOS/AgentIntegrationHookHelper'")
        #expect(!command.contains("/bin/sh"))
    }

    @Test("routes PermissionRequest through the helper, with its trust in the same flags")
    func approvalRouting_carriesItsTrust() throws {
        try withTempDir { dir in
            let lifecycle = dir.appendingPathComponent("weir-hook")
            let helper = dir.appendingPathComponent("AgentIntegrationHookHelper")
            #expect(FileManager.default.createFile(atPath: lifecycle.path, contents: Data()))
            #expect(FileManager.default.createFile(
                atPath: helper.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o700]
            ))
            let installer = CodexHookInstaller(
                hookScriptURL: lifecycle,
                worktreeHookScriptURL: nil,
                approvalHelperURL: helper
            )

            let arguments = installer.environment(writesRecords: true)["WEIR_CODEX_HOOK_ARGS"] ?? ""
            #expect(arguments.contains("permission-request codex"))
            let expectedHash = CodexTrustHash.compute(
                eventLabel: "permission_request",
                command: CodexHookInstaller.executableCommand(for: helper)
                    + " permission-request codex",
                timeoutSec: 600
            )
            #expect(arguments.contains(expectedHash))
        }
    }
}
