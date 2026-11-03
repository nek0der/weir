// WeirUpdateDriver.swift
// Weir — full `SPUUserDriver` implementation that drives the
// main window's update control + popover state machine. Each update
// session shows either inline, through our `UpdateStateModel`, or in a
// wrapped `SPUStandardUserDriver` once a step finds no window that could
// show it, so users never miss an update found while the app has no
// visible main Weir window.
//
// Sparkle's lifecycle invokes ~20 protocol methods in a fixed order
// (permission → check → found → release-notes → download → extract
// → ready → install → installed). Each delegate reply / acknowledgment
// / cancellation closure MUST be called exactly once — forgetting one
// stalls Sparkle's internal state machine for the rest of the session,
// calling it twice asserts. We protect both directions with `OneShot`
// at the driver boundary and consume the OneShot whenever we discard
// a state (auto-dismiss timer, state overwrites).

import Foundation
import Sparkle

/// Declared `@MainActor` because Sparkle calls every `SPUUserDriver`
/// method on the main thread. Letting Swift see the isolation makes
/// the embedded reply / cancellation closures usable without
/// `Sendable` gymnastics — they're captured into `UpdateState` which
/// lives on the same actor.
@MainActor
final class WeirUpdateDriver: NSObject, SPUUserDriver {
    private let stateModel: UpdateStateModel
    /// Sparkle's own UI, an `SPUStandardUserDriver` outside tests.
    private let standard: any SPUUserDriver
    /// Whether some window can show the update inline, read at each event;
    /// the UI knows its windows (`WeirWindowRole.isUpdateControlInSight`).
    private let isInlineTargetInSight: @MainActor () -> Bool

    /// Whether this update session went to Sparkle's own UI. Once one
    /// step has, the rest of the session follows it there, even if a
    /// window that could show it inline opens meanwhile, and the inline
    /// state stays idle: a session shown in both places would let the
    /// person answer it twice, and the rail's badge would say something
    /// Sparkle's window no longer does. Cleared when the session ends.
    private(set) var isStandardFlow = false

    private var hasInlineTarget: Bool {
        isInlineTargetInSight()
    }

