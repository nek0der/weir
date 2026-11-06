// AutomationChannel.swift
// Weir — starts and stops the verification channel for one run.

#if DEBUG && WEIR_AUTOMATION

    import AppKit
    import Darwin
    import Foundation
    import OSLog

    private let log = Logger.weir("automation")

    /// The channel of one run: its folder, its socket, and the controller that
    /// answers. Off unless the launching environment says `WEIR_AUTOMATION=1`,
    /// and off when the run would use the person's own data.
    @MainActor
    final class AutomationChannel {
        private let folder: AutomationRunFolder
        private let server: AutomationServer
        let controller: AutomationController
        private var terminateObserver: (any NSObjectProtocol)?
        /// The monitor that drops a posted key bound for the wrong place
        /// (`AutomationPostedKeys.installGate`).
        private var postedKeyGate: Any?

        private init(folder: AutomationRunFolder, server: AutomationServer, controller: AutomationController) {
            self.folder = folder
            self.server = server
            self.controller = controller
        }

        /// Starts the channel when asked and allowed; `nil` otherwise. A
        /// failure to start is logged and leaves the app as it would be
        /// without the channel.
        static func startIfAsked(
            state: AppState,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> AutomationChannel? {
            switch decision(environment: environment) {
            case .notAsked:
                return nil
            case let .refused(refusal):
                log.error("automation not started: \(refusal, privacy: .public)")
                return nil
            case .runs:
                break
            }
            let folder = AutomationRunFolder()
            AutomationRunFolder.removeStale(in: folder.base)
            do {
                let token = try folder.create()
                let controller = AutomationController(state: state, runID: folder.runID.uuidString)
                let server = AutomationServer(token: token) { request in
                    await controller.handle(request)
                }
                try server.start(at: folder.socketURL.path)
                let channel = AutomationChannel(folder: folder, server: server, controller: controller)
                channel.terminateObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak channel] _ in
                    MainActor.assumeIsolated { channel?.stop() }
                }
                let registry = state.windowRegistry
                channel.postedKeyGate = AutomationPostedKeys.installGate { window in
                    registry.windows.contains { registry.nsWindow(for: $0.id) === window }
                }
                state.windowRegistry.keepsOffScreenPanesDrawing = true
                SurfaceRegistry.keepsDrawingOffScreen = true
                log.notice("automation listening in \(folder.folder.path, privacy: .private)")
                return channel
            } catch {
                log.error("automation not started: \(String(describing: error), privacy: .private)")
                folder.remove()
                return nil
            }
        }

        /// Whether the launching environment asks for the channel, and whether
        /// the run may open it.
        enum Decision: Equatable {
            /// `WEIR_AUTOMATION=1` is not set.
            case notAsked
            /// Asked for, on the person's own data (`dataRefusal`).
            case refused(String)
            case runs
        }

        /// What `startIfAsked` decides for `environment`, before it opens
        /// anything. One rule, so a run the channel refuses is an ordinary
        /// run everywhere else too (`isAutomationRun`). The account's home is
        /// read only once the channel is asked for, so an ordinary launch
        /// never looks it up.
        static func decision(
            environment: [String: String],
            isDemoActive: Bool = DemoFixture.isDemoActive,
            bundleID: String = WeirPaths.bundleID,
            realHome: @autoclosure () -> String? = realHomeDirectory()
        ) -> Decision {
            guard environment["WEIR_AUTOMATION"] == "1" else { return .notAsked }
            if let refusal = dataRefusal(
                environment: environment,
                isDemoActive: isDemoActive,
                bundleID: bundleID,
                realHome: realHome()
            ) {
                return .refused(refusal)
            }
            return .runs
        }

        /// Whether this run is one the channel drives: asked for, and on data
        /// that is not the person's. Such a run leaves what is the person's
        /// alone even where its own identifier does not keep it apart, such as
        /// the approval service's registration, which is one per user.
        static func isAutomationRun(
            environment: [String: String],
            isDemoActive: Bool = DemoFixture.isDemoActive,
            bundleID: String = WeirPaths.bundleID,
            realHome: @autoclosure () -> String? = realHomeDirectory()
        ) -> Bool {
            decision(environment: environment, isDemoActive: isDemoActive, bundleID: bundleID, realHome: realHome()) == .runs
        }

        /// Whether this process is a copy the launcher made, started outside
        /// the channel: by Relaunch, whose `open` passes no environment, or
        /// from Spotlight or Finder, which can still find the copy. Without
        /// the launch's `CFFIXED_USER_HOME` it would open the person's
        /// `Weir Dev` data, so it quits before anything opens.
        static func isCopyOutsideTheChannel(
            environment: [String: String],
            isDemoActive: Bool = DemoFixture.isDemoActive,
            bundleID: String = WeirPaths.bundleID,
            realHome: @autoclosure () -> String? = realHomeDirectory()
        ) -> Bool {
            bundleID.hasPrefix(automationBundlePrefix)
                && !isAutomationRun(environment: environment, isDemoActive: isDemoActive, bundleID: bundleID, realHome: realHome())
        }

        /// How the bundle identifier of a copy that
        /// `scripts/weir-automation.py launch` makes for a run begins
        /// (`AUTOMATION_BUNDLE_PREFIX` there).
        static let automationBundlePrefix = "com.nekoder.Weir.automation-"

        /// Why this run may not open the channel, or `nil` when it may. A run
        /// it drives must not write what the person is using. Its bundle
        /// identifier must be a copy's (`automationBundlePrefix`): macOS keeps
        /// the user defaults by identifier under the account's own
        /// `~/Library/Preferences`, whatever the home, so under the build's
        /// own identifier the run would read and write the person's
        /// language, and what AppKit and Sparkle keep there. And it needs the
        /// demo, or a `CFFIXED_USER_HOME` that is not the person's home, which
        /// moves Application Support with it.
        static func dataRefusal(
            environment: [String: String],
            isDemoActive: Bool,
            bundleID: String = WeirPaths.bundleID,
            realHome: String? = realHomeDirectory()
        ) -> String? {
            guard bundleID.hasPrefix(automationBundlePrefix) else {
                return "WEIR_AUTOMATION needs the copy that scripts/weir-automation.py launch makes, "
                    + "so the run does not use the person's user defaults"
            }
            if isDemoActive {
                return nil
            }
            guard let fixedHome = environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty else {
                return "WEIR_AUTOMATION needs WEIR_DEMO=1 or a CFFIXED_USER_HOME, so the run does not use the person's data"
            }
            let fixed = URL(fileURLWithPath: fixedHome).standardizedFileURL.resolvingSymlinksInPath().path
            let real = realHome.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            guard fixed != real else {
                return "CFFIXED_USER_HOME is the person's own home"
            }
            return nil
        }

        /// The home folder of the account, from the user database rather than
        /// `HOME` or `CFFIXED_USER_HOME`, which the launch can set. `getpwuid_r`,
        /// as `TestWriteGuard` uses, rather than `getpwuid`'s shared buffer.
        nonisolated static func realHomeDirectory() -> String? {
            var entry = passwd()
            var found: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: 4096)
            return buffer.withUnsafeMutableBufferPointer { storage -> String? in
                guard let base = storage.baseAddress,
                      getpwuid_r(getuid(), &entry, base, storage.count, &found) == 0,
                      found != nil,
                      let dir = entry.pw_dir
                else { return nil }
                return String(cString: dir)
            }
        }

        func stop() {
            server.stop()
            folder.remove()
            if let terminateObserver {
                NotificationCenter.default.removeObserver(terminateObserver)
                self.terminateObserver = nil
            }
            if let postedKeyGate {
                NSEvent.removeMonitor(postedKeyGate)
                self.postedKeyGate = nil
            }
        }
    }

#endif
