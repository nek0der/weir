// SparkleUpdater.swift
// Weir — Sparkle integration. Holds the `SPUUpdater`, the full
// `SPUUserDriver` (see `WeirUpdateDriver`), and the shared
// `UpdateStateModel` that the update controls / popover subscribe to.
//
// We bypass `SPUStandardUpdaterController` entirely and construct
// `SPUUpdater(hostBundle:applicationBundle:userDriver:delegate:)`
// ourselves so we can supply a custom `SPUUserDriver`. The standard
// controller wires up its own driver internally and there's no way
// to swap it after construction.

import Observation
import OSLog
import Sparkle

private let log = Logger.weir("updates")

// MARK: - Update presentation

/// Immutable appcast fields needed by Weir's update UI.
///
/// Sparkle owns `SUAppcastItem` construction and version-dependent state. We
/// copy presentation values at the user-driver boundary so fallback and Debug
/// states never need to manufacture framework objects with private APIs.
struct UpdateDisplayItem {
    let displayVersion: String
    let contentLength: UInt64
    let date: Date?
    let releaseNotesURL: URL?

    init(appcastItem: SUAppcastItem) {
        // The prefix keeps versions distinct from file sizes, percentages,
        // and dates shown in the same compact metadata block.
        self.displayVersion = "v\(appcastItem.displayVersionString)"
        self.contentLength = appcastItem.contentLength
        self.date = appcastItem.date
        self.releaseNotesURL = appcastItem.releaseNotesURL
    }

    init(
        displayVersion: String,
        contentLength: UInt64 = 0,
        date: Date? = nil,
        releaseNotesURL: URL? = nil
    ) {
        self.displayVersion = displayVersion
        self.contentLength = contentLength
        self.date = date
        self.releaseNotesURL = releaseNotesURL
    }

}

// MARK: - One-shot callback wrapper

/// Wraps a Sparkle reply / acknowledgment / cancellation closure so
/// it can be invoked from multiple call sites (the left rail's popover,
/// the inline Settings popover, auto-dismiss timer, fallback to standard driver)
/// without violating Sparkle's "call exactly once" contract. First call
/// wins; subsequent calls are silently dropped.
///
/// Forgetting to call a Sparkle callback at all is a different bug
/// (stalls the state machine for the rest of the session). The OneShot
/// only fixes the *double-call* hazard — code that takes ownership of
/// a OneShot still has to call it before transitioning state, or the
/// driver loses the chance to advance Sparkle's pipeline.
@MainActor
final class OneShot<Argument> {
    private var callback: ((Argument) -> Void)?

    init(_ callback: @escaping (Argument) -> Void) {
        self.callback = callback
    }

    /// Fire the callback if it hasn't fired yet. Subsequent calls
    /// no-op (no warning — the design is to make double-call safe).
    func call(_ value: Argument) {
        guard let cb = callback else { return }
        callback = nil
        cb(value)
    }

    /// True after `call(_:)` has been invoked. Only tests read it.
    var hasFired: Bool {
        callback == nil
    }
}

extension OneShot where Argument == Void {
    /// Parameterless convenience for callbacks like `acknowledgment`
    /// and `cancellation` that don't carry a value.
    func call() {
        call(())
    }
}

// MARK: - Update state