    convenience init(stateModel: UpdateStateModel, hostBundle: Bundle, hasInlineTarget: @escaping @MainActor () -> Bool) {
        self.init(
            stateModel: stateModel,
            standard: SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil),
            hasInlineTarget: hasInlineTarget
        )
    }

    init(stateModel: UpdateStateModel, standard: any SPUUserDriver, hasInlineTarget: @escaping @MainActor () -> Bool) {
        self.stateModel = stateModel
        self.isInlineTargetInSight = hasInlineTarget
        self.standard = standard
        super.init()
    }

    /// Decides, at a step that shows something new, where the session
    /// goes from here. Handing over to Sparkle's UI settles the inline
    /// state's pending callback and clears it, so no badge is left
    /// behind. Steps that only report progress follow `isStandardFlow`
    /// without calling this, since settling a download's state would
    /// cancel the download.
    private func showsInStandardUI() -> Bool {
        if !isStandardFlow, !hasInlineTarget {
            consumePendingCallback()
            stateModel.state = .idle
            isStandardFlow = true
        }
        return isStandardFlow
    }

    /// Pre-flight any pending OneShot embedded in the current state so
    /// it doesn't get dropped on the floor when we overwrite. Sparkle
    /// treats unfired acknowledgments as a stall; this ensures every
    /// state transition consumes its predecessor's contract.
    private func consumePendingCallback() {
        switch stateModel.state {
        case let .checking(cancel):
            cancel.call()
        case let .available(_, reply),
             let .readyToInstall(_, reply):
            // No user choice was made; behave like Later.
            // Sparkle currently tolerates a late `.dismiss` arriving
            // after a fresh `showUserInitiatedUpdateCheck` has rolled
            // the state machine forward (`SPUUserDriver.h:88-90`
            // documents `Dismiss` as "keep the update around for
            // later"). The `OneShot` wrapper keeps the call safe
            // locally; if upstream ever tightens this and starts
            // asserting double-consumption, switch to leaving the
            // prior reply un-fired and letting Sparkle's own state
            // overwrite it.
            reply.call(.dismiss)
        case let .downloading(_, _, _, cancel):
            cancel.call()
        case let .notFound(ack),
             let .error(_, ack),
             let .installed(ack):
            ack.call()
        case .idle, .extracting, .installing:
            break
        }
    }

    // MARK: - Permission

    func show(
        _: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // We don't surface the permission prompt in our own UI — the
        // "Automatically check for updates" toggle in Settings is the
        // authoritative control. Reply with the user's current
        // preference; Sparkle will respect it. Dev builds default off
        // so a debugger session never silently pulls a release update.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: !WeirPaths.isDevBuild,
            sendSystemProfile: false
        ))
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        let cancelOnce = OneShot(cancellation)
        if showsInStandardUI() {
            standard.showUserInitiatedUpdateCheck(cancellation: { cancelOnce.call() })
        } else {
            consumePendingCallback()
            stateModel.state = .checking(cancel: cancelOnce)
        }
    }

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let ackOnce = OneShot(acknowledgement)
        if !showsInStandardUI() {
            consumePendingCallback()
            stateModel.state = .notFound(acknowledgement: ackOnce)
            // Auto-dismiss after a moment so the update control doesn't
            // keep a "no update" badge around forever. The OneShot ensures
            // the auto-dismiss and a manual OK click never both fire
            // ack, and that ack ALWAYS fires before we leave the
            // state — Sparkle stalls otherwise.
            let stateRef = stateModel
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if case .notFound = stateRef.state {
                    ackOnce.call()
                    stateRef.state = .idle
                }
            }
        } else {
            standard.showUpdateNotFoundWithError(error, acknowledgement: { ackOnce.call() })
        }
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let ackOnce = OneShot(acknowledgement)
        if !showsInStandardUI() {
            consumePendingCallback()
            stateModel.state = .error(error: error, acknowledgement: ackOnce)
        } else {
            standard.showUpdaterError(error, acknowledgement: { ackOnce.call() })
        }
    }

    // MARK: - Update found

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let replyOnce = OneShot(reply)
        if !showsInStandardUI() {
            consumePendingCallback()
            stateModel.state = .available(
                item: UpdateDisplayItem(appcastItem: appcastItem),
                reply: replyOnce
            )
        } else {
            standard.showUpdateFound(
                with: appcastItem,
                state: state,
                reply: { choice in replyOnce.call(choice) }
            )
        }
    }

    func showUpdateReleaseNotes(with _: SPUDownloadData) {
        // Release notes are surfaced via the appcast `releaseNotesURL`
        // link inside the popover, not via Sparkle's bundled
        // WebKit-based renderer. No-op.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_: any Error) {
        // Same reason — we don't render release notes inline.
    }

    // MARK: - Download progress

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        let cancelOnce = OneShot(cancellation)
        if showsInStandardUI() {
            standard.showDownloadInitiated(cancellation: { cancelOnce.call() })
            return
        }
        // Carry forward the display item if we have one in state;
        // otherwise show a placeholder.
        let item = stateModel.pendingItem ?? .placeholder
        consumePendingCallback()
        stateModel.state = .downloading(
            item: item,
            expectedBytes: nil,
            receivedBytes: 0,
            cancel: cancelOnce
        )
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if isStandardFlow {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
            return
        }
        guard case let .downloading(item, _, received, cancel) = stateModel.state else { return }
        stateModel.state = .downloading(
            item: item,
            expectedBytes: expectedContentLength,
            receivedBytes: received,
            cancel: cancel
        )
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if isStandardFlow {
            standard.showDownloadDidReceiveData(ofLength: length)
            return
        }
        guard case let .downloading(item, expected, received, cancel) = stateModel.state else { return }
        stateModel.state = .downloading(
            item: item,
            expectedBytes: expected,
            receivedBytes: received + length,
            cancel: cancel
        )
    }

    // MARK: - Extraction

    func showDownloadDidStartExtractingUpdate() {
        // Extracting doesn't carry a cancellation, so we don't need
        // `consumePendingCallback` — the previous `.downloading`
        // cancel is naturally fulfilled (download succeeded), not
        // dropped.
        if isStandardFlow {
            standard.showDownloadDidStartExtractingUpdate()
        } else {
            stateModel.state = .extracting(progress: 0)
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if isStandardFlow {
            standard.showExtractionReceivedProgress(progress)
        } else {
            stateModel.state = .extracting(progress: progress)
        }
    }

    // MARK: - Install + relaunch

    func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let replyOnce = OneShot(reply)
        if !showsInStandardUI() {
            let item = stateModel.pendingItem ?? .placeholder
            consumePendingCallback()
            stateModel.state = .readyToInstall(item: item, reply: replyOnce)
        } else {
            standard.showReady(
                toInstallAndRelaunch: { choice in replyOnce.call(choice) }
            )
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // A session in Sparkle's UI keeps the retry there, where its
        // `showUpdateInFocus` offers it again.
        if isStandardFlow {
            standard.showInstallingUpdate(
                withApplicationTerminated: applicationTerminated,
                retryTerminatingApplication: retryTerminatingApplication
            )
            return
        }
        // Capture Sparkle's retry escape hatch so the inline view can
        // expose it if the app cancels or delays its quit (e.g. a
        // confirm-quit dialog blocks termination). Without this the
        // user is stuck on the "Installing update…" row with no way
        // out — the standard driver path is deliberately skipped
        // (Sparkle would otherwise layer its own modal on top).
        stateModel.state = .installing(retry: OneShot(retryTerminatingApplication))
    }

    func showUpdateInstalledAndRelaunched(
        _: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        consumePendingCallback()
        isStandardFlow = false
        let ackOnce = OneShot(acknowledgement)
        stateModel.state = .installed(acknowledgement: ackOnce)
        // Acknowledge immediately so Sparkle frees its resources; the
        // OneShot keeps any view-side `acknowledgement.call()` safe.
        ackOnce.call()
        // Auto-dismiss the inline state regardless of whether the
        // popover is ever opened. Without this the green ✓ badge
        // persists indefinitely after a real-Sparkle relaunch (the
        // popover view's own onAppear timer only fires while the
        // popover is open, which it isn't in a freshly-relaunched
        // process). 5 s is a touch longer than `.notFound`'s 3 s so
        // the success message has time to land.
        let stateRef = stateModel
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .installed = stateRef.state {
                stateRef.state = .idle
            }
        }
    }

    // MARK: - Misc lifecycle

    /// Sparkle calls this, instead of starting a check, when Check for
    /// Updates is chosen while an update is being shown. It brings that
    /// update forward wherever the session is: Sparkle's window, or the
    /// update popover of the window in front.
    func showUpdateInFocus() {
        if isStandardFlow {
            standard.showUpdateInFocus?()
        } else if stateModel.showsBadge {
            stateModel.focusRequests += 1
        }
    }

    func dismissUpdateInstallation() {
        consumePendingCallback()
        stateModel.state = .idle
        if isStandardFlow {
            // Sparkle's driver closes its checking and progress windows
            // here; without the call they outlive the session.
            isStandardFlow = false
            standard.dismissUpdateInstallation()
        }
    }

}
