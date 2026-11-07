// WeirUpdateDriverTests.swift
// Weir — where an update session shows, and how each session keeps its own timers, checks, and update.

import Foundation
import Sparkle
import Testing
@testable import Weir

@MainActor
struct WeirUpdateDriverTests {
    /// Records the calls that reach Sparkle's own UI.
    @MainActor
    final class FakeStandardDriver: NSObject, SPUUserDriver {
        var calls: [String] = []
        var expectedLengths: [UInt64] = []
        var receivedLengths: [UInt64] = []
        var extractionProgress: [Double] = []
        var downloadCancellation: (() -> Void)?
        var errorAcknowledgement: (() -> Void)?
        var readyReply: ((SPUUserUpdateChoice) -> Void)?

        func show(_: SPUUpdatePermissionRequest, reply _: @escaping (SUUpdatePermissionResponse) -> Void) {
            calls.append("permission")
        }

        func showUserInitiatedUpdateCheck(cancellation _: @escaping () -> Void) {
            calls.append("checking")
        }

        func showUpdateFound(
            with _: SUAppcastItem,
            state _: SPUUserUpdateState,
            reply _: @escaping (SPUUserUpdateChoice) -> Void
        ) {
            calls.append("found")
        }

        func showUpdateReleaseNotes(with _: SPUDownloadData) {}
        func showUpdateReleaseNotesFailedToDownloadWithError(_: any Error) {}

        func showUpdateNotFoundWithError(_: any Error, acknowledgement _: @escaping () -> Void) {
            calls.append("notFound")
        }

        func showUpdaterError(_: any Error, acknowledgement: @escaping () -> Void) {
            calls.append("error")
            errorAcknowledgement = acknowledgement
        }

        func showDownloadInitiated(cancellation: @escaping () -> Void) {
            calls.append("download")
            downloadCancellation = cancellation
        }

        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
            calls.append("length")
            expectedLengths.append(expectedContentLength)
        }

        func showDownloadDidReceiveData(ofLength length: UInt64) {
            calls.append("data")
            receivedLengths.append(length)
        }

        func showDownloadDidStartExtractingUpdate() {
            calls.append("extract")
        }

