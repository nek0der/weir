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

        func showUpdaterError(_: any Error, acknowledgement _: @escaping () -> Void) {
            calls.append("error")
        }

        func showDownloadInitiated(cancellation _: @escaping () -> Void) {
            calls.append("download")
        }

        func showDownloadDidReceiveExpectedContentLength(_: UInt64) {
            calls.append("length")
        }

        func showDownloadDidReceiveData(ofLength _: UInt64) {
            calls.append("data")
        }

        func showDownloadDidStartExtractingUpdate() {
            calls.append("extract")
        }

        func showExtractionReceivedProgress(_: Double) {
            calls.append("extractProgress")
        }

        func showReady(toInstallAndRelaunch _: @escaping (SPUUserUpdateChoice) -> Void) {
            calls.append("ready")
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

    @Test func checkForUpdates_duringAnUpdateInSparklesWindow_bringsThatWindowForward() {
        let harness = Harness(isInSight: false)
        harness.driver.showDownloadInitiated(cancellation: {})

        harness.driver.showUpdateInFocus()

        #expect(harness.standard.calls == ["download", "focus"])
    }

    @Test func checkForUpdates_duringAnInlineUpdate_asksTheWindowToOpenItsPopover() {
        let harness = Harness(isInSight: true)
        harness.findUpdate()
        harness.driver.showDownloadInitiated(cancellation: {})

        harness.driver.showUpdateInFocus()

        #expect(harness.model.focusRequests == 1)
        #expect(harness.standard.calls.isEmpty)
    }

    @Test func checkForUpdates_withNothingShown_asksForNothing() {
        let harness = Harness(isInSight: true)

        harness.driver.showUpdateInFocus()

        #expect(harness.model.focusRequests == 0)
        #expect(harness.standard.calls.isEmpty)
    }

    @Test func aSessionInSparklesWindow_leavesTheInlineStateIdle() {
        let harness = Harness(isInSight: false)

        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(!harness.model.showsBadge)
        harness.driver.showDownloadInitiated(cancellation: {})
        harness.driver.showDownloadDidReceiveExpectedContentLength(100)
        harness.driver.showDownloadDidReceiveData(ofLength: 50)
        harness.driver.showDownloadDidStartExtractingUpdate()
        harness.driver.showExtractionReceivedProgress(0.5)

        #expect(!harness.model.showsBadge)
        #expect(harness.standard.calls == ["checking", "download", "length", "data", "extract", "extractProgress"])
    }

    @Test func aWindowThatOpensMidSession_doesNotTakeTheSessionFromSparklesWindow() {
        let harness = Harness(isInSight: false)
        harness.driver.showDownloadInitiated(cancellation: {})

        harness.isInSight = true
        harness.driver.showDownloadDidReceiveData(ofLength: 10)
        harness.driver.showReady(toInstallAndRelaunch: { _ in })

        #expect(!harness.model.showsBadge)
        #expect(harness.standard.calls == ["download", "data", "ready"])
    }

    @Test func anInlineSessionWhoseWindowGoes_movesToSparklesWindowWithoutABadge() {
        let harness = Harness(isInSight: true)
        harness.findUpdate()
        harness.driver.showDownloadInitiated(cancellation: {})
        harness.driver.showDownloadDidStartExtractingUpdate()
        #expect(harness.model.showsBadge)

        harness.isInSight = false
        harness.driver.showReady(toInstallAndRelaunch: { _ in })

        #expect(!harness.model.showsBadge)
        #expect(harness.standard.calls == ["ready"])
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

    @Test func handingOverToSparklesWindow_settlesTheInlineCallback() {
        let harness = Harness(isInSight: true)
        var cancelCount = 0
        harness.driver.showUserInitiatedUpdateCheck(cancellation: { cancelCount += 1 })

        harness.isInSight = false
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: {})

        #expect(cancelCount == 1)
        #expect(!harness.model.showsBadge)
        #expect(harness.standard.calls == ["error"])
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
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: {})
        let callbacks = try #require(harness.errorCallbacks)

        callbacks.acknowledgement.call()
        harness.sparkleEndsTheSession()

        #expect(harness.startedChecks == 0)
    }

    @Test func aRetryLeftFromAnEarlierSession_startsNoCheck() throws {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: {})
        let earlier = try #require(harness.errorCallbacks)
        earlier.acknowledgement.call()
        harness.sparkleEndsTheSession()

        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        earlier.retry.call()
        harness.driver.updateCycleDidFinish()

        #expect(harness.startedChecks == 0)
    }

    @Test func theInstallConfirmation_namesTheVersionSparkleFound() {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        harness.findUpdate(version: "v1.2.3")
        guard case let .available(_, reply) = harness.model.state else {
            Issue.record("the update is not offered inline")
            return
        }
        reply.call(.install)

        harness.driver.showDownloadInitiated(cancellation: {})
        guard case let .downloading(downloading, _, _, _) = harness.model.state else {
            Issue.record("the download is not shown inline")
            return
        }
        #expect(downloading.displayVersion == "v1.2.3")

        harness.driver.showDownloadDidStartExtractingUpdate()
        harness.driver.showExtractionReceivedProgress(1)
        harness.driver.showReady(toInstallAndRelaunch: { _ in })

        guard case let .readyToInstall(ready, _) = harness.model.state else {
            Issue.record("the install confirmation is not shown inline")
            return
        }
        #expect(ready.displayVersion == "v1.2.3")
        #expect(harness.standard.calls.isEmpty)
    }

    @Test func anInstallStepWithNoUpdateFound_goesToSparklesWindow() {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})

        harness.driver.showReady(toInstallAndRelaunch: { _ in })

        #expect(!harness.model.showsBadge)
        #expect(harness.standard.calls == ["ready"])
    }

    @Test func theStateShown_belongsToTheSessionThatShowedIt() {
        let harness = Harness(isInSight: true)
        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})
        let first = harness.model.sessionID
        harness.sparkleEndsTheSession()
        #expect(harness.model.sessionID == nil)

        harness.driver.showUserInitiatedUpdateCheck(cancellation: {})

        #expect(first != nil)
        #expect(harness.model.sessionID != nil)
        #expect(harness.model.sessionID != first)
    }

    // MARK: - Check for Updates through the updater stack

    #if DEBUG
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

        @Test func checkForUpdates_whileUpToDateShows_runsOnceSparkleEndsThatSession() {
            let stack = makeStack()
            var acks = 0
            stack.driver.showUserInitiatedUpdateCheck(cancellation: {})
            stack.driver.showUpdateNotFoundWithError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })

            stack.checkForUpdates()
            #expect(acks == 1)
            #expect(!isOffered(stack.stateModel.state))

            sparkleEndsTheSession(of: stack)
            #expect(isOffered(stack.stateModel.state))
        }

        @Test func checkForUpdates_whileAFailureShows_runsOnceSparkleEndsThatSession() {
            let stack = makeStack()
            var acks = 0
            stack.driver.showUserInitiatedUpdateCheck(cancellation: {})
            stack.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: { acks += 1 })

            stack.checkForUpdates()
            #expect(acks == 1)
            #expect(!isOffered(stack.stateModel.state))

            sparkleEndsTheSession(of: stack)
            #expect(isOffered(stack.stateModel.state))
        }

        @Test func retry_startsItsCheckThroughTheStack() {
            let stack = makeStack()
            stack.driver.showUserInitiatedUpdateCheck(cancellation: {})
            stack.driver.showUpdaterError(CocoaError(.fileNoSuchFile), acknowledgement: {})
            guard case let .error(_, _, retry) = stack.stateModel.state else {
                Issue.record("the failure is not shown inline")
                return
            }

            retry.call()
            sparkleEndsTheSession(of: stack)

            #expect(isOffered(stack.stateModel.state))
        }

        @Test func checkForUpdates_whileARealCheckRuns_leavesItsStateToSparkle() {
            let stack = makeStack()
            var cancels = 0
            stack.driver.showUserInitiatedUpdateCheck(cancellation: { cancels += 1 })

            stack.checkForUpdates()

            guard case .checking = stack.stateModel.state else {
                Issue.record("the mock replaced a real session's state")
                return
            }
            #expect(cancels == 0)
        }

        @Test func checkForUpdates_withNoSessionOpen_runsTheMock() {
            let stack = makeStack()

            stack.checkForUpdates()

            #expect(isOffered(stack.stateModel.state))
        }
    #endif
}