/// All states the updater lifecycle can be in. Closures embedded in
/// each case carry Sparkle's reply / cancellation / acknowledgment
/// callbacks wrapped in `OneShot` — the popover and the update controls
/// read them through this enum and may legitimately call from multiple
/// surfaces.
///
/// Not Equatable / Sendable on purpose: the OneShots aren't, and we
/// only mutate this on `@MainActor` anyway.
@MainActor
enum UpdateState {
    case idle
    case checking(cancel: OneShot<Void>)
    case available(item: UpdateDisplayItem, reply: OneShot<SPUUserUpdateChoice>)
    case downloading(item: UpdateDisplayItem, expectedBytes: UInt64?, receivedBytes: UInt64, cancel: OneShot<Void>)
    case extracting(progress: Double)
    case readyToInstall(item: UpdateDisplayItem, reply: OneShot<SPUUserUpdateChoice>)
    /// `retry` is Sparkle's escape hatch for the install phase: when
    /// `applicationWillTerminate` is canceled or stalls, calling it
    /// gives the user driver another shot at terminating. Nil only in
    /// the mock-fixture branch where there's nothing real to retry.
    case installing(retry: OneShot<Void>?)
    case installed(acknowledgement: OneShot<Void>)
    case notFound(acknowledgement: OneShot<Void>)
    /// `retry` closes the failed check and starts a new one once Sparkle
    /// has ended it (`WeirUpdateDriver.updateCycleDidFinish`); a check
    /// asked for while the failed one is still open is ignored.
    case error(error: any Error, acknowledgement: OneShot<Void>, retry: OneShot<Void>)
}

/// The identity of one Sparkle update session: a check and whatever
/// follows it, up to the moment Sparkle ends it. A timer or a choice made for one session
/// compares its identity with the session the update interface shows, so
/// one left over from an earlier session never ends a later one.
struct UpdateSessionID: Hashable {
    let rawValue: UInt64
}

/// Shared observable wrapping `UpdateState`. The driver writes; the
/// update controls / popover read. Splitting the enum out so SwiftUI can read
/// the *current* state without invoking any of the embedded closures
/// during diff.
@MainActor
@Observable
final class UpdateStateModel {
    /// The state the update interface shows, written only through
    /// `show(_:for:)` so its session never goes stale.
    private(set) var state: UpdateState = .idle

    /// The Sparkle session `state` belongs to; nil for an idle state and
    /// for the Debug mock, which runs no session.
    private(set) var sessionID: UpdateSessionID?

    /// Shows `state` as part of `session`.
    func show(_ state: UpdateState, for session: UpdateSessionID? = nil) {
        self.state = state
        sessionID = session
    }

    /// Counts the times Check for Updates was chosen while an update was
    /// shown inline. The window in front opens its update popover on each
    /// change, so the choice brings the update forward instead of doing
    /// nothing (`WeirUpdateDriver.showUpdateInFocus`).
    var focusRequests = 0

    /// True when an update control (the left rail's icon) should render.
    /// `.idle` and `.notFound` (after auto-dismiss)
    /// hide it.
    var showsBadge: Bool {
        switch state {
        case .idle: false
        default: true
        }
    }

    /// True while an update operation is actively in flight (network
    /// fetch, download, extract, install). Terminal states (.available /
    /// .readyToInstall awaiting user choice, .notFound / .installed /
    /// .error) are not busy.
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .extracting, .installing:
            true
        case .idle, .available, .readyToInstall, .installed, .notFound, .error:
            false
        }
    }

    /// Whether Check for Updates is off. Sparkle answers a check made
    /// while it shows an update by bringing that update forward, so a
    /// real check stays on through a download or an install and is off
    /// only while checking, which Sparkle ignores. The Debug mock has no
    /// such guard and would start a second pipeline, so it is off
    /// whenever `isBusy`.
    var disablesCheckForUpdates: Bool {
        #if DEBUG
            isBusy
        #else
            if case .checking = state {
                true
            } else {
                false
            }
        #endif
    }
}

// MARK: - Updater stack (owns SPUUpdater + driver + state)

/// Bundles the `SPUUpdater`, its `WeirUpdateDriver`, and the shared
/// `UpdateStateModel` into one object with matched lifetime. `WeirApp`
/// holds one of these as a stored `let`.
@MainActor
final class UpdaterStack {
    let updater: SPUUpdater
    let driver: WeirUpdateDriver
    let stateModel: UpdateStateModel
    /// The updater's delegate, held here because `SPUUpdater` keeps its
    /// delegate weakly.
    let cycleObserver: UpdateCycleObserver