        func showExtractionReceivedProgress(_ progress: Double) {
            calls.append("extractProgress")
            extractionProgress.append(progress)
        }

        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
            calls.append("ready")
            readyReply = reply
        }

        func showInstallingUpdate(withApplicationTerminated _: Bool, retryTerminatingApplication _: @escaping () -> Void) {
            calls.append("installing")
        }

        func showUpdateInstalledAndRelaunched(_: Bool, acknowledgement _: @escaping () -> Void) {
            calls.append("installed")
        }

        func showUpdateInFocus() {
            calls.append("focus")
        }

        func dismissUpdateInstallation() {
            calls.append("dismiss")
        }
    }

    /// A driver whose inline target is whatever `isInSight` holds when an
    /// event arrives.
    @MainActor
    final class Harness {
        let model = UpdateStateModel()
        let standard = FakeStandardDriver()
        let clock = ManualTimer()
        var isInSight: Bool
        /// How many checks Retry started.
        private(set) var startedChecks = 0
        private(set) lazy var driver: WeirUpdateDriver = {
            let driver = WeirUpdateDriver(
                stateModel: model,
                standard: standard,
                timer: clock.timer,
                hasInlineTarget: { [unowned self] in isInSight }
            )
            driver.startsCheck = { [unowned self] in startedChecks += 1 }
            return driver
        }()

        init(isInSight: Bool) {
            self.isInSight = isInSight
        }

        /// Sparkle's end of a session after its last acknowledgment: the
        /// user driver is dismissed, then the updater reports the cycle done.
        func sparkleEndsTheSession() {
            driver.dismissUpdateInstallation()
            driver.updateCycleDidFinish()
        }

        /// Sparkle offers an update inline, as it does before any download.
        func findUpdate(version: String = "v1.2.3") {
            driver.showUpdateFound(UpdateDisplayItem(displayVersion: version), reply: { _ in }, inStandardUI: { _ in
                Issue.record("the update went to Sparkle's window")
            })
        }

        /// Uses the display item seam to record that the found step was sent to standard UI.
        func offerInStandardUI() throws -> OneShot<SPUUserUpdateChoice> {
            var forwarded: OneShot<SPUUserUpdateChoice>?
            driver.showUpdateFound(
                UpdateDisplayItem(displayVersion: "v2.3.4"),
                reply: { _ in },
                inStandardUI: { reply in
                    standard.calls.append("found")
                    forwarded = reply
                }
            )
            return try #require(forwarded)
        }

        var isIdle: Bool {
            if case .idle = model.state {
                model.sessionID == nil
            } else {
                false
            }
        }

        /// A check that finds no update, returning its acknowledgment count.
        func checkFindingNothing() -> () -> Int {
            var acks = 0
            driver.showUserInitiatedUpdateCheck(cancellation: {})
            driver.showUpdateNotFoundWithError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })
            return { acks }
        }

        /// The error state's acknowledgment and Retry.
        var errorCallbacks: (acknowledgement: OneShot<Void>, retry: OneShot<Void>)? {
            if case let .error(_, acknowledgement, retry) = model.state {
                (acknowledgement, retry)
            } else {
                nil
            }
        }
    }

    enum ShownUpdate: Sendable {
        case standard
        case inline
        case none
    }

    @Test(arguments: [ShownUpdate.standard, .inline, .none])
    func askingToFocusAnUpdate_targetsOnlyItsPresentation(_ shown: ShownUpdate) throws {
        let harness = Harness(isInSight: shown != .standard)
        switch shown {
        case .standard:
            harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
            _ = try harness.offerInStandardUI()
        case .inline:
            harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
            harness.findUpdate()
        case .none:
            break
        }
        let id = harness.model.sessionID

        harness.driver.showUpdateInFocus()

        #expect(harness.model.focusRequests == (shown == .inline ? 1 : 0))
        #expect(harness.standard.calls == (shown == .standard ? ["checking", "found", "focus"] : []))
        #expect(harness.model.sessionID == id)
        if shown == .inline {
            guard case let .available(item, _) = harness.model.state else {
                Issue.record("the inline offer was replaced")
                return
            }
            #expect(id != nil)
            #expect(item.displayVersion == "v1.2.3")
        } else {
            #expect(harness.isIdle)
        }
    }

    @Test func aSessionInSparklesWindow_leavesTheInlineStateIdle() throws {
        let harness = Harness(isInSight: false)

        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(harness.isIdle)
        try harness.offerInStandardUI().call(.install)
        #expect(harness.isIdle)
        harness.driver.showDownloadInitiated(cancellation: {})
        harness.driver.showDownloadDidReceiveExpectedContentLength(100)
        harness.driver.showDownloadDidReceiveData(ofLength: 51)
        #expect(harness.isIdle)
        harness.driver.showDownloadDidStartExtractingUpdate()
        harness.driver.showExtractionReceivedProgress(0.5)

        #expect(harness.isIdle)
        #expect(harness.standard.calls == ["checking", "found", "download", "length", "data", "extract", "extractProgress"])
        #expect(harness.standard.expectedLengths == [100])
        #expect(harness.standard.receivedLengths == [51])
        #expect(harness.standard.extractionProgress == [0.5])
    }

    @Test func aWindowThatOpensMidSession_doesNotTakeTheSessionFromSparklesWindow() throws {
        let harness = Harness(isInSight: false)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        try harness.offerInStandardUI().call(.install)
        harness.driver.showDownloadInitiated(cancellation: {})
        try #require(harness.driver.isStandardFlow && harness.isIdle)

        harness.isInSight = true
        harness.driver.showDownloadDidReceiveData(ofLength: 10)
        harness.driver.showDownloadDidStartExtractingUpdate()
        harness.driver.showReady(toInstallAndRelaunch: { _ in })

        #expect(harness.isIdle)
        #expect(harness.driver.isStandardFlow)
        #expect(harness.standard.calls == ["checking", "found", "download", "data", "extract", "ready"])
        #expect(harness.standard.receivedLengths == [10])
    }

    @Test func anInlineSessionWhoseWindowGoes_movesToSparklesWindowWithoutABadge() throws {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.findUpdate()
        guard case let .available(_, offer) = harness.model.state else {
            Issue.record("expected an inline offer")
            return
        }
        offer.call(.install)
        harness.driver.showDownloadInitiated(cancellation: {})
        harness.driver.showDownloadDidStartExtractingUpdate()
        harness.driver.showExtractionReceivedProgress(0.5)
        guard case let .extracting(progress) = harness.model.state else {
            Issue.record("expected inline extraction")
            return
        }
        #expect(progress == 0.5)
        try #require(harness.model.sessionID != nil)

        harness.isInSight = false
        var choices: [SPUUserUpdateChoice] = []
        harness.driver.showReady(toInstallAndRelaunch: { choices.append($0) })

        #expect(harness.isIdle)
        #expect(harness.standard.calls == ["ready"])
        let reply = try #require(harness.standard.readyReply)
        reply(.install)
        reply(.dismiss)
        #expect(choices == [.install])
    }

    @Test func theEndOfASessionInSparklesWindow_closesItsWindows_andTheNextSessionCanShowInline() {
        let harness = Harness(isInSight: false)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})

        harness.driver.dismissUpdateInstallation()
        #expect(harness.standard.calls == ["checking", "dismiss"])
        #expect(!harness.driver.isStandardFlow)

        harness.isInSight = true
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(harness.model.showsBadge)
        #expect(harness.standard.calls == ["checking", "dismiss"])
    }

    @Test func handingOverToSparklesWindow_settlesTheInlineCallback() throws {
        let harness = Harness(isInSight: true)
        var cancels = 0
        var acknowledgements = 0
        harness.driver.showUserInitiatedUpdateCheck(cancellation: { cancels += 1 })
        guard case let .checking(cancel) = harness.model.state else {
            Issue.record("expected an inline check")
            return
        }

        harness.isInSight = false
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: { acknowledgements += 1 })

        #expect(cancels == 1)
        #expect(acknowledgements == 0)
        #expect(harness.isIdle)
        #expect(harness.standard.calls == ["error"])
        let acknowledgement = try #require(harness.standard.errorAcknowledgement)
        acknowledgement()
        acknowledgement()
        cancel.call()
        harness.sparkleEndsTheSession()
        harness.sparkleEndsTheSession()

        #expect(cancels == 1)
        #expect(acknowledgements == 1)
        #expect(harness.isIdle)
        #expect(harness.standard.calls == ["error", "dismiss"])
    }

    // MARK: - Each session keeps its own timers, Retry, and update

    @Test func anEarlierChecksDismissTimer_leavesALaterChecksResultToItsOwnTimer() {
        let harness = Harness(isInSight: true)
        let firstAcks = harness.checkFindingNothing()
        if case let .notFound(acknowledgement) = harness.model.state {
            acknowledgement.call()
        }
        harness.sparkleEndsTheSession()
        #expect(firstAcks() == 1)

        harness.clock.advance(by: .seconds(2))
        let secondAcks = harness.checkFindingNothing()
        // The first check's timer falls due here.
        harness.clock.advance(by: .seconds(1))

        #expect(secondAcks() == 0)
        guard case .notFound = harness.model.state else {
            Issue.record("the later check's result was cleared by the earlier check's timer")
            return
        }

        harness.clock.advance(by: .seconds(2))
        #expect(secondAcks() == 1)
        #expect(!harness.model.showsBadge)
    }

    @Test func retry_startsACheckOnlyOnceSparkleHasEndedTheFailedOne() throws {
        let harness = Harness(isInSight: true)
        var acks = 0
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })
        let callbacks = try #require(harness.errorCallbacks)

        callbacks.retry.call()
        #expect(acks == 1)
        #expect(harness.startedChecks == 0)

        harness.driver.dismissUpdateInstallation()
        #expect(harness.startedChecks == 0)

        harness.driver.updateCycleDidFinish()
        #expect(harness.startedChecks == 1)

        harness.driver.updateCycleDidFinish()
        #expect(harness.startedChecks == 1)
    }

    @Test func closingAFailedCheck_startsNoCheck() throws {
        let harness = Harness(isInSight: true)
        var acks = 0
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })
        let callbacks = try #require(harness.errorCallbacks)

        callbacks.acknowledgement.call()
        callbacks.acknowledgement.call()
        #expect(acks == 1)
        #expect(harness.startedChecks == 0)

        harness.sparkleEndsTheSession()
        harness.sparkleEndsTheSession()
        #expect(acks == 1)
        #expect(harness.startedChecks == 0)
        #expect(harness.isIdle)
    }

    @Test func aRetryLeftFromAnEarlierSession_startsNoCheck() throws {
        let harness = Harness(isInSight: true)
        var earlierAcks = 0
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: { earlierAcks += 1 })
        let earlier = try #require(harness.errorCallbacks)
        let earlierID = try #require(harness.model.sessionID)
        earlier.acknowledgement.call()
        harness.sparkleEndsTheSession()

        var newerAcks = 0
        let newerError = CocoaError(.fileWriteNoPermission)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.driver.showUpdaterError(newerError, acknowledgement: { newerAcks += 1 })
        let newerID = try #require(harness.model.sessionID)
        try #require(newerID != earlierID)
        let newer = try #require(harness.errorCallbacks)
        try #require(earlier.acknowledgement !== newer.acknowledgement)

        earlier.retry.call()
        earlier.retry.call()

        #expect(earlierAcks == 1)
        #expect(newerAcks == 0)
        #expect(harness.startedChecks == 0)
        #expect(harness.model.sessionID == newerID)
        guard case let .error(error, acknowledgement, retry) = harness.model.state else {
            Issue.record("the newer error was replaced")
            return
        }
        #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        #expect(acknowledgement === newer.acknowledgement)
        #expect(retry === newer.retry)

        acknowledgement.call()
        harness.sparkleEndsTheSession()
        #expect(newerAcks == 1)
        #expect(harness.startedChecks == 0)
    }

    @Test func theInstallConfirmation_namesTheVersionSparkleFound() {
        let harness = Harness(isInSight: true)
        for version in ["v1.2.3", "v2.3.4"] {
            let releaseNotes = URL(string: "https://example.invalid/notes/\(version)")
            let offered = UpdateDisplayItem(displayVersion: version, contentLength: 100, releaseNotesURL: releaseNotes)
            var offerChoices: [SPUUserUpdateChoice] = []
            var installChoices: [SPUUserUpdateChoice] = []
            var downloadCancels = 0
            harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
            harness.driver.showUpdateFound(
                offered,
                reply: { offerChoices.append($0) },
                inStandardUI: { _ in Issue.record("expected the offer to stay inline") }
            )
            guard case let .available(available, offer) = harness.model.state else {
                Issue.record("expected an inline offer")
                return
            }
            #expect(available.displayVersion == version)
            offer.call(.install)

            harness.driver.showDownloadInitiated(cancellation: { downloadCancels += 1 })
            harness.driver.showDownloadDidReceiveExpectedContentLength(100)
            harness.driver.showDownloadDidReceiveData(ofLength: 44)
            guard case let .downloading(item, expected, received, _) = harness.model.state else {
                Issue.record("expected an inline download")
                return
            }
            #expect(item.displayVersion == version)
            #expect(item.releaseNotesURL == releaseNotes)
            #expect(expected == 100)
            #expect(received == 44)

            harness.driver.showDownloadDidStartExtractingUpdate()
            harness.driver.showExtractionReceivedProgress(1)
            guard case let .extracting(progress) = harness.model.state else {
                Issue.record("expected inline extraction")
                return
            }
            #expect(progress == 1)
            harness.driver.showReady(toInstallAndRelaunch: { installChoices.append($0) })
            guard case let .readyToInstall(ready, reply) = harness.model.state else {
                Issue.record("expected an inline install confirmation")
                return
            }
            #expect(ready.displayVersion == version)
            #expect(ready.contentLength == 100)
            #expect(ready.releaseNotesURL == releaseNotes)
            reply.call(.install)
            reply.call(.dismiss)
            harness.sparkleEndsTheSession()
            #expect(offerChoices == [.install])
            #expect(installChoices == [.install])
            #expect(downloadCancels == 0)
            #expect(harness.standard.calls.isEmpty)
            #expect(harness.isIdle)
        }
    }

    @Test(arguments: [false, true])
    func anInstallStepWithNoUpdateFound_goesToSparklesWindow(isReadyStep: Bool) throws {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.findUpdate(version: "v0.0.1")
        harness.sparkleEndsTheSession()
        try #require(harness.isIdle)

        var checkingCancels = 0
        harness.driver.showUserInitiatedUpdateCheck(cancellation: { checkingCancels += 1 })
        if isReadyStep {
            var replies: [SPUUserUpdateChoice] = []
            harness.driver.showReady(toInstallAndRelaunch: { replies.append($0) })
            let reply = try #require(harness.standard.readyReply)
            reply(.dismiss)
            reply(.install)
            #expect(replies == [.dismiss])
        } else {
            var downloadCancels = 0
            harness.driver.showDownloadInitiated(cancellation: { downloadCancels += 1 })
            let cancel = try #require(harness.standard.downloadCancellation)
            cancel()
            cancel()
            #expect(downloadCancels == 1)
        }

        #expect(checkingCancels == 1)
        #expect(harness.isIdle)
        #expect(harness.standard.calls == [isReadyStep ? "ready" : "download"])
    }

    @Test func theStateShown_belongsToTheSessionThatShowedIt() throws {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        let first = try #require(harness.model.sessionID)
        guard case .checking = harness.model.state else {
            Issue.record("expected an inline check")
            return
        }
        harness.findUpdate()
        guard case let .available(_, offer) = harness.model.state else {
            Issue.record("expected an inline offer")
            return
        }
        #expect(harness.model.sessionID == first)
        offer.call(.install)
        harness.driver.showDownloadInitiated(cancellation: {})
        guard case .downloading = harness.model.state else {
            Issue.record("expected an inline download")
            return
        }
        #expect(harness.model.sessionID == first)
        harness.driver.showDownloadDidStartExtractingUpdate()
        guard case .extracting = harness.model.state else {
            Issue.record("expected inline extraction")
            return
        }
        #expect(harness.model.sessionID == first)
        harness.driver.showReady(toInstallAndRelaunch: { _ in })
        guard case .readyToInstall = harness.model.state else {
            Issue.record("expected an inline install confirmation")
            return
        }
        #expect(harness.model.sessionID == first)

        harness.sparkleEndsTheSession()
        #expect(harness.isIdle)

        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        let second = try #require(harness.model.sessionID)
        #expect(second != first)
    }

    @Test func anInstalledReport_dismissesAfterFiveSeconds_withoutOpeningACheck() throws {
        let harness = Harness(isInSight: true)
        var acknowledgements = 0
        harness.driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: {})
        harness.driver.showUpdateInstalledAndRelaunched(false, acknowledgement: { acknowledgements += 1 })
        let id = try #require(harness.model.sessionID)
        guard case let .installed(acknowledgement) = harness.model.state else {
            Issue.record("expected the install completion")
            return
        }
        #expect(acknowledgements == 1)
        #expect(!harness.driver.hasOpenSession)

        harness.clock.advance(by: .milliseconds(4999))
        #expect(harness.model.sessionID == id)
        #expect(harness.model.showsBadge)

        acknowledgement.call()
        harness.clock.advance(by: .milliseconds(1))
        #expect(harness.isIdle)
        #expect(!harness.model.showsBadge)
        #expect(!harness.driver.hasOpenSession)
        #expect(acknowledgements == 1)
        #expect(harness.startedChecks == 0)
    }

    @Test func anEarlierInstallTimer_doesNotDismissTheNextInstallReport() throws {
        let harness = Harness(isInSight: true)
        var firstAcks = 0
        var secondAcks = 0
        harness.driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: {})
        harness.driver.showUpdateInstalledAndRelaunched(false, acknowledgement: { firstAcks += 1 })
        let first = try #require(harness.model.sessionID)
        harness.clock.advance(by: .seconds(2))

        harness.driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: {})
        harness.driver.showUpdateInstalledAndRelaunched(false, acknowledgement: { secondAcks += 1 })
        let second = try #require(harness.model.sessionID)
        try #require(second != first)

        // The first timer falls due while the same state shows a newer report.
        harness.clock.advance(by: .seconds(3))
        guard case .installed = harness.model.state else {
            Issue.record("the earlier timer dismissed the newer install report")
            return
        }
        #expect(harness.model.sessionID == second)
        #expect(!harness.driver.hasOpenSession)

        harness.clock.advance(by: .seconds(2))
        #expect(harness.isIdle)
        #expect(firstAcks == 1)
        #expect(secondAcks == 1)
    }

}

