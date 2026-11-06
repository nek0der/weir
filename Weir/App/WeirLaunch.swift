// WeirLaunch.swift
// Weir — the process entry: Weir itself, or a bare host for the test bundle.

import AppKit
import OSLog

/// Xcode runs our tests inside the app (`TEST_HOST`). Were the host Weir
/// itself, every test run would launch a Dock app that takes the focus and
/// opens a project window, and would register the notification delegate,
/// the global hot key, and the defaults of the Debug build being checked
/// by hand, which shares the bundle id. Our tests make their own stores
/// and windows, so the host only has to be an application.
@main
enum WeirLaunch {
    @MainActor
    static func main() {
        // We read the environment because it is there from the first
        // instruction; the XCTest classes arrive only once the bundle is
        // injected, after launch.
        if WeirPaths.isTestHostByEnvironment {
            TestHost.run()
        } else {
            #if DEBUG && WEIR_AUTOMATION
                if AutomationChannel.isCopyOutsideTheChannel(environment: ProcessInfo.processInfo.environment) {
                    Logger.weir("automation").error("a channel run's copy started outside the channel; quitting")
                    exit(0)
                }
                // Before `WeirApp` and its stored properties are made, as
                // they read the defaults.
                AutomationDefaults.startOverIfTheHomeIsFresh()
            #endif
            WeirApp.main()
        }
    }
}

/// An application with no window, no Dock icon, and no menu, which the
/// test bundle is injected into.
@MainActor
private final class TestHost: NSObject, NSApplicationDelegate {
    /// The one terminal engine a process may have. We make it here because
    /// the FFI tests expect the host to have loaded libghostty
    /// (`GhosttyAvailability`). `nil` when it failed to start; those tests
    /// are then skipped as they are without it.
    private var ghosttyApp: GhosttyApp?

    static func run() {
        let app = NSApplication.shared
        // The test runner launches the host asking for it to be activated,
        // and an accessory app still came forward: a prohibited one never
        // does. The tests that move the first responder pass under it.
        app.setActivationPolicy(.prohibited)
        let host = TestHost()
        // `delegate` is weak; `run()` never returns, so `host` outlives it.
        app.delegate = host
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `try?`: a host without libghostty skips the FFI tests rather than
        // failing the whole run.
        ghosttyApp = try? GhosttyApp()
    }
}