    /// `startsUpdater` is false in demo mode. Started, Sparkle checks at
    /// once when its defaults hold no last check, as in the isolated home
    /// `make screenshot` launches with, and a release newer than the build
    /// would put its badge into the hero; it would also write its check
    /// dates into the defaults the person's installed copy reads, since a
    /// demo run of a Release build has the same bundle identifier. Not
    /// started, it checks nothing and writes nothing, and "Check for
    /// Updates…" does nothing in a demo run, which is for screenshots.
    init(
        allowsAutomaticChecks: Bool,
        startsUpdater: Bool = true,
        hasInlineTarget: @escaping @MainActor () -> Bool
    ) {
        let stateModel = UpdateStateModel()
        let driver = WeirUpdateDriver(stateModel: stateModel, hostBundle: .main, hasInlineTarget: hasInlineTarget)
        let cycleObserver = UpdateCycleObserver(driver: driver)
        self.stateModel = stateModel
        self.driver = driver
        self.cycleObserver = cycleObserver
        self.updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: cycleObserver
        )
        // Retry on a failed check starts the next one here, the way the
        // menu item and Settings do.
        driver.startsCheck = { [weak self] in self?.checkForUpdates() }
        guard startsUpdater else { return }
        // Otherwise always `start()` — without it, `checkForUpdates()`
        // (both the menu item and Settings → Check Now) silently no-ops.
        // We still want manual checks to work in Debug, so the gating
        // happens on the auto-check schedule via
        // `automaticallyChecksForUpdates` rather than on `start()`
        // itself.
        do {
            try updater.start()
        } catch {
            log.error("SPUUpdater.start failed: \(String(describing: error), privacy: .private)")
        }
        // In Debug, keep scheduled auto-checks off so a `make dev`
        // session running alongside the installed Release dmg can't
        // replace its own DerivedData binary mid-debug. Note: this is
        // a once-on-start gate — Settings → Updates binds the same
        // toggle directly to `automaticallyChecksForUpdates`, so a
        // user who flips it on in Settings overrides this default
        // for the rest of the session (intentional escape hatch for
        // testing the Settings UI in Debug).
        if !allowsAutomaticChecks {
            updater.automaticallyChecksForUpdates = false
        }
    }

    /// Starts a check for updates, for the app menu, Settings, and Retry
    /// on a failed check. While a session shows "You’re up to date" or a
    /// failure, Sparkle still has it open and would ignore the check, so
    /// the driver settles that result and starts the check once Sparkle
    /// has ended it. Debug builds run the mock pipeline instead of a
    /// Sparkle check, so the update interface can be seen without a
    /// release feed, except while a real session is open: the mock would
    /// replace that session's state without settling its callback.
    func checkForUpdates() {
        if driver.defersCheckToSessionEnd() {
            return
        }
        #if DEBUG
            if driver.hasOpenSession {
                updater.checkForUpdates()
            } else {
                MockUpdateAvailability.simulate(into: stateModel)
            }
        #else
            updater.checkForUpdates()
        #endif
    }
}

/// The delegate that tells the driver when Sparkle has ended an update
/// session. Sparkle ends one only after the acknowledgment of its last
/// step, on a later turn of the main queue, and ignores a check asked for
/// before then.
@MainActor
final class UpdateCycleObserver: NSObject, SPUUpdaterDelegate {
    private weak var driver: WeirUpdateDriver?

    init(driver: WeirUpdateDriver) {
        self.driver = driver
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error _: (any Error)?) {
        driver?.updateCycleDidFinish()
    }
}

