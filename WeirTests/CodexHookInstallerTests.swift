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
    @Test("builds a quoted approval helper command without a shell prefix")
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

            let exported = try #require(installer.environment(writesRecords: true)["WEIR_CODEX_HOOK_ARGS"])
            let arguments = exported.split(separator: "\n")
            let permission = try #require(arguments.first { $0.hasPrefix("hooks.PermissionRequest=") })
            let trust = try #require(arguments.first { $0.hasPrefix("hooks.state=") })
            let command = "'\(helper.resolvingSymlinksInPath().path)' permission-request codex"
            #expect(permission == #"hooks.PermissionRequest=[{hooks=[{type="command",command="\#(command)",timeout=600}]}]"#)

            let expectedHash = CodexTrustHash.compute(eventLabel: "permission_request", command: command, timeoutSec: 600)
            let key = "/<session-flags>/config.toml:permission_request:0:0"
            #expect(trust.contains(#""\#(key)"={enabled=true,trusted_hash="\#(expectedHash)"}"#))
        }
    }
}
