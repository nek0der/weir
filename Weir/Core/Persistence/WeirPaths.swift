// WeirPaths.swift
// Weir — branches data directory + app identity off the build's
// bundle id so the dmg-installed Release ("com.nekoder.Weir") and a
// Debug build running out of DerivedData ("com.nekoder.Weir.dev")
// can coexist on the same Mac without trampling each other's
// state.json, notifications.json, or scrollback dumps; and gives each
// build an identity of its own for the hook links.

import CryptoKit
import Foundation

enum WeirPaths {
    /// Bundle identifier of the *currently running* binary. Falls back
    /// to the Release id when the bundle dictionary is missing.
    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.nekoder.Weir"
    }

    /// `true` when the running binary is the Xcode test host. Used to
    /// move the data directory out of `~/Library` and to arm
    /// `TestWriteGuard`, so a test that forgets to inject
    /// `init(directory:)` cannot reach the user's real data.
    /// `Bundle.main.bundleIdentifier` is the host app's id during tests,
    /// not the test bundle's, so it cannot tell.
    static var isRunningInTests: Bool {
        isTestHostByEnvironment || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil
    }

    /// The variables Xcode sets on the test host before it starts. The
    /// XCTest classes are loaded only once the test bundle is injected, so
    /// the host app's launch could ask before they exist and save into the
    /// real folder; the environment is there from the first instruction.
    static let isTestHostByEnvironment: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }()

    /// `true` when the running binary is a Debug build (suffix `.dev`).
    /// Drives both the data directory name and Sparkle's auto-check
    /// gate — we don't want a Debug build to auto-update itself out
    /// from under the Xcode runner.
    static var isDevBuild: Bool {
        bundleID.hasSuffix(".dev")
    }

    /// The identity of this one build, for what each build must keep to
    /// itself on a Mac where several run at once: the no-space hook links
    /// a Claude shim makes in the user's temporary folder
    /// (`WEIR_CLAUDE_HOOK_NAMESPACE`). The Release app is its bundle id, as
    /// it always was, so a Claude session it started before this build keeps
    /// the links it was given. Every Debug build shares one bundle id, and
    /// people run one from each worktree's DerivedData, so a Debug build
    /// adds a hash of its bundle's path: by the bundle id alone, one build's
    /// `claude` start would point the other builds' running sessions at its
    /// own hooks, whose approvals the other builds never see.
    static var buildIdentity: String {
        buildIdentity(bundleID: bundleID, bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path)
    }

    /// Returns the build identity of a bundle with `bundleID` at
    /// `bundlePath`, which need not be the running one, so tests can name
    /// two. We cut the path's SHA-256 to 8 hex digits: enough to tell a
    /// handful of worktrees apart, and short enough that the link folder's
    /// name stays well inside the 128 characters the shim accepts.
    static func buildIdentity(bundleID: String, bundlePath: String) -> String {
        guard bundleID.hasSuffix(".dev") else { return bundleID }
        let digest = SHA256.hash(data: Data(bundlePath.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(bundleID)-\(prefix)"
    }

    /// Folder name under `~/Library/Application Support/` where the
    /// session snapshot (`state.json`), notification history
    /// (`notifications.json`), scrollback dumps, review drafts
    /// (`reviews/`), and `settings.json`
    /// live. Different per build so a Release crash can't corrupt the
    /// in-progress Debug session and vice versa.
    static var applicationSupportDirectoryName: String {
        isDevBuild ? "Weir Dev" : "Weir"
    }

    /// Absolute URL of the per-build Application Support directory.
    /// Created on demand by the caller (`SecureFileWrite.ensureUserOnlyDirectory`).
    /// Under the test host it is a folder of this process in the temporary
    /// directory instead: a test that builds a store without injecting its
    /// folder lands here rather than in the person's data, and
    /// `TestWriteGuard` refuses a `SecureFileWrite` change inside
    /// `~/Library`. A fresh folder per run also keeps one run's files from
    /// being read by the next.
    static func applicationSupportDirectory() -> URL {
        if isRunningInTests {
            return testRunDirectory
        }
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    /// Where the test host keeps what it would keep in Application Support.
    /// Fixed for the process so every store and the host app agree on it.
    /// Named by a UUID rather than the process id, which the system reuses,
    /// so no run finds an earlier run's session.
    private static let testRunDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Weir Tests \(UUID().uuidString)", isDirectory: true)
}