#if DEBUG

    // MARK: - Check for Updates through the updater stack

    extension WeirUpdateDriverTests {
        /// The app's own stack, never started, so no check reaches the
        /// network; its Check for Updates runs the Debug mock.
        private func makeStack() -> UpdaterStack {
            UpdaterStack(allowsAutomaticChecks: false, startsUpdater: false, hasInlineTarget: { true })
        }

        /// Sparkle's end of the open session, through the updater's delegate.
        private func sparkleEndsTheSession(of stack: UpdaterStack) {
            stack.driver.dismissUpdateInstallation()
            stack.cycleObserver.updater(stack.updater, didFinishUpdateCycleFor: .updates, error: nil)
        }

        private func isOffered(_ state: UpdateState) -> Bool {
            if case .available = state {
                true
            } else {
                false
            }
        }

        enum DeferredCheck: Sendable {
            case upToDateMenu
            case errorMenu
            case errorRetry
        }

        @Test(arguments: [DeferredCheck.upToDateMenu, .errorMenu, .errorRetry])
        func aResultAction_rechecksOnceAfterSparkleFinishes(_ action: DeferredCheck) throws {
            let stack = makeStack()
            var acks = 0
            var deferredStarts = 0
            let originalStart = try #require(stack.driver.startsCheck)
            stack.driver.startsCheck = {
                deferredStarts += 1
                originalStart()
            }
            stack.driver.showUserInitiatedUpdateCheck(cancellation: {})
            let originalID = try #require(stack.stateModel.sessionID)
            if action == .upToDateMenu {
                stack.driver.showUpdateNotFoundWithError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })
            } else {
                stack.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })
            }

            if action == .errorRetry {
                guard case let .error(_, _, retry) = stack.stateModel.state else {
                    Issue.record("expected the inline error")
                    return
                }
                retry.call()
                retry.call()
            } else {
                stack.checkForUpdates()
                stack.checkForUpdates()
            }

            #expect(acks == 1)
            #expect(deferredStarts == 0)
            #expect(stack.stateModel.sessionID == originalID)
            switch (action, stack.stateModel.state) {
            case (.upToDateMenu, .notFound), (.errorMenu, .error), (.errorRetry, .error):
                break
            default:
                Issue.record("the result was replaced before the cycle ended")
            }

            stack.driver.dismissUpdateInstallation()
            #expect(deferredStarts == 0)
            stack.cycleObserver.updater(stack.updater, didFinishUpdateCycleFor: .updates, error: nil)
            #expect(deferredStarts == 1)
            #expect(stack.stateModel.sessionID == nil)
            guard case let .available(_, firstReply) = stack.stateModel.state else {
                Issue.record("expected the Debug check to offer an update")
                return
            }

            stack.cycleObserver.updater(stack.updater, didFinishUpdateCycleFor: .updates, error: nil)
            #expect(acks == 1)
            #expect(deferredStarts == 1)
            guard case let .available(_, repeatedReply) = stack.stateModel.state else {
                Issue.record("the Debug offer disappeared after duplicate completion")
                return
            }
            #expect(repeatedReply === firstReply)
        }

        @Test func checkForUpdates_whileACheckIsOpen_preservesTheInlineState() throws {
            let stack = makeStack()
            var cancels = 0
            var deferredStarts = 0
            let originalStart = try #require(stack.driver.startsCheck)
            stack.driver.startsCheck = {
                deferredStarts += 1
                originalStart()
            }
            stack.driver.showUserInitiatedUpdateCheck(cancellation: { cancels += 1 })
            let id = try #require(stack.stateModel.sessionID)
            guard case let .checking(original) = stack.stateModel.state else {
                Issue.record("expected the inline check")
                return
            }

            stack.checkForUpdates()

            guard case let .checking(current) = stack.stateModel.state else {
                Issue.record("the check was replaced")
                return
            }
            #expect(current === original)
            #expect(stack.stateModel.sessionID == id)
            #expect(cancels == 0)

            sparkleEndsTheSession(of: stack)
            #expect(cancels == 1)
            #expect(deferredStarts == 0)
            #expect(stack.stateModel.sessionID == nil)
            guard case .idle = stack.stateModel.state else {
                Issue.record("an extra check started after the cycle")
                return
            }
        }

        @Test func checkForUpdates_withNoSessionOpen_runsTheMock() {
            let stack = makeStack()

            stack.checkForUpdates()

            #expect(isOffered(stack.stateModel.state))
        }
    }
#endif
