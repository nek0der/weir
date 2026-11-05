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
//
// Each session has an identity (`UpdateSessionID`). The state the
// driver shows carries it, and every timer and Retry checks it, so one
// left over from an earlier session never acts on a later one.

import Foundation
import OSLog
import Sparkle

private let log = Logger.weir("updates")

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
    /// The timer that runs the auto-dismiss of a finished check or
    /// install; tests step it by hand.
    private let timer: HoverDelayTimer

    /// The action that starts a check the way Check for Updates does. Set
    /// by `UpdaterStack`, which owns that entry; a check deferred to the
    /// end of a session runs it once Sparkle has ended that session.
    var startsCheck: (@MainActor () -> Void)?

    /// One Sparkle session, from its first step to the moment Sparkle ends
    /// it (`dismissUpdateInstallation` or `updateCycleDidFinish`).
    private struct Session {
        let id: UpdateSessionID
        /// The update Sparkle offered in this session. Download and
        /// install steps carry no item of their own, and the state shown
        /// in between (extracting) has none, so the session keeps it.
        var item: UpdateDisplayItem?
        /// Whether this session went to Sparkle's own UI. Once one step
        /// has, the rest of the session follows it there, even if a window
        /// that could show it inline opens meanwhile, and the inline state
        /// stays idle: a session shown in both places would let the person
        /// answer it twice, and the rail's badge would say something
        /// Sparkle's window no longer does.
        var isStandardFlow = false
    }

    /// The open session; nil between sessions. A step that arrives with
    /// none open (a scheduled check finding an update) opens one.
    private var session: Session?
    private var lastSessionNumber: UInt64 = 0
    /// Whether a check was asked for while the open session showed its
    /// result, so one starts when Sparkle ends that session. Sparkle
    /// ignores a check asked for before then.
    private var startsCheckWhenCycleEnds = false

    /// Whether the open session shows in Sparkle's own UI.
    var isStandardFlow: Bool {
        session?.isStandardFlow ?? false
    }

    /// Whether a Sparkle session is open, so Sparkle answers a check asked
    /// for now itself.
    var hasOpenSession: Bool {
        session != nil
    }

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

    init(
        stateModel: UpdateStateModel,
        standard: any SPUUserDriver,
        timer: HoverDelayTimer = .live,
        hasInlineTarget: @escaping @MainActor () -> Bool
    ) {
        self.stateModel = stateModel
        self.isInlineTargetInSight = hasInlineTarget
        self.standard = standard
        self.timer = timer
        super.init()
    }

    // MARK: - Session

    /// Opens a new session, ending any open one: Sparkle starts each
    /// user-initiated check with a fresh session, whether or not it told
    /// us the last one ended.
    @discardableResult
    private func beginSession() -> UpdateSessionID {
        lastSessionNumber += 1
        let id = UpdateSessionID(rawValue: lastSessionNumber)
        session = Session(id: id)
        return id
    }

    /// Returns the open session's identity, opening a session if none is
    /// open.
    @discardableResult
    private func ensureSession() -> UpdateSessionID {
        session?.id ?? beginSession()
    }

    /// Shows `state` inline as part of the open session.
    private func show(_ state: UpdateState) {
        stateModel.show(state, for: ensureSession())
    }

    /// Records that Sparkle ended an update session
    /// (`SPUUpdaterDelegate`). Sparkle accepts a new check from here on,
    /// so a check deferred during the session starts now.
    func updateCycleDidFinish() {
        session = nil
        guard startsCheckWhenCycleEnds else { return }
        startsCheckWhenCycleEnds = false
        startsCheck?()
    }

    /// Decides, at a step that shows something new, where the session
    /// goes from here. Handing over to Sparkle's UI settles the inline
    /// state's pending callback and clears it, so no badge is left
    /// behind. Steps that only report progress follow `isStandardFlow`
    /// without calling this, since settling a download's state would
    /// cancel the download.
    ///
    /// `needsItem` marks a step whose inline view names the update. With
    /// no item in the session, which Sparkle's order of steps rules out,
    /// the step goes to Sparkle's UI, which reads the item itself, rather
    /// than showing a made-up version.
    private func showsInStandardUI(needsItem: Bool = false) -> Bool {
        ensureSession()
        let lacksItem = needsItem && session?.item == nil
        if !isStandardFlow, !hasInlineTarget || lacksItem {
            if lacksItem {
                log.fault("an update step arrived with no update found in its session")
            }
            consumePendingCallback()
            stateModel.show(.idle)
            session?.isStandardFlow = true
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
             let .error(_, ack, _),
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
        beginSession()
        if showsInStandardUI() {
            standard.showUserInitiatedUpdateCheck(cancellation: { cancelOnce.call() })
        } else {
            consumePendingCallback()
            show(.checking(cancel: cancelOnce))
        }
    }

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let ackOnce = OneShot(acknowledgement)
        if !showsInStandardUI() {
            consumePendingCallback()
            show(.notFound(acknowledgement: ackOnce))
            // Auto-dismiss after a moment so the update control doesn't
            // keep a "no update" badge around forever. The OneShot ensures
            // the auto-dismiss and a manual OK click never both fire
            // ack, and that ack ALWAYS fires before we leave the
            // state — Sparkle stalls otherwise. The timer acts only on
            // this session's result: a later check's own "no update"
            // keeps its acknowledgment until its own timer or OK.
            dismissAfter(.seconds(3)) { state in
                guard case .notFound = state else { return false }
                ackOnce.call()
                return true
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
            let id = ensureSession()
            let retry = OneShot<Void> { [weak self] in
                self?.retry(afterSession: id, acknowledgement: ackOnce)
            }
            show(.error(error: error, acknowledgement: ackOnce, retry: retry))
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
        showUpdateFound(UpdateDisplayItem(appcastItem: appcastItem), reply: reply) { [standard] replyOnce in
            standard.showUpdateFound(
                with: appcastItem,
                state: state,
                reply: { choice in replyOnce.call(choice) }
            )
        }
    }

    /// Shows a found update given as Weir's own item, which tests can
    /// make; `inStandardUI` hands the step to Sparkle's UI.
    func showUpdateFound(
        _ item: UpdateDisplayItem,
        reply: @escaping (SPUUserUpdateChoice) -> Void,
        inStandardUI: (OneShot<SPUUserUpdateChoice>) -> Void
    ) {
        let replyOnce = OneShot(reply)
        ensureSession()
        session?.item = item
        if !showsInStandardUI() {
            consumePendingCallback()
            show(.available(item: item, reply: replyOnce))
        } else {
            inStandardUI(replyOnce)
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
        guard !showsInStandardUI(needsItem: true), let item = session?.item else {
            standard.showDownloadInitiated(cancellation: { cancelOnce.call() })
            return
        }
        consumePendingCallback()
        show(.downloading(
            item: item,
            expectedBytes: nil,
            receivedBytes: 0,
            cancel: cancelOnce
        ))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if isStandardFlow {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
            return
        }
        guard case let .downloading(item, _, received, cancel) = stateModel.state else { return }
        show(.downloading(
            item: item,
            expectedBytes: expectedContentLength,
            receivedBytes: received,
            cancel: cancel
        ))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if isStandardFlow {
            standard.showDownloadDidReceiveData(ofLength: length)
            return
        }
        guard case let .downloading(item, expected, received, cancel) = stateModel.state else { return }
        show(.downloading(
            item: item,
            expectedBytes: expected,
            receivedBytes: received + length,
            cancel: cancel
        ))
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
            show(.extracting(progress: 0))
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if isStandardFlow {
            standard.showExtractionReceivedProgress(progress)
        } else {
            show(.extracting(progress: progress))
        }
    }

    // MARK: - Install + relaunch

    func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let replyOnce = OneShot(reply)
        if !showsInStandardUI(needsItem: true), let item = session?.item {
            consumePendingCallback()
            show(.readyToInstall(item: item, reply: replyOnce))
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
        show(.installing(retry: OneShot(retryTerminatingApplication)))
    }

    func showUpdateInstalledAndRelaunched(
        _: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        consumePendingCallback()
        // The relaunched app reports the install of a session the earlier
        // process ran; it shows inline as a session of its own.
        beginSession()
        let ackOnce = OneShot(acknowledgement)
        show(.installed(acknowledgement: ackOnce))
        // No Sparkle session of this process belongs to the report, and
        // none will end it, so we close ours now; its dismiss timer still
        // matches the state's session.
        session = nil
        // Acknowledge immediately so Sparkle frees its resources; the
        // OneShot keeps any view-side `acknowledgment.call()` safe.
        ackOnce.call()
        // Auto-dismiss the inline state regardless of whether the
        // popover is ever opened. Without this the green ✓ badge
        // persists indefinitely after a real-Sparkle relaunch (the
        // popover view's own onAppear timer only fires while the
        // popover is open, which it isn't in a freshly-relaunched
        // process). 5 s is a touch longer than `.notFound`'s 3 s so
        // the success message has time to land.
        dismissAfter(.seconds(5)) { state in
            if case .installed = state {
                true
            } else {
                false
            }
        }
    }

    /// Clears the inline state after `delay` if it still shows this
    /// session's result. `settles` checks the state, settles its callback,
    /// and says whether to clear it.
    private func dismissAfter(_ delay: Duration, settles: @escaping @MainActor (UpdateState) -> Bool) {
        let id = ensureSession()
        let stateRef = stateModel
        _ = timer.schedule(delay) {
            guard stateRef.sessionID == id, settles(stateRef.state) else { return }
            stateRef.show(.idle)
        }
    }

    /// Acknowledges a failed check and starts another once Sparkle has
    /// ended it; a Retry left from an earlier session only acknowledges.
    private func retry(afterSession id: UpdateSessionID, acknowledgement: OneShot<Void>) {
        if session?.id == id, stateModel.sessionID == id, defersCheckToSessionEnd() {
            return
        }
        acknowledgement.call()
    }

    /// Takes a check asked for while the open session shows its result,
    /// "You’re up to date" or a failure: settles that result, which lets
    /// Sparkle end the session, and starts the check once it has. Returns
    /// whether it took the check; Sparkle answers any other check itself.
    func defersCheckToSessionEnd() -> Bool {
        guard let id = session?.id, stateModel.sessionID == id else { return false }
        switch stateModel.state {
        case let .notFound(acknowledgement),
             let .error(_, acknowledgement, _):
            startsCheckWhenCycleEnds = true
            acknowledgement.call()
            return true
        case .idle, .checking, .available, .downloading, .extracting, .readyToInstall, .installing, .installed:
            return false
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
        stateModel.show(.idle)
        let wasStandardFlow = isStandardFlow
        // Sparkle calls this only as it ends a session.
        session = nil
        if wasStandardFlow {
            // Sparkle's driver closes its checking and progress windows
            // here; without the call they outlive the session.
            standard.dismissUpdateInstallation()
        }
    }

}
