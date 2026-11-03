// WeirUpdateDriverTests.swift
// Weir — where an update session shows, and what Check for Updates does while one is shown.

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
        var isInSight: Bool
        private(set) lazy var driver = WeirUpdateDriver(
            stateModel: model,
            standard: standard,
            hasInlineTarget: { [unowned self] in isInSight }
        )

        init(isInSight: Bool) {
            self.isInSight = isInSight
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
}