#if DEBUG
    /// Inject a fake state so the update popover can be visually
    /// iterated without a real appcast / server round-trip. Hooked
    /// into the App menu (Debug builds only).
    @MainActor
    enum MockUpdateAvailability {
        /// Drives the full mock lifecycle in one entry point. Sets
        /// `.available`; when the user presses Install in the popover
        /// the embedded reply closure advances us through download →
        /// extract → readyToInstall → installing → installed → idle,
        /// each step visually inspectable in the rail + popover. Skip /
        /// Later route to `.idle` immediately.
        static func simulate(into model: UpdateStateModel) {
            let item = makeFakeItem()
            let reply = OneShot<SPUUserUpdateChoice> { [weak model] choice in
                guard let model else { return }
                switch choice {
                case .install:
                    runFakeInstallPipeline(item: item, into: model)
                case .skip, .dismiss:
                    model.show(.idle)
                @unknown default:
                    model.show(.idle)
                }
            }
            model.show(.available(item: item, reply: reply))
        }

        /// Runs the download → extract → ready chain with realistic-
        /// feeling delays. Pressing Install in `.readyToInstall` then
        /// hands off to `runFakeInstallStage` to complete the loop.
        private static func runFakeInstallPipeline(
            item: UpdateDisplayItem,
            into model: UpdateStateModel
        ) {
            let cancel = OneShot<Void> { [weak model] in model?.show(.idle) }
            let total: UInt64 = 60_817_408
            model.show(.downloading(item: item, expectedBytes: total, receivedBytes: 0, cancel: cancel))
            Task { @MainActor [weak model] in
                guard let model else { return }
                await runFakeDownload(item: item, total: total, cancel: cancel, in: model)
                guard case .downloading = model.state else { return }
                await runFakeExtract(in: model)
                guard case .extracting = model.state else { return }
                try? await Task.sleep(for: .milliseconds(180))
                model.show(.readyToInstall(
                    item: item,
                    reply: makeReadyReply(item: item, model: model)
                ))
            }
        }

        private static func runFakeDownload(
            item: UpdateDisplayItem,
            total: UInt64,
            cancel: OneShot<Void>,
            in model: UpdateStateModel
        ) async {
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(220))
                guard case .downloading = model.state else { return }
                let received = UInt64(Double(total) * Double(step) / 10.0)
                model.show(.downloading(
                    item: item,
                    expectedBytes: total,
                    receivedBytes: received,
                    cancel: cancel
                ))
            }
        }

        private static func runFakeExtract(in model: UpdateStateModel) async {
            try? await Task.sleep(for: .milliseconds(180))
            model.show(.extracting(progress: 0))
            for step in 1...6 {
                try? await Task.sleep(for: .milliseconds(180))
                guard case .extracting = model.state else { return }
                model.show(.extracting(progress: Double(step) / 6.0))
            }
        }

        /// Reply handler for the mock `.readyToInstall` state. Install
        /// kicks off the installing → installed → idle tail; Skip /
        /// Later short-circuit back to idle.
        private static func makeReadyReply(
            item _: UpdateDisplayItem,
            model: UpdateStateModel
        ) -> OneShot<SPUUserUpdateChoice> {
            OneShot<SPUUserUpdateChoice> { [weak model] choice in
                guard let model else { return }
                if case .install = choice {
                    Task { @MainActor [weak model] in
                        guard let model else { return }
                        await runFakeInstallStage(in: model)
                    }
                } else {
                    model.show(.idle)
                }
            }
        }

        private static func runFakeInstallStage(in model: UpdateStateModel) async {
            // Mock has nothing real to retry — pass nil so the inline
            // view hides the Retry affordance for the simulated stage.
            model.show(.installing(retry: nil))
            try? await Task.sleep(for: .milliseconds(800))
            let ack = OneShot<Void> { [weak model] in model?.show(.idle) }
            model.show(.installed(acknowledgement: ack))
            // Mirror the production driver's auto-dismiss so the
            // green ✓ doesn't persist forever in Debug iterations.
            try? await Task.sleep(for: .seconds(5))
            if case .installed = model.state {
                model.show(.idle)
            }
        }

        private static func makeFakeItem() -> UpdateDisplayItem {
            // `pubDate` floats one day behind "today" so designers
            // iterating on the popover see a realistic Release Date
            // instead of a hardcoded literal that drifts out of
            // relevance over time.
            UpdateDisplayItem(
                displayVersion: "v0.1.99",
                contentLength: 60_817_408,
                date: Date().addingTimeInterval(-86400),
                releaseNotesURL: URL(string: "https://nek0der.github.io/weir/Weir-0.1.16.md")
            )
        }
    }
#endif
